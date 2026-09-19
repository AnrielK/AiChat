import Foundation

/// Anthropic Messages API se streamováním.
struct ClaudeProvider: ChatProvider {
    let apiKey: String
    let model: String
    let systemPrompt: String
    let maxTokens: Int
    let reasoning: Bool
    /// Zmenšit prompt podle limitu tarifu (vstupní tokeny za minutu).
    var adaptToTier = true
    /// Limit vstupu za minutu z vybraného tarifu / ruční hodnoty (nil = zjištěný z API).
    var tierInputPerMinute: Int?

    static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    static let apiVersion = "2023-06-01"

    /// Co model umí s přemýšlením – odvozeno z verze v ID (claude-sonnet-4-5-…, claude-opus-5, claude-fable-5-1).
    ///
    /// - 5.x: přemýšlí automaticky, vypíná se `{"type": "disabled"}`
    /// - Fable / Mythos: přemýšlení vypnout nejde (`disabled` vrací 400)
    /// - 4.6–4.8: adaptivní přemýšlení, bez parametru je vypnuté
    /// - 3.7–4.5: jen starší režim s pevným rozpočtem `budget_tokens`
    /// Teplotu Claude od 4.7 nepřijímá vůbec, proto se neposílá nikdy.
    struct Capabilities {
        let version: Double
        let alwaysThinks: Bool

        init(model: String) {
            let id = model.lowercased()
            alwaysThinks = id.contains("fable") || id.contains("mythos")

            var numbers: [Int] = []
            for part in id.split(separator: "-") {
                if part.count <= 2, let number = Int(part) {
                    numbers.append(number)
                    if numbers.count == 2 { break }
                } else if !numbers.isEmpty {
                    break
                }
            }
            if let major = numbers.first {
                version = Double(major) + Double(numbers.count > 1 ? numbers[1] : 0) / 10
            } else {
                version = 5 // neznámé ID = počítej s nejnovějším API
            }
        }

        var supportsThinking: Bool { alwaysThinks || version >= 3.7 }
        var supportsAdaptive: Bool { alwaysThinks || version >= 4.6 }
        var thinksByDefault: Bool { alwaysThinks || version >= 5 }
    }

