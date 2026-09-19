import Foundation

/// Kus dokumentu připravený k vyhledávání.
struct IndexedChunk: Sendable, Identifiable {
    let id: Int
    /// Název souboru, ze kterého kus pochází.
    let source: String
    /// Název kapitoly podle `DocumentSections`; prázdný, když dokument nadpisy nemá.
    let section: String
    let text: String
    /// Kolikrát se v kusu vyskytuje který kmen. Počítá se při stavbě indexu,
    /// aby hledání bylo jen součet přes kmeny dotazu.
    let counts: [String: Int]
    /// Počet kmenů v kusu (délka pro normalizaci BM25).
    let length: Int

    var label: String { section.isEmpty ? source : "\(source) – \(section)" }
}

/// Normalizace slov na kmeny. Stejná úvaha jako v `TaskProfile.detect`: čeština skloňuje,
/// takže „faktura“, „faktury“ i „fakturu“ musí být jeden klíč. Diakritika se odstraní
/// (uživatel ji v dotazu často vynechá) a slovo se zkrátí na prvních šest znaků –
/// hrubé, ale na vyhledávání to stačí a nepotřebuje to slovník.
/// Jazyk textu, jen na rozlišení „stejný / jiný než dotaz“.
///
/// Hledá se na slovech, takže překlad dotazu má smysl jen tehdy, když je podklad
/// v jiném jazyce. Zjistit to stojí jeden průchod vzorkem – proti volání modelu,
/// které to stálo dosud, je to zadarmo.
enum TextLanguage: String, Sendable {
    case czech, english, unknown

    private static let czechMarkers = [" a ", " je ", " se ", " na ", " v ", " to ", " za ", " pro ", " podle "]
    private static let englishMarkers = [" the ", " of ", " and ", " to ", " in ", " for ", " with ", " that "]

    static func of(_ text: String) -> TextLanguage {
        let sample = " " + text.prefix(4_000).lowercased() + " "
        func hits(_ markers: [String]) -> Int {
            markers.reduce(0) { $0 + sample.components(separatedBy: $1).count - 1 }
        }
        // Diakritika je pro češtinu silnější signál než kterékoli jednotlivé slovo.
        let diacritics = sample.unicodeScalars.reduce(0) {
            "áčďéěíňóřšťúůýž".unicodeScalars.contains($1) ? $0 + 1 : $0
        }
        let czech = hits(czechMarkers) + diacritics / 4
        let english = hits(englishMarkers)
        if czech < 3, english < 3 { return .unknown }
        return czech >= english ? .czech : .english
    }
}

enum Terms {
    /// Kmen slova, nebo nil, když slovo pro hledání nemá cenu.
    static func stem(_ word: String) -> String? {
        guard let first = word.first else { return nil }
        // Čísla se nezkracují – „2024“ a „2025“ se nesmí slít, částky taky ne.
        if first.isNumber { return String(word.prefix(12)) }
        guard word.count >= 3, !stopwords.contains(word) else { return nil }
        return String(word.prefix(6))
    }

    static func stems(of text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "cs"))
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap { stem(String($0)) }
    }

    /// Slova, která jsou v každém dokumentu a o relevanci nic neříkají.
    /// Delší seznam nemá smysl – BM25 běžná slova stejně potlačí přes IDF.
    static let stopwords: Set<String> = [
        "ale", "aby", "ani", "ano", "byl", "byla", "bylo", "byt", "coz", "dal", "dale",
        "jak", "jako", "jde", "jen", "jeho", "jeji", "jejich", "jenz", "jest", "jeste",
        "jsem", "jses", "jsi", "jsou", "kdo", "kdy", "kde", "kdyz", "ktera", "ktere",
        "kteri", "ktery", "mezi", "muze", "nad", "nam", "nas", "nebo", "neni", "nez",
        "nic", "pak", "podle", "pouze", "pred", "pres", "pri", "pro", "proc", "proto",
        "prave", "pta", "sve", "svuj", "tak", "take", "tato", "tedy", "tento", "teto",
        "tim", "tom", "tomu", "tyto", "vam", "vas", "vice", "vsak", "vsech", "zde",
        "and", "are", "but", "for", "from", "has", "have", "into", "not", "that", "the",
        "their", "there", "these", "this", "those", "was", "were", "which", "will", "with"
    ]
}

