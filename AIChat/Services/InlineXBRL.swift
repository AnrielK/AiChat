import Foundation

/// Čísla z inline XBRL (SEC 10-K, 10-Q, 20-F…).
///
/// Výroční zpráva ze SECu není obyčejné HTML: každé číslo ve výkazech je otagované
/// značkou `<ix:nonFraction name="us-gaap:Revenues" contextRef="c-1" scale="6">215,938</…>`
/// a kontext k němu říká období i rozpad (segment, region). `HTMLText.extract` tohle
/// všechno zahodí a modelu zbyde tabulka, ve které musí počítat sloupce – přesně tam
/// vznikla chyba „tržby 139 297“ (ve skutečnosti provozní zisk segmentů).
///
/// Z otagovaných faktů se dá postavit tabulka, kde si každé číslo nese, co je zač.
/// Hledání se pak u číselných dotazů scvrkne na lookup a BM25 se jich nemusí ani dotknout.
///
/// Parsuje se jen `ix:nonFraction` (čísla) a hrstka `dei:` údajů z hlavičky. Textové
/// bloky (`ix:nonNumeric`) jsou celé kapitoly zprávy – ty patří běžnému hledání v textu.
enum InlineXBRL {
    /// Oddělovač hlavičky a dat v uložené tabulce.
    static let separator = "\n---\n"

    /// Kolik místa dostane celý výkaz, když si o něj dotaz řekne. Rozvaha má 67 řádků,
    /// výkaz peněžních toků 105 – na to nestačí rozpočet pro jednotlivé ukazatele.
    private static let statementBudget = 8_000
    private static let statementLines = 160

    /// Míň faktů než tohle = soubor nejspíš jen náhodou obsahuje slovo „nonFraction“.
    private static let minimumFacts = 20
    /// Strop na velikost vstupu; nad ním se parsování nevyplatí (a na telefonu trvá).
    private static let maximumInput = 20_000_000

    private static let log = EngineLog(category: "retrieval")

    // MARK: - Veřejné API

    /// Tabulka faktů, nebo nil, když soubor inline XBRL není.
    ///
    /// Formát: pár řádků hlavičky (kdo, jaká období), `---`, pak jeden fakt na řádek
    /// `ukazatel | období | rozpad | hodnota`.
    static func factTable(from html: String, fileName: String) -> String? {
        guard html.count <= maximumInput, html.contains("nonFraction") else { return nil }

        let contexts = parseContexts(html)
        guard !contexts.isEmpty else { return nil }
        let header = parseHeader(html)
        let facts = parseFacts(html, contexts: contexts)
        guard facts.count >= minimumFacts else { return nil }

        let labels = periodLabels(contexts, header: header)

        // Výkazy jako celek. Fakt si nenese, do kterého výkazu patří – ta informace je
        // v presentation linkbase, což je jiný soubor. Zjistí se tedy z pozice: mezi
        // nadpisem „Consolidated Balance Sheets“ a nadpisem dalšího výkazu leží přesně
        // fakta té rozvahy. Bez toho dotaz „vypiš rozvahu“ nemá co potkat a hledání
        // podle slov v názvu ukazatele mu vrátí „Valuation Allowances And Reserves
        // Balance“, protože v názvu má slovo Balance.
        let statements = statementRanges(html, facts: facts, notes: narrativeBlocks(html))

        // Stejný fakt je ve zprávě klidně třikrát (výkaz, příloha, shrnutí) – v tabulce
        // stačí jednou. Bere se první výskyt, takže fakt zůstane u svého výkazu.
        var seen = Set<String>()
        var grouped = [[String]](repeating: [], count: statements.count)
        var other: [String] = []
        var cursor = 0
        for fact in facts {
            guard let context = contexts[fact.contextID],
                  let period = labels[fact.contextID] else { continue }
            let breakdown = context.members.map(Self.readable).joined(separator: " / ")
            let key = "\(fact.tag)|\(period)|\(breakdown)|\(fact.value)"
            guard seen.insert(key).inserted else { continue }
            var parts = [spaced(fact.tag), period]
            if !breakdown.isEmpty { parts.append(breakdown) }
            parts.append(format(fact.value, unit: fact.unit))
            let line = parts.joined(separator: " | ")

            while cursor < statements.count, fact.position >= statements[cursor].end { cursor += 1 }
            if cursor < statements.count, fact.position >= statements[cursor].start {
                grouped[cursor].append(line)
            } else {
                other.append(line)
            }
        }

        // Ve výkazu se řádky nechávají v pořadí, v jakém je dokument tiskne (tržby,
        // náklady, hrubý zisk…). Jinde je abecedně, tam žádné přirozené pořadí není.
        var lines: [String] = []
        for (index, statement) in statements.enumerated() where !grouped[index].isEmpty {
            lines.append(groupPrefix + statement.title)
            lines.append(contentsOf: grouped[index])
        }
        if !other.isEmpty {
            if !lines.isEmpty { lines.append(groupPrefix + "Ostatní údaje") }
            lines.append(contentsOf: other.sorted())
        }
        guard !lines.isEmpty else { return nil }

        var heading = ["[Otagovaná čísla (XBRL) ze souboru \u{201E}\(fileName)\u{201C} – "
            + "přesné hodnoty tak, jak je firma sama označila]"]
        let identity = [header["EntityRegistrantName"], header["DocumentType"],
                        header["EntityCentralIndexKey"].map { "CIK \($0)" }].compactMap { $0 }
        if !identity.isEmpty { heading.append("Zdroj: " + identity.joined(separator: ", ")) }
        let ranges = fiscalRanges(contexts, labels: labels)
        if !ranges.isEmpty { heading.append("Období: " + ranges.joined(separator: " · ")) }
        heading.append("Řádek: ukazatel | období | rozpad (segment / region) | hodnota")
        // Bez tohohle model sečte „Data Center" s „Compute" a „Networking", přestože
        // druhé dvě jsou jeho části. XBRL vztah nadřazenosti mezi členy nenese, takže
        // se z řádků samotných poznat nedá.
        heading.append("Pozor: rozpady se navzájem překrývají a nesčítají se – "
            + "jeden ukazatel je rozepsaný po segmentech, po regionech i po trzích zvlášť.")

        log.notice("XBRL: \(facts.count) faktů, \(lines.count) řádků, \(contexts.count) období")
        log.debug("XBRL ze souboru \(fileName)")
        return heading.joined(separator: "\n") + separator + lines.joined(separator: "\n")
    }

