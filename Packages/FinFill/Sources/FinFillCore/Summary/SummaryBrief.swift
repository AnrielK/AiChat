import Foundation

/// Pevná šablona souhrnu 10-K: jen to, co investor s DCF modelem opravdu potřebuje.
///
/// Model vyplní oddíly se značkami (`THESIS:`, `CHANGES:` …) a krátkými body; appka je
/// rozpozná a vykreslí vždy stejně (list Souhrn v Sheets, náhled v appce). Čísla v souhrnu
/// píše model jen z ověřené tabulky klíčových čísel – samotná tabulka se počítá z XBRL v kódu.
public struct SummaryBrief: Sendable, Equatable {
    public enum Section: String, CaseIterable, Sendable {
        case thesis = "THESIS"
        case changes = "CHANGES"
        case drivers = "DRIVERS"
        case risks = "RISKS"
        case capital = "CAPITAL"
        case outlook = "OUTLOOK"
        case valuation = "VALUATION"

        /// Nejvýš tolik bodů – víc se zahodí, ať souhrn zůstane na jednu obrazovku.
        public var maxItems: Int {
            switch self {
            case .thesis: 2
            case .changes: 4
            case .drivers, .risks, .capital, .valuation: 3
            case .outlook: 2
            }
        }

        /// Co do oddílu patří – pro prompt.
        var instruction: String {
            switch self {
            case .thesis: "1–2 sentences: how the company makes money and the main story of this fiscal year"
            case .changes: "up to 4 bullets: the most important changes vs. the prior year"
            case .drivers: "up to 3 bullets: what drives revenue and profit (products, segments, customers)"
            case .risks: "up to 3 bullets: the most material risks specific to this company (no generic boilerplate)"
            case .capital: "up to 3 bullets: buybacks, dividends, capex, acquisitions, debt"
            case .outlook: "up to 2 bullets: guidance or expectations stated by management"
            case .valuation: "up to 3 bullets: what to watch in a DCF – revenue growth, margins, capex, share count"
            }
        }

        public func title(czech: Bool) -> String {
            switch self {
            case .thesis: czech ? "Teze" : "Thesis"
            case .changes: czech ? "Co se změnilo" : "What changed"
            case .drivers: czech ? "Tahouni byznysu" : "Business drivers"
            case .risks: czech ? "Hlavní rizika" : "Key risks"
            case .capital: czech ? "Kapitál a akcionáři" : "Capital allocation"
            case .outlook: czech ? "Výhled vedení" : "Management outlook"
            case .valuation: czech ? "Pro valuaci (DCF)" : "For the valuation (DCF)"
            }
        }

        /// Značky, které modely občas přeloží do jazyka souhrnu.
        var aliases: [String] {
            switch self {
            case .thesis: ["THESIS", "TEZE", "SUMMARY", "SHRNUTÍ"]
            case .changes: ["CHANGES", "ZMĚNY", "CO SE ZMĚNILO", "WHAT CHANGED"]
            case .drivers: ["DRIVERS", "TAHOUNI", "TAHOUNI BYZNYSU", "BUSINESS DRIVERS"]
            case .risks: ["RISKS", "RIZIKA", "HLAVNÍ RIZIKA", "KEY RISKS"]
            case .capital: ["CAPITAL", "KAPITÁL", "CAPITAL ALLOCATION", "KAPITÁL A AKCIONÁŘI"]
            case .outlook: ["OUTLOOK", "VÝHLED", "VÝHLED VEDENÍ", "GUIDANCE"]
            case .valuation: ["VALUATION", "VALUACE", "PRO VALUACI", "DCF", "PRO VALUACI (DCF)"]
            }
        }
    }

    /// Body každého oddílu (teze = 1 položka textu). Prázdné pole = firma k tomu nic neuvádí.
    public var items: [Section: [String]]

    public subscript(_ section: Section) -> [String] { items[section] ?? [] }

    // MARK: - Prompt

    /// Instrukce pro finální krok souhrnu: vyplnit šablonu.
    public static func prompt(company: String, fiscalYear: Int, language: String,
                              keyFigures: String, sections: String) -> String {
        let template = Section.allCases.map { s in
            s == .thesis ? "\(s.rawValue):\n<\(s.instruction)>" : "\(s.rawValue):\n- <\(s.instruction)>"
        }.joined(separator: "\n")
        return """
        Fill in this template about \(company)'s 10-K for fiscal year \(fiscalYear) for an investor. \
        Write the content in \(language), keep the section labels exactly as they are (in English, followed by a colon). \
        Each bullet at most 20 words, concrete facts only, no filler, no disclaimers. \
        Cite numbers only from the verified figures below. If the filing says nothing for a section, write "- n/a".

        \(template)

        Verified figures (from XBRL):
        \(keyFigures)

        Section summaries of the 10-K:
        \(sections)
        """
    }

