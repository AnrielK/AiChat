import Foundation

/// OpenAI (ChatGPT) přes Responses API se streamováním.
///
/// Responses API místo starších Chat Completions: jen tady model vrací shrnutí přemýšlení
/// (`reasoning.summary`) a nejnovější modely (GPT-6) jsou dělané primárně pro něj.
struct OpenAIProvider: ChatProvider {
    let apiKey: String
    let model: String
    let systemPrompt: String
    let maxTokens: Int
    /// Jen modely bez přemýšlení (GPT-4.x) – přemýšlející modely vlastní teplotu nepřijímají.
    let temperature: Double?
    let reasoning: Bool
    /// Zmenšit prompt podle limitu tarifu (tokeny za minutu).
    var adaptToTier = true
    /// Ruční limit tokenů za minutu (nil = zjištěný z hlaviček API).
    var tierInputPerMinute: Int?

    static let baseURL = URL(string: "https://api.openai.com/v1")!

    /// Co model umí s přemýšlením – odvozeno z ID.
    ///
    /// - GPT-6 Sol / Luna, GPT-5.1 a novější: úsilí `none` … `max`, `none` = bez přemýšlení
    /// - GPT-6 Astra: `none` neumí, nejméně `low`
    /// - GPT-5 (první generace, i mini / nano): nejméně `minimal`
    /// - o1 / o3 / o4: nejméně `low`
    /// - GPT-4.x a starší: nepřemýšlí, parametr `reasoning` se neposílá, teplota ano
    struct Capabilities {
        let isReasoning: Bool
        /// Nejnižší úsilí – použije se při vypnutém přemýšlení (nil = parametr vynechat).
        let lowestEffort: String?

        init(model: String) {
            let id = model.lowercased()
            if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.contains("astra") {
                isReasoning = true
                lowestEffort = "low"
            } else if id.hasPrefix("gpt-5") {
                let reasons = !id.contains("chat")
                // gpt-5, gpt-5-mini, gpt-5-nano, gpt-5-2025-… (první generace) znají jen `minimal`.
                let rest = id.dropFirst("gpt-5".count)
                let firstGeneration = rest.isEmpty || rest.hasPrefix("-")
                isReasoning = reasons
                lowestEffort = reasons ? (firstGeneration ? "minimal" : "none") : nil
            } else if id.hasPrefix("gpt-4") || id.hasPrefix("gpt-3") || id.hasPrefix("chatgpt-4") {
                isReasoning = false
                lowestEffort = nil
            } else {
                // GPT-6 a novější (neznámé ID = počítej s nejnovějším API).
                isReasoning = true
                lowestEffort = "none"
            }
        }
    }

    /// Okno a max. odpověď podle ID. Models API OpenAI je nevrací (jen id a vlastníka),
    /// takže tabulka podle dokumentace (září 2026). nil = neznámé, použije se opatrný odhad.
    static func knownLimits(model: String) -> (window: Int?, maxOutput: Int?) {
        let id = model.lowercased()
        if id.hasPrefix("gpt-6") { return (1_050_000, 128_000) }
        if id.hasPrefix("gpt-5.") {
            // GPT-5.4 a novější mají okno 1,05M, 5.1–5.3 400k.
            let minor = Int(id.dropFirst("gpt-5.".count).prefix { $0.isNumber }) ?? 0
            return (minor >= 4 ? 1_050_000 : 400_000, 128_000)
        }
        if id.hasPrefix("gpt-5") { return id.contains("chat") ? (128_000, 16_384) : (400_000, 128_000) }
        if id.hasPrefix("gpt-4.1") { return (1_047_576, 32_768) }
        if id.hasPrefix("gpt-4o") || id.hasPrefix("chatgpt-4o") { return (128_000, 16_384) }
        if id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("o1") { return (200_000, 100_000) }
        return (nil, nil)
    }

