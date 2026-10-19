import Foundation
import FinFillCore

// Usage:
//   finfill new AMD                      (zbytek z nastavení – viz `finfill config`)
//   finfill run NVDA [--write]           (sešit z nastavení „sheet“ nebo --sheet)
//   finfill analyze NVDA [--peers AMD,AVGO] [--quarterly]
//   finfill config                       (výpis)   finfill config set ua "Jméno email@x.cz"
//   finfill config peers NVDA AMD,AVGO,INTC       finfill config unset token
//
//   Plné tvary (přepínače mají přednost před nastavením):
//   finfill local --html nvda-20260125.htm [--companyfacts CIK0001045810.json] [--mapping m.json]
//                 [--column O] [--emit-json cells.json] [--llm http://localhost:8080/v1 --model qwen3.5-4b] [--language Czech]
//   finfill run --ticker NVDA --ua "Name email@x.com" --sheet <ID|URL> --token <OAuth token>
//               [--write] [--overwrite] [--fy 2026] [--llm URL --model NAME]
//   finfill new --ticker AMD --ua "Name email@x.com" --token <OAuth token> [--fy 2025]   (new workbook, 9 years)
//   finfill local --html F --universal --all-years --emit-json cells.json                (offline, all years)
//   finfill analyze --ticker NVDA --ua "Name email@x.com" --sheet <ID|URL> --token <OAuth token>
//                   [--peers AMD,AVGO,INTC] [--quarterly] [--no-sensitivity] [--llm URL --model NAME]
//   finfill quarters --companyfacts CIK0001045810.json [--peers-facts AMD=CIK0000002488.json,...]  (offline)

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
func flag(_ name: String) -> Bool { args.contains(name) }

func loadMapping() throws -> TemplateMapping {
    if let p = opt("--mapping") { return try TemplateMapping.load(from: Data(contentsOf: URL(fileURLWithPath: p))) }
    if flag("--universal") { return try TemplateMapping.bundledUniversal() }
    return try TemplateMapping.bundledNVDA()
}

var settings = CLISettings.load()

/// Přepínač, jinak nastavení (FINFILL_<KLÍČ> nebo config.json).
func value(_ flagName: String, _ key: String) -> String? { opt(flagName) ?? settings.string(key) }

/// Ticker: `--ticker NVDA` nebo první slovo po příkazu (`finfill new AMD`).
func tickerArg() -> String? {
    if let t = opt("--ticker") { return t.uppercased() }
    guard args.count >= 2, !args[1].hasPrefix("--") else { return nil }
    return args[1].uppercased()
}

func require(_ v: String?, _ what: String, _ key: String? = nil) -> String {
    if let v, !v.isEmpty { return v }
    if let key {
        print("Chybí \(what). Zadej ho přepínačem, nebo jednou do nastavení: finfill config set \(key) <hodnota>")
    } else {
        print("Chybí \(what).")
    }
    exit(2)
}

func token() -> String {
    require(opt("--token") ?? settings.oauthToken(), "OAuth token Google", "token_command")
}

func engine() -> LLMEngine? {
    guard let u = value("--llm", "llm"), let url = URL(string: u) else { return nil }
    return OpenAICompatibleEngine(baseURL: url, model: value("--model", "model") ?? "default",
                                  contextTokens: Int(value("--ctx", "ctx") ?? "") ?? 32_768)
}

