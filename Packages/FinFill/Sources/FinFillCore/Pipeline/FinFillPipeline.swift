import Foundation

/// Everything known about one annual filing, ready to be mapped.
public struct PreparedFiling: Sendable {
    public let company: String
    public let ticker: String?
    public let facts: FactStore
    public let period: FiscalPeriod
    public let prior: FiscalPeriod?
    public let filingHTML: String?
    public let documentURL: URL?
    public var cik: Int? = nil
    /// Older 10-Ks (newest first) — sources of segment revenue for earlier years.
    public var olderFilings: [SECClient.Filing] = []
    /// Dimensional revenue facts of this filing (segments, markets, regions).
    public var segmentFacts: [Fact] = []

    /// Offline: from a downloaded 10-K (.htm, inline XBRL) and optionally a companyfacts JSON.
    public static func local(html: String, companyFacts: Data? = nil) throws -> PreparedFiling {
        let doc = try InlineXBRLParser.parse(html: html)
        var store = FactStore(doc.facts)
        var accession: String?
        if let companyFacts {
            let cf = try CompanyFactsParser.parse(companyFacts)
            store.add(cf.facts)
            accession = nil
        }
        guard let end = store.latestAnnualEnd() else { throw PipelineError.noAnnualData }
        let fy = doc.fiscalYear ?? Int(end.prefix(4))!
        let period = FiscalPeriod(fiscalYear: fy, endDate: end, accession: accession)
        return PreparedFiling(company: doc.registrantName ?? "Company", ticker: doc.ticker, facts: store,
                              period: period, prior: priorPeriod(store, before: period), filingHTML: html, documentURL: nil,
                              segmentFacts: SegmentExtractor.revenueFacts(doc.facts))
    }

    static func priorPeriod(_ store: FactStore, before p: FiscalPeriod) -> FiscalPeriod? {
        let ends = store.facts.lazy
            .filter { $0.concept == "us-gaap:NetIncomeLoss" && $0.dimensions.isEmpty && $0.end < p.endDate }
            .filter { ($0.durationDays.map { (350...380).contains($0) }) ?? false }
            .map(\.end)
        guard let end = ends.max() else { return nil }
        return FiscalPeriod(fiscalYear: p.fiscalYear - 1, endDate: end, accession: nil)
    }
}

public enum PipelineError: Error, LocalizedError {
    case noAnnualData
    case checksFailed([CheckResult])
    public var errorDescription: String? {
        switch self {
        case .noAnnualData: return "No annual (10-K) data found."
        case let .checksFailed(c):
            return "Validation failed: " + c.filter { !$0.passed }.map(\.label).joined(separator: ", ")
        }
    }
}

public struct FinFillPipeline: Sendable {
    public struct Config: Sendable {
        public var ticker: String
        public var secUserAgent: String                // "Anriel glierjml@example.com"
        public var spreadsheet: String                 // ID or URL
        public var mapping: TemplateMapping
        public var fiscalYear: Int? = nil              // nil = latest 10-K
        public var overwrite = false                   // false = only fill empty / 0 cells
        public var dryRun = true                       // plan only, do not write
        public var writeEvenIfChecksFail = false
        public var backtestPriorYear = true
        /// List se souhrnem: vždy první v sešitu, nový souhrn ho přepíše. nil = souhrn do Sheets nepsat.
        public var summarySheetTitle: String? = "Souhrn"
        /// Nový sešit: nejnovější rok v prvním sloupci výkazů, starší doprava.
        /// (Existující sešit si pořadí nese sám – pozná se z hlavičky.)
        public var newestFirst = true
        /// Sheet "Segments": revenue by segment / market / region, YoY change, share (rebuilt on write).
        public var segments = true
        public var summaryOptions = Summarizer.Options()

        public init(ticker: String, secUserAgent: String, spreadsheet: String, mapping: TemplateMapping) {
            self.ticker = ticker
            self.secUserAgent = secUserAgent
            self.spreadsheet = spreadsheet
            self.mapping = mapping
        }
    }

    public enum Event: Sendable {
        case log(String)
        case summary(Summarizer.Progress)
    }

    public struct Report: Sendable {
        public let filing: PreparedFiling
        public let rows: [ResolvedRow]
        public let checks: [CheckResult]
        public let backtest: [ColumnDifference]
        public let plan: [PlannedWrite]
        /// Year columns that are missing and get created on write.
        public let newColumns: [ColumnCreation]
        public let written: Int
        public let summary: Summarizer.Result?
        public var segmentGroups: [SegmentGroup] = []
        public var allChecksPassed: Bool { checks.allSatisfy(\.passed) }
    }

    let config: Config
    let tokens: AccessTokenProvider
    let engine: LLMEngine?

