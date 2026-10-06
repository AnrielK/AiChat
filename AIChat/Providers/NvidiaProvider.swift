import Foundation

/// NVIDIA API Catalog (build.nvidia.com) – hostované NIM modely (DeepSeek, Qwen, Llama,
/// Nemotron, Kimi, GLM…) přes OpenAI-kompatibilní Chat Completions se streamováním.
///
/// Free tier pro vývojáře: bez kreditní karty, limit ~40 dotazů za minutu (podle modelu),
/// jen pro prototypování – ne pro produkční nasazení. Limit tokenů za minutu není,
/// proto se prompt přizpůsobuje jen oknu modelu a 429 se řeší čekáním.
struct NvidiaProvider: ChatProvider {
    let apiKey: String
    let model: String
    let systemPrompt: String
    let maxTokens: Int
    /// nil = výchozí teplota modelu.
    let temperature: Double?
    let reasoning: Bool

    static let baseURL = URL(string: "https://integrate.api.nvidia.com/v1")!

    /// Prodlevy (s) mezi opakováními: přetížení (5xx) a překročení limitu dotazů za minutu (429).
    /// Při 429 se čeká déle – okno limitu je minuta.
    static let overloadDelays = [3, 8, 20]
    static let rateLimitDelays = [15, 30, 60]

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let store = await CloudLimitsStore.shared
                    let model = model
                    await store.refreshModelInfo(provider: .nvidia, model: model, apiKey: apiKey)
                    let inspect: @Sendable (HTTPURLResponse, Data?) async -> Void = { response, _ in
                        await RateLimitStatusStore.shared.record(provider: .nvidia, model: model, response: response)
                    }

                    var plan = await store.plan(provider: .nvidia, model: model, requestedMaxTokens: maxTokens, adaptToTier: false)
                    var fitted = Self.fit(history, plan: plan, systemPrompt: systemPrompt)
                    var templateKwargs = true
                    var contextRetried = false
                    var overloadAttempt = 0
                    var rateAttempt = 0

