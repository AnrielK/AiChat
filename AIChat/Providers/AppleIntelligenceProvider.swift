import Foundation
import FoundationModels

/// Vestavěný model Apple Intelligence (framework FoundationModels, iOS 26).
/// Nic se nestahuje, běží offline. Kontext má jen ~4 000 tokenů, proto se posílá zkrácená historie.
///
/// Model umí jen pevný seznam jazyků (čeština v něm zatím není). Když dostane prompt
/// v nepodporovaném jazyce – nebo pokyn „odpovídej česky“ – vyhodí
/// `GenerationError.unsupportedLanguageOrLocale`. Proto se rámec promptu i výchozí
/// instrukce staví anglicky a chyba se překládá do srozumitelné hlášky.
struct AppleIntelligenceProvider: ChatProvider {
    let instructions: String
    let temperature: Double
    let maxTokens: Int

    /// Anglický systémový prompt pro případ, že jazyk zařízení model nepodporuje.
    static let englishFallbackInstructions = "You are a helpful assistant. Answer concisely and to the point."

    /// nil = model je připravený. Jazyk se tu neřeší – blokuje jen nedostupnost modelu.
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "Toto zařízení Apple Intelligence nepodporuje."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Zapni Apple Intelligence v Nastavení systému."
        case .unavailable(.modelNotReady):
            return "Model Apple Intelligence se ještě stahuje, zkus to za chvíli."
        case .unavailable:
            return "Apple Intelligence teď není dostupná."
        @unknown default:
            return "Apple Intelligence teď není dostupná."
        }
    }

    /// Podporuje model jazyk zařízení? `supportsLocale` počítá i s fallbacky regionů.
    static var supportsCurrentLocale: Bool {
        SystemLanguageModel.default.supportsLocale(Locale.current)
    }

    /// Lokalizované názvy jazyků, které model umí – seznam se mezi verzemi iOS mění,
    /// proto se čte za běhu a nikde se nedrží natvrdo.
    static var supportedLanguageNames: [String] {
        let names = SystemLanguageModel.default.supportedLanguages.compactMap { language -> String? in
            guard let code = language.languageCode?.identifier else { return nil }
            return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized
        }
        return Set(names).sorted()
    }

    /// nil = vše v pořádku. Jinak upozornění do Nastavení (model jde použít, ale jen anglicky apod.).
    static var languageNotice: String? {
        guard availabilityMessage == nil, !supportsCurrentLocale else { return nil }
        return unsupportedLanguageMessage
    }

    static var unsupportedLanguageMessage: String {
        let languages = supportedLanguageNames
        let list = languages.isEmpty ? "angličtinu a několik dalších jazyků" : languages.joined(separator: ", ")
        return "Apple Intelligence neumí češtinu – piš tomuto modelu anglicky. Podporované jazyky: \(list)."
    }

    /// Když model jazyk zařízení neumí, český systémový prompt by generování shodil hned
    /// na první zprávě (i kdyby uživatel psal anglicky). Nahradí se anglickým.
    private var effectiveInstructions: String {
        guard !Self.supportsCurrentLocale else { return instructions }
        return Self.englishFallbackInstructions
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        // Kontext má ~4 000 tokenů – přílohy dostanou, co zbude z ~6 000 znaků.
        let prompt = Self.prompt(from: ChatTurn.inliningAttachments(history, characterBudget: 6_000))
        let instructions = effectiveInstructions
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let message = Self.availabilityMessage {
                        throw ProviderError.unavailable(message)
                    }
                    let session = LanguageModelSession(instructions: instructions)
                    // FoundationModels počet tokenů neprozradí – odhad ~3 znaky na token.
                    var usage = TokenUsage(
                        promptTokens: (instructions.count + prompt.count) / 3,
                        outputTokens: 0,
                        contextWindow: 4096,
                        maxOutputTokens: options.maximumResponseTokens,
                        isEstimate: true
                    )
                    continuation.yield(.usage(usage))
                    var emitted = ""
                    // Snapshoty jsou kumulativní – posíláme dál jen přírůstek.
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let text = snapshot.content
                        if text.hasPrefix(emitted) {
                            let delta = String(text.dropFirst(emitted.count))
                            if !delta.isEmpty { continuation.yield(.text(delta)) }
                        }
                        emitted = text
                    }
                    usage.outputTokens = emitted.count / 3
                    continuation.yield(.usage(usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Chyby frameworku nesou jen technický `debugDescription` – nahradíme je hláškou pro uživatele.
    private static func friendly(_ error: Error) -> Error {
        guard let generation = error as? LanguageModelSession.GenerationError else { return error }
        switch generation {
        case .unsupportedLanguageOrLocale:
            return ProviderError.unavailable(unsupportedLanguageMessage)
        case .exceededContextWindowSize:
            return ProviderError.engine("Konverzace přerostla kontext modelu (~4 000 tokenů). Začni nový chat.")
        case .guardrailViolation:
            return ProviderError.engine("Bezpečnostní filtr Apple Intelligence odpověď zablokoval.")
        default:
            return error
        }
    }

    /// Poslední zpráva + tolik předchozích výměn, kolik se vejde do ~6 000 znaků.
    /// Rámec je anglicky – model nepodporované jazyky odmítá a česká návěští by ho shodila.
    private static func prompt(from history: [ChatTurn]) -> String {
        guard let last = history.last else { return "" }
        var context: [String] = []
        var budget = 6_000 - last.text.count
        for turn in history.dropLast().reversed() {
            let line = (turn.role == .user ? "User: " : "Assistant: ") + turn.text
            guard line.count <= budget else { break }
            budget -= line.count
            context.insert(line, at: 0)
        }
        guard !context.isEmpty else { return last.text }
        return "Conversation so far:\n" + context.joined(separator: "\n")
            + "\n\nReply to the last user message:\n" + last.text
    }
}
