import Foundation

/// Map-reduce summary of a 10-K sized for small on-device models:
/// section → chunks → notes → section summary → executive summary.
public struct Summarizer: Sendable {
    public struct Options: Sendable {
        public var language: String = "English"
        public var items: [String] = FilingSections.defaultItems
        /// Characters per chunk. nil = derived from engine.contextTokens (~4 chars/token).
        public var chunkChars: Int? = nil
        public var notesMaxTokens = 450
        public var sectionMaxTokens = 700
        public var finalMaxTokens = 1_200
        /// Qwen3.x / distills loop with greedy decoding; model cards recommend ~0.6.
        public var temperature = 0.6
        /// Appended to prompts for Qwen3-style hybrid models to skip the <think> phase.
        public var noThinkSuffix: String? = " /no_think"
        public init() {}
    }

    public struct Result: Sendable {
        public let sections: [(item: String, title: String, summary: String)]
        public let executiveSummary: String
        public let keyFigures: KeyFigures
        /// Jazyk souhrnu („Czech“ → české popisky oddílů a čísel).
        public var language: String = "English"

        public var isCzech: Bool { language.lowercased().hasPrefix("cz") || language.lowercased().hasPrefix("če") }

        /// Šablona vyplněná modelem; nil = model ji nedodržel (zobrazí se text, jak je).
        public var brief: SummaryBrief? { SummaryBrief.parse(executiveSummary) }

        /// Markdown pro náhled v appce – stejné pořadí oddílů jako list Souhrn.
        public func markdown(company: String) -> String {
            let czech = isCzech
            var s = "# \(company) — 10-K FY\(keyFigures.fiscalYear)\n\n"
            if let brief {
                let parts = brief.markdown(czech: czech).components(separatedBy: "\n\n## ")
                // Teze nahoře, pak klíčová čísla, pak ostatní oddíly.
                s += (parts.first ?? "") + "\n\n"
                s += "## " + (czech ? "Klíčová čísla (z XBRL)" : "Key figures (from XBRL)") + "\n\n" + figuresMarkdown(czech: czech) + "\n\n"
                s += parts.dropFirst().map { "## " + $0 }.joined(separator: "\n\n") + "\n"
            } else {
                s += "## " + (czech ? "Shrnutí" : "Executive summary") + "\n\n\(executiveSummary)\n\n"
                s += "## " + (czech ? "Klíčová čísla (z XBRL)" : "Key figures (from XBRL)") + "\n\n" + figuresMarkdown(czech: czech) + "\n"
            }
            return s
        }

        func figuresMarkdown(czech: Bool) -> String {
            let fy = keyFigures.fiscalYear
            var rows = ["| \(czech ? "Ukazatel" : "Metric") | FY\(fy) | FY\(fy - 1) | \(czech ? "Změna" : "Change") |",
                        "|---|---:|---:|---:|"]
            for line in keyFigures.briefLines {
                rows.append("| \(KeyFigures.displayName(line.name, czech: czech)) | \(KeyFigures.format(line.current, line.kind)) | "
                            + "\(KeyFigures.format(line.prior, line.kind)) | \(KeyFigures.changeText(line)) |")
            }
            return rows.joined(separator: "\n")
        }
    }

    public enum Progress: Sendable {
        case section(item: String, chunk: Int, of: Int)
        case reducing(item: String)
        case final
    }

    let engine: LLMEngine
    let options: Options

    public init(engine: LLMEngine, options: Options = .init()) {
        self.engine = engine
        self.options = options
    }

    var chunkChars: Int {
        if let c = options.chunkChars { return c }
        // Leave room for system prompt, instructions and output.
        let usable = max(engine.contextTokens - options.notesMaxTokens - 700, 1_500)
        return min(usable * 4 * 8 / 10, 48_000)
    }

    var system: String {
        """
        You are a financial analyst summarizing an SEC 10-K filing for an investor who maintains a DCF valuation model. \
        Be factual and concise. Only use information present in the provided text. Do not invent numbers. \
        Write in \(options.language).
        """
    }

