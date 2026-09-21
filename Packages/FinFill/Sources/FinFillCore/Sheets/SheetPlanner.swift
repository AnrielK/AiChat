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
    public var range: String { A1.cell(sheet, column, row) }
}

public enum SheetPlanner {
    public enum PlannerError: Error, LocalizedError {
        case yearColumnNotFound(sheet: String, year: Int, header: [String])
        public var errorDescription: String? {
            switch self {
            case let .yearColumnNotFound(sheet, year, header):
                return "Sheet \(sheet): no column with year \(year) in the header row (found: \(header.joined(separator: ", ")))"
            }
        }
    }

    /// Finds the column whose header row value equals the fiscal year (e.g. 2026 → "O").
    public static func yearColumn(headerRow: [Any], year: Int) -> Int? {
        headerRow.firstIndex { v in
            if let d = v as? Double { return Int(d) == year }
            if let i = v as? Int { return i == year }
            if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces).prefix(4)) == year }
            return false
        }
    }

    /// Treats empty cells and 0 placeholders as empty.
    static func isEmpty(_ v: Any?) -> Bool {
        guard let v else { return true }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty || s == "0" }
        if let d = v as? Double { return d == 0 }
        if let i = v as? Int { return i == 0 }
        return false
    }

    /// Reads header + target column from the sheet and builds the write plan (nothing is written).
    public static func plan(mapping: TemplateMapping, rows: [ResolvedRow], period: FiscalPeriod,
                            sheets: GoogleSheetsClient, overwrite: Bool) async throws -> [PlannedWrite] {
        let sheetNames = mapping.sheets
        let headers = try await sheets.batchGet(
            sheetNames.map { "\(A1.quote($0))!A\(mapping.headerRow):AZ\(mapping.headerRow)" }, render: .unformatted)

        var columns: [String: Int] = [:]
        for (i, name) in sheetNames.enumerated() {
            let header = headers[safe: i]?.first ?? []
            guard let col = yearColumn(headerRow: header, year: period.fiscalYear) else {
                throw PlannerError.yearColumnNotFound(sheet: name, year: period.fiscalYear, header: header.map { "\($0)" })
            }
            columns[name] = col
        }

        let maxRow = (rows.map(\.spec.row).max() ?? 60) + 5
        let current = try await sheets.batchGet(
            sheetNames.map { "\(A1.quote($0))!\(A1.column(columns[$0]!))1:\(A1.column(columns[$0]!))\(maxRow)" },
            render: .formula)
        var existing: [String: [Int: Any]] = [:]
        for (i, name) in sheetNames.enumerated() {
            for (r, rowValues) in (current[safe: i] ?? []).enumerated() { existing[name, default: [:]][r + 1] = rowValues.first }
        }
        return plan(rows: rows, columns: columns, existing: existing, overwrite: overwrite)
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
            return PlannedWrite(sheet: r.spec.sheet, row: r.spec.row, column: col, label: r.spec.label,
                                content: content, existing: oldText, action: action)
        }
    }

    public static func execute(_ plan: [PlannedWrite], sheets: GoogleSheetsClient) async throws -> Int {
        let cells = plan.filter { $0.action == .write }.compactMap { p in p.content.map { (range: p.range, value: $0.sheetsValue) } }
        guard !cells.isEmpty else { return 0 }
        try await sheets.batchUpdate(cells)
        return cells.count
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
