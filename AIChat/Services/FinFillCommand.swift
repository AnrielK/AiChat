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
///     … sešit <ID|URL>                 kam zapsat (jinak vybraný sešit; ten se tím přepne)
///
/// Když název vybraného sešitu ticker neobsahuje, nic se nezapíše a odpověď nabídne soubory
/// z Disku s tickerem v názvu – klepnutím na odkaz (aichat://send) nebo napsáním čísla.
///
/// Funguje s lomítkem i bez (`/finfill …`) a bez ohledu na velikost písmen. Zpráva se modelu
/// neposílá – příkaz spustí FinFill a odpověď je jeho výsledek (průběh jde do stavového řádku).
struct FinFillCommand: Sendable, Equatable {
    enum Action: Sendable, Equatable { case new, analyze, run(write: Bool), help }

    let action: Action
    let ticker: String?
    let peers: String?
    let fiscalYear: Int?
    /// Cílový sešit zadaný v příkazu (ID nebo URL); nil = vybraný na obrazovce 10-K → Sheets.
    var sheet: String? = nil

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
        var sheet: String?
        if let i = lower.firstIndex(where: { ["sešit", "sesit", "--sheet", "sheet", "do"].contains($0) }), i + 1 < rest.count {
            sheet = rest[i + 1]
        }