    public init(config: Config, tokens: AccessTokenProvider, engine: LLMEngine?) {
        self.config = config
        self.tokens = tokens
        self.engine = engine
    }

    // MARK: - Steps

    public func fetchFiling(log: @Sendable (Event) -> Void) async throws -> PreparedFiling {
        let sec = SECClient(userAgent: config.secUserAgent)
        log(.log("SEC: looking up \(config.ticker)…"))
        let (cik, name) = try await sec.cik(forTicker: config.ticker)
        let filings = try await sec.filings(cik: cik, forms: ["10-K", "10-K/A"]).filter { $0.form == "10-K" }

        async let factsData = sec.companyFactsData(cik: cik)
        let cf = try CompanyFactsParser.parse(try await factsData)

        let filing: SECClient.Filing
        if let fy = config.fiscalYear {
            guard let f = filings.first(where: { cf.annualReports[$0.accessionNumber] == fy }) ?? filings.first(where: { $0.reportDate.hasPrefix(String(fy)) })
            else { throw SECClient.SECError.noAnnualReport("\(config.ticker) FY\(fy)") }
            filing = f
        } else {
            guard let f = filings.first else { throw SECClient.SECError.noAnnualReport(config.ticker) }
            filing = f
        }
        log(.log("10-K \(filing.accessionNumber), period end \(filing.reportDate) — downloading document…"))
        let html = try await sec.document(filing)
        let doc = try InlineXBRLParser.parse(html: html)

        var store = FactStore(cf.facts)
        store.add(doc.facts)
        let fy = cf.annualReports[filing.accessionNumber] ?? doc.fiscalYear ?? Int(filing.reportDate.prefix(4))!
        let period = FiscalPeriod(fiscalYear: fy, endDate: filing.reportDate, accession: filing.accessionNumber)
        log(.log("Facts: \(cf.facts.count) companyfacts + \(doc.facts.count) inline XBRL, FY\(fy)"))
        return PreparedFiling(company: name, ticker: config.ticker, facts: store, period: period,
                              prior: PreparedFiling.priorPeriod(store, before: period),
                              filingHTML: html, documentURL: filing.documentURL, cik: cik,
                              olderFilings: filings.filter { $0.reportDate < filing.reportDate },
                              segmentFacts: SegmentExtractor.revenueFacts(doc.facts))
    }