    func ask(_ prompt: String, maxTokens: Int) async throws -> String {
        let raw = try await engine.generate(system: system, prompt: prompt + (engine.handlesThinking ? "" : (options.noThinkSuffix ?? "")),
                                            maxTokens: maxTokens, temperature: options.temperature)
        return LLMOutput.clean(raw)
    }

    public func summarize(filingHTML: String, company: String, keyFigures: KeyFigures,
                          progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        let text = HTMLText.toPlainText(filingHTML)
        let sections = FilingSections.extract(plainText: text, items: options.items)
        var out: [(String, String, String)] = []

        for sec in sections {
            let chunks = FilingSections.chunk(sec.text, maxChars: chunkChars)
            var notes: [String] = []
            for (i, chunk) in chunks.enumerated() {
                progress(.section(item: sec.item, chunk: i + 1, of: chunks.count))
                let p = """
                10-K of \(company), Item \(sec.item) (\(sec.title)), part \(i + 1) of \(chunks.count).
                Extract the points that matter for an investor as 3–8 short bullet points \
                (business drivers, changes vs. prior year, guidance, risks, capital allocation). \
                Skip boilerplate and legal disclaimers.

                TEXT:
                \(chunk)
                """
                notes.append(try await ask(p, maxTokens: options.notesMaxTokens))
            }
            progress(.reducing(item: sec.item))
            let summary = notes.count == 1 ? notes[0] : try await reduce(notes, section: sec)
            out.append((sec.item, sec.title, summary))
        }

        progress(.final)
        let joined = out.map { "### Item \($0.0) — \($0.1)\n\($0.2)" }.joined(separator: "\n\n")
        // Pevná šablona (SummaryBrief): teze, změny, tahouni, rizika, kapitál, výhled, pro DCF.
        let finalPrompt = SummaryBrief.prompt(company: company, fiscalYear: keyFigures.fiscalYear,
                                              language: options.language, keyFigures: keyFigures.table(),
                                              sections: clip(joined, chunkChars))
        var exec = try await ask(finalPrompt, maxTokens: options.finalMaxTokens)
        if SummaryBrief.parse(exec) == nil {
            // Malé modely šablonu občas nedodrží – jeden pokus s připomínkou, jinak se vezme text, jak je.
            let retry = try await ask(finalPrompt + "\n\nIMPORTANT: answer ONLY with the template above – " +
                                      "the labels THESIS:, CHANGES:, DRIVERS:, RISKS:, CAPITAL:, OUTLOOK:, VALUATION: each on its own line.",
                                      maxTokens: options.finalMaxTokens)
            if SummaryBrief.parse(retry) != nil { exec = retry }
        }
        return Result(sections: out, executiveSummary: exec, keyFigures: keyFigures, language: options.language)
    }

    /// Hierarchical reduce so it also fits small contexts.
    func reduce(_ notes: [String], section: FilingSection) async throws -> String {
        var level = notes
        while true {
            let joined = level.joined(separator: "\n\n")
            if joined.count <= chunkChars {
                let p = """
                Merge these notes from Item \(section.item) (\(section.title)) into one summary of 5–10 bullet points. \
                Remove duplicates, keep concrete facts.

                NOTES:
                \(joined)
                """
                return try await ask(p, maxTokens: options.sectionMaxTokens)
            }
            // Group notes into batches that fit, merge each batch, repeat.
            var groups: [[String]] = [[]]
            var size = 0
            for n in level {
                if size + n.count > chunkChars, !(groups.last!.isEmpty) { groups.append([]); size = 0 }
                groups[groups.count - 1].append(n); size += n.count
            }
            var next: [String] = []
            for g in groups {
                next.append(try await ask("Merge these notes into 5–8 bullet points, keep concrete facts:\n\n" +
                                          g.joined(separator: "\n\n"), maxTokens: options.sectionMaxTokens))
            }
            if next.count >= level.count { return next.joined(separator: "\n") } // safety: no progress
            level = next
        }
    }

    func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "\n…" }
}
