import Foundation
import FinFillCore

/// Příkazy FinFillu přímo v chatu – stejné jako v CLI, zbytek se bere z obrazovky 10-K → Sheets
/// (User-Agent, vybraný sešit, přepínače analýz, peery pro ticker) a z přihlášení ke Google.
///
///     finfill new AMD                  nový sešit ze šablony (9 let) + Citlivost, Comps, Kvartály
///     finfill new AMD peers NVDA,INTC  …s peery pro Comps (uloží se pro AMD)
///     finfill analyze NVDA             jen analýzy do vybraného sešitu
///     finfill run NVDA                 náhled zápisu do vybraného sešitu
///     finfill run NVDA zapsat          zápis (+ analýzy a souhrn)
///
/// Funguje s lomítkem i bez (`/finfill …`) a bez ohledu na velikost písmen. Zpráva se modelu
/// neposílá – příkaz spustí FinFill a odpověď je jeho výsledek (průběh jde do stavového řádku).
struct FinFillCommand: Sendable, Equatable {
    enum Action: Sendable, Equatable { case new, analyze, run(write: Bool), help }

    let action: Action
    let ticker: String?
    let peers: String?
    let fiscalYear: Int?

    static func parse(_ text: String) -> FinFillCommand? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first?.lowercased(), first == "finfill" || first == "/finfill" else { return nil }
        let rest = Array(words.dropFirst())
        let verb = rest.first?.lowercased() ?? ""
        let lower = rest.map { $0.lowercased() }

        let action: Action
        switch verb {
        case "new", "nový", "novy", "novej": action = .new
        case "analyze", "analyzy", "analýzy", "analyza", "analýza": action = .analyze
        case "run":
            action = .run(write: lower.contains { ["--write", "write", "zapsat", "zapiš"].contains($0) })
        case "zapis", "zápis", "zapsat":
            action = .run(write: true)
        default: action = .help
        }

        var ticker: String?
        if rest.count >= 2, rest[1].range(of: #"^[A-Za-z][A-Za-z.\-]{0,6}$"#, options: .regularExpression) != nil {
            ticker = rest[1].uppercased()
        }
        var peers: String?
        if let i = lower.firstIndex(where: { ["peers", "--peers", "vs", "peery"].contains($0) }), i + 1 < rest.count {
            peers = rest[(i + 1)...].filter { !$0.hasPrefix("--") && !["zapsat", "write"].contains($0.lowercased()) }
                .joined(separator: ",")
        }
        var fy: Int?
        if let i = lower.firstIndex(where: { $0 == "--fy" || $0 == "fy" }), i + 1 < rest.count { fy = Int(rest[i + 1]) }
        if let w = lower.first(where: { $0.hasPrefix("fy") && $0.count == 6 }) { fy = fy ?? Int(w.dropFirst(2)) }

        return FinFillCommand(action: ticker == nil ? .help : action, ticker: ticker, peers: peers, fiscalYear: fy)
    }

    static let help = """
    **FinFill v chatu**

    - `finfill new AMD` – nový sešit v Google Sheets (výkazy 9 let, DCF, WACC) + Citlivost, Comps a Kvartály
    - `finfill new AMD peers NVDA,INTC` – totéž s peery pro Comps (pro AMD se zapamatují)
    - `finfill analyze NVDA` – jen Citlivost / Comps / Kvartály do vybraného sešitu
    - `finfill run NVDA` – náhled zápisu posledního 10-K do vybraného sešitu, `finfill run NVDA zapsat` zapíše
    - `fy2025` kdekoli v příkazu = konkrétní fiskální rok

    SEC User-Agent, vybraný sešit a přepínače analýz jsou v *Nastavení › 10-K → Sheets*, tam je i přihlášení ke Google.
    Souhrn a earnings review píše model vybraný v Nastavení.
    """
}

/// Spustí `FinFillCommand` a výsledek pošle jako odpověď v chatu.
struct FinFillCommandProvider: ChatProvider {
    let command: FinFillCommand
    let engine: FinFillEngine?

