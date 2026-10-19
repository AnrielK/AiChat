import Foundation

/// Šablona earnings review posledního kvartálu (podle skillu earnings-analysis z anthropics/financial-services,
/// zkráceno pro malé modely): titulek · výsledky · tahouni · výhled · co upravit v DCF · rizika.
///
/// Konsenzus analytiků v datech SEC není, takže „beat/miss“ se nehodnotí – výsledky se porovnávají
/// se stejným kvartálem loni a s předchozím kvartálem.
public struct QuarterBrief: Sendable, Equatable {
    public struct Spec: Sendable {
        public let key: String
        public let aliases: [String]
        public let maxItems: Int
        public let instruction: String
        public let czech: String
        public let english: String
        public var paragraph: Bool { maxItems == 1 }
    }

    public static let specs: [Spec] = [
        Spec(key: "HEADLINE", aliases: ["HEADLINE", "TITULEK", "SHRNUTÍ", "SUMMARY"], maxItems: 1,
             instruction: "1–2 sentences: the main story of this quarter for an investor",
             czech: "Kvartál v kostce", english: "The quarter in brief"),
        Spec(key: "RESULTS", aliases: ["RESULTS", "VÝSLEDKY", "KEY RESULTS"], maxItems: 4,
             instruction: "up to 4 bullets: revenue, margins, EPS and cash flow vs. the same quarter last year, using the verified figures",
             czech: "Výsledky", english: "Results"),
        Spec(key: "DRIVERS", aliases: ["DRIVERS", "TAHOUNI", "SEGMENTS", "SEGMENTY"], maxItems: 3,
             instruction: "up to 3 bullets: which segments, products, customers or regions drove the change",
             czech: "Co táhlo výsledky", english: "What drove it"),
        Spec(key: "GUIDANCE", aliases: ["GUIDANCE", "OUTLOOK", "VÝHLED"], maxItems: 2,
             instruction: "up to 2 bullets: guidance or expectations stated by management for the next quarter or year",
             czech: "Výhled vedení", english: "Guidance"),
        Spec(key: "MODEL", aliases: ["MODEL", "DCF", "VALUATION", "VALUACE", "PRO MODEL"], maxItems: 3,
             instruction: "up to 3 bullets: what to update in a DCF model – revenue growth, margins, capex, share count",
             czech: "Co upravit v modelu", english: "Model update"),
        Spec(key: "RISKS", aliases: ["RISKS", "RIZIKA", "WATCH"], maxItems: 2,
             instruction: "up to 2 bullets: new risks or items to watch next quarter",
             czech: "Rizika a na co dát pozor", english: "Risks to watch"),
    ]

    public var items: [String: [String]]

    public subscript(_ key: String) -> [String] { items[key] ?? [] }

    public static func prompt(company: String, quarter: String, language: String,
                              figures: String, sections: String) -> String {
        let template = specs.map { s in
            s.paragraph ? "\(s.key):\n<\(s.instruction)>" : "\(s.key):\n- <\(s.instruction)>"
        }.joined(separator: "\n")
        return """
        Fill in this template about \(company)'s quarterly report (10-Q) for \(quarter) for an investor who follows the company. \
        Write the content in \(language), keep the section labels exactly as they are (in English, followed by a colon). \
        Focus on what is NEW this quarter. Each bullet at most 20 words, concrete facts only, no filler, no disclaimers. \
        Cite numbers only from the verified figures below. There are no analyst estimates – do not claim a beat or a miss. \
        If the filing says nothing for a section, write "- n/a".

        \(template)

        Verified figures (from XBRL, SEC):
        \(figures)

        Section summaries of the 10-Q:
        \(sections)
        """
    }