    public func run(filing prepared: PreparedFiling? = nil,
                    log: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> Report {
        let filing: PreparedFiling
        if let prepared { filing = prepared } else { filing = try await fetchFiling(log: log) }
        let mapping = config.mapping

        // 1) Map + validate
        var rows = MappingResolver.resolve(mapping, facts: filing.facts, period: filing.period)
        for r in rows where !r.isComplete { log(.log("⚠︎ \(r.spec.sheet)!\(r.spec.row) \(r.spec.label): chybí \(r.missing.joined(separator: ", "))")) }
        let checks = Validator.reconcile(mapping, rows: &rows, facts: filing.facts, period: filing.period)
        for c in checks {
            let mark: String
            switch c.status {
            case .passed: mark = "✓"
            case let .plugged(row, amount): mark = "± ř.\(row) \(NumberFormat.plain(amount))"
            case .notReported: mark = "–"
            case .incomplete: mark = "… chybí data"
            case .failed: mark = "✗"
            }
            log(.log("\(mark) \(c.label): \(NumberFormat.plain(c.computed)) vs vykázáno \(c.reported.map(NumberFormat.plain) ?? "n/a")"))
        }

        // 2) Plan against the sheet
        let sheets = GoogleSheetsClient(spreadsheetID: GoogleSheetsClient.spreadsheetID(from: config.spreadsheet), tokens: tokens)
        let sheetPlan = try await SheetPlanner.plan(mapping: mapping, rows: rows, period: filing.period,
                                                    sheets: sheets, overwrite: config.overwrite)
        let plan = sheetPlan.writes
        for c in sheetPlan.newColumns {
            log(.log("\(c.sheet): sloupec \(c.column) pro \(c.year) se vytvoří kopií \(c.sourceColumn) (vzorce + formát)"))
        }
        log(.log("Plán: \(plan.filter { $0.action == .write }.count) buněk k zápisu, \(plan.filter { $0.action == .skipNotEmpty }.count) přeskočeno (neprázdné)"))

        // 3) Backtest prior year against what is already in the sheet
        var backtest: [ColumnDifference] = []
        if config.backtestPriorYear, let prior = filing.prior {
            backtest = try await self.backtest(prior: prior, filing: filing, sheets: sheets)
            log(.log("Backtest FY\(prior.fiscalYear): \(backtest.count) rows differ from the sheet"))
        }

        // 4) Write
        var written = 0
        if !config.dryRun {
            guard checks.allSatisfy(\.passed) || config.writeEvenIfChecksFail else { throw PipelineError.checksFailed(checks) }
            written = try await SheetPlanner.execute(sheetPlan, sheets: sheets)
            log(.log("Zapsáno \(written) buněk"))
        }

        // 5) Segments sheet
        var segmentGroups: [SegmentGroup] = []
        if config.segments {
            if config.dryRun {
                segmentGroups = SegmentExtractor.extract(facts: filing.segmentFacts,
                                                         periods: filing.facts.annualPeriods(latest: filing.period, count: 3))
                if !segmentGroups.isEmpty {
                    log(.log("Segmenty: \(segmentGroups.map { "\($0.title) \($0.lines.count)" }.joined(separator: ", ")) – při zápisu se přegeneruje list „\(SegmentSheet.title)“"))
                }
            } else {
                do { segmentGroups = try await rebuildSegments(filing: filing, sheets: sheets, log: log) }
                catch { log(.log("⚠︎ List Segments se nepodařilo zapsat: \(error.localizedDescription)")) }
            }
        }

        // 6) Summary
        let summary = try await summarize(filing: filing, sheets: sheets, write: !config.dryRun, log: log)
        return Report(filing: filing, rows: rows, checks: checks, backtest: backtest, plan: plan,
                      newColumns: sheetPlan.newColumns, written: written, summary: summary, segmentGroups: segmentGroups)
    }

    func backtest(prior: FiscalPeriod, filing: PreparedFiling, sheets: GoogleSheetsClient) async throws -> [ColumnDifference] {
        let mapping = config.mapping
        var rows = MappingResolver.resolve(mapping, facts: filing.facts, period: prior)
        Validator.reconcile(mapping, rows: &rows, facts: filing.facts, period: prior)
        let names = mapping.sheets
        let headers = try await sheets.batchGet(names.map { "\(A1.quote($0))!A\(mapping.headerRow):AZ\(mapping.headerRow)" }, render: .unformatted)
        var ranges: [String] = [], used: [String] = []
        for (i, n) in names.enumerated() {
            guard let col = SheetPlanner.yearColumn(headerRow: headers[safe: i]?.first ?? [], year: prior.fiscalYear) else { continue }
            let c = A1.column(col)
            ranges.append("\(A1.quote(n))!\(c)1:\(c)\((rows.map(\.spec.row).max() ?? 60) + 5)")
            used.append(n)
        }
        guard !ranges.isEmpty else { return [] }
        let values = try await sheets.batchGet(ranges, render: .unformatted)
        var existing: [String: [Int: Double]] = [:]
        for (i, n) in used.enumerated() {
            for (r, v) in (values[safe: i] ?? []).enumerated() {
                if let d = v.first as? Double { existing[n, default: [:]][r + 1] = d }
                else if let x = v.first as? Int { existing[n, default: [:]][r + 1] = Double(x) }
            }
        }
        return Validator.compare(rows: rows.filter { used.contains($0.spec.sheet) }, existing: existing)
    }

    /// Summary by the engine (if any); written to the first sheet `summarySheetTitle` when `write`.
    func summarize(filing: PreparedFiling, sheets: GoogleSheetsClient, write: Bool,
                   log: @escaping @Sendable (Event) -> Void) async throws -> Summarizer.Result? {
        guard let engine, let html = filing.filingHTML else { return nil }
        let segments = config.mapping.rows.compactMap { r -> (name: String, dims: [String: String])? in
            guard let d = r.terms?.first?.dims, !d.isEmpty else { return nil }
            return (r.label, d)
        }
        let kf = KeyFigures.compute(facts: filing.facts, period: filing.period, prior: filing.prior, segments: segments)
        let result = try await Summarizer(engine: engine, options: config.summaryOptions)
            .summarize(filingHTML: html, company: filing.company, keyFigures: kf) { p in log(.summary(p)) }
        if write, let title = config.summarySheetTitle {
            try await writeSummary(result, title: title, company: filing.company, sheets: sheets)
            log(.log("Souhrn zapsán na list „\(title)“ (první list sešitu)"))
        }
        return result
    }

    /// Jeden list se souhrnem na prvním místě sešitu; existující se vyčistí a přepíše.
    func writeSummary(_ s: Summarizer.Result, title: String, company: String, sheets: GoogleSheetsClient) async throws {
        let info = try await sheets.sheetInfo()
        let usedIds = Set(info.map(\.sheetId))
        var newId = Int.random(in: 100_000...900_000)
        while usedIds.contains(newId) { newId = Int.random(in: 100_000...900_000) }
        try await sheets.structuralUpdate(SummarySheet.requests(
            s, company: company, title: title,
            existingSheetId: info.first { $0.title == title }?.sheetId, newSheetId: newId))
    }
}
