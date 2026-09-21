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

        /// Markdown document (for a "Summary" sheet, notes, or display).
        public func markdown(company: String) -> String {
            var s = "# \(company) — 10-K FY\(keyFigures.fiscalYear)\n\n## Executive summary\n\n\(executiveSummary)\n\n"
            s += "## Key figures (from XBRL)\n\n\(keyFigures.table())\n\n"
            for sec in sections { s += "## Item \(sec.item) — \(sec.title)\n\n\(sec.summary)\n\n" }
            return s
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
        let finalPrompt = """
        Write an executive summary (max ~250 words) of \(company)'s 10-K for fiscal year \(keyFigures.fiscalYear), \
        followed by "Key risks" (3–5 bullets) and "What to watch for the valuation" (3–5 bullets: \
        revenue growth, margins, capex, capital returns).
        Use ONLY these verified figures when citing numbers:
        \(keyFigures.table())

        Section summaries:
        \(clip(joined, chunkChars))
        """
        let exec = try await ask(finalPrompt, maxTokens: options.finalMaxTokens)
        return Result(sections: out, executiveSummary: exec, keyFigures: keyFigures)
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