/// Fulltextový index nad přílohami konverzace.
///
/// Dokument se rozdělí na kapitoly (`DocumentSections`) a ty dál na kusy velikosti
/// jednoho odstavce až dvou. Hledá se BM25 nad kmeny – stejný algoritmus jako
/// klasické fulltextové vyhledávače. Žádné embeddingy: druhý model by zabral paměť,
/// kterou potřebuje ten, co odpovídá, a u dotazů typu „kolik je splatnost faktury“
/// je shoda na slovech přesnější než na významu.
struct DocumentIndex: Sendable {
    let chunks: [IndexedChunk]
    /// Názvy kapitol v pořadí, v jakém jdou za sebou. Posílá se modelu jako osnova,
    /// aby věděl, co v dokumentu je, i když tu kapitolu zrovna nedostal.
    let outline: [String]
    /// Celková délka indexovaného textu ve znacích.
    let characterCount: Int
    /// Jazyk podkladu. Rozhoduje, jestli má smysl dotaz překládat.
    let language: TextLanguage

    /// V kolika kusech se kmen vyskytuje (pro IDF).
    private let frequency: [String: Int]
    private let averageLength: Double

    var isEmpty: Bool { chunks.isEmpty }

    /// Kus textu, ze kterého model pozná jazyk podkladu (`QueryExpansion`).
    var sample: String { String((chunks.first?.text ?? "").prefix(600)) }

    /// Kolik kmenů z dotazu se v dokumentu vůbec vyskytuje. Nula znamená, že dotaz
    /// s podkladem nemá jediné slovo společné – typicky proto, že se ho netýká.
    /// Zadarmo: slovník už existuje jako klíče `frequency`.
    func overlap(with query: String) -> Int {
        var hits = 0
        for term in Set(Terms.stems(of: query)) where frequency[term] != nil { hits += 1 }
        return hits
    }

    // MARK: - Stavba

    static func build(from attachments: [Attachment], chunkSize: Int) -> DocumentIndex {
        build(
            sources: attachments.filter { !$0.text.isEmpty }.map { ($0.name, sections(of: $0)) },
            chunkSize: chunkSize)
    }

    /// Index nad kapitolami, které už někdo rozdělil – `SummaryPipeline` takhle hledá
    /// uvnitř kapitoly vybrané podle zadání, místo aby ji celou procházela po částech.
    static func build(sections: [DocumentSection], source: String, chunkSize: Int) -> DocumentIndex {
        build(sources: [(source, sections)], chunkSize: chunkSize)
    }

    private static func build(
        sources: [(name: String, sections: [DocumentSection])], chunkSize: Int
    ) -> DocumentIndex {
        var chunks: [IndexedChunk] = []
        var outline: [String] = []
        var frequency: [String: Int] = [:]
        var characters = 0

        for source in sources {
            for section in source.sections {
                characters += section.text.count
                if !section.title.isEmpty, !outline.contains(section.title) {
                    outline.append(section.title)
                }
                let pieces = tableChunks(of: section.text, maxCharacters: chunkSize)
                    ?? DocumentSections.chunks(of: section.text, maxCharacters: chunkSize)
                for piece in pieces {
                    var counts: [String: Int] = [:]
                    var length = 0
                    for term in Terms.stems(of: piece) {
                        counts[term, default: 0] += 1
                        length += 1
                    }
                    guard length > 0 else { continue }
                    for term in counts.keys { frequency[term, default: 0] += 1 }
                    chunks.append(IndexedChunk(
                        id: chunks.count,
                        source: source.name,
                        section: section.title,
                        text: piece,
                        counts: counts,
                        length: length
                    ))
                }
            }
        }

        let average = chunks.isEmpty
            ? 1
            : Double(chunks.reduce(0) { $0 + $1.length }) / Double(chunks.count)
        return DocumentIndex(
            chunks: chunks,
            outline: outline,
            characterCount: characters,
            language: TextLanguage.of(chunks.prefix(4).map(\.text).joined(separator: " ")),
            frequency: frequency,
            averageLength: max(1, average)
        )
    }