/// Citlivost, Comps a Kvartály: přepínače > nastavení.
func applyAnalyses(_ cfg: inout FinFillPipeline.Config) {
    cfg.sensitivity = !flag("--no-sensitivity") && (settings.bool("sensitivity") ?? true)
    cfg.quarterly = flag("--quarterly") || (!flag("--no-quarterly") && (settings.bool("quarterly") ?? false))
    if let p = opt("--peers") ?? settings.peers(for: cfg.ticker) { cfg.peers = [p] }
    if let l = value("--language", "language") { cfg.summaryOptions.language = l }
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
        var mark: String
        switch c.status {
        case .passed: mark = "✓"
        case let .plugged(row, amount): mark = "± row \(row) \(NumberFormat.plain(amount))"
        case .notReported: mark = "– not tagged"
        case .incomplete: mark = "… incomplete"
        case .failed: mark = "✗"
        }
        print("  \(c.label.padding(toLength: 28, withPad: " ", startingAt: 0)) computed \(NumberFormat.plain(c.computed))  reported \(c.reported.map(NumberFormat.plain) ?? "n/a")  \(mark)")
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
        var rows = MappingResolver.resolve(mapping, facts: filing.facts, period: filing.period)
        let checks = Validator.reconcile(mapping, rows: &rows, facts: filing.facts, period: filing.period)
        printRows(rows, column: col, title: "FY\(filing.period.fiscalYear) → column \(col)")
        printChecks(checks)
        if let out = opt("--emit-segments") {
            let periods = filing.facts.annualPeriods(latest: filing.period, count: 9)
            let groups = SegmentExtractor.extract(facts: filing.segmentFacts, periods: periods)
            var yc: [Int: Int] = [:]
            for i in 0..<9 { yc[filing.period.fiscalYear - 8 + i] = 6 + i }
            let req = SegmentSheet.updateCells(sheetId: 1, groups: groups, yearColumns: yc)
            try JSONSerialization.data(withJSONObject: req[0], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out))
            for g in groups { print(g.title, g.lines.map { ($0.parent == nil ? "" : "  ") + $0.name }) }
        }
        if flag("--all-years"), let out = opt("--emit-json") {
            // Same as a new workbook from the universal template: 9 years ending with this 10-K in G..O.
            let periods = filing.facts.annualPeriods(latest: filing.period, count: 9)
            let plan = WorkbookFiller.plan(mapping: mapping, facts: filing.facts, periods: periods,
                                           firstYear: filing.period.fiscalYear - 8, firstColumn: 6, columnCount: 9)
            for y in plan.years { print("FY\(y.fiscalYear) → \(y.column): \(y.cells) cells, plugs \(y.plugged), failed \(y.failed)") }
            let cells: [[String: Any]] = plan.writes.compactMap { w in
                w.content.map { ["sheet": w.sheet, "cell": "\(w.column)\(w.row)", "value": $0.sheetsValue] }
            }
            try JSONSerialization.data(withJSONObject: cells, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        } else if let out = opt("--emit-json") {
            let prev = A1.column(max(0, A1.index(col) - 1))
            let cells: [[String: Any]] = rows.compactMap { r in
                guard let c = MappingResolver.content(for: r, column: col, previousColumn: prev) else { return nil }
                return ["sheet": r.spec.sheet, "cell": "\(col)\(r.spec.row)", "value": c.sheetsValue]
            }
            try JSONSerialization.data(withJSONObject: cells, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: out))
        }
        if let prior = filing.prior {
            var pr = MappingResolver.resolve(mapping, facts: filing.facts, period: prior)
            let pc = Validator.reconcile(mapping, rows: &pr, facts: filing.facts, period: prior)
            printRows(pr, column: A1.column(max(0, A1.index(col) - 1)), title: "FY\(prior.fiscalYear) (backtest)")
            printChecks(pc)
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

    case "analyze":
        let ticker = require(tickerArg(), "ticker (finfill analyze NVDA)")
        let ua = require(value("--ua", "ua"), "SEC User-Agent", "ua")
        let sheet = require(value("--sheet", "sheet"), "sešit (--sheet ID|URL)", "sheet")
        var cfg = FinFillPipeline.Config(ticker: ticker, secUserAgent: ua, spreadsheet: sheet, mapping: try TemplateMapping.bundledUniversal())
        cfg.fiscalYear = opt("--fy").flatMap(Int.init)
        applyAnalyses(&cfg)
        let (_, a) = try await FinFillPipeline(config: cfg, tokens: StaticTokenProvider(token()), engine: engine())
            .analyzeOnly { e in if case let .log(s) = e { print(s) } }
        if let d = a.dcf { print("\n== Kontrola DCF\n" + d.logLines.joined(separator: "\n")) }
        if let q = a.quarter { print("\n" + q.markdown()) }
        for n in a.notes { print("note: \(n)") }

    case "quarters":
        guard let path = opt("--companyfacts") else { print("--companyfacts required"); exit(2) }
        let cf = try CompanyFactsParser.parse(Data(contentsOf: URL(fileURLWithPath: path)),
                                              forms: CompanyFactsParser.annualAndQuarterlyForms)
        let figures = QuarterlyFigures.compute(facts: cf.facts)
        print(figures.markdown(maxColumns: 8))
        print("\n" + figures.promptTable())
        let target = CompanySnapshot.compute(ticker: opt("--ticker") ?? "TARGET", name: cf.entityName ?? "Company", facts: cf.facts)
        var peers: [CompanySnapshot] = []
        for pair in (opt("--peers-facts") ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let p = try CompanyFactsParser.parse(Data(contentsOf: URL(fileURLWithPath: kv[1])), forms: CompanyFactsParser.annualAndQuarterlyForms)
            peers.append(CompanySnapshot.compute(ticker: kv[0], name: p.entityName ?? kv[0], facts: p.facts))
        }
        for s in [target] + peers {
            func m(_ v: Double?) -> String { v.map { String(format: "%.0f", $0 / 1e6) } ?? "—" }
            print("\(s.ticker.padding(toLength: 6, withPad: " ", startingAt: 0)) LTM \(s.ltmEnd ?? "—")(\(s.ltmQuarters)q) rev \(m(s.revenue)) "
                  + "ebitda \(m(s.ebitda)) ni \(m(s.netIncome)) fcf \(m(s.freeCashFlow)) netDebt \(m(s.netDebt)) "
                  + "shares \(s.shares.map { String(format: "%.1fM", $0 / 1e6) } ?? "—") growth \(s.revenueGrowth.map { String(format: "%.1f%%", $0 * 100) } ?? "—")")
        }
        if let out = opt("--emit-comps") {
            let req = CompsSheet.requests(sheetId: 1, target: target, peers: peers, hasDCF: true)
            try JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out))
        }

    case "run":
        let ticker = require(tickerArg(), "ticker (finfill run NVDA)")
        let ua = require(value("--ua", "ua"), "SEC User-Agent", "ua")
        let sheet = require(value("--sheet", "sheet"), "sešit (--sheet ID|URL)", "sheet")
        var cfg = FinFillPipeline.Config(ticker: ticker, secUserAgent: ua, spreadsheet: sheet, mapping: try loadMapping())
        cfg.dryRun = !flag("--write")
        cfg.overwrite = flag("--overwrite")
        cfg.fiscalYear = opt("--fy").flatMap(Int.init)
        applyAnalyses(&cfg)
        let report = try await FinFillPipeline(config: cfg, tokens: StaticTokenProvider(token()), engine: engine()).run { e in
            if case let .log(s) = e { print(s) }
        }
        for c in report.newColumns { print("new column \(c.sheet)!\(c.column) for \(c.year), copied from \(c.sourceColumn), clearing rows \(c.clearRows)") }
        for p in report.plan { print("\(p.action.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(p.range)  \(p.content?.display ?? "")  (was: \(p.existing ?? "empty"))") }
        for d in report.backtest { print("backtest \(d.sheet)!\(d.row) \(d.label): mapping \(NumberFormat.plain(d.computed)) vs sheet \(d.existing.map(NumberFormat.plain) ?? "empty")") }
        if let s = report.summary { print("\n" + s.markdown(company: report.filing.company)) }

    case "new":
        let ticker = require(tickerArg(), "ticker (finfill new AMD)")
        let ua = require(value("--ua", "ua"), "SEC User-Agent", "ua")
        var cfg = FinFillPipeline.Config(ticker: ticker, secUserAgent: ua, spreadsheet: "", mapping: try TemplateMapping.bundledUniversal())
        cfg.fiscalYear = opt("--fy").flatMap(Int.init)
        applyAnalyses(&cfg)
        let r = try await FinFillPipeline(config: cfg, tokens: StaticTokenProvider(token()), engine: engine())
            .createWorkbook(template: try SpreadsheetTemplate.bundledUniversal()) { e in if case let .log(s) = e { print(s) } }
        if let d = r.analysis?.dcf { print("\n== Kontrola DCF\n" + d.logLines.joined(separator: "\n")) }
        print("\n\(r.title): \(r.url.absoluteString)")

    case "config":
        switch args.dropFirst().first {
        case "set":
            guard args.count >= 4 else { print("finfill config set <klíč> <hodnota>"); exit(2) }
            let key = args[2]
            guard CLISettings.keys.contains(where: { $0.key == key }) else {
                print("Neznámý klíč \(key). Klíče: " + CLISettings.keys.map(\.key).joined(separator: ", ")); exit(2)
            }
            settings.set(key, args[3...].joined(separator: " "))
            try settings.save()
        case "unset":
            guard args.count >= 3 else { print("finfill config unset <klíč>"); exit(2) }
            settings.values[args[2]] = nil
            try settings.save()
        case "peers":
            guard args.count >= 3 else { print("finfill config peers NVDA AMD,AVGO,INTC   (bez seznamu = smazat)"); exit(2) }
            let list = FinFillPipeline.normalizedPeers([args[3...].joined(separator: ",")], excluding: args[2]).joined(separator: ",")
            settings.setPeers(args[2], list)
            try settings.save()
        default:
            break
        }
        print(settings.describe())

    default:
        print("""
        usage:
          finfill new AMD                    nový sešit ze šablony (9 let) + analýzy
          finfill run NVDA [--write]         výkazy do sešitu z nastavení (bez --write náhled)
          finfill analyze NVDA               jen Citlivost / Comps / Kvartály
          finfill quarters --companyfacts F  offline kvartály a LTM
          finfill local --html F             offline 10-K
          finfill config                     nastavení (ua, token_command, sheet, llm, peers…)
        """)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
