import Foundation
import FinFillCore

/// Most mezi FinFill (souhrn 10-K) a poskytovateli AIChat.
///
/// FinFill potřebuje jen jednorázové kolo „instrukce + text → odpověď“. Poskytovatel se
/// staví přes `SettingsStore.makeProvider` stejně jako v `SummaryPipeline`, takže souhrn běží
/// na modelu vybraném v Nastavení (lokální GGUF / MLX, Apple Intelligence i cloud).
/// Každé kolo je `oneShot()` – kusy 10-K se nemají hromadit v KV cache.
struct FinFillEngine: LLMEngine {
    let contextTokens: Int
    /// Přemýšlení vypíná poskytovatel (`reasoningOverride: false`), FinFill nepřidává `/no_think`.
    var handlesThinking: Bool { true }

    private let make: @MainActor @Sendable (_ maxTokens: Int) throws -> any ChatProvider

    /// `nil`, když nejde sestavit poskytovatele (např. není vybraný lokální model).
    @MainActor
    static func current(settings: SettingsStore, models: ModelManager) -> FinFillEngine? {
        let make: @MainActor @Sendable (Int) throws -> any ChatProvider = { maxTokens in
            try settings.makeProvider(models: models, profile: .summarize,
                                      reasoningOverride: false, maxTokensOverride: maxTokens)
        }
        guard (try? make(512)) != nil else { return nil }
        return FinFillEngine(contextTokens: contextTokens(settings: settings), make: make)
    }

    /// Stejná logika jako `SummaryPipeline`: nastavená délka kontextu je jen strop, engine ji
    /// podle paměti zkracuje. Bez skutečné hodnoty se bere opatrných 8k.
    @MainActor
    private static func contextTokens(settings: SettingsStore) -> Int {
        switch settings.provider {
        case .local:
            let cap = settings.local.summaryChunkTokens
            return min(settings.local.contextLength,
                       LocalRuntime.shared.effectiveContext ?? 8_192,
                       cap > 0 ? cap : .max)
        case .apple:
            return 4_096
        case .claude, .gemini, .openai, .nvidia:
            return 100_000
        }
    }

    func generate(system: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        let provider = try await MainActor.run { try make(maxTokens) }.oneShot()
        // Systémový prompt z Nastavení dodá poskytovatel sám; instrukce FinFillu jdou do zprávy.
        let turn = ChatTurn(role: .user, text: system + "\n\n" + prompt)
        var text = ""
        for try await event in provider.stream([turn]) {
            switch event {
            case .text(let piece): text += piece
            case .promoteTextToReasoning: text = ""
            default: break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