        return FinFillCommand(action: ticker == nil ? .help : action, ticker: ticker, peers: peers, fiscalYear: fy, sheet: sheet)
    }

    /// Text příkazu (pro odkazy v nabídce sešitů).
    var text: String {
        guard let ticker else { return "finfill" }
        var parts = ["finfill"]
        switch action {
        case .new: parts.append("new")
        case .analyze: parts.append("analyze")
        case .run: parts.append("run")
        case .help: break
        }
        parts.append(ticker)
        if case .run(write: true) = action { parts.append("zapsat") }
        if let fiscalYear { parts.append("fy\(fiscalYear)") }
        if let sheet { parts += ["sešit", sheet] }
        return parts.joined(separator: " ")
    }

    /// Stejný příkaz s jiným cílovým sešitem.
    func with(sheet id: String) -> FinFillCommand {
        var c = self; c.sheet = id; return c
    }

    /// Odkaz, který v chatu po klepnutí odešle příkaz jako novou zprávu.
    static func link(_ title: String, _ command: String) -> String {
        var comps = URLComponents()
        comps.scheme = "aichat"; comps.host = "send"
        comps.queryItems = [URLQueryItem(name: "text", value: command)]
        let label = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(label)](\(comps.url?.absoluteString ?? ""))"
    }

    static let help = """
    **FinFill v chatu**

    - `finfill new AMD` – nový sešit v Google Sheets (výkazy 9 let, DCF, WACC) + Citlivost, Comps a Kvartály
    - `finfill new AMD peers NVDA,INTC` – totéž s peery pro Comps (pro AMD se zapamatují)
    - `finfill analyze NVDA` – jen Citlivost / Comps / Kvartály do vybraného sešitu
    - `finfill run NVDA` – náhled zápisu posledního 10-K do vybraného sešitu, `finfill run NVDA zapsat` zapíše
    - `fy2025` kdekoli v příkazu = konkrétní fiskální rok, `sešit <ID nebo URL>` = kam zapsat

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
        guard let command = FinFillCommand.parse(text) ?? PendingChoice.take(text) else { return nil }
        return FinFillCommandProvider(command: command, engine: FinFillEngine.current(settings: settings, models: models))
    }

    /// Nabídka sešitů z poslední odpovědi – odpověď „2“ vybere druhou možnost (platí 15 minut).
    enum PendingChoice {
        static let key = "finfill.pendingChoices", timeKey = "finfill.pendingChoicesAt"

        static func save(_ commands: [String]) {
            UserDefaults.standard.set(commands, forKey: key)
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: timeKey)
        }

        static func clear() { UserDefaults.standard.removeObject(forKey: key) }

        static func take(_ text: String) -> FinFillCommand? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
            guard let n = Int(t), n >= 1,
                  let list = UserDefaults.standard.stringArray(forKey: key), n <= list.count,
                  Date.now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: timeKey) < 15 * 60
            else { return nil }
            clear()
            return FinFillCommand.parse(list[n - 1])
        }
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
                                         spreadsheet: command.sheet ?? stored.spreadsheet, mapping: mapping)
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

        // Sešit pro analyze / run: zadaný v příkazu se rovnou vybere, vybraný se zkontroluje podle názvu.
        var sheetName = stored.spreadsheetName
        if command.action != .new, !cfg.spreadsheet.isEmpty {
            let id = GoogleSheetsClient.spreadsheetID(from: cfg.spreadsheet)
            let title = (try? await GoogleSheetsClient(spreadsheetID: id, tokens: GoogleTokenProvider()).title()) ?? sheetName ?? id
            sheetName = title
            if command.sheet != nil {
                Self.select(id: id, name: title, ticker: ticker)
            } else if !SpreadsheetMatch.name(title, contains: ticker) {
                out.yield(.text(await Self.offerSheets(for: command, ticker: ticker, current: title, currentID: id)))
                return
            }
        }
        PendingChoice.clear()

        var md = ""
        do {
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
                out.yield(.status("FinFill: analýzy pro \(ticker) do „\(sheetName ?? cfg.spreadsheet)“…\n"))
                let pipeline = FinFillPipeline(config: cfg, tokens: GoogleTokenProvider(), engine: engine)
                let (_, a) = try await pipeline.analyzeOnly(log: log)
                md += "**Sešit:** \(Self.sheetLink(sheetName, cfg.spreadsheet))\n\n" + Self.analysisMarkdown(a)

            case let .run(write):
                guard !cfg.spreadsheet.isEmpty else { md = Self.noSheet(ticker); break }
                cfg.dryRun = !write
                out.yield(.status("FinFill: \(write ? "zápis" : "náhled") \(ticker) do „\(sheetName ?? cfg.spreadsheet)“…\n"))
                let pipeline = FinFillPipeline(config: cfg, tokens: GoogleTokenProvider(), engine: write ? engine : nil)
                do {
                    let r = try await pipeline.run(log: log)
                    md += "**Sešit:** \(Self.sheetLink(sheetName, cfg.spreadsheet)) · FY\(r.filing.period.fiscalYear) · \(r.filing.company)\n\n"
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
        } catch let AnalysisError.tickerMismatch(workbook, _) {
            // Název sedí, ale DCF!C4 patří jiné firmě.
            md = await Self.offerSheets(for: command, ticker: ticker,
                                        current: (sheetName ?? cfg.spreadsheet) + " (DCF je pro \(workbook))",
                                        currentID: GoogleSheetsClient.spreadsheetID(from: cfg.spreadsheet), allowCurrent: false)
        }
        out.yield(.text(md))
    }

    static func noSheet(_ ticker: String) -> String {
        "Není vybraný žádný sešit. Vyber ho v *Nastavení › 10-K → Sheets*, nebo založ nový: `finfill new \(ticker)`."
    }

    static func sheetLink(_ name: String?, _ id: String) -> String {
        let sid = GoogleSheetsClient.spreadsheetID(from: id)
        return "[\(name ?? sid)](https://docs.google.com/spreadsheets/d/\(sid)/edit)"
    }

    /// Vybraný sešit i na obrazovce 10-K → Sheets.
    static func select(id: String, name: String, ticker: String) {
        UserDefaults.standard.set(ticker, forKey: "finfill.ticker")
        UserDefaults.standard.set(id, forKey: "finfill.sheet")
        UserDefaults.standard.set(name, forKey: "finfill.sheetName")
    }

    /// Nabídka, kam zapsat: soubory z Disku s tickerem v názvu, nový sešit, případně vybraný i tak.
    static func offerSheets(for command: FinFillCommand, ticker: String, current: String, currentID: String,
                            allowCurrent: Bool = true) async -> String {
        var md = "Vybraný sešit **\(current)** neodpovídá \(ticker), takže jsem nic nezapsal. Kam zapsat?\n\n"
        var choices: [(title: String, command: String)] = []
        var driveError: String?
        do {
            let files = try await GoogleDriveClient(tokens: GoogleTokenProvider()).spreadsheets(search: ticker, limit: 50)
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "cs_CZ")
            for f in SpreadsheetMatch.candidates(files, ticker: ticker) where f.id != currentID {
                let when = f.modified.map { " · upraveno " + rel.localizedString(for: $0, relativeTo: .now) } ?? ""
                choices.append((f.name + when, command.with(sheet: f.id).text))
            }
        } catch {
            driveError = error.localizedDescription
        }
        choices.append(("Založit nový sešit pro \(ticker)", FinFillCommand(action: .new, ticker: ticker, peers: nil,
                                                                            fiscalYear: command.fiscalYear).text))
        if allowCurrent { choices.append(("Přesto zapsat do „\(current)“", command.with(sheet: currentID).text)) }

        for (i, c) in choices.enumerated() {
            md += "\(i + 1). " + FinFillCommand.link(c.title, c.command) + "\n"
        }
        if choices.count == (allowCurrent ? 2 : 1) {
            md += "\n_Na Disku není žádný sešit s „\(ticker)“ v názvu._\n"
        }
        if let driveError { md += "\n_Seznam z Disku se nepodařilo načíst: \(driveError)_\n" }
        md += "\nKlepni na možnost, nebo napiš její číslo."
        PendingChoice.save(choices.map(\.command))
        return md
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
