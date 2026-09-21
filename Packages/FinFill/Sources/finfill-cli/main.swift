import Foundation
import FinFillCore

// Usage:
//   finfill local --html nvda-20260125.htm [--companyfacts CIK0001045810.json] [--mapping m.json]
//                 [--column O] [--emit-json cells.json] [--llm http://localhost:8080/v1 --model qwen3.5-4b] [--language Czech]
//   finfill run --ticker NVDA --ua "Name email@x.com" --sheet <ID|URL> --token <OAuth token>
//               [--write] [--overwrite] [--fy 2026] [--llm URL --model NAME]

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
func flag(_ name: String) -> Bool { args.contains(name) }

func loadMapping() throws -> TemplateMapping {
    if let p = opt("--mapping") { return try TemplateMapping.load(from: Data(contentsOf: URL(fileURLWithPath: p))) }
    return try TemplateMapping.bundledNVDA()
}

func engine() -> LLMEngine? {
    guard let u = opt("--llm"), let url = URL(string: u) else { return nil }
    return OpenAICompatibleEngine(baseURL: url, model: opt("--model") ?? "default",
                                  contextTokens: Int(opt("--ctx") ?? "") ?? 32_768)
}

func printRows(_ rows: [ResolvedRow], column: String, title: String) {
    print("\n== \(title)")
    let prev = A1.column(max(0, A1.index(column) - 1))
    for r in rows {
        let c = MappingResolver.content(for: r, column: column, previousColumn: prev)
        let v = r.value.map(NumberFormat.plain) ?? "—"
        let label = r.spec.label.padding(toLength: 46, withPad: " ", startingAt: 0)
        print("\(r.spec.sheet.prefix(4)) \(String(format: "%2d", r.spec.row))  \(label) \(v.padding(toLength: 10, withPad: " ", startingAt: 0))  \(c?.display ?? "MISSING \(r.missing)")")
    }
}

func printChecks(_ checks: [CheckResult]) {
    for c in checks {
        print("  \(c.passed ? "✓" : "✗") \(c.label.padding(toLength: 28, withPad: " ", startingAt: 0)) computed \(NumberFormat.plain(c.computed))  reported \(c.reported.map(NumberFormat.plain) ?? "n/a")")
    }
}

do {
    switch args.first {
    case "local":
        guard let htmlPath = opt("--html") else { print("--html required"); exit(2) }
        let html = try String(contentsOfFile: htmlPath, encoding: .utf8)
        let cf = try opt("--companyfacts").map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let filing = try PreparedFiling.local(html: html, companyFacts: cf)
        let mapping = try loadMapping()
        print("\(filing.company) FY\(filing.period.fiscalYear) (end \(filing.period.endDate)), \(filing.facts.facts.count) facts")
        let col = opt("--column") ?? "O"
        let rows = MappingResolver.resolve(mapping, facts: filing.facts, period: filing.period)
        printRows(rows, column: col, title: "FY\(filing.period.fiscalYear) → column \(col)")
        printChecks(Validator.run(mapping, rows: rows, facts: filing.facts, period: filing.period))
        if let out = opt("--emit-json") {
            let prev = A1.column(max(0, A1.index(col) - 1))
            let cells: [[String: Any]] = rows.compactMap { r in
                guard let c = MappingResolver.content(for: r, column: col, previousColumn: prev) else { return nil }
                return ["sheet": r.spec.sheet, "cell": "\(col)\(r.spec.row)", "value": c.sheetsValue]
            }
            try JSONSerialization.data(withJSONObject: cells, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: out))
        }
        if let prior = filing.prior {
            let pr = MappingResolver.resolve(mapping, facts: filing.facts, period: prior)
            printRows(pr, column: A1.column(max(0, A1.index(col) - 1)), title: "FY\(prior.fiscalYear) (backtest)")
            printChecks(Validator.run(mapping, rows: pr, facts: filing.facts, period: prior))
        }
        if let e = engine() {
            var o = Summarizer.Options()
            o.language = opt("--language") ?? "English"
            let segs = mapping.rows.compactMap { r in r.terms?.first?.dims.map { (name: r.label, dims: $0) } }
            let kf = KeyFigures.compute(facts: filing.facts, period: filing.period, prior: filing.prior, segments: segs)
            let res = try await Summarizer(engine: e, options: o).summarize(filingHTML: html, company: filing.company, keyFigures: kf) { p in
                FileHandle.standardError.write("… \(p)\n".data(using: .utf8)!)
            }
            print("\n" + res.markdown(company: filing.company))
        }

    case "run":
        guard let ticker = opt("--ticker"), let ua = opt("--ua"), let sheet = opt("--sheet"), let token = opt("--token") else {
            print("--ticker, --ua, --sheet, --token required"); exit(2)
        }
        var cfg = FinFillPipeline.Config(ticker: ticker, secUserAgent: ua, spreadsheet: sheet, mapping: try loadMapping())
        cfg.dryRun = !flag("--write")
        cfg.overwrite = flag("--overwrite")
        cfg.fiscalYear = opt("--fy").flatMap(Int.init)
        if let l = opt("--language") { cfg.summaryOptions.language = l }
        let report = try await FinFillPipeline(config: cfg, tokens: StaticTokenProvider(token), engine: engine()).run { e in
            if case let .log(s) = e { print(s) }
        }
        for p in report.plan { print("\(p.action.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(p.range)  \(p.content?.display ?? "")  (was: \(p.existing ?? "empty"))") }
        for d in report.backtest { print("backtest \(d.sheet)!\(d.row) \(d.label): mapping \(NumberFormat.plain(d.computed)) vs sheet \(d.existing.map(NumberFormat.plain) ?? "empty")") }
        if let s = report.summary { print("\n" + s.markdown(company: report.filing.company)) }

    default:
        print("usage: finfill local --html FILE [...] | finfill run --ticker T --ua UA --sheet ID --token TOKEN [--write]")
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
