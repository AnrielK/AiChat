import Foundation

/// Google Gemini API (generateContent se streamováním přes SSE).
struct GeminiProvider: ChatProvider {
    let apiKey: String
    let model: String
    let systemPrompt: String
    let maxTokens: Int
    /// nil = výchozí teplota modelu (u Gemini 3 doporučené).
    let temperature: Double?
    let reasoning: Bool
    /// Zmenšit prompt podle limitu tarifu (vstupní tokeny za minutu, u free tieru nízký).
    var adaptToTier = true
    /// Limit vstupu za minutu z vybraného tarifu / ruční hodnoty (nil = zjištěný z API).
    var tierInputPerMinute: Int?

    static let base = "https://generativelanguage.googleapis.com/v1beta"

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let store = await CloudLimitsStore.shared
                    let model = model
                    // Okno a max. odpověď modelu (endpoint models/{id}, jednou za týden).
                    await store.refreshModelInfo(provider: .gemini, model: model, apiKey: apiKey)
                    // Gemini limity tarifu neposílá v hlavičkách, jen v chybě 429 (QuotaFailure).
                    let inspect: @Sendable (HTTPURLResponse, Data?) async -> Void = { response, body in
                        // Zbývající limity Gemini neposílá – zapíše se aspoň odeslaný dotaz (počítadlo).
                        await RateLimitStatusStore.shared.record(provider: .gemini, model: model, response: response)
                        await Self.recordTier(from: body, model: model)
                    }

                    var plan = await store.plan(provider: .gemini, model: model, requestedMaxTokens: maxTokens, adaptToTier: adaptToTier, tierInputPerMinute: tierInputPerMinute)
                    var fitted = ChatTurn.fittingCloud(history, tokenBudget: plan.inputTokenBudget, systemPrompt: systemPrompt, charactersPerToken: plan.charactersPerToken)

