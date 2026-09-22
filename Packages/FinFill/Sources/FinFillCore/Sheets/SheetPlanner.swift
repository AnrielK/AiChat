import Foundation

public struct PlannedWrite: Sendable, Identifiable {
    public enum Action: String, Sendable { case write, skipNotEmpty, skipMissingData }
    public var id: String { range }
    public let sheet: String
    public let row: Int
    public let column: String
    public let label: String
    public let content: CellContent?
    public let existing: String?      // current cell content (formula view), if any
    public let action: Action
    /// Checks whose difference was put into this cell (see `TemplateMapping.Check.plugRow`).
    public var adjustment: Double = 0
    public var adjustedBy: [String] = []
    public var range: String { A1.cell(sheet, column, row) }
}

/// A year column that does not exist yet and will be created right after the previous year:
/// insert a column (inherits width), copy the previous column with formulas and formatting
/// (relative references shift: `=N3+N4` → `=O3+O4`, `=N2+1` → `=O2+1`), then empty the cells
/// that held the previous year's typed-in numbers.
public struct ColumnCreation: Sendable, Identifiable {
    public var id: String { sheet }
    public let sheet: String
    public let sheetId: Int
    public let sourceIndex: Int           // 0-based, previous year
    public let targetIndex: Int           // 0-based, new column
    public let year: Int
    public let headerRow: Int
    /// 1-based rows emptied after the copy: typed-in values and formulas without cell references
    /// (e.g. `=6283+1793`), plus every mapped row (FinFill writes those).
    public let clearRows: [Int]
    /// Header was a typed-in year (not `=N2+1`), so the new year is written explicitly.
    public let setHeader: Bool

    public var sourceColumn: String { A1.column(sourceIndex) }
    public var column: String { A1.column(targetIndex) }

    /// Requests for spreadsheets.batchUpdate.
    public func requests() -> [[String: Any]] {
        [
            ["insertDimension": [
                "range": ["sheetId": sheetId, "dimension": "COLUMNS", "startIndex": targetIndex, "endIndex": targetIndex + 1],
                "inheritFromBefore": true,
            ] as [String: Any]],
            ["copyPaste": [
                "source": ["sheetId": sheetId, "startColumnIndex": sourceIndex, "endColumnIndex": sourceIndex + 1],
                "destination": ["sheetId": sheetId, "startColumnIndex": targetIndex, "endColumnIndex": targetIndex + 1],
                "pasteType": "PASTE_NORMAL",
                "pasteOrientation": "NORMAL",
            ] as [String: Any]],
        ]
    }
}

public struct SheetPlan: Sendable {
    public let writes: [PlannedWrite]
    public let newColumns: [ColumnCreation]
}

public enum SheetPlanner {
    public enum PlannerError: Error, LocalizedError {
        case noYearHeader(sheet: String, row: Int)
        case missingYears(sheet: String, last: Int, wanted: Int)
        case sheetMissing(String)
        public var errorDescription: String? {
            switch self {
            case let .noYearHeader(sheet, row):
                return "List \(sheet): v řádku \(row) nejsou roky, nový sloupec není podle čeho vytvořit."
            case let .missingYears(sheet, last, wanted):
                let gap = (last + 1...wanted - 1).map(String.init).joined(separator: ", ")
                return "List \(sheet): poslední rok je \(last), \(wanted) navazovat nemůže. Nejdřív doplň \(gap) (pole Fiskální rok)."
            case let .sheetMissing(name):
                return "Sešit nemá list „\(name)“, který šablona používá."
            }
        }
    }

    // MARK: - Header

    static func year(_ v: Any) -> Int? {
        let y: Int?
        if let d = v as? Double { y = d == d.rounded() ? Int(d) : nil }
        else if let i = v as? Int { y = i }
        else if let s = v as? String { y = Int(s.trimmingCharacters(in: .whitespaces).prefix(4)) }
        else { y = nil }
        return y.flatMap { (1900...2200).contains($0) ? $0 : nil }
    }

    /// Finds the column whose header row value equals the fiscal year (e.g. 2026 → "O").
    public static func yearColumn(headerRow: [Any], year: Int) -> Int? {
        headerRow.firstIndex { Self.year($0) == year }
    }