    /// Hodnota pole `reasoning` (nil = vynechat). `summary: auto` = shrnutí přemýšlení do UI.
    func reasoningConfig(summaries: Bool) -> [String: Any]? {
        let caps = Capabilities(model: model)
        guard caps.isReasoning else { return nil }
        if reasoning {
            // Úsilí nechá na výchozí hodnotě modelu (u většiny `medium`).
            return summaries ? ["summary": "auto"] : nil
        }
        return caps.lowestEffort.map { ["effort": $0] }
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let store = await CloudLimitsStore.shared
                    let model = model
                    await store.refreshModelInfo(provider: .openai, model: model, apiKey: apiKey)
                    // Limity tarifu jsou v hlavičkách každé odpovědi (x-ratelimit-*).
                    let inspect: @Sendable (HTTPURLResponse, Data?) async -> Void = { response, _ in
                        await Self.recordTier(from: response, model: model)
                    }

                    var plan = await store.plan(provider: .openai, model: model, requestedMaxTokens: maxTokens, adaptToTier: adaptToTier, tierInputPerMinute: tierInputPerMinute)
                    var fitted = ChatTurn.fittingCloud(history, tokenBudget: plan.inputTokenBudget, systemPrompt: systemPrompt, charactersPerToken: plan.charactersPerToken)
                    var summaries = true

                    let bytes: URLSession.AsyncBytes
                    do {
                        bytes = try await HTTPStreaming.open(makeRequest(fitted.turns, plan: plan, summaries: summaries), inspect: inspect)
                    } catch let error as ProviderError {
                        guard case .http(let status, let message) = error else { throw error }
                        if status == 400, reasoning, message.lowercased().contains("verif") {
                            // Shrnutí přemýšlení u nejnovějších modelů vyžaduje ověřenou organizaci –
                            // bez ověření se odpoví bez nich (model přemýšlí dál, jen text neukáže).
                            summaries = false
                        } else if status == 429, adaptToTier {
                            // Prompt větší než limit tarifu: limit teď známe z hlaviček, jeden pokus s menším.
                            let smaller = await store.plan(provider: .openai, model: model, requestedMaxTokens: maxTokens, adaptToTier: true)
                            guard smaller.inputTokenBudget < plan.inputTokenBudget else { throw error }
                            plan = smaller
                            fitted = ChatTurn.fittingCloud(history, tokenBudget: plan.inputTokenBudget, systemPrompt: systemPrompt, charactersPerToken: plan.charactersPerToken)
                        } else {
                            throw error
                        }
                        bytes = try await HTTPStreaming.open(makeRequest(fitted.turns, plan: plan, summaries: summaries), inspect: inspect)
                    }

                    var usage = TokenUsage(
                        promptTokens: 0,
                        outputTokens: 0,
                        contextWindow: plan.effectiveWindow,
                        maxOutputTokens: plan.maxOutputTokens,
                        droppedHistory: fitted.dropped,
                        modelContextWindow: plan.modelWindow
                    )
                    // Odstavce shrnutí přemýšlení (každá část summary) oddělit prázdným řádkem.
                    var lastSummaryIndex: Int?

                    for try await line in bytes.lines {
                        guard let event = HTTPStreaming.event(fromLine: line),
                              let type = event["type"] as? String else { continue }
                        switch type {
                        case "response.output_text.delta":
                            if let text = event["delta"] as? String { continuation.yield(.text(text)) }
                        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta", "response.reasoning_text.delta":
                            guard let text = event["delta"] as? String else { continue }
                            let index = (event["summary_index"] as? NSNumber)?.intValue
                            if let index, let last = lastSummaryIndex, index != last {
                                continuation.yield(.reasoning("\n\n"))
                            }
                            if index != nil { lastSummaryIndex = index }
                            continuation.yield(.reasoning(text))
                        case "response.completed", "response.incomplete":
                            let response = event["response"] as? [String: Any]
                            if let counts = response?["usage"] as? [String: Any] {
                                usage.promptTokens = (counts["input_tokens"] as? NSNumber)?.intValue ?? usage.promptTokens
                                usage.outputTokens = (counts["output_tokens"] as? NSNumber)?.intValue ?? usage.outputTokens
                                continuation.yield(.usage(usage))
                            }
                            if type == "response.incomplete",
                               let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String,
                               reason == "max_output_tokens" {
                                continuation.yield(.text("\n\n_(Odpověď přerušena – došel limit max. délky odpovědi.)_"))
                            }
                        case "response.failed":
                            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                            throw ProviderError.api(error?["message"] as? String ?? "Odpověď se nepodařila.")
                        case "error":
                            let nested = event["error"] as? [String: Any]
                            let message = event["message"] as? String ?? nested?["message"] as? String
                            throw ProviderError.api(message ?? "Neznámá chyba")
                        default:
                            break
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

    /// Limity tarifu z hlaviček. OpenAI má jeden limit tokenů za minutu (vstup + odhad výstupu),
    /// ten se bere jako limit vstupu.
    private static func recordTier(from response: HTTPURLResponse, model: String) async {
        await RateLimitStatusStore.shared.record(provider: .openai, model: model, response: response)
        func value(_ name: String) -> Int? {
            response.value(forHTTPHeaderField: name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        let tokens = [value("x-ratelimit-limit-tokens"), value("x-ratelimit-limit-project-tokens")]
            .compactMap { $0 }.filter { $0 > 0 }.min()
        let requests = value("x-ratelimit-limit-requests")
        guard tokens != nil || requests != nil else { return }
        await CloudLimitsStore.shared.recordTier(
            provider: .openai,
            model: model,
            inputPerMinute: tokens,
            requestsPerMinute: requests
        )
    }

    private func makeRequest(_ turns: [ChatTurn], plan: CloudRequestPlan, summaries: Bool) throws -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        Self.authorize(&request, apiKey: apiKey)

        var body: [String: Any] = [
            "model": model,
            "max_output_tokens": plan.maxOutputTokens,
            "stream": true,
            // Konverzaci drží appka – na serveru OpenAI se neukládá.
            "store": false,
            "input": Self.input(for: turns)
        ]
        if !systemPrompt.isEmpty { body["instructions"] = systemPrompt }
        if let config = reasoningConfig(summaries: summaries) { body["reasoning"] = config }
        if let temperature, !Capabilities(model: model).isReasoning { body["temperature"] = temperature }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Historie už prošla `ChatTurn.fittingCloud`: textové přílohy jsou v textu,
    /// obrázky a PDF zůstaly jako originály (`input_image` / `input_file`).
    static func input(for turns: [ChatTurn]) -> [[String: Any]] {
        turns.map { turn -> [String: Any] in
            guard turn.role == .user, !turn.attachments.isEmpty else {
                return ["role": turn.role.rawValue, "content": turn.text]
            }
            var parts: [[String: Any]] = turn.attachments.compactMap { attachment -> [String: Any]? in
                guard let payload = attachment.nativePayload() else { return nil }
                let dataURL = "data:\(payload.mimeType);base64,\(payload.base64)"
                if attachment.kind == .image {
                    return ["type": "input_image", "image_url": dataURL]
                }
                return ["type": "input_file", "filename": attachment.name, "file_data": dataURL]
            }
            parts.append(["type": "input_text", "text": turn.text])
            return ["role": "user", "content": parts]
        }
    }

    static func authorize(_ request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    /// Okno a max. odpověď – Models API je nezná, bere se tabulka podle ID.
    static func modelInfo(model: String, apiKey: String) async throws -> (window: Int?, maxOutput: Int?) {
        knownLimits(model: model)
    }

    /// Modely pro chat dostupné pro daný klíč (bez embeddingů, obrázků, zvuku, moderace…).
    static func listModels(apiKey: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        authorize(&request, apiKey: apiKey)
        let json = try await HTTPStreaming.json(for: request)
        let items = json["data"] as? [[String: Any]] ?? []
        let excluded = ["embedding", "image", "audio", "realtime", "live", "tts", "transcribe", "whisper",
                        "moderation", "dall-e", "search", "davinci", "babbage", "instruct", "codex", "sora", "computer-use"]
        return items
            .compactMap { item -> (RemoteModel, Double)? in
                guard let id = item["id"] as? String else { return nil }
                let lower = id.lowercased()
                guard lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("chatgpt"),
                      !excluded.contains(where: { lower.contains($0) }) else { return nil }
                return (RemoteModel(id: id, name: id), (item["created"] as? NSNumber)?.doubleValue ?? 0)
            }
            .sorted { $0.1 > $1.1 }   // nejnovější nahoře
            .map(\.0)
    }
}
