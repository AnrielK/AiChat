import Foundation

/// Klíčová slova pro hledání v jazyce podkladu.
///
/// `DocumentIndex` hledá na slovech, takže česky položený dotaz nad anglickým dokumentem
/// nenajde nic: „závislost“ nepotká „dependence“, „omezení“ nepotká „restrictions“.
/// Projde jen to, co je v obou jazycích stejné – vlastní jména a slova jako „export“.
/// Tohle je jediné místo celého hledání, kde model umí něco, co BM25 ne, takže se na
/// jeden krátký průchod zavolá.
///
/// Pouští se až když se běžné hledání netrefí – u dotazu ve stejném jazyce jako podklad
/// je to zbytečná vteřina navíc.
enum QueryExpansion {
    /// Delší výstup než tohle už nejsou klíčová slova, ale povídání – čtení se utne.
    private static let outputLimit = 200

    /// Stejně jako v `RetrievalPipeline`: do logu v appce jde jen to, co se dá
    /// přečíst bez obsahu dotazu.
    private static let log = EngineLog(category: "retrieval")

    /// - Parameters:
    ///   - sample: kus podkladu, ze kterého model pozná, v jakém jazyce je
    ///   - provider: poskytovatel pro krátký průchod; čtení se utne na prvním řádku,
    ///     takže na jeho nastaveném stropu délky odpovědi nezáleží
    static func keywords(
        for question: String, sample: String, using provider: any ChatProvider
    ) async -> String? {
        let prompt = """
            Tohle je úryvek z dokumentu:

            \(sample)

            Uživatel se ptá: \(question)

            Vypiš nejvýš šest klíčových slov, pod kterými se odpověď v tom dokumentu dá \
            najít. Piš je v jazyce dokumentu, ne v jazyce dotazu. Odpověz jediným řádkem \
            slov oddělených čárkou – žádný úvod, žádné vysvětlení, žádné odrážky.
            """

        guard let line = try? await collect(prompt, using: provider), !line.isEmpty else { return nil }
        let words = line
            .split(whereSeparator: { ",;".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .:•-–—\"'")) }
            .filter { $0.count >= 2 && $0.count <= 40 }
            .prefix(6)
        guard words.count >= 2 else { return nil }

        let keywords = words.joined(separator: " ")
        log.notice("překlad dotazu: \(words.count) klíčových slov")
        log.debug("klíčová slova: \(keywords)")
        return keywords
    }

    /// Nechá model vybrat kapitolu, ve které odpověď hledat.
    ///
    /// U finančních výkazů je BM25 slabý: dotaz na tržby potká slovo „revenue“ na
    /// stovkách míst a rozhodne o pořadí podle délky kusu, ne podle toho, kde jsou
    /// čísla. Osnovu přitom dokument nese sám a model z ní pozná, že se ptáš na
    /// položku, která patří do výkazu zisku a ztráty.
    ///
    /// Stojí to jeden krátký průchod: vstup je osnova a dotaz, výstup jedno číslo.
    /// - Returns: název kapitoly, nebo nil, když model neodpověděl použitelně.
    static func section(
        for question: String, outline: [String], using provider: any ChatProvider
    ) async -> String? {
        // Strop na 60: s otagovanými kapitolami má 10-K kolem 45 položek osnovy
        // (dřív 28) a při stropu 40 by se uřízly zrovna přílohy účetní závěrky,
        // které jsou v seznamu poslední.
        let titles = Array(outline.prefix(60))
        guard titles.count >= 3 else { return nil }
        let list = titles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
            Kapitoly dokumentu:

            \(list)

            Uživatel se ptá: \(question)

            Ve které kapitole odpověď nejspíš je? Odpověz jediným číslem z výpisu. \
            Když si nejsi jistý nebo se dotaz netýká žádné, odpověz 0. \
            Žádné vysvětlení, jen číslo.
            """

        guard let line = try? await collect(prompt, using: provider) else { return nil }
        // Model rád přidá tečku, „Kapitola“ nebo celý název – bere se první číslo.
        let digits = line.split(whereSeparator: { !$0.isNumber })
        guard let first = digits.first, let number = Int(first), number >= 1, number <= titles.count
        else { return nil }
        // Název kapitoly je struktura dokumentu, ne obsah dotazu, a uživatel ho stejně
        // vidí v hlášení nad odpovědí – do logu v appce patří.
        let title = titles[number - 1]
        log.notice("vybraná kapitola \(number)/\(titles.count): \(title)")
        return title
    }

    /// Jeden průchod useknutý na prvním řádku. Menší modely rády přidají vysvětlení
    /// pod seznam; generovat ho do nastaveného stropu by trvalo déle než celé hledání.
    private static func collect(_ prompt: String, using provider: any ChatProvider) async throws -> String {
        var text = ""
        for try await event in provider.stream([ChatTurn(role: .user, text: prompt)]) {
            guard case .text(let piece) = event else { continue }
            text += piece
            if text.count >= outputLimit || text.contains("\n") { break }
        }
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
        return String(first).trimmingCharacters(in: .whitespaces)
    }
}