    /// Kapitoly přílohy. Sešit z xlsx se dělí po listech – `OfficeText` je uvozuje
    /// řádkem `[list „Název“ – hodnoty oddělené tabulátorem]` a název listu je
    /// lepší nadpis, než co by v tabulce našlo hledání nadpisů.
    private static func sections(of attachment: Attachment) -> [DocumentSection] {
        let lines = attachment.text.components(separatedBy: "\n")
        guard lines.contains(where: isSheetCaption) else {
            return DocumentSections.split(attachment.text)
        }

        var sections: [DocumentSection] = []
        var title = ""
        var body: [String] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sections.append(DocumentSection(title: title, text: text)) }
            body = []
        }
        for line in lines {
            if isSheetCaption(line) {
                flush()
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            }
            body.append(line)
        }
        flush()
        return sections.isEmpty ? DocumentSections.split(attachment.text) : sections
    }

    private static func isSheetCaption(_ line: String) -> Bool {
        line.hasPrefix("[list ")
    }

    /// Tabulka rozdělená po řádcích, s popiskem a hlavičkou zopakovanými v každém kusu.
    /// Bez toho model u druhého a dalšího kusu nevidí, co který sloupec znamená –
    /// dělení po odstavcích tabulku rozsekne přesně takhle špatně.
    ///
    /// Vrátí nil, když text tabulka není; volající pak použije běžné dělení.
    private static func tableChunks(of text: String, maxCharacters: Int) -> [String]? {
        let lines = text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 5 else { return nil }

        // Řádek tabulky pozná tabulátor (xlsx, docx tabulky) nebo aspoň dva
        // oddělovače (CSV, středníkem oddělený export z Excelu).
        func isRow(_ line: String) -> Bool {
            if line.contains("\t") { return true }
            return line.filter { $0 == ";" || $0 == "," }.count >= 2
        }
        let rows = lines.filter(isRow)
        guard Double(rows.count) / Double(lines.count) >= 0.6, let header = rows.first else { return nil }

        let caption = isRow(lines[0]) ? nil : lines[0]
        let repeated = [caption, header].compactMap { $0 }.joined(separator: "\n")

        var chunks: [String] = []
        var current = repeated
        for row in rows.dropFirst() {
            if current.count + row.count + 1 > maxCharacters, current != repeated {
                chunks.append(current)
                current = repeated
            }
            current += "\n" + row
        }
        if current != repeated { chunks.append(current) }
        return chunks.isEmpty ? nil : chunks
    }

    // MARK: - Hledání

    /// Kusy nejbližší dotazu, seřazené tak, jak jdou v dokumentu za sebou
    /// (model pak čte text v původním pořadí, ne od nejlepší shody).
    /// Sousední kusy se slučují, aby se neroztrhla věta přes hranici.
    ///
    /// - Parameters:
    ///   - characterBudget: kolik znaků se smí vrátit dohromady
    ///   - maxChunks: strop na počet úryvků, ať výběr nezdrobní na nesouvislé věty
    func search(_ query: String, characterBudget: Int, maxChunks: Int = 8) -> [IndexedChunk] {
        let terms = Set(Terms.stems(of: query))
        guard !terms.isEmpty, !chunks.isEmpty, characterBudget > 0 else { return [] }

        let total = Double(chunks.count)
        var scored: [(chunk: IndexedChunk, score: Double)] = []
        for chunk in chunks {
            var score = 0.0
            for term in terms {
                guard let hits = chunk.counts[term] else { continue }
                let documents = Double(frequency[term] ?? 1)
                let idf = log(1 + (total - documents + 0.5) / (documents + 0.5))
                let tf = Double(hits)
                // BM25 s obvyklými konstantami k1 = 1,2 a b = 0,75.
                let norm = 1.2 * (0.25 + 0.75 * Double(chunk.length) / averageLength)
                score += idf * (tf * 2.2) / (tf + norm)
            }
            if score > 0 { scored.append((chunk, score)) }
        }
        guard !scored.isEmpty else { return [] }

        scored.sort { $0.score > $1.score }
        var picked: [IndexedChunk] = []
        var used = 0
        for candidate in scored {
            guard picked.count < maxChunks else { break }
            let cost = candidate.chunk.text.count + 40  // režie hlavičky úryvku
            guard used + cost <= characterBudget else { continue }
            used += cost
            picked.append(candidate.chunk)
        }
        return Self.merged(picked.sorted { $0.id < $1.id })
    }

    /// Hledání omezené na jednu kapitolu. Když v ní nic není, vrátí prázdno –
    /// volající si pak řekne o hledání přes celý dokument.
    func search(_ query: String, inSection section: String, characterBudget: Int) -> [IndexedChunk] {
        let ids = Set(chunks.filter { $0.section == section }.map(\.id))
        guard !ids.isEmpty else { return [] }
        return search(query, characterBudget: characterBudget, maxChunks: 8)
            .filter { ids.contains($0.id) }
    }

    /// Celá kapitola od začátku, dokud se vejde. Pro případ, že model kapitolu vybral,
    /// ale dotaz s ní nesdílí slova – u tabulek s čísly běžné.
    func section(_ title: String, characterBudget: Int) -> [IndexedChunk] {
        var picked: [IndexedChunk] = []
        var used = 0
        for chunk in chunks where chunk.section == title {
            let cost = chunk.text.count + 40
            guard used + cost <= characterBudget else { break }
            used += cost
            picked.append(chunk)
        }
        return Self.merged(picked)
    }

    /// Kusy na začátku dokumentu – záloha, když dotaz nemá s textem jediné slovo společné.
    /// Lepší než nevrátit nic: model aspoň vidí, o jaký dokument jde, a může to říct.
    func opening(characterBudget: Int) -> [IndexedChunk] {
        var picked: [IndexedChunk] = []
        var used = 0
        for chunk in chunks {
            let cost = chunk.text.count + 40
            guard used + cost <= characterBudget else { break }
            used += cost
            picked.append(chunk)
        }
        return Self.merged(picked)
    }

    /// Slepí kusy, které v dokumentu sousedí a jsou ze stejného souboru.
    private static func merged(_ chunks: [IndexedChunk]) -> [IndexedChunk] {
        var result: [IndexedChunk] = []
        // Sleduje se číslo posledního zpracovaného kusu, ne toho v `result` –
        // po sloučení si tam zůstává číslo prvního z nich.
        var previousID = -2
        for chunk in chunks {
            if let last = result.last, previousID + 1 == chunk.id, last.source == chunk.source {
                result[result.count - 1] = IndexedChunk(
                    id: last.id,
                    source: last.source,
                    section: last.section,
                    text: last.text + "\n" + chunk.text,
                    counts: last.counts,
                    length: last.length + chunk.length
                )
            } else {
                result.append(chunk)
            }
            previousID = chunk.id
        }
        return result
    }
}