    @MainActor
    static func wrapping(text: String, settings: SettingsStore, models: ModelManager) -> FinFillCommandProvider? {
        guard let command = FinFillCommand.parse(text) else { return nil }
        return FinFillCommandProvider(command: command, engine: FinFillEngine.current(settings: settings, models: models))
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Běh

    /// Stejné klíče jako obrazovka 10-K → Sheets (`FinFillViewModel`).
    struct Stored {
        let defaults = UserDefaults.standard
        var userAgent: String { defaults.string(forKey: "finfill.ua").flatMap { $0.isEmpty ? nil : $0 } ?? "AIChat FinFill contact@example.com" }
        var spreadsheet: String { defaults.string(forKey: "finfill.sheet") ?? "" }
        var spreadsheetName: String? { defaults.string(forKey: "finfill.sheetName") }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func peers(_ ticker: String) -> String { defaults.string(forKey: "finfill.peers." + ticker) ?? "" }
    }

    private func run(into out: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        guard let ticker = command.ticker else {
            out.yield(.text(FinFillCommand.help))
            return
        }
        let stored = Stored()
        if let p = command.peers {
            let list = FinFillPipeline.normalizedPeers([p], excluding: ticker).joined(separator: ", ")
            UserDefaults.standard.set(list, forKey: "finfill.peers." + ticker)
        }

        let mapping = try TemplateMapping.bundledUniversal()
        var cfg = FinFillPipeline.Config(ticker: ticker, secUserAgent: stored.userAgent,
                                         spreadsheet: stored.spreadsheet, mapping: mapping)
        cfg.fiscalYear = command.fiscalYear
        cfg.summaryOptions.language = "Czech"
        cfg.segments = stored.bool("finfill.segments", true)
        cfg.newestFirst = stored.bool("finfill.newestFirst", true)
        cfg.sensitivity = stored.bool("finfill.sensitivity", true)
        cfg.quarterly = stored.bool("finfill.quarterly", true)
        cfg.peers = [stored.peers(ticker)]

        let log: @Sendable (FinFillPipeline.Event) -> Void = { e in
            switch e {
            case let .log(line): out.yield(.status(line + "\n"))
            case let .summary(p):
                switch p {
                case let .reducing(item): out.yield(.status("Souhrn: slučuji Item \(item)\n"))
                case .final: out.yield(.status("Souhrn: finální text\n"))
                case .section: break
                }
            }
        }

        // Přihlášení ke Google až tady, ať je chyba srozumitelná.
        do { _ = try await GoogleTokenProvider().accessToken() } catch {
            out.yield(.text("Nejsem přihlášený ke Google, takže sešit nejde vytvořit ani zapsat. Přihlas se v *Nastavení › 10-K → Sheets › Google účet* (ikona vpravo nahoře) a zkus to znovu.\n\n_\(error.localizedDescription)_"))
            return
        }

        var md = ""
        switch command.action {
        case .help:
            md = FinFillCommand.help

        case .new:
            out.yield(.status("FinFill: nový sešit pro \(ticker)…\n"))
            let pipeline = FinFillPipeline(config: cfg, tokens: GoogleTokenProvider(), engine: engine)
            let w = try await pipeline.createWorkbook(template: try SpreadsheetTemplate.bundledUniversal(), log: log)
            // Nový sešit je od teď vybraný i na obrazovce 10-K → Sheets.
            UserDefaults.standard.set(ticker, forKey: "finfill.ticker")
            UserDefaults.standard.set(w.spreadsheetID, forKey: "finfill.sheet")
            UserDefaults.standard.set(w.title, forKey: "finfill.sheetName")
            md += "**Sešit:** [\(w.title)](\(w.url.absoluteString))\n\n"
            let ok = w.years.filter { $0.failed == 0 }
            md += "Vyplněno \(w.written) buněk za \(ok.count) let (FY\(ok.map(\.fiscalYear).min().map(String.init) ?? "–")–FY\(ok.map(\.fiscalYear).max().map(String.init) ?? "–"))"
            let skipped = w.years.filter { $0.failed > 0 }
            if !skipped.isEmpty { md += ", vynecháno: " + skipped.map { "FY\($0.fiscalYear)" }.joined(separator: ", ") }
            md += ".\n\n"
            md += Self.analysisMarkdown(w.analysis)
            if let s = w.summary { md += "\n" + s.markdown(company: w.filing.company) }

        case .analyze:
            guard !cfg.spreadsheet.isEmpty else { md = Self.noSheet(ticker); break }
            out.yield(.status("FinFill: analýzy pro \(ticker) do „\(stored.spreadsheetName ?? cfg.spreadsheet)“…\n"))
            let pipeline = FinFillPipeline(config: cfg, tokens: GoogleTokenProvider(), engine: engine)
            let (_, a) = try await pipeline.analyzeOnly(log: log)
            md += "**Sešit:** \(Self.sheetLink(stored, cfg.spreadsheet))\n\n" + Self.analysisMarkdown(a)

        case let .run(write):
            guard !cfg.spreadsheet.isEmpty else { md = Self.noSheet(ticker); break }
            cfg.dryRun = !write
            out.yield(.status("FinFill: \(write ? "zápis" : "náhled") \(ticker) do „\(stored.spreadsheetName ?? cfg.spreadsheet)“…\n"))
            let pipeline = FinFillPipeline(config: cfg, tokens: GoogleTokenProvider(), engine: write ? engine : nil)
            do {
                let r = try await pipeline.run(log: log)
                md += "**Sešit:** \(Self.sheetLink(stored, cfg.spreadsheet)) · FY\(r.filing.period.fiscalYear) · \(r.filing.company)\n\n"
                let failed = r.checks.filter { !$0.passed }
                md += failed.isEmpty ? "✓ Kontroly součtů prošly.\n\n"
                    : "✗ Nesedí: " + failed.map(\.label).joined(separator: ", ") + " – zápis je zablokovaný.\n\n"
                let toWrite = r.plan.filter { $0.action == .write }.count
                md += write ? "Zapsáno \(r.written) buněk.\n\n"
                    : "Náhled: \(toWrite) buněk k zápisu. Zapíšeš příkazem `finfill run \(ticker) zapsat`.\n\n"
                md += Self.analysisMarkdown(r.analysis)
                if let s = r.summary { md += "\n" + s.markdown(company: r.filing.company) }
            } catch let PipelineError.checksFailed(checks) {
                md = "✗ Kontroly součtů nesedí (" + checks.filter { !$0.passed }.map(\.label).joined(separator: ", ")
                    + "), nic se nezapsalo. Podrobnosti ukáže náhled na obrazovce 10-K → Sheets."
            }
        }
        out.yield(.text(md))
    }

    static func noSheet(_ ticker: String) -> String {
        "Není vybraný žádný sešit. Vyber ho v *Nastavení › 10-K → Sheets*, nebo založ nový: `finfill new \(ticker)`."
    }

    static func sheetLink(_ s: Stored, _ id: String) -> String {
        let sid = GoogleSheetsClient.spreadsheetID(from: id)
        return "[\(s.spreadsheetName ?? sid)](https://docs.google.com/spreadsheets/d/\(sid)/edit)"
    }

    static func analysisMarkdown(_ a: AnalysisReport?) -> String {
        guard let a, !a.isEmpty else { return "" }
        var md = ""
        if let d = a.dcf {
            md += "### Kontrola DCF\n\n" + d.markdown() + "\n\n"
        }
        if let t = a.target, !a.peers.isEmpty {
            md += "### Comps · \(t.ticker) vs. \(a.peers.map(\.ticker).joined(separator: ", "))\n\n"
            md += CompsSheet.summary(target: t, peers: a.peers) + "\n\n"
            md += "Multiply, kvartily a implikovaná cena jsou na listu **Comps** (cena živě z GOOGLEFINANCE).\n\n"
        }
        if !a.peerErrors.isEmpty { md += "_Comps: " + a.peerErrors.joined(separator: "; ") + "_\n\n" }
        if let q = a.quarter { md += q.markdown().replacingOccurrences(of: "\n# ", with: "\n### ").replacingOccurrences(of: "# ", with: "### ", options: .anchored) + "\n" }
        for n in a.notes { md += "_\(n)_\n\n" }
        return md
    }
}
