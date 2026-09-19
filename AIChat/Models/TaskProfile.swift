import Foundation

/// Režim generování podle úkolu. Parametry vzorkování se podle něj mění před každou odpovědí:
/// extrakce dat chce téměř deterministický výstup, shrnutí mírně volnější, běžný chat nejvolnější.
enum TaskProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case extract, summarize, chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extract: "Extrakce dat"
        case .summarize: "Shrnutí"
        case .chat: "Běžný chat"
        }
    }

    var symbol: String {
        switch self {
        case .extract: "tablecells"
        case .summarize: "text.append"
        case .chat: "bubble.left.and.bubble.right"
        }
    }

    /// Výchozí hodnoty; uživatel si je může v Parametrech upravit.
    var defaults: SamplingParameters {
        switch self {
        case .extract: SamplingParameters(temperature: 0.20, topP: 0.90, minP: 0.05, topK: 40, repeatPenalty: 1.08)
        case .summarize: SamplingParameters(temperature: 0.30, topP: 0.90, minP: 0.05, topK: 40, repeatPenalty: 1.05)
        case .chat: SamplingParameters(temperature: 0.70, topP: 0.90, minP: 0.05, topK: 40, repeatPenalty: 1.10)
        }
    }

    /// Osnova, podle které se píše shrnutí. Prázdná = model si strukturu zvolí sám.
    ///
    /// U dlouhé kapitoly se shrnuje po částech a každá část jde do modelu zvlášť. Bez
    /// společné osnovy si každá zvolí jiný tvar – jedna odrážky, druhá tabulku, třetí
    /// odstavec – a spojit se to pak nedá. S osnovou se všechny části vyplňují do
    /// stejných nadpisů a poskládání je mechanické.
    var defaultOutline: [String] {
        switch self {
        case .summarize:
            [
                "Co kapitola pokrývá",
                "Klíčová čísla (s obdobím)",
                "Meziroční změny a jejich důvody",
                "Rizika a nejistoty",
                "Co je nové oproti minulému roku",
            ]
        case .extract, .chat:
            []
        }
    }

    /// Pravidlo, které musí jít s osnovou vždycky.
    ///
    /// Pevné nadpisy svádějí model k tomu, aby prázdné vyplnil odjinud – appka takhle
    /// jednou vymyslela odkaz na docs.nvidia.com, který v podkladech nebyl. Bez téhle
    /// věty osnova přesnost zhorší, ne zlepší.
    static let outlineRule = "Když k některému nadpisu v podkladech nic není, napiš pod "
        + "něj „neuvedeno“. Nedoplňuj nic z vlastní paměti a nepřidávej vlastní nadpisy."

    /// Osnova jako blok do promptu.
    static func outlineBlock(_ headings: [String]) -> String? {
        guard !headings.isEmpty else { return nil }
        let list = headings.enumerated().map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return """
            Piš pod těmito nadpisy, v tomhle pořadí:
            \(list)

            \(outlineRule)
            """
    }

    var note: String {
        switch self {
        case .extract: "Nízká teplota a přísnější vzorkování – model si míň vymýšlí a drží se toho, co v souboru opravdu je."
        case .summarize: "Trochu volnější než extrakce, aby shrnutí plynulo, ale pořád se drží zdroje."
        case .chat: "Volnější a rozmanitější odpovědi pro běžnou konverzaci."
        }
    }

    /// Výchozí stav přemýšlení pro tento režim. U extrakce se vyplatí – model si projde
    /// zdroj, než odpoví. U shrnování ne: text už v kontextu je, přemýšlení jen přidá
    /// tisíce tokenů navíc a u dlouhého dokumentu se každou částí násobí.
    var thinksByDefault: Bool {
        switch self {
        case .extract: true
        case .summarize, .chat: false
        }
    }
}

/// Parametry vzorkování jednoho režimu.
struct SamplingParameters: Codable, Equatable, Sendable {
    var temperature: Double
    var topP: Double
    var minP: Double
    var topK: Int
    var repeatPenalty: Double
}

/// Jak se režim vybírá.
enum TaskProfileMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Podle obsahu zprávy (přílohy + klíčová slova).
    case automatic
    case extract, summarize, chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automaticky"
        case .extract: TaskProfile.extract.title
        case .summarize: TaskProfile.summarize.title
        case .chat: TaskProfile.chat.title
        }
    }

    var fixedProfile: TaskProfile? {
        switch self {
        case .automatic: nil
        case .extract: .extract
        case .summarize: .summarize
        case .chat: .chat
        }
    }
}

extension TaskProfile {
    /// Delší vložený text (~400 slov) je práce s dokumentem, i když není jako příloha.
    static let longInputCharacters = 1_200

    /// Odhad úkolu z odesílané zprávy.
    ///
    /// Porovnávají se **kmeny slov**, ne celé tvary – čeština skloňuje a časuje, takže
    /// „souhrn“, „shrnutí“ i „stručný“ musí zabrat stejně. Kmen se hledá jen na začátku
    /// slova, aby „scéna“ nespustila extrakci kvůli „cena“.
    /// Když klíčová slova chybí, rozhoduje kontext: dlouhý vložený text nebo příloha
    /// znamená shrnutí, navazující dotaz v chatu nad dokumentem zůstane u předchozího režimu.
    ///
    /// - Parameters:
    ///   - hasAttachments: zpráva, která se právě odesílá, nese soubory
    ///   - conversationHasDocuments: v chatu už je příloha nebo dlouhý vložený text
    ///   - previous: režim poslední odpovědi v tomto chatu
    static func detect(
        text: String,
        hasAttachments: Bool,
        conversationHasDocuments: Bool = false,
        previous: TaskProfile? = nil
    ) -> TaskProfile {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "cs"))
        let words = normalized.split { !$0.isLetter && !$0.isNumber }

        func hasStem(_ stems: [String]) -> Bool {
            words.contains { word in stems.contains { word.hasPrefix($0) } }
        }
        func hasPhrase(_ phrases: [String]) -> Bool {
            phrases.contains { normalized.contains($0) }
        }

        let summary = hasStem([
            "shrn", "souhrn", "struc", "zjednodus", "sumar", "podstat", "prehled", "zaver",
            "summar", "overview", "tldr"
        ]) || hasPhrase(["o cem", "hlavni bod", "klicove bod", "tl;dr", "key point", "ve zkratce"])

        let extraction = hasStem([
            "vytah", "vypis", "vyps", "extrah", "najd", "vyhled", "kolik", "datum", "faktur",
            "castk", "cena", "tabulk", "seznam", "udaj", "parametr", "hodnot", "termin",
            "splatnost", "podmink", "cislo", "celkem", "procent", "extract", "invoice", "json", "csv"
        ]) || hasPhrase(["list all", "find all", "how much"])

        // Tvůrčí a konverzační zadání patří do chatu i uprostřed práce nad dokumentem.
        let creative = hasStem(["vymysli", "brainstorm", "basen", "pribeh", "vtip", "zavtipkuj"])
            || hasPhrase(["co si myslis", "tvuj nazor", "popovidej"])

        let isLongInput = text.count >= longInputCharacters
        let isDocumentWork = hasAttachments || isLongInput

        if creative, !isDocumentWork { return .chat }
        if extraction, !summary { return .extract }
        if summary { return .summarize }

        // Bez klíčových slov: příloha i dlouhý vložený text znamenají shrnutí.
        if isDocumentWork { return .summarize }
        // Navazující dotaz nad dokumentem – zůstat u režimu, ve kterém chat běžel.
        if conversationHasDocuments, let previous, previous != .chat { return previous }
        return .chat
    }
}
