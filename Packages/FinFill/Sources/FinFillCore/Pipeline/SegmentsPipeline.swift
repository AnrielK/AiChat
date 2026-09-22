import Foundation

extension FinFillPipeline {
    /// Dimensional revenue facts for `years`: this filing's plus older 10-Ks (each covers 3 years),
    /// newest first so restated values win.
    func segmentHistory(filing: PreparedFiling, years: ClosedRange<Int>,
                        log: @escaping @Sendable (Event) -> Void) async -> [Fact] {
        var facts = filing.segmentFacts
        guard let cik = filing.cik else { return facts }
        _ = cik
        let sec = SECClient(userAgent: config.secUserAgent)
        var target = filing.period.fiscalYear - 3
        var used = Set<String>()
        while target >= years.lowerBound, used.count < 3 {
            let back = filing.period.fiscalYear - target
            let candidate = filing.olderFilings
                .filter { !used.contains($0.accessionNumber) }
                .min { a, b in
                    abs((DateOnly.days(from: a.reportDate, to: filing.period.endDate) ?? 0) - back * 365) <
                        abs((DateOnly.days(from: b.reportDate, to: filing.period.endDate) ?? 0) - back * 365)
                }
            guard let f = candidate,
                  let d = DateOnly.days(from: f.reportDate, to: filing.period.endDate), abs(d - back * 365) < 60 else { break }
            used.insert(f.accessionNumber)
            log(.log("Segmenty: stahuji 10-K \(f.reportDate.prefix(4)) (\(f.accessionNumber))…"))
            do {
                let doc = try InlineXBRLParser.parse(html: try await sec.document(f))
                facts += SegmentExtractor.revenueFacts(doc.facts)
            } catch {
                log(.log("⚠︎ 10-K \(f.reportDate): \(error.localizedDescription)"))
            }
            target -= 3
        }
        return facts
    }

    /// Replaces the "Segments" sheet of an existing workbook (years = IncomeStatement header).
    func rebuildSegments(filing: PreparedFiling, sheets: GoogleSheetsClient,
                         log: @escaping @Sendable (Event) -> Void) async throws -> [SegmentGroup] {
        let header = try await sheets.batchGet(["\(A1.quote("IncomeStatement"))!A\(config.mapping.headerRow):ZZ\(config.mapping.headerRow)"],
                                               render: .unformatted).first?.first ?? []
        var yearColumns: [Int: Int] = [:]
        for (i, v) in header.enumerated() { if let y = SheetPlanner.year(v) { yearColumns[y] = i } }
        guard let minYear = yearColumns.keys.min(), let maxYear = yearColumns.keys.max() else { return [] }
        let periods = filing.facts.annualPeriods(latest: filing.period, count: filing.period.fiscalYear - minYear + 1)
            .filter { $0.fiscalYear <= maxYear }
        let facts = await segmentHistory(filing: filing, years: minYear...maxYear, log: log)
        let groups = SegmentExtractor.extract(facts: facts, periods: periods)
        guard !groups.isEmpty else { log(.log("Segmenty: firma v XBRL segmenty tržeb nevykazuje")); return [] }

        let size = SegmentSheet.gridSize(groups: groups, yearColumns: yearColumns)
        let newId = Int.random(in: 100_000...900_000)
        var requests: [[String: Any]] = []
        if let old = try await sheets.sheetInfo().first(where: { $0.title == SegmentSheet.title }) {
            requests.append(["deleteSheet": ["sheetId": old.sheetId]])
        }
        requests.append(["addSheet": ["properties": [
            "sheetId": newId, "title": SegmentSheet.title,
            "gridProperties": ["rowCount": size.rows, "columnCount": size.columns, "hideGridlines": true],
        ] as [String: Any]]])
        requests += SegmentSheet.updateCells(sheetId: newId, groups: groups, yearColumns: yearColumns)
        try await sheets.structuralUpdate(requests)
        log(.log("List „\(SegmentSheet.title)“: \(groups.map { "\($0.title) \($0.lines.count)" }.joined(separator: ", "))"))
        return groups
    }
}
