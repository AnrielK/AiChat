import Foundation

public extension FinFillPipeline {
    struct NewWorkbookReport: Sendable {
        public let spreadsheetID: String
        public let url: URL
        public let title: String
        public let filing: PreparedFiling
        public let years: [WorkbookFiller.YearResult]
        public let written: Int
        public let summary: Summarizer.Result?
        public let segmentGroups: [SegmentGroup]
    }

    /// Creates a new Google Sheets workbook from `template` (statements + DCF + WACC with formulas
    /// and formatting) and fills every year column the SEC data covers — for the universal
    /// template the 9 fiscal years ending with the chosen 10-K.
    ///
    /// Uses `config.ticker`, `config.fiscalYear`, `config.mapping`, `config.secUserAgent`;
    /// `config.spreadsheet` is ignored.
    func createWorkbook(template original: SpreadsheetTemplate, title: String? = nil,
                        log: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> NewWorkbookReport {
        // Výkazy i Segments: nejnovější rok vlevo, starší doprava (výchozí), nebo naopak.
        let newestFirst = config.newestFirst
        let template = newestFirst ? original.newestFirst() : original
        let filing = try await fetchFiling(log: log)
        let yc = template.yearColumns
        let firstYear = filing.period.fiscalYear - (yc.count - 1)
        let periods = filing.facts.annualPeriods(latest: filing.period, count: yc.count)
        log(.log("Roky v datech SEC: \(periods.map { String($0.fiscalYear) }.reversed().joined(separator: ", "))"))

        // Segments of all years (older 10-Ks downloaded) before the workbook exists.
        var groups: [SegmentGroup] = []
        var yearColumns: [Int: Int] = [:]
        for i in 0..<yc.count {
            yearColumns[firstYear + i] = WorkbookFiller.column(offset: i, firstColumn: yc.first, columnCount: yc.count, newestFirst: newestFirst)
        }
        if config.segments {
            let facts = await segmentHistory(filing: filing, years: firstYear...filing.period.fiscalYear, log: log)
            groups = SegmentExtractor.extract(facts: facts, periods: periods)
        }

        // 1) Workbook with formulas and formatting.
        let ticker = config.ticker.uppercased()
        let name = title ?? "\(ticker) Valuation FY\(filing.period.fiscalYear)"
        var body = TemplateRequests.createBody(template, title: name)
        let segmentsId = 777_001
        if !groups.isEmpty, var list = body["sheets"] as? [[String: Any]] {
            let size = SegmentSheet.gridSize(groups: groups, yearColumns: yearColumns)
            let isIndex = template.sheets.firstIndex { $0.title == "IncomeStatement" }.map { $0 + 1 } ?? list.count
            list.insert(["properties": [
                "sheetId": segmentsId, "title": SegmentSheet.title, "index": isIndex,
                "gridProperties": ["rowCount": size.rows, "columnCount": size.columns, "hideGridlines": true],
            ] as [String: Any]], at: isIndex)
            for i in list.indices { if var p = list[i]["properties"] as? [String: Any] { p["index"] = i; list[i]["properties"] = p } }
            body["sheets"] = list
        }
        let created = try await GoogleSheetsClient.create(body: body, tokens: tokens)
        log(.log("Vytvořen sešit „\(name)“"))
        let sheets = GoogleSheetsClient(spreadsheetID: created.spreadsheetID, tokens: tokens)
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        let fyEnd = filing.period.endDate.split(separator: "-").compactMap { Int($0) }
        let values: [String: String] = [
            "TICKER": ticker,
            "FY_FIRST": String(firstYear),
            "TODAY": "DATE(\(today.year!),\(today.month!),\(today.day!))",
            "FYEND": fyEnd.count == 3 ? "DATE(\(fyEnd[0]),\(fyEnd[1]),\(fyEnd[2]))" : "TODAY()",
        ]
        try await sheets.structuralUpdate(TemplateRequests.contentRequests(template, sheetIds: created.sheetIds, values: values))
        log(.log("Šablona nahrána (\(template.sheets.map(\.title).joined(separator: ", ")))"))

        // 2) All years.
        let plan = WorkbookFiller.plan(mapping: config.mapping, facts: filing.facts, periods: periods,
                                       firstYear: firstYear, firstColumn: yc.first, columnCount: yc.count,
                                       newestFirst: newestFirst)
        for y in plan.years {
            let note = y.failed > 0 ? "✗ \(y.failed) kontrol nesedí – rok vynechán"
                : y.plugged > 0 ? "± \(y.plugged) dorovnání" : "✓"
            log(.log("FY\(y.fiscalYear) → \(y.column): \(y.cells) buněk \(note)"))
        }
        let cells = plan.writes.compactMap { p in p.content.map { (range: p.range, value: $0.sheetsValue) } }
        if !cells.isEmpty { try await sheets.batchUpdate(cells) }
        log(.log("Zapsáno \(cells.count) buněk"))

        if !groups.isEmpty {
            let id = created.sheetIds[SegmentSheet.title] ?? segmentsId
            try await sheets.structuralUpdate(SegmentSheet.updateCells(sheetId: id, groups: groups, yearColumns: yearColumns))
            log(.log("List „\(SegmentSheet.title)“: \(groups.map { "\($0.title) \($0.lines.count)" }.joined(separator: ", "))"))
        }

        // 3) Summary of the latest 10-K.
        let summary = try await summarize(filing: filing, sheets: sheets, write: true, log: log)
        return NewWorkbookReport(spreadsheetID: created.spreadsheetID, url: created.url, title: name, filing: filing,
                                 years: plan.years, written: cells.count, summary: summary, segmentGroups: groups)
    }
}
