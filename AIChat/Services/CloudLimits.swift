import Foundation
import Observation

/// Co model a účet dovolí.
/// - okno a max. délka odpovědi: Models API (Claude `max_input_tokens` / `max_tokens`,
///   Gemini `inputTokenLimit` / `outputTokenLimit`),
/// - limity tarifu za minutu: Claude je posílá v hlavičkách každé odpovědi
///   (`anthropic-ratelimit-*`), Gemini jen v chybě 429 (QuotaFailure, včetně „FreeTier“).
struct CloudLimits: Codable, Equatable, Sendable {
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var inputTokensPerMinute: Int?
    var outputTokensPerMinute: Int?
    var requestsPerMinute: Int?
    /// Gemini: projekt je na free tieru (nil = zatím nevíme).
    var isFreeTier: Bool?
    var modelInfoDate: Date?
    var tierDate: Date?
}

/// Parametry jednoho požadavku odvozené z limitů.
struct CloudRequestPlan: Sendable {
    /// max_tokens / maxOutputTokens – nejvýš kolik model dovolí.
    let maxOutputTokens: Int
    /// Kolik tokenů smí mít prompt (systémový prompt, historie, přílohy).
    let inputTokenBudget: Int
    /// Okno modelu podle Models API (nebo výchozí odhad).
    let modelWindow: Int
    /// Prompt omezuje tarif (tokeny za minutu), ne okno modelu.
    let limitedByTier: Bool
    /// Odhad znaků na token pro češtinu – Claude 5 má nový tokenizér (~30 % tokenů navíc).
    let charactersPerToken: Double

    /// Kolik tokenů může konverzace zabrat – pro ukazatel kontextu.
    var effectiveWindow: Int { limitedByTier ? inputTokenBudget : modelWindow }
}

@MainActor
@Observable
final class CloudLimitsStore {
    static let shared = CloudLimitsStore()