    /// Hodnota pole `thinking` v požadavku (nil = pole vynechat).
    func thinkingConfig(maxTokens requested: Int? = nil) -> [String: Any]? {
        let maxTokens = requested ?? self.maxTokens
        let caps = Capabilities(model: model)
        let adaptive: [String: Any] = ["type": "adaptive", "display": "summarized"]

        if caps.alwaysThinks {
            // Vypnout nejde; bez pole model přemýšlí dál, jen text přemýšlení nevrátí.
            return reasoning ? adaptive : nil
        }
        if caps.version >= 5 {
            return reasoning ? adaptive : ["type": "disabled"]
        }
        if caps.supportsAdaptive {
            return reasoning ? adaptive : nil
        }
        if caps.supportsThinking, reasoning, maxTokens > 2048 {
            // budget_tokens musí být aspoň 1024 a menší než max_tokens.
            return ["type": "enabled", "budget_tokens": max(1024, min(maxTokens / 2, 16_000))]
        }
        return nil
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let store = await CloudLimitsStore.shared
                    let model = model
                    // Okno a max. odpověď modelu (Models API, jednou za týden).
                    await store.refreshModelInfo(provider: .claude, model: model, apiKey: apiKey)
                    // Limity tarifu jsou v hlavičkách každé odpovědi, i chybové 429.
                    let inspect: @Sendable (HTTPURLResponse, Data?) async -> Void = { response, _ in
                        await Self.recordTier(from: response, model: model)
                    }

                    var plan = await store.plan(provider: .claude, model: model, requestedMaxTokens: maxTokens, adaptToTier: adaptToTier, tierInputPerMinute: tierInputPerMinute)
                    var fitted = ChatTurn.fittingCloud(history, tokenBudget: plan.inputTokenBudget, systemPrompt: systemPrompt, charactersPerToken: plan.charactersPerToken)

                    // Požadavek se staví až tady – čtení a base64 příloh nemá blokovat hlavní vlákno.
                    let bytes: URLSession.AsyncBytes
                    do {
                        bytes = try await HTTPStreaming.open(makeRequest(fitted.turns, plan: plan), inspect: inspect)
                    } catch let error as ProviderError {
                        // 429 kvůli velikosti promptu: limit tarifu teď známe z hlaviček,
                        // jeden pokus s promptem zmenšeným na něj. Jinak (vyčerpaný limit) chyba.
                        guard case .http(let status, _) = error, status == 429, adaptToTier else { throw error }
                        // Skutečný limit z API má přednost před vybraným tarifem (tarif mohl být zvolen špatně).
                        let smaller = await store.plan(provider: .claude, model: model, requestedMaxTokens: maxTokens, adaptToTier: true)
                        guard smaller.inputTokenBudget < plan.inputTokenBudget else { throw error }
                        plan = smaller
                        fitted = ChatTurn.fittingCloud(history, tokenBudget: plan.inputTokenBudget, systemPrompt: systemPrompt, charactersPerToken: plan.charactersPerToken)
                        bytes = try await HTTPStreaming.open(makeRequest(fitted.turns, plan: plan), inspect: inspect)
                    }

                    var usage = TokenUsage(
                        promptTokens: 0,
                        outputTokens: 0,
                        contextWindow: plan.effectiveWindow,
                        maxOutputTokens: plan.maxOutputTokens,
                        droppedHistory: fitted.dropped,
                        modelContextWindow: plan.modelWindow
                    )
                    for try await line in bytes.lines {
                        guard let event = HTTPStreaming.event(fromLine: line) else { continue }
                        switch event["type"] as? String {
                        case "message_start":
                            // Vstup = nové + zapsané do cache + přečtené z cache.
                            let counts = (event["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
                            usage.promptTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                                .reduce(0) { $0 + ((counts[$1] as? NSNumber)?.intValue ?? 0) }
                            usage.outputTokens = (counts["output_tokens"] as? NSNumber)?.intValue ?? 0
                            continuation.yield(.usage(usage))
                        case "message_delta":
                            // output_tokens je kumulativní.
                            if let output = ((event["usage"] as? [String: Any])?["output_tokens"] as? NSNumber)?.intValue {
                                usage.outputTokens = output
                                continuation.yield(.usage(usage))
                            }
                        case "content_block_delta":
                            guard let delta = event["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let text = delta["text"] as? String { continuation.yield(.text(text)) }
                            case "thinking_delta":
                                if let text = delta["thinking"] as? String { continuation.yield(.reasoning(text)) }
                            default:
                                break
                            }
                        case "error":
                            let error = event["error"] as? [String: Any]
                            throw ProviderError.api(error?["message"] as? String ?? "Neznámá chyba")
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

    /// Limity tarifu z hlaviček `anthropic-ratelimit-*` (za minutu, pro rodinu modelů).
    private static func recordTier(from response: HTTPURLResponse, model: String) async {
        func value(_ name: String) -> Int? {
            response.value(forHTTPHeaderField: name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        let input = value("anthropic-ratelimit-input-tokens-limit")
        let output = value("anthropic-ratelimit-output-tokens-limit")
        let requests = value("anthropic-ratelimit-requests-limit")
        guard input != nil || output != nil || requests != nil else { return }
        await CloudLimitsStore.shared.recordTier(
            provider: .claude,
            model: model,
            inputPerMinute: input,
            outputPerMinute: output,
            requestsPerMinute: requests
        )
    }

    private func makeRequest(_ turns: [ChatTurn], plan: CloudRequestPlan) throws -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        Self.authorize(&request, apiKey: apiKey)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": plan.maxOutputTokens,
            "stream": true,
            "messages": Self.messages(for: turns)
        ]
        if !systemPrompt.isEmpty { body["system"] = systemPrompt }
        if let thinking = thinkingConfig(maxTokens: plan.maxOutputTokens) { body["thinking"] = thinking }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Historie už prošla `ChatTurn.fittingCloud`: textové přílohy jsou v textu,
    /// obrázky a skeny PDF zůstaly jako bloky `image` / `document`.
    static func messages(for turns: [ChatTurn]) -> [[String: Any]] {
        turns.map { turn -> [String: Any] in
            guard turn.role == .user, !turn.attachments.isEmpty else {
                return ["role": turn.role.rawValue, "content": turn.text]
            }
            var blocks: [[String: Any]] = turn.attachments.compactMap { attachment -> [String: Any]? in
                guard let payload = attachment.nativePayload() else { return nil }
                let source: [String: Any] = ["type": "base64", "media_type": payload.mimeType, "data": payload.base64]
                return ["type": attachment.kind == .image ? "image" : "document", "source": source]
            }
            blocks.append(["type": "text", "text": turn.text])
            return ["role": "user", "content": blocks]
        }
    }

    static func authorize(_ request: inout URLRequest, apiKey: String) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
    }

    /// Okno a max. délka odpovědi modelu (`max_input_tokens`, `max_tokens` z Models API).
    static func modelInfo(model: String, apiKey: String) async throws -> (window: Int?, maxOutput: Int?) {
        var request = URLRequest(url: baseURL.appending(path: "models").appending(path: model))
        authorize(&request, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        return ((json["max_input_tokens"] as? NSNumber)?.intValue, (json["max_tokens"] as? NSNumber)?.intValue)
    }

    /// Seznam modelů dostupných pro daný klíč.
    static func listModels(apiKey: String) async throws -> [RemoteModel] {
        let url = baseURL.appending(path: "models").appending(queryItems: [URLQueryItem(name: "limit", value: "100")])
        var request = URLRequest(url: url)
        authorize(&request, apiKey: apiKey)
        let json = try await HTTPStreaming.json(for: request)
        let items = json["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return RemoteModel(id: id, name: item["display_name"] as? String ?? id)
        }
    }
}