/// Úryvek, ze kterého odpověď vznikla. Ukládá se ke zprávě (`ChatMessage.sourcesData`),
/// takže i po otevření chatu z historie jde zkontrolovat, odkud model bral.
struct MessageSource: Codable, Hashable, Sendable, Identifiable {
    /// Pořadové číslo, kterým se na úryvek odkazuje v odpovědi – `[1]`, `[2]`…
    var id: Int
    var label: String
    var text: String

    init(number: Int, chunk: IndexedChunk, limit: Int = 1_200) {
        self.id = number
        self.label = chunk.label
        self.text = chunk.text.count > limit
            ? String(chunk.text.prefix(limit)) + "\n[… zkráceno …]"
            : chunk.text
    }
}


/// Postavený index posledního podkladu.
///
/// Bez toho se u každé zprávy znovu parsuje celý soubor, dělí na kapitoly, kusy
/// a počítají se kmeny – u 10K dokumentu je to práce, která se mezi dotazy nemění.
/// Klíč drží název a délku příloh a velikost kusu; jakmile se kterákoli změní,
/// index se postaví znovu.
actor DocumentIndexCache {
    static let shared = DocumentIndexCache()

    private var signature = ""
    private var cached: DocumentIndex?
    /// Přeložená klíčová slova k dotazu. Stejný dotaz (opakování, druhé kolo,
    /// „zkus to znovu“) pak nestojí další volání modelu.
    private var keywords: [String: String] = [:]
    /// Kapitola, kterou model k dotazu vybral. Platí po stejnou dobu jako index.
    private var sections: [String: String] = [:]

    func index(for documents: [Attachment], chunkSize: Int) -> DocumentIndex {
        let key = documents.map { "\($0.name):\($0.characterCount)" }
            .joined(separator: "|") + "#\(chunkSize)"
        if key == signature, let cached { return cached }
        let built = DocumentIndex.build(from: documents, chunkSize: chunkSize)
        signature = key
        cached = built
        keywords = [:]
        sections = [:]
        return built
    }

    func keywords(for question: String) -> String? { keywords[question] }
    func store(keywords value: String, for question: String) { keywords[question] = value }
    func section(for question: String) -> String? { sections[question] }
    func store(section value: String, for question: String) { sections[question] = value }
}