                    // Přetížený model (503 „high demand“) bývá jen chvilkový – zkusí se znovu
                    // s rostoucí prodlevou, dokud z odpovědi ještě nic nepřišlo.
                    var attempt = 0
                    while true {
                        var producedOutput = false
                        do {
                            // Požadavek se staví až tady – čtení a base64 příloh nemá blokovat hlavní vlákno.
                            let bytes: URLSession.AsyncBytes
                            do {
                                bytes = try await HTTPStreaming.open(makeRequest(fitted.turns, plan: plan), inspect: inspect)
                            } catch let error as ProviderError {
                                // 429 kvůli velikosti promptu (typicky free tier): limit teď známe z chyby,
                                // jeden pokus s promptem zmenšeným na něj. Jinak (vyčerpaný limit) chyba.
                                guard case .http(let status, _) = error, status == 429, adaptToTier else { throw error }
                                // Skutečný limit z API má přednost před vybraným tarifem (tarif mohl být zvolen špatně).
                                let smaller = await store.plan(provider: .gemini, model: model, requestedMaxTokens: maxTokens, adaptToTier: true)
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

                                // Počty tokenů chodí v usageMetadata (průběžně, poslední kus je konečný).
                                if let metadata = event["usageMetadata"] as? [String: Any] {
                                    func count(_ key: String) -> Int { (metadata[key] as? NSNumber)?.intValue ?? 0 }
                                    usage.promptTokens = count("promptTokenCount")
                                    usage.outputTokens = count("candidatesTokenCount") + count("thoughtsTokenCount")
                                    continuation.yield(.usage(usage))
                                }

                                if let error = event["error"] as? [String: Any] {
                                    // Chyba uprostřed streamu (HTTP 200) – kód 503/UNAVAILABLE se dá zopakovat.
                                    let message = error["message"] as? String ?? "Neznámá chyba"
                                    if let code = (error["code"] as? NSNumber)?.intValue, code >= 400 {
                                        throw ProviderError.http(status: code, message: message)
                                    }
                                    if (error["status"] as? String) == "UNAVAILABLE" {
                                        throw ProviderError.http(status: 503, message: message)
                                    }
                                    throw ProviderError.api(message)
                                }
                                if let feedback = event["promptFeedback"] as? [String: Any],
                                   let reason = feedback["blockReason"] as? String {
                                    throw ProviderError.api("Gemini požadavek zablokoval (\(reason)).")
                                }
                                guard let candidates = event["candidates"] as? [[String: Any]],
                                      let content = candidates.first?["content"] as? [String: Any],
                                      let parts = content["parts"] as? [[String: Any]] else { continue }

                                for part in parts {
                                    guard let text = part["text"] as? String else { continue }
                                    // Shrnutí přemýšlení má příznak thought == true.
                                    let isThought = (part["thought"] as? Bool) == true
                                    // Jen text odpovědi brání opakování; přemýšlení se při novém pokusu
                                    // vypíše znovu, což je menší zlo než celou analýzu vzdát.
                                    if !isThought { producedOutput = true }
                                    continuation.yield(isThought ? .reasoning(text) : .text(text))
                                }
                            }
                            break
                        } catch {
                            // Když už část textu odpovědi dorazila, opakování by ho zdvojilo – chyba jde dál.
                            guard !producedOutput, !Task.isCancelled, HTTPStreaming.isTransient(error) else { throw error }
                            guard attempt < Self.retryDelays.count else { throw Self.overloaded(error, model: model, attempts: attempt + 1) }
                            let delay = Self.retryDelays[attempt]
                            attempt += 1
                            continuation.yield(.status("\nGemini (\(model)) je přetížený, zkouším znovu za \(delay) s (pokus \(attempt + 1)/\(Self.retryDelays.count + 1)).\n"))
                            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
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

    /// Prodlevy (s) mezi opakováními při přetížení – celkem ~35 s, pak se to vzdá.
    static let retryDelays = [3, 8, 20]

    /// Po vyčerpání pokusů srozumitelná hláška: chyba je u Googlu, ne v klíči ani v aplikaci.
    private static func overloaded(_ error: Error, model: String, attempts: Int) -> Error {
        guard case .http(let status, let message)? = error as? ProviderError, status == 503 else { return error }
        return ProviderError.http(
            status: status,
            message: "\(message)\n\nModel \(model) je teď přetížený na straně Googlu (zkoušeno \(attempts)×). Klíč i připojení jsou v pořádku – zkus to za chvíli, nebo přepni na jiný model (např. starší Flash nebo Pro)."
        )
    }

    /// Limit tarifu z chyby 429: `QuotaFailure.violations` s `quotaId`
    /// (…InputTokensPerModelPerMinute-FreeTier) a `quotaValue`.
    private static func recordTier(from body: Data?, model: String) async {
        guard let body, let root = try? JSONSerialization.jsonObject(with: body) else { return }
        let object = (root as? [String: Any]) ?? (root as? [[String: Any]])?.first ?? [:]
        guard let details = (object["error"] as? [String: Any])?["details"] as? [[String: Any]] else { return }

        var inputPerMinute: Int?
        var isFreeTier: Bool?
        for detail in details where (detail["@type"] as? String)?.hasSuffix("QuotaFailure") == true {
            for violation in detail["violations"] as? [[String: Any]] ?? [] {
                let id = violation["quotaId"] as? String ?? ""
                if id.contains("FreeTier") {
                    isFreeTier = true
                } else if !id.isEmpty, isFreeTier == nil {
                    isFreeTier = false
                }
                if id.contains("InputTokens"), id.contains("PerMinute") {
                    let raw = violation["quotaValue"]
                    inputPerMinute = (raw as? String).flatMap { Int($0) } ?? (raw as? NSNumber)?.intValue ?? inputPerMinute
                }
            }
        }
        guard inputPerMinute != nil || isFreeTier != nil else { return }
        await CloudLimitsStore.shared.recordTier(provider: .gemini, model: model, inputPerMinute: inputPerMinute, isFreeTier: isFreeTier)
    }

    /// Okno a max. délka odpovědi (`inputTokenLimit`, `outputTokenLimit` z endpointu models/{id}).
    static func modelInfo(model: String, apiKey: String) async throws -> (window: Int?, maxOutput: Int?) {
        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
        guard let url = URL(string: "\(base)/\(modelPath)") else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        return ((json["inputTokenLimit"] as? NSNumber)?.intValue, (json["outputTokenLimit"] as? NSNumber)?.intValue)
    }

    private func makeRequest(_ turns: [ChatTurn], plan: CloudRequestPlan) throws -> URLRequest {
        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
        guard let url = URL(string: "\(Self.base)/\(modelPath):streamGenerateContent?alt=sse") else {
            throw ProviderError.notConfigured("Neplatné ID modelu Gemini.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var config: [String: Any] = ["maxOutputTokens": plan.maxOutputTokens]
        if let temperature { config["temperature"] = temperature }
        if let thinking = thinkingConfig() { config["thinkingConfig"] = thinking }

        // Historie už prošla ChatTurn.fittingCloud: textové přílohy jsou v textu,
        // obrázky a skeny PDF zůstaly jako originály (inlineData).
        var body: [String: Any] = [
            "contents": turns.map { turn -> [String: Any] in
                var parts: [[String: Any]] = turn.attachments.compactMap { attachment -> [String: Any]? in
                    guard let payload = attachment.nativePayload() else { return nil }
                    let data: [String: Any] = ["mimeType": payload.mimeType, "data": payload.base64]
                    return ["inlineData": data]
                }
                parts.append(["text": turn.text])
                return [
                    "role": turn.role == .user ? "user" : "model",
                    "parts": parts
                ]
            },
            "generationConfig": config
        ]
        if !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Přemýšlení podle generace modelu:
    /// - Gemini 3+: `thinkingLevel` (minimal/low/medium/high); Pro neumí „minimal“, proto „low“
    /// - Gemini 2.5: `thinkingBudget` (0 = vypnuto, Pro minimálně 128, -1 = dynamicky)
    /// - starší modely přemýšlení nemají – pole se nepošle, jinak by vrátily chybu.
    func thinkingConfig() -> [String: Any]? {
        let id = model.lowercased()
        let isPro = id.contains("pro")
        let version = Self.version(of: id) ?? 3
        guard version >= 2.5 else { return nil }

        if version < 3 {
            return reasoning
                ? ["thinkingBudget": -1, "includeThoughts": true]
                : ["thinkingBudget": isPro ? 128 : 0]
        }
        return reasoning
            ? ["includeThoughts": true]
            : ["thinkingLevel": isPro ? "low" : "minimal"]
    }

    /// „gemini-3.6-flash“ → 3.6, „gemini-2.5-pro“ → 2.5, „gemini-flash-latest“ → nil.
    private static func version(of id: String) -> Double? {
        guard let range = id.range(of: #"gemini-(\d+)(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(id[range].dropFirst("gemini-".count))
    }

    /// Textové modely dostupné pro daný klíč (bez embeddingů, obrázků a řeči).
    static func listModels(apiKey: String) async throws -> [RemoteModel] {
        guard let url = URL(string: "\(base)/models?pageSize=1000") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let json = try await HTTPStreaming.json(for: request)
        let items = json["models"] as? [[String: Any]] ?? []
        let excluded = ["embedding", "image", "tts", "live", "audio", "aqa", "veo", "imagen"]

        return items.compactMap { item -> RemoteModel? in
            guard let name = item["name"] as? String,
                  let methods = item["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            guard id.contains("gemini"), !excluded.contains(where: { id.contains($0) }) else { return nil }
            return RemoteModel(id: id, name: item["displayName"] as? String ?? id)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }
    }
}