    /// Řádky tabulky, které se týkají dotazu, i s hlavičkou (kvůli mapování FY na data).
    ///
    /// Dvě kola: nejdřív se vyberou **ukazatele** (dotaz „tržby“ má vyhrát „Revenues“,
    /// ne „Revenue Remaining Performance Obligation“), pak se k nim doberou řádky
    /// s přednostmi podle roku a rozpadu. Bez prvního kola vítězí dlouhé názvy, ve kterých
    /// se hledané slovo mihne jednou mezi pěti dalšími.
    static func excerpt(
        from table: String,
        matching query: String,
        maxIndicators: Int = 6,
        maxLines: Int = 40,
        characterBudget: Int = 3_500
    ) -> String {
        guard let split = table.range(of: separator) else { return "" }
        let heading = String(table[table.startIndex..<split.lowerBound])
        var rows: [Row] = []
        var groups: [String: [String]] = [:]
        var order: [String] = []
        var group = ""
        for raw in table[split.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix(groupPrefix) {
                group = String(raw.dropFirst(groupPrefix.count))
                if groups[group] == nil { groups[group] = []; order.append(group) }
                continue
            }
            rows.append(Row(raw, group: group))
            groups[group, default: []].append(String(raw))
        }
        guard !rows.isEmpty else { return "" }

        let asked = Set(Terms.stems(of: query))

        // Dotaz na celý výkaz se neřeší po ukazatelích – vypíše se ta skupina celá,
        // v pořadí, v jakém ji dokument tiskne.
        if let name = matchedStatement(for: asked, among: order), let lines = groups[name] {
            var picked: [String] = []
            var used = 0
            let budget = max(characterBudget, statementBudget)
            for line in lines {
                guard picked.count < statementLines, used + line.count <= budget else { break }
                used += line.count + 1
                picked.append(line)
            }
            if !picked.isEmpty {
                return heading + "\n" + groupPrefix + name + "\n" + picked.joined(separator: "\n")
            }
        }

        let years = Set(asked.compactMap { Int($0) }.filter { $0 > 1900 && $0 < 2200 })
        var terms = asked.subtracting(years.map(String.init))
        for (key, value) in synonyms where terms.contains(where: { $0.hasPrefix(key) }) {
            terms.formUnion(Terms.stems(of: value))
        }
        guard !terms.isEmpty else { return "" }

        // 1. kolo – ukazatele. Rozhoduje, jakou část názvu dotaz pokryl: „Revenues“
        // pokryté celé bije „Revenue Remaining Performance Obligation“ pokryté z pětiny.
        var best: [String: Double] = [:]
        for row in rows {
            let hits = row.indicatorStems.intersection(terms).count
            guard hits > 0 else { continue }
            let precision = Double(hits) / Double(max(1, row.indicatorStems.count))
            let score = 10 * precision * precision + Double(hits)
            if score > best[row.indicator] ?? 0 { best[row.indicator] = score }
        }
        guard !best.isEmpty else { return "" }
        let picked = best
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(maxIndicators)
            .map(\.key)
        let rank = Dictionary(uniqueKeysWithValues: picked.enumerated().map { ($0.element, $0.offset) })

        // 2. kolo – řádky vybraných ukazatelů. Žádaný rok napřed, pak shoda rozpadu
        // („tržby v Číně“), pak celkové hodnoty bez rozpadu a novější roky dřív.
        let selected = rows
            .compactMap { row -> (key: [Int], line: String)? in
                guard let order = rank[row.indicator] else { return nil }
                let yearMiss = years.isEmpty || years.contains(row.year) ? 0 : 1
                let breakdownMiss = terms.isDisjoint(with: row.breakdownStems) ? 1 : 0
                return ([order, yearMiss, breakdownMiss, row.breakdown.isEmpty ? 0 : 1, -row.year],
                        row.line)
            }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }

        var lines: [String] = []
        var used = 0
        for candidate in selected {
            guard lines.count < maxLines, used + candidate.line.count <= characterBudget else { break }
            used += candidate.line.count + 1
            lines.append(candidate.line)
        }
        guard !lines.isEmpty else { return "" }
        return heading + "\n" + lines.joined(separator: "\n")
    }

    /// Značka kapitoly vložená před otagovaný textový blok. `DocumentSections` podle ní
    /// pozná hranici kapitoly, kterou by z holého textu nenašel.
    static let sectionMarker = "§§ "

    /// Vloží do HTML značky kapitol podle otagovaných textových bloků.
    ///
    /// Přílohy účetní závěrky jsou v iXBRL obalené blokem `…TextBlock`, jehož jméno je
    /// rovnou název poznámky: `IncomeTaxDisclosureTextBlock`, `SegmentReportingDisclosureTextBlock`,
    /// `LesseeOperatingLeasesTextBlock`. Bez nich celá tahle část dokumentu spadne pod
    /// jedinou hlavičku `Item 15 – Exhibits and Financial Statement Schedules`, protože
    /// vlastní nadpisy poznámek žádné `Item` číslo nemají — proto byly na screenshotech
    /// všechny úryvky označené jako Item 15.
    ///
    /// Vrací původní HTML, když otagované bloky nejsou.
    static func marking(_ html: String) -> String {
        guard html.count <= maximumInput, html.contains("nonNumeric") else { return html }
        let blocks = narrativeBlocks(html)
        guard !blocks.isEmpty else { return html }
        log.notice("XBRL: \(blocks.count) otagovaných kapitol")

        var result = ""
        result.reserveCapacity(html.count + blocks.count * 64)
        var cursor = html.startIndex
        for block in blocks {
            result += html[cursor..<block.start]
            // Uzavírací značka na začátku je schválně: `HTMLText` dělá nový řádek jen
            // z uzavíracích značek, a bez ní se marker uvnitř tabulky přilepí na konec
            // předchozího řádku. Ze 22 kapitol jich tak na začátku řádku skončilo 5.
            result += "</p><p>\(sectionMarker)\(block.title)</p>"
            cursor = block.start
        }
        result += html[cursor...]
        return result
    }

    // MARK: - Výkazy

    /// Předpona řádku, který v tabulce uvozuje výkaz.
    static let groupPrefix = "## "

    /// Pozná dotaz na celý výkaz („vypiš rozvahu“, „Consolidated Statements of Income“).
    /// Takový dotaz nechce jeden ukazatel, ale celou tabulku, takže se pro něj v pipeline
    /// nezkracuje výběr a nevynucuje jednovětá odpověď.
    static func statementRequest(in query: String) -> Bool {
        matchedStatement(for: Set(Terms.stems(of: query)), among: statementNames) != nil
    }

    private static let statementNames = [
        "Consolidated Statements of Income",
        "Consolidated Statements of Comprehensive Income",
        "Consolidated Balance Sheets",
        "Consolidated Statements of Shareholders Equity",
        "Consolidated Statements of Cash Flows",
    ]

    /// České názvy výkazů. Anglická slova z nadpisů se potkají sama.
    private static let statementSynonyms: [String: String] = [
        "rozvah": "Balance Sheets", "bilanc": "Balance Sheets",
        // Jednotné číslo se s množným v názvu nepotká: „sheet“ má pět znaků, „sheets“
        // šest, takže se ořežou na různý kmen. Totéž „flow“ proti „flows“.
        "sheet": "Balance Sheets", "balanc": "Balance Sheets", "flow": "Cash Flows",
        "vysledovk": "Statements of Income", "vykaz": "Statements",
        "zisku": "Income", "ztrat": "Income",
        "penezn": "Cash Flows", "toky": "Cash Flows", "cash": "Cash Flows",
        "kapital": "Shareholders Equity", "vlastn": "Shareholders Equity",
    ]

    /// Název výkazu, na který dotaz sedí nejlíp, nebo nil. Vyžadují se dvě shodná slova –
    /// samotné „income“ je v 10-K na každé druhé řádce.
    private static func matchedStatement(for terms: Set<String>, among names: [String]) -> String? {
        var expanded = terms
        for (key, value) in statementSynonyms where terms.contains(where: { $0.hasPrefix(key) }) {
            expanded.formUnion(Terms.stems(of: value))
        }
        var best: (name: String, score: Int)?
        for name in names {
            let score = Set(Terms.stems(of: name)).intersection(expanded).count
            if score >= 2, score > (best?.score ?? 1) { best = (name, score) }
        }
        return best?.name
    }

    private struct Statement {
        let start: String.Index
        let end: String.Index
        let title: String
    }

    /// Úseky dokumentu, ve kterých leží jednotlivé výkazy.
    ///
    /// Nadpis výkazu je v souboru víckrát: v obsahu, ve vlastním výkazu a pak ještě
    /// v odkazech uvnitř příloh („recorded in our Consolidated Balance Sheets“). Bere se
    /// první výskyt, za kterým následuje aspoň 15 čísel – obsah tím vypadne, protože mezi
    /// jeho položkami žádná čísla nejsou – a každý nadpis se použije jen jednou, takže
    /// pozdější zmínky v textu příloh se zahodí.
    private static func statementRanges(
        _ html: String, facts: [Fact], notes: [Narrative]
    ) -> [Statement] {
        var occurrences: [(index: String.Index, title: String)] = []
        for title in statementNames {
            // „Shareholders Equity“ je v dokumentu s apostrofem; hledá se kratší předpona.
            let needle = title.replacingOccurrences(of: " Shareholders Equity", with: " Shareholders")
            var cursor = html.startIndex
            while let found = html.range(
                of: needle, options: .caseInsensitive, range: cursor..<html.endIndex) {
                occurrences.append((found.lowerBound, title))
                cursor = found.upperBound
            }
        }
        guard !occurrences.isEmpty else { return [] }
        occurrences.sort { $0.index < $1.index }

        let positions = facts.map(\.position)
        func factCount(from start: String.Index, to end: String.Index) -> Int {
            positions.reduce(0) { $0 + (($1 >= start && $1 < end) ? 1 : 0) }
        }

        var accepted: [(index: String.Index, title: String)] = []
        var used = Set<String>()
        for (offset, occurrence) in occurrences.enumerated() {
            guard !used.contains(occurrence.title) else { continue }
            let next = offset + 1 < occurrences.count ? occurrences[offset + 1].index : html.endIndex
            guard factCount(from: occurrence.index, to: next) >= 15 else { continue }
            accepted.append(occurrence)
            used.insert(occurrence.title)
        }
        guard !accepted.isEmpty else { return [] }

        return accepted.enumerated().map { offset, occurrence in
            // Konec úseku: další výkaz, nebo začátek otagovaných příloh. Poslední výkaz
            // jinak nemá kde skončit a pobral by i účetní postupy.
            var end = offset + 1 < accepted.count ? accepted[offset + 1].index : html.endIndex
            if let note = notes.first(where: { $0.start > occurrence.index })?.start, note < end {
                end = note
            }
            return Statement(start: occurrence.index, end: end, title: occurrence.title)
        }
    }

    // MARK: - Kapitoly

    private struct Narrative {
        let start: String.Index
        let title: String
    }

    /// Nejvyšší úroveň otagovaných textových bloků, zleva doprava.
    ///
    /// Bloky jsou vnořené (v `SignificantAccountingPolicies` sedí jednotlivé
    /// `…PolicyTextBlock`, v poznámce k dani jednotlivé tabulky) a dlouhé bloky jsou
    /// v HTML rozsekané na `ix:continuation` — samotná značka má pak jen pár set bajtů
    /// a zbytek poznámky leží jinde. Nejdřív se tedy dopočítá skutečný konec podle řetězu
    /// pokračování a pak se jede zametákem: co začíná uvnitř už přijatého bloku, se zahodí.
    private static func narrativeBlocks(_ html: String) -> [Narrative] {
        let continuations = pairs(in: html, tag: "continuation")
        var ends: [String: (end: String.Index, next: String?)] = [:]
        for block in continuations {
            guard let id = attribute("id", in: block.head) else { continue }
            ends[id] = (block.end, attribute("continuedAt", in: block.head))
        }

        var candidates: [(start: String.Index, end: String.Index, title: String)] = []
        for block in pairs(in: html, tag: "nonNumeric") {
            guard let name = attribute("name", in: block.head), name.hasSuffix("TextBlock")
            else { continue }
            var end = block.end
            var key = attribute("continuedAt", in: block.head)
            var visited = Set<String>()
            while let current = key, let step = ends[current], visited.insert(current).inserted {
                if step.end > end { end = step.end }
                key = step.next
            }
            candidates.append((block.start, end, sectionTitle(name)))
        }
        candidates.sort { $0.start < $1.start }

        var result: [Narrative] = []
        var reach: String.Index?
        for candidate in candidates {
            if let reach, candidate.start < reach { continue }
            result.append(Narrative(start: candidate.start, title: candidate.title))
            if reach == nil || candidate.end > reach! { reach = candidate.end }
        }
        return result
    }

    private struct Pair {
        let start: String.Index
        let end: String.Index
        let head: Substring
    }

    /// Spáruje `<ix:NÁZEV …>` s `</ix:NÁZEV>` přes zásobník, aby vnořené bloky seděly.
    /// Předpona se nekontroluje – hledá se jen jméno značky a podle dvou znaků před ním
    /// se pozná, jestli jde o otevírací, nebo zavírací.
    private static func pairs(in html: String, tag: String) -> [Pair] {
        var stack: [(start: String.Index, head: Substring)] = []
        var result: [Pair] = []
        var cursor = html.startIndex
        while let mark = html.range(of: tag, range: cursor..<html.endIndex) {
            guard let close = html.range(of: ">", range: mark.upperBound..<html.endIndex) else { break }
            cursor = close.upperBound

            let twoBack = html.index(mark.lowerBound, offsetBy: -2, limitedBy: html.startIndex)
            let isClosing = twoBack.map { html[$0..<mark.lowerBound] == "</" } ?? false
            if isClosing {
                guard let open = stack.popLast() else { continue }
                result.append(Pair(start: open.start, end: close.upperBound, head: open.head))
                continue
            }
            // Otevírací značka: krok zpět na „<“, aby se dala vložit značka kapitoly
            // přesně před ni.
            var tagStart = mark.lowerBound
            var steps = 0
            while steps < 8, tagStart > html.startIndex {
                let previous = html.index(before: tagStart)
                tagStart = previous
                steps += 1
                if html[previous] == "<" { break }
            }
            guard html[tagStart] == "<" else { continue }
            stack.append((tagStart, html[mark.upperBound..<close.lowerBound]))
        }
        return result
    }

    /// `us-gaap:IncomeTaxDisclosureTextBlock` → „Income Tax“.
    private static func sectionTitle(_ qualified: String) -> String {
        var name = local(qualified)
        if name.hasSuffix("TextBlock") { name.removeLast("TextBlock".count) }
        var trimming = true
        while trimming {
            trimming = false
            for suffix in ["Policy", "Disclosure", "Table", "Note"]
            where name.hasSuffix(suffix) && name.count > suffix.count + 3 {
                name.removeLast(suffix.count)
                trimming = true
            }
        }
        if name.hasPrefix("ScheduleOf") { name.removeFirst("ScheduleOf".count) }
        return String(spaced(name).prefix(80))
    }

    /// Kolik faktů tabulka nese – na popisek přílohy v UI.
    static func factCount(in table: String) -> Int {
        guard let split = table.range(of: separator) else { return 0 }
        return table[split.upperBound...].split(separator: "\n").count
    }

    // MARK: - Řádek tabulky

    private struct Row {
        let line: String
        let indicator: String
        let breakdown: String
        let year: Int
        let indicatorStems: Set<String>
        let breakdownStems: Set<String>

        let group: String

        init(_ raw: Substring, group: String) {
            self.group = group
            line = String(raw)
            let parts = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            indicator = parts.first ?? ""
            let period = parts.count > 1 ? parts[1] : ""
            // Rozpad je třetí pole jen tehdy, když jsou pole čtyři – jinak je to hodnota.
            breakdown = parts.count > 3 ? parts[2] : ""
            indicatorStems = Set(Terms.stems(of: indicator))
            breakdownStems = Set(Terms.stems(of: breakdown))
            year = Self.year(in: period)
        }

        /// První čtyřčíslí v popisu období – „FY2026“ i „k 2026-01-25“.
        private static func year(in period: String) -> Int {
            var digits = ""
            for character in period {
                if character.isNumber {
                    digits.append(character)
                    if digits.count == 4 { return Int(digits) ?? 0 }
                } else {
                    digits = ""
                }
            }
            return 0
        }
    }

    /// Česká slova, která v anglickém výkazu nemají co potkat. Krátký seznam schválně:
    /// jde o názvy hlavních řádků výkazů, ne o slovník.
    private static let synonyms: [String: String] = [
        "trzb": "Revenues", "vynos": "Revenues", "obrat": "Revenues", "prodej": "Revenues",
        "zisk": "Net Income Loss", "ztrat": "Net Income Loss", "provoz": "Operating Income Loss",
        "marz": "Gross Profit", "hrub": "Gross Profit", "naklad": "Cost Of Revenue",
        "dan": "Income Tax Expense Benefit", "akci": "Earnings Per Share",
        "divide": "Payments Of Dividends", "hotov": "Cash And Cash Equivalents",
        "dluh": "Long Term Debt", "aktiv": "Assets", "pasiv": "Liabilities",
        "vlastn": "Stockholders Equity", "zasob": "Inventory Net",
        "capex": "Payments To Acquire Property Plant And Equipment",
        "vyzkum": "Research And Development", "vyvoj": "Research And Development",
        "cin": "China", "tchaj": "TW", "usa": "US", "americ": "US",
        "segmen": "Segment", "herni": "Gaming",
    ]

    // MARK: - Kontexty

    private struct Context {
        let start: String?
        let end: String?
        let isInstant: Bool
        let members: [String]
    }

    /// `<xbrli:context id="c-193">` … `</xbrli:context>`. Předpona se u filerů liší,
    /// takže se hledá jen `context id="` a `context>` – v otevírací značce se `context>`
    /// nevyskytuje, takže první výskyt za ní je vždycky ta zavírací.
    private static func parseContexts(_ html: String) -> [String: Context] {
        var result: [String: Context] = [:]
        var cursor = html.startIndex
        while let open = html.range(of: "context id=\"", range: cursor..<html.endIndex) {
            guard let close = html.range(of: "context>", range: open.upperBound..<html.endIndex)
            else { break }
            let block = html[open.upperBound..<close.lowerBound]
            cursor = close.upperBound
            guard let quote = block.firstIndex(of: "\"") else { continue }
            let id = String(block[block.startIndex..<quote])
            let instant = value(between: "instant>", and: "<", in: block)
            result[id] = Context(
                start: value(between: "startDate>", and: "<", in: block),
                end: value(between: "endDate>", and: "<", in: block) ?? instant,
                isInstant: instant != nil,
                members: members(in: block)
            )
        }
        return result
    }

    /// `<xbrldi:explicitMember dimension="…">nvda:ComputeAndNetworkingSegmentMember</…>`.
    private static func members(in block: Substring) -> [String] {
        var result: [String] = []
        var cursor = block.startIndex
        while let mark = block.range(of: "dimension=\"", range: cursor..<block.endIndex) {
            guard let open = block.range(of: ">", range: mark.upperBound..<block.endIndex),
                  let close = block.range(of: "<", range: open.upperBound..<block.endIndex)
            else { break }
            let member = block[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !member.isEmpty { result.append(member) }
            cursor = close.upperBound
        }
        return result
    }

    // MARK: - Fakta

    private struct Fact {
        let tag: String
        let contextID: String
        let unit: String
        let value: Double
        /// Pozice v HTML. Podle ní se pozná, do kterého výkazu fakt patří.
        let position: String.Index
    }

    private static func parseFacts(_ html: String, contexts: [String: Context]) -> [Fact] {
        var result: [Fact] = []
        var cursor = html.startIndex
        while let open = html.range(of: "nonFraction", range: cursor..<html.endIndex) {
            guard let headEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
                  let close = html.range(of: "nonFraction>", range: headEnd.upperBound..<html.endIndex)
            else { break }
            let head = html[open.upperBound..<headEnd.lowerBound]
            // Za hodnotou zbyde kus zavírací značky (`</ix:`); `stripTags` ho zahodí,
            // protože od `<` dál už nic nepřebírá.
            let body = html[headEnd.upperBound..<close.lowerBound]
            cursor = close.upperBound

            guard let name = attribute("name", in: head),
                  let contextID = attribute("contextRef", in: head),
                  contexts[contextID] != nil,
                  let number = decimal(
                    stripTags(body),
                    commaDecimal: attribute("format", in: head)?.contains("comma-decimal") == true)
            else { continue }

            var value = number
            if let scale = attribute("scale", in: head), let exponent = Int(scale) {
                value *= pow(10, Double(exponent))
            }
            if attribute("sign", in: head) == "-" { value = -value }
            result.append(Fact(
                tag: local(name),
                contextID: contextID,
                unit: attribute("unitRef", in: head) ?? "",
                value: value,
                position: open.lowerBound
            ))
        }
        return result
    }

    /// Pár údajů z hlavičky zprávy (`dei:`). Bere se první textový úsek za značkou –
    /// u těchhle položek je hodnota hned na začátku, další značky se dají ignorovat.
    private static func parseHeader(_ html: String) -> [String: String] {
        let wanted: Set<String> = [
            "EntityRegistrantName", "DocumentType", "EntityCentralIndexKey",
            "DocumentFiscalYearFocus", "DocumentPeriodEndDate",
        ]
        var result: [String: String] = [:]
        var cursor = html.startIndex
        while let open = html.range(of: "nonNumeric", range: cursor..<html.endIndex),
              result.count < wanted.count {
            guard let headEnd = html.range(of: ">", range: open.upperBound..<html.endIndex)
            else { break }
            let head = html[open.upperBound..<headEnd.lowerBound]
            cursor = headEnd.upperBound
            guard let name = attribute("name", in: head), name.hasPrefix("dei:") else { continue }
            let key = local(name)
            guard wanted.contains(key), result[key] == nil else { continue }
            guard let next = html.range(of: "<", range: headEnd.upperBound..<html.endIndex)
            else { continue }
            let text = html[headEnd.upperBound..<next.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result[key] = text }
        }
        return result
    }

    // MARK: - Období

    /// Popis období ke každému kontextu: „FY2026“, „k 2026-01-25“, u kvartálů a nestandardních
    /// úseků rovnou data.
    ///
    /// Fiskální rok se počítá od toho, který zpráva hlásí (`DocumentFiscalYearFocus`), zpátky
    /// po rocích. Nedá se jet podle kalendáře: NVIDII končí FY2026 25. ledna 2026, takže
    /// srovnávací rok končící 26. ledna 2025 je FY2025, ne 2024.
    private static func periodLabels(
        _ contexts: [String: Context], header: [String: String]
    ) -> [String: String] {
        let focus = header["DocumentFiscalYearFocus"].flatMap(Int.init)
        let documentEnd = contexts.values.compactMap(\.end).max().flatMap(days(inISO:))
        var result: [String: String] = [:]

        for (id, context) in contexts {
            guard let end = context.end, let endDay = days(inISO: end) else { continue }
            if context.isInstant {
                result[id] = "k \(end)"
                continue
            }
            guard let start = context.start, let startDay = days(inISO: start) else {
                result[id] = "do \(end)"
                continue
            }
            let length = endDay - startDay
            let year: Int
            if let focus, let documentEnd {
                year = focus - Int((Double(documentEnd - endDay) / 365.25).rounded())
            } else {
                year = Int(end.prefix(4)) ?? 0
            }
            if length >= 300 {
                result[id] = "FY\(year)"
            } else if length >= 60 {
                result[id] = "Q FY\(year) (\(start)…\(end))"
            } else {
                result[id] = "\(start)…\(end)"
            }
        }
        return result
    }

    /// „FY2026 = 2025-01-27…2026-01-25“ pro hlavičku, od nejnovějšího.
    private static func fiscalRanges(
        _ contexts: [String: Context], labels: [String: String]
    ) -> [String] {
        var ranges: [String: String] = [:]
        for (id, context) in contexts {
            guard let label = labels[id], label.hasPrefix("FY"),
                  let start = context.start, let end = context.end,
                  ranges[label] == nil else { continue }
            ranges[label] = "\(label) = \(start)…\(end)"
        }
        return ranges.keys.sorted(by: >).compactMap { ranges[$0] }
    }

    /// Dny od 1970-01-01 pro „YYYY-MM-DD“ (Howard Hinnant, days from civil).
    /// DateFormatter by se v téhle smyčce volal tisíckrát.
    private static func days(inISO text: String) -> Int? {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]),
              let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let shifted = year - (month <= 2 ? 1 : 0)
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: - Drobnosti

    private static func attribute(_ name: String, in head: Substring) -> String? {
        guard let mark = head.range(of: "\(name)=\"") else { return nil }
        guard let end = head.range(of: "\"", range: mark.upperBound..<head.endIndex) else { return nil }
        return String(head[mark.upperBound..<end.lowerBound])
    }

    private static func value(between open: String, and close: String, in block: Substring) -> String? {
        guard let start = block.range(of: open),
              let end = block.range(of: close, range: start.upperBound..<block.endIndex)
        else { return nil }
        let text = block[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func stripTags(_ text: Substring) -> String {
        var result = ""
        var inside = false
        for character in text {
            if character == "<" { inside = true }
            else if character == ">" { inside = false }
            else if !inside { result.append(character) }
        }
        return result
    }

    /// Číslo z buňky. Entity (`&#160;`) i měnové značky se zahodí – zůstanou číslice.
    private static func decimal(_ raw: String, commaDecimal: Bool) -> Double? {
        var digits = ""
        for character in raw {
            if character.isNumber { digits.append(character) }
            else if character == "-" && digits.isEmpty { digits.append(character) }
            else if character == "." && !commaDecimal { digits.append(character) }
            else if character == "," && commaDecimal { digits.append(".") }
        }
        guard digits.contains(where: \.isNumber) else { return nil }
        return Double(digits)
    }

    private static func local(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    /// `nvda:ComputeAndNetworkingSegmentMember` → „Compute And Networking Segment“.
    private static func readable(_ qualified: String) -> String {
        var name = local(qualified)
        if name.hasSuffix("Member") { name.removeLast("Member".count) }
        return spaced(name)
    }

    /// `OperatingIncomeLoss` → „Operating Income Loss“. Bez toho by hledání na slovech
    /// nemělo v názvu ukazatele co potkat.
    private static func spaced(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// Hodnota v podobě, ve které ji zpráva tiskne – tedy v milionech, ne v jednotkách.
    /// `215938000000` si model přečte špatně, „215 938 mil. USD“ ne.
    private static func format(_ value: Double, unit: String) -> String {
        switch unit.lowercased() {
        case "usd", "eur", "gbp":
            let currency = unit.uppercased()
            guard abs(value) >= 1_000_000 else { return grouped(value, decimals: 0) + " \(currency)" }
            return grouped(value / 1_000_000, decimals: 0) + " mil. \(currency)"
        case "shares":
            guard abs(value) >= 1_000_000 else { return grouped(value, decimals: 0) + " ks" }
            return grouped(value / 1_000_000, decimals: 1) + " mil. ks"
        case let other where other.contains("pershare"):
            return grouped(value, decimals: 2) + " na akcii"
        default:
            return grouped(value, decimals: abs(value) >= 1_000 ? 0 : 4)
        }
    }

    private static func grouped(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.maximumFractionDigits = decimals
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