                    while true {
                        var producedText = false
                        do {
                            let bytes = try await HTTPStreaming.open(
                                makeRequest(fitted.turns, plan: plan, templateKwargs: templateKwargs),
                                inspect: inspect
                            )
                            var usage = TokenUsage(
                                promptTokens: 0,
                                outputTokens: 0,
                                contextWindow: plan.effectiveWindow,
                                maxOutputTokens: plan.maxOutputTokens,
                                droppedHistory: fitted.dropped,
                                modelContextWindow: plan.modelWindow
                            )
                            continuation.yield(.usage(usage))
                            // Část modelů posílá přemýšlení v `reasoning_content`, jiné jako <think>…</think> v textu.
                            var parser = ThinkTagParser()
                            var truncated = false

                            for try await line in bytes.lines {
                                guard let event = HTTPStreaming.event(fromLine: line) else { continue }
                                if let error = event["error"] as? [String: Any] {
                                    let message = error["message"] as? String ?? "Neznámá chyba"
                                    let code = (error["code"] as? NSNumber)?.intValue ?? 0
                                    throw code >= 400 ? ProviderError.http(status: code, message: message) : ProviderError.api(message)
                                }
                                if let counts = event["usage"] as? [String: Any] {
                                    usage.promptTokens = (counts["prompt_tokens"] as? NSNumber)?.intValue ?? usage.promptTokens
                                    usage.outputTokens = (counts["completion_tokens"] as? NSNumber)?.intValue ?? usage.outputTokens
                                    continuation.yield(.usage(usage))
                                }
                                guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
                                if (choice["finish_reason"] as? String) == "length" { truncated = true }
                                guard let delta = choice["delta"] as? [String: Any] else { continue }

                                if let thought = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
                                   !thought.isEmpty {
                                    continuation.yield(.reasoning(thought))
                                }
                                if let text = delta["content"] as? String, !text.isEmpty {
                                    for item in parser.feed(text) {
                                        if case .text = item { producedText = true }
                                        continuation.yield(item)
                                    }
                                }
                            }
                            parser.flush().forEach { continuation.yield($0) }
                            if truncated {
                                continuation.yield(.text("\n\n_(Odpověď přerušena – došel limit max. délky odpovědi.)_"))
                            }
                            break
                        } catch {
                            guard !producedText, !Task.isCancelled,
                                  case .http(let status, let message)? = error as? ProviderError else {
                                if !producedText, !Task.isCancelled, HTTPStreaming.isTransient(error),
                                   overloadAttempt < Self.overloadDelays.count {
                                    try await pause(Self.overloadDelays[overloadAttempt], reason: "spojení se přerušilo", continuation)
                                    overloadAttempt += 1
                                    continue
                                }
                                throw error
                            }
                            let lower = message.lowercased()

                            // Prompt delší než okno: skutečné okno je v chybě („maximum context length is N“).
                            if status == 400, !contextRetried, let window = Self.contextLength(in: message) {
                                contextRetried = true
                                await store.recordModelInfo(provider: .nvidia, model: model, window: window)
                                plan = await store.plan(provider: .nvidia, model: model, requestedMaxTokens: maxTokens, adaptToTier: false)
                                fitted = Self.fit(history, plan: plan, systemPrompt: systemPrompt)
                                continuation.yield(.status("Prompt se nevešel do okna modelu (\(window.formatted()) tok.), zkracuji.\n"))
                                continue
                            }
                            // Model nezná chat_template_kwargs (přepínač přemýšlení) – jednou znovu bez nich.
                            if status == 400 || status == 422, templateKwargs,
                               ["template", "kwarg", "extra", "unexpected", "unrecognized", "not permitted"].contains(where: { lower.contains($0) }) {
                                templateKwargs = false
                                continue
                            }
                            // Limit dotazů za minutu (free tier ~40/min) – vícekolové zpracování ho snadno vyčerpá.
                            if status == 429, rateAttempt < Self.rateLimitDelays.count {
                                try await pause(Self.rateLimitDelays[rateAttempt], reason: "limit dotazů za minutu", continuation)
                                rateAttempt += 1
                                continue
                            }
                            if HTTPStreaming.isTransient(error), overloadAttempt < Self.overloadDelays.count {
                                try await pause(Self.overloadDelays[overloadAttempt], reason: "model je přetížený (\(status))", continuation)
                                overloadAttempt += 1
                                continue
                            }
                            if status == 429 {
                                throw ProviderError.http(status: status, message: message + "\n\nVyčerpaný limit dotazů za minutu na free tieru NVIDIA (~40/min). Zkus to za minutu.")
                            }
                            if status == 404 {
                                throw ProviderError.http(status: status, message: message + "\n\nModel \(model) na NVIDIA API není (nebo byl stažen) – vyber jiný v Nastavení › NVIDIA › Načíst modely.")
                            }
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pause(
        _ seconds: Int,
        reason: String,
        _ continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.status("\nNVIDIA: \(reason), zkouším znovu za \(seconds) s.\n"))
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    /// Chat Completions tu neumí PDF – nativně se posílají jen obrázky (u modelů s viděním),
    /// text PDF se vloží do zprávy jako u textových příloh.
    private static func fit(_ history: [ChatTurn], plan: CloudRequestPlan, systemPrompt: String) -> (turns: [ChatTurn], dropped: Bool) {
        ChatTurn.fittingCloud(
            history,
            tokenBudget: plan.inputTokenBudget,
            systemPrompt: systemPrompt,
            charactersPerToken: plan.charactersPerToken,
            keepSeparate: { $0.kind == .image }
        )
    }

    /// „…maximum context length is 131072 tokens…“ (vLLM / NIM) → 131072.
    static func contextLength(in message: String) -> Int? {
        guard let range = message.range(of: #"maximum context length is \d+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(message[range].split(separator: " ").last ?? "")
    }

    private func makeRequest(_ turns: [ChatTurn], plan: CloudRequestPlan, templateKwargs: Bool) throws -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        Self.authorize(&request, apiKey: apiKey)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty { messages.append(["role": "system", "content": systemPrompt]) }
        messages += turns.map(Self.message(for:))

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": plan.maxOutputTokens,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if let temperature { body["temperature"] = temperature }
        // Přepínač přemýšlení – DeepSeek V3.x/V4 čte `thinking`, Qwen3 `enable_thinking`.
        // Modely, které ho nemají, neznámé proměnné šablony ignorují; kdyby ne, pošle se znovu bez nich.
        if templateKwargs {
            body["chat_template_kwargs"] = ["thinking": reasoning, "enable_thinking": reasoning]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func message(for turn: ChatTurn) -> [String: Any] {
        let role = turn.role == .user ? "user" : "assistant"
        let images = turn.attachments.filter { $0.kind == .image }.compactMap { $0.nativePayload() }
        guard turn.role == .user, !images.isEmpty else { return ["role": role, "content": turn.text] }
        var parts: [[String: Any]] = images.map { payload in
            ["type": "image_url", "image_url": ["url": "data:\(payload.mimeType);base64,\(payload.base64)"]]
        }
        parts.append(["type": "text", "text": turn.text])
        return ["role": role, "content": parts]
    }

    static func authorize(_ request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    /// Okno modelu – katalog ho v /models většinou neposílá (`max_model_len` jen u některých),
    /// jinak se zjistí z první chyby „maximum context length“.
    static func modelInfo(model: String, apiKey: String) async throws -> (window: Int?, maxOutput: Int?) {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        authorize(&request, apiKey: apiKey)
        let json = try await HTTPStreaming.json(for: request)
        let item = (json["data"] as? [[String: Any]])?.first { ($0["id"] as? String) == model }
        let window = (item?["max_model_len"] as? NSNumber)?.intValue
            ?? (item?["context_length"] as? NSNumber)?.intValue
        return (window, nil)
    }

    /// Chatovací modely z katalogu (bez embeddingů, rerankerů, obrázků, řeči, guardrails…).
    static func listModels(apiKey: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        authorize(&request, apiKey: apiKey)
        let json = try await HTTPStreaming.json(for: request)
        let items = json["data"] as? [[String: Any]] ?? []
        let excluded = ["embed", "rerank", "retriever", "guard", "safety", "reward", "clip", "parse", "ocr",
                        "detector", "asr", "tts", "whisper", "riva", "flux", "stable-diffusion", "sdxl",
                        "cosmos", "nemoretriever", "pii", "translate", "kosmos", "deplot", "paligemma"]
        return items
            .compactMap { item -> RemoteModel? in
                guard let id = item["id"] as? String else { return nil }
                let lower = id.lowercased()
                guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
                return RemoteModel(id: id, name: id)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