    /// Treats empty cells and 0 placeholders as empty.
    static func isEmpty(_ v: Any?) -> Bool {
        guard let v else { return true }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty || s == "0" }
        if let d = v as? Double { return d == 0 }
        if let i = v as? Int { return i == 0 }
        return false
    }

    /// `=N3+N4`, `=SUM(G5:N5)`, `=IncomeStatement!N5` → true; `=6283+1793` → false.
    static func referencesCells(_ formula: String) -> Bool {
        let unquoted = formula.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
        return unquoted.range(of: #"(?<![A-Za-z_])\$?[A-Za-z]{1,3}\$?[0-9]+"#, options: .regularExpression) != nil
    }

    /// `=(1112+6081+4500)-N12`, `=6682-N21`: numbers typed by hand for one year, next to references.
    static func hasTypedNumbers(_ formula: String) -> Bool {
        let noStrings = formula.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
        let noRefs = noStrings.replacingOccurrences(of: #"(?<![A-Za-z_])\$?[A-Za-z]{1,3}\$?[0-9]+"#, with: "", options: .regularExpression)
        return noRefs.range(of: #"(?<![A-Za-z_.])([0-9]{2,}|[0-9]+\.[0-9]+)"#, options: .regularExpression) != nil
    }

    /// Plans the creation of the `year` column from the previous year's column.
    /// - Parameter sourceColumn: the previous year column in FORMULA render, index 0 = row 1.
    public static func columnCreation(sheet: String, sheetId: Int, header: [Any], year: Int, headerRow: Int,
                                      sourceColumn: [Any?], mappedRows: Set<Int>) throws -> ColumnCreation {
        let years = header.enumerated().compactMap { i, v in Self.year(v).map { (index: i, year: $0) } }
        guard let last = years.max(by: { $0.year < $1.year }) else { throw PlannerError.noYearHeader(sheet: sheet, row: headerRow) }
        guard last.year == year - 1 else { throw PlannerError.missingYears(sheet: sheet, last: last.year, wanted: year) }

        var clear: [Int] = []
        for (i, v) in sourceColumn.enumerated() {
            let row = i + 1
            guard row > headerRow, let v, !isEmpty(v) || mappedRows.contains(row) else { continue }
            if mappedRows.contains(row) { clear.append(row); continue }
            if let s = v as? String, s.hasPrefix("=") {
                if !referencesCells(s) || hasTypedNumbers(s) { clear.append(row) }
            } else {
                clear.append(row) // typed-in number or text of the previous year
            }
        }
        for r in mappedRows where r > headerRow && !clear.contains(r) { clear.append(r) }

        let headerSource = sourceColumn.indices.contains(headerRow - 1) ? sourceColumn[headerRow - 1] : nil
        let headerIsFormula = (headerSource as? String).map { $0.hasPrefix("=") && referencesCells($0) } ?? false
        return ColumnCreation(sheet: sheet, sheetId: sheetId, sourceIndex: last.index, targetIndex: last.index + 1,
                              year: year, headerRow: headerRow, clearRows: clear.sorted(), setHeader: !headerIsFormula)
    }

    // MARK: - Plan

    /// Reads the sheets and builds the plan (nothing is written). A missing year column is
    /// planned as a `ColumnCreation` right after the previous year.
    public static func plan(mapping: TemplateMapping, rows: [ResolvedRow], period: FiscalPeriod,
                            sheets: GoogleSheetsClient, overwrite: Bool) async throws -> SheetPlan {
        let names = mapping.sheets
        let infos = Dictionary(try await sheets.sheetInfo().map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        for n in names where infos[n] == nil { throw PlannerError.sheetMissing(n) }

        let headers = try await sheets.batchGet(
            names.map { "\(A1.quote($0))!A\(mapping.headerRow):ZZ\(mapping.headerRow)" }, render: .unformatted)
        let maxRow = max((rows.map(\.spec.row).max() ?? 60) + 20, 80)

        var columns: [String: Int] = [:]
        var toCreate: [(name: String, header: [Any])] = []
        for (i, name) in names.enumerated() {
            let header = headers[safe: i]?.first ?? []
            if let col = yearColumn(headerRow: header, year: period.fiscalYear) { columns[name] = col }
            else { toCreate.append((name, header)) }
        }

        // Previous-year columns of the sheets that need a new column.
        var creations: [ColumnCreation] = []
        if !toCreate.isEmpty {
            var sourceRanges: [String] = []
            for item in toCreate {
                let years = item.header.enumerated().compactMap { i, v in year(v).map { (i, $0) } }
                guard let last = years.max(by: { $0.1 < $1.1 }) else {
                    throw PlannerError.noYearHeader(sheet: item.name, row: mapping.headerRow)
                }
                let c = A1.column(last.0)
                sourceRanges.append("\(A1.quote(item.name))!\(c)1:\(c)\(maxRow)")
            }
            let sources = try await sheets.batchGet(sourceRanges, render: .formula)
            for (i, item) in toCreate.enumerated() {
                let column = (sources[safe: i] ?? []).map { $0.first }
                let mapped = Set(rows.filter { $0.spec.sheet == item.name }.map(\.spec.row))
                let creation = try columnCreation(sheet: item.name, sheetId: infos[item.name]!.sheetId, header: item.header,
                                                  year: period.fiscalYear, headerRow: mapping.headerRow,
                                                  sourceColumn: column, mappedRows: mapped)
                creations.append(creation)
                columns[item.name] = creation.targetIndex
            }
        }

        // Current content of existing target columns (new columns will be empty in mapped rows).
        var existing: [String: [Int: Any]] = [:]
        let existingNames = names.filter { n in !creations.contains { $0.sheet == n } }
        if !existingNames.isEmpty {
            let current = try await sheets.batchGet(
                existingNames.map { "\(A1.quote($0))!\(A1.column(columns[$0]!))1:\(A1.column(columns[$0]!))\(maxRow)" },
                render: .formula)
            for (i, name) in existingNames.enumerated() {
                for (r, rowValues) in (current[safe: i] ?? []).enumerated() { existing[name, default: [:]][r + 1] = rowValues.first }
            }
        }
        return SheetPlan(writes: plan(rows: rows, columns: columns, existing: existing, overwrite: overwrite),
                         newColumns: creations)
    }

    /// Pure planning step (unit-testable without network).
    public static func plan(rows: [ResolvedRow], columns: [String: Int], existing: [String: [Int: Any]],
                            overwrite: Bool) -> [PlannedWrite] {
        rows.map { r in
            let colIndex = columns[r.spec.sheet] ?? 0
            let col = A1.column(colIndex), prev = A1.column(max(colIndex - 1, 0))
            let old = existing[r.spec.sheet]?[r.spec.row]
            let oldText = old.map { "\($0)" }
            let content = MappingResolver.content(for: r, column: col, previousColumn: prev)
            let action: PlannedWrite.Action
            if content == nil { action = .skipMissingData }
            else if !overwrite && !isEmpty(old) { action = .skipNotEmpty }
            else { action = .write }
            var w = PlannedWrite(sheet: r.spec.sheet, row: r.spec.row, column: col, label: r.spec.label,
                                 content: content, existing: oldText, action: action)
            w.adjustment = r.adjustment
            w.adjustedBy = r.adjustedBy
            return w
        }
    }

    /// Creates missing columns, empties the copied previous-year inputs, then writes the cells.
    public static func execute(_ plan: SheetPlan, sheets: GoogleSheetsClient) async throws -> Int {
        try await sheets.structuralUpdate(plan.newColumns.flatMap { $0.requests() })

        var prep: [(range: String, value: Any)] = []
        for c in plan.newColumns {
            for r in c.clearRows { prep.append((A1.cell(c.sheet, c.column, r), "")) }
            if c.setHeader { prep.append((A1.cell(c.sheet, c.column, c.headerRow), Double(c.year))) }
        }
        if !prep.isEmpty { try await sheets.batchUpdate(prep) }

        let cells = plan.writes.filter { $0.action == .write }.compactMap { p in p.content.map { (range: p.range, value: $0.sheetsValue) } }
        guard !cells.isEmpty else { return 0 }
        try await sheets.batchUpdate(cells)
        return cells.count
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