    // MARK: - Rozpoznání

    /// Z odpovědi modelu. nil = model šablonu nedodržel (méně než 3 oddíly) – použije se text, jak je.
    public static func parse(_ text: String) -> SummaryBrief? {
        var items: [Section: [String]] = [:]
        var current: Section?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let (section, rest) = header(line) {
                current = section
                items[section] = items[section] ?? []
                if !rest.isEmpty { append(rest, to: section, &items) }
                continue
            }
            guard let current else { continue }
            append(line, to: current, &items)
        }
        guard items.count >= 3 else { return nil }
        for (section, list) in items { items[section] = Array(list.prefix(section.maxItems)) }
        return SummaryBrief(items: items)
    }

    /// „THESIS:“, „**Risks:** …“, „## VÝHLED“ → oddíl a text za dvojtečkou.
    static func header(_ line: String) -> (Section, String)? {
        var s = line.replacingOccurrences(of: "**", with: "")
        s = String(s.drop { $0 == "#" || $0 == " " })
        let upper = s.uppercased()
        for section in Section.allCases {
            for alias in section.aliases.sorted(by: { $0.count > $1.count }) where upper.hasPrefix(alias) {
                var rest = s.dropFirst(alias.count).trimmingCharacters(in: .whitespaces)
                // Značka musí končit dvojtečkou, nebo být sama na řádku („Risks of …“ není nadpis).
                if rest.hasPrefix(":") || rest.hasPrefix("：") {
                    rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                } else if !rest.isEmpty {
                    continue
                }
                return (section, rest)
            }
        }
        return nil
    }

    static func append(_ line: String, to section: Section, _ items: inout [Section: [String]]) {
        var text = line.replacingOccurrences(of: "**", with: "")
        for prefix in ["- ", "* ", "• ", "– "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if let r = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { text.removeSubrange(r) }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<"), text.hasSuffix(">") { return }        // nevyplněný zástupný text
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !text.isEmpty, !["n/a", "na", "none", "neuvedeno", "není uvedeno", "nic", "—", "-"].contains(lower) else { return }
        if section == .thesis, let first = items[section]?.first {
            items[section] = [first + " " + text]                     // teze = jeden odstavec
        } else {
            items[section, default: []].append(text)
        }
    }

    // MARK: - Markdown (náhled v appce)

    public func markdown(czech: Bool) -> String {
        Section.allCases.map { section in
            let list = self[section]
            let body: String
            if list.isEmpty { body = "—" }
            else if section == .thesis { body = list.joined(separator: " ") }
            else { body = list.map { "- \($0)" }.joined(separator: "\n") }
            return "## \(section.title(czech: czech))\n\n\(body)"
        }
        .joined(separator: "\n\n")
    }
}

// MARK: - Klíčová čísla pro souhrn

public extension KeyFigures {
    /// Řádky, které se ukazují v souhrnu (provozní zisk, provozní CF a capex shrnuje FCF a marže).
    static let briefNames: Set<String> = [
        "Revenue", "Gross margin", "Operating margin", "Net income", "Diluted EPS",
        "Free cash flow", "Cash + short-term investments", "Total debt",
    ]

    var briefLines: [Line] {
        lines.filter { Self.briefNames.contains($0.name) || $0.name.hasPrefix("Revenue – ") }
    }

    static func displayName(_ name: String, czech: Bool) -> String {
        guard czech else { return name }
        let names = [
            "Revenue": "Tržby", "Gross margin": "Hrubá marže", "Operating income": "Provozní zisk",
            "Operating margin": "Provozní marže", "Net income": "Čistý zisk", "Diluted EPS": "EPS (zředěný)",
            "Operating cash flow": "Provozní cash flow", "Capital expenditures": "Investice (capex)",
            "Free cash flow": "Volné cash flow (FCF)", "Cash + short-term investments": "Hotovost + krátkodobé investice",
            "Total debt": "Dluh celkem",
        ]
        if name.hasPrefix("Revenue – ") { return "Tržby – " + String(name.dropFirst("Revenue – ".count)) }
        return names[name] ?? name
    }
}