    /// nil = model šablonu nedodržel (méně než 3 oddíly).
    public static func parse(_ text: String) -> QuarterBrief? {
        var items: [String: [String]] = [:]
        var current: Spec?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let (spec, rest) = header(line) {
                current = spec
                items[spec.key] = items[spec.key] ?? []
                if !rest.isEmpty { append(rest, to: spec, &items) }
                continue
            }
            guard let current else { continue }
            append(line, to: current, &items)
        }
        guard items.count >= 3 else { return nil }
        for s in specs { if let list = items[s.key] { items[s.key] = Array(list.prefix(s.maxItems)) } }
        return QuarterBrief(items: items)
    }

    static func header(_ line: String) -> (Spec, String)? {
        var s = line.replacingOccurrences(of: "**", with: "")
        s = String(s.drop { $0 == "#" || $0 == " " })
        let upper = s.uppercased()
        for spec in specs {
            for alias in spec.aliases.sorted(by: { $0.count > $1.count }) where upper.hasPrefix(alias) {
                var rest = s.dropFirst(alias.count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":") || rest.hasPrefix("：") {
                    rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                } else if !rest.isEmpty {
                    continue
                }
                return (spec, rest)
            }
        }
        return nil
    }

    static func append(_ line: String, to spec: Spec, _ items: inout [String: [String]]) {
        var text = line.replacingOccurrences(of: "**", with: "")
        for prefix in ["- ", "* ", "• ", "– "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if let r = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { text.removeSubrange(r) }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<"), text.hasSuffix(">") { return }
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !text.isEmpty, !["n/a", "na", "none", "neuvedeno", "není uvedeno", "nic", "—", "-"].contains(lower) else { return }
        if spec.paragraph, let first = items[spec.key]?.first {
            items[spec.key] = [first + " " + text]
        } else {
            items[spec.key, default: []].append(text)
        }
    }

    public func markdown(czech: Bool) -> String {
        Self.specs.map { spec in
            let list = self[spec.key]
            let body = list.isEmpty ? "—" : spec.paragraph ? list.joined(separator: " ") : list.map { "- \($0)" }.joined(separator: "\n")
            return "## \(czech ? spec.czech : spec.english)\n\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// Řádky pro list „Kvartály“: (nadpis oddílu, body).
    public func sheetBlocks(czech: Bool) -> [(title: String, lines: [String], paragraph: Bool)] {
        Self.specs.map { spec in
            let list = self[spec.key]
            return (czech ? spec.czech : spec.english, list.isEmpty ? ["—"] : list, spec.paragraph)
        }
    }
}

/// Výsledek kvartálního updatu: čísla z XBRL + volitelně text modelem z posledního 10-Q.
public struct QuarterlyReview: Sendable {
    public let company: String
    public let figures: QuarterlyFigures
    /// Poslední 10-Q (nil = od posledního 10-K žádný 10-Q, nebo se nepodařilo stáhnout).
    public let filing: SECClient.Filing?
    /// Odpověď modelu (nil = bez modelu).
    public let text: String?
    public let language: String

    public var isCzech: Bool { language.lowercased().hasPrefix("cz") || language.lowercased().hasPrefix("če") }
    public var brief: QuarterBrief? { text.flatMap(QuarterBrief.parse) }

    public func markdown() -> String {
        let czech = isCzech
        let label = figures.latest?.quarter.label ?? "—"
        var s = "# \(company) — \(label)\n\n"
        if let brief {
            let parts = brief.markdown(czech: czech).components(separatedBy: "\n\n## ")
            s += (parts.first ?? "") + "\n\n"
            s += "## " + (czech ? "Čísla (z XBRL)" : "Figures (from XBRL)") + "\n\n" + figures.markdown() + "\n\n"
            s += parts.dropFirst().map { "## " + $0 }.joined(separator: "\n\n") + "\n"
        } else {
            if let text, !text.isEmpty { s += text + "\n\n" }
            s += "## " + (czech ? "Čísla (z XBRL)" : "Figures (from XBRL)") + "\n\n" + figures.markdown() + "\n"
        }
        s += "\n_" + (czech ? "Bez konsenzu analytiků – srovnání se stejným kvartálem loni a s předchozím kvartálem. ≈ = dopočteno (Q4 = rok − 9 měsíců)."
                      : "No analyst consensus – compared with the year-ago and prior quarter. ≈ = derived (Q4 = year − 9 months).") + "_\n"
        return s
    }
}

extension Summarizer {
    /// Earnings review posledního 10-Q: MD&A → poznámky → šablona `QuarterBrief`.
    public func reviewQuarter(filingHTML: String, company: String, figures: QuarterlyFigures,
                              progress: @Sendable (Progress) -> Void = { _ in }) async throws -> String {
        let text = HTMLText.toPlainText(filingHTML)
        let sections = FilingSections.extract(plainText: text, items: FilingSections.quarterlyItems,
                                              titleOverrides: FilingSections.quarterlyTitles)
        let notes = try await sectionSummaries(sections, document: "10-Q", company: company, progress: progress)
        progress(.final)
        let joined = notes.map { "### Item \($0.item) — \($0.title)\n\($0.summary)" }.joined(separator: "\n\n")
        let prompt = QuarterBrief.prompt(company: company, quarter: figures.latest?.quarter.label ?? "the latest quarter",
                                         language: options.language, figures: figures.promptTable(),
                                         sections: clip(joined.isEmpty ? "(MD&A section not found)" : joined, chunkChars))
        var out = try await ask(prompt, maxTokens: options.finalMaxTokens)
        if QuarterBrief.parse(out) == nil {
            let retry = try await ask(prompt + "\n\nIMPORTANT: answer ONLY with the template above – the labels " +
                                      QuarterBrief.specs.map { $0.key + ":" }.joined(separator: ", ") + " each on its own line.",
                                      maxTokens: options.finalMaxTokens)
            if QuarterBrief.parse(retry) != nil { out = retry }
        }
        return out
    }
}