    private(set) var all: [String: CloudLimits] = [:]
    private static let defaultsKey = "cloudLimits"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: CloudLimits].self, from: data) {
            all = decoded
        }
    }

    private static func key(_ provider: AIProvider, _ model: String) -> String {
        provider.rawValue + ":" + model
    }

    func limits(for provider: AIProvider, model: String) -> CloudLimits {
        all[Self.key(provider, model)] ?? CloudLimits()
    }

    private func modify(_ provider: AIProvider, _ model: String, _ change: (inout CloudLimits) -> Void) {
        var value = self.limits(for: provider, model: model)
        change(&value)
        guard value != all[Self.key(provider, model)] else { return }
        all[Self.key(provider, model)] = value
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Zápis

    /// Limity tarifu za minutu (z hlaviček nebo z chyby 429). nil hodnoty nic nepřepíšou.
    func recordTier(
        provider: AIProvider,
        model: String,
        inputPerMinute: Int? = nil,
        outputPerMinute: Int? = nil,
        requestsPerMinute: Int? = nil,
        isFreeTier: Bool? = nil
    ) {
        modify(provider, model) { limits in
            if let inputPerMinute, inputPerMinute > 0 { limits.inputTokensPerMinute = inputPerMinute }
            if let outputPerMinute, outputPerMinute > 0 { limits.outputTokensPerMinute = outputPerMinute }
            if let requestsPerMinute, requestsPerMinute > 0 { limits.requestsPerMinute = requestsPerMinute }
            if let isFreeTier { limits.isFreeTier = isFreeTier }
            limits.tierDate = .now
        }
    }

    /// Okno a max. odpověď z Models API – když chybí nebo jsou starší než týden (`force` = vždy).
    func refreshModelInfo(provider: AIProvider, model: String, apiKey: String, force: Bool = false) async {
        let current = self.limits(for: provider, model: model)
        if !force, let date = current.modelInfoDate, date.timeIntervalSinceNow > -7 * 86_400 { return }
        let info: (window: Int?, maxOutput: Int?)?
        switch provider {
        case .claude: info = try? await ClaudeProvider.modelInfo(model: model, apiKey: apiKey)
        case .gemini: info = try? await GeminiProvider.modelInfo(model: model, apiKey: apiKey)
        case .openai: info = try? await OpenAIProvider.modelInfo(model: model, apiKey: apiKey)
        case .nvidia: info = try? await NvidiaProvider.modelInfo(model: model, apiKey: apiKey)
        default: info = nil
        }
        guard let info, info.window != nil || info.maxOutput != nil else { return }
        modify(provider, model) { limits in
            limits.contextWindow = info.window ?? limits.contextWindow
            limits.maxOutputTokens = info.maxOutput ?? limits.maxOutputTokens
            limits.modelInfoDate = .now
        }
    }

    /// Okno zjištěné jinak než z Models API (NVIDIA: z chyby „maximum context length“).
    func recordModelInfo(provider: AIProvider, model: String, window: Int?, maxOutput: Int? = nil) {
        modify(provider, model) { limits in
            if let window, window > 0 { limits.contextWindow = window }
            if let maxOutput, maxOutput > 0 { limits.maxOutputTokens = maxOutput }
            limits.modelInfoDate = .now
        }
    }

    /// Zapomene zjištěný tarif (po přechodu na vyšší tarif se limity načtou znovu).
    func resetTier(provider: AIProvider, model: String) {
        modify(provider, model) { limits in
            limits.inputTokensPerMinute = nil
            limits.outputTokensPerMinute = nil
            limits.requestsPerMinute = nil
            limits.isFreeTier = nil
            limits.tierDate = nil
        }
    }

    // MARK: - Plán požadavku

    /// Parametry pro další požadavek.
    /// - max. odpověď nepřesáhne limit modelu (Claude by jinak vrátil chybu 400),
    /// - prompt se vejde do okna (u Claude okno zahrnuje i odpověď),
    /// - s `adaptToTier` se prompt vejde i do limitu vstupních tokenů za minutu – větší
    ///   požadavek by tarif odmítl vždy (429), ať se čeká jakkoli dlouho.
    /// `tierInputPerMinute`: limit z vybraného tarifu nebo ruční hodnota; nil = zjištěný z API.
    func plan(
        provider: AIProvider,
        model: String,
        requestedMaxTokens: Int,
        adaptToTier: Bool,
        tierInputPerMinute: Int? = nil
    ) -> CloudRequestPlan {
        let known = self.limits(for: provider, model: model)
        let fallbackWindow: Int = switch provider {
        case .claude: 200_000
        case .openai: OpenAIProvider.knownLimits(model: model).window ?? 128_000
        // Katalog NVIDIA okno neposílá; 128k má většina modelů, menší okno se zjistí z chyby.
        case .nvidia: 128_000
        default: 1_048_576
        }
        let window = known.contextWindow ?? fallbackWindow
        var maxOutput = max(256, min(requestedMaxTokens, known.maxOutputTokens ?? requestedMaxTokens))
        let perMinuteCandidates = [tierInputPerMinute, known.inputTokensPerMinute].compactMap { $0 }.filter { $0 > 0 }
        // OpenAI počítá do limitu za minutu prompt + max_output_tokens. Na free tieru (10k TPM
        // u GPT-6 Sol) by 8k odpovědi nechalo na prompt jen pár set tokenů – odpověď max. na půl limitu.
        if provider == .openai, adaptToTier, let perMinute = perMinuteCandidates.min() {
            maxOutput = max(256, min(maxOutput, perMinute / 2))
        }

        // Claude, OpenAI i NVIDIA (vLLM) počítají do okna i odpověď, Gemini má limit vstupu zvlášť.
        var input = provider == .gemini ? window : max(4_000, window - maxOutput)
        var limitedByTier = false
        // Vybraný tarif i hodnota zjištěná z API – platí nižší (API ví, co opravdu platí;
        // po přechodu na vyšší tarif se zjištěná hodnota obnoví z hlaviček / „Znovu zjistit limity“).
        if adaptToTier, let perMinute = perMinuteCandidates.min() {
            // 10 % rezerva: odhad tokenů ze znaků není přesný.
            // OpenAI do limitu za minutu započítá i max_output_tokens požadavku.
            let tierBudget = (provider == .openai ? perMinute - maxOutput : perMinute) * 9 / 10
            if tierBudget < input {
                input = max(1_000, tierBudget)
                limitedByTier = true
            }
        }
        return CloudRequestPlan(
            maxOutputTokens: maxOutput,
            inputTokenBudget: input,
            modelWindow: window,
            limitedByTier: limitedByTier,
            charactersPerToken: provider == .claude ? 2.0 : 2.5
        )
    }
}

extension ChatTurn {
    /// Historie pro cloudový model tak, aby se vešla do `tokenBudget`:
    /// textové přílohy se vloží do textu (zkrácené podle rozpočtu), obrázky a skeny PDF
    /// zůstanou jako originály a nejstarší výměny se vynechají, když se nevejdou ani texty.
    static func fittingCloud(
        _ history: [ChatTurn],
        tokenBudget: Int,
        systemPrompt: String,
        charactersPerToken: Double = 2.5,
        keepSeparate: (Attachment) -> Bool = { $0.sendsNatively }
    ) -> (turns: [ChatTurn], dropped: Bool) {
        // Originály stojí tokeny i bez textu: obrázek ~1 600, strana PDF ~2 000.
        let nativeTokens = history.flatMap(\.attachments).filter { keepSeparate($0) && $0.sendsNatively }.reduce(0) { total, file in
            total + (file.kind == .image ? 1_600 : 2_000 * (file.pageCount ?? 1))
        }
        // Raději méně znaků na token než překročit limit (čeština tokenizuje hůř než angličtina).
        let characterBudget = max(2_000, Int(Double(tokenBudget - nativeTokens) * charactersPerToken) - systemPrompt.count)

        var turns = inliningAttachments(history, characterBudget: characterBudget, keepSeparate: { keepSeparate($0) && $0.sendsNatively })
        var dropped = false
        while turns.count > 1, turns.reduce(0, { $0 + $1.text.count }) > characterBudget {
            turns.removeFirst(min(2, turns.count - 1))
            while turns.count > 1, turns.first?.role == .assistant { turns.removeFirst() }
            dropped = true
        }
        return (turns, dropped)
    }
}
