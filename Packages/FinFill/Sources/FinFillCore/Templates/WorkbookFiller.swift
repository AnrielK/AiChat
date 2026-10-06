import Foundation

/// Fills all year columns of a freshly created workbook.
public enum WorkbookFiller {
    public struct YearResult: Sendable, Identifiable {
        public var id: Int { fiscalYear }
        public let fiscalYear: Int
        public let column: String
        public let checks: [CheckResult]
        public let cells: Int
        public var plugged: Int { checks.filter { if case .plugged = $0.status { return true } else { return false } }.count }
        public var failed: Int { checks.filter { $0.status == .failed }.count }
    }

    public struct Plan: Sendable {
        public let writes: [PlannedWrite]
        public let years: [YearResult]
    }

    /// - Parameters:
    ///   - firstYear: nejstarší rok bloku (vlevo, nebo s `newestFirst` vpravo).
    ///   - periods: available fiscal years (from `FactStore.annualPeriods`).
    ///   - newestFirst: nejnovější rok v prvním sloupci bloku, starší doprava (`SpreadsheetTemplate.newestFirst()`).
    public static func plan(mapping: TemplateMapping, facts: FactStore, periods: [FiscalPeriod],
                            firstYear: Int, firstColumn: Int, columnCount: Int, newestFirst: Bool = false) -> Plan {
        var writes: [PlannedWrite] = []
        var years: [YearResult] = []
        for period in periods.sorted(by: { $0.fiscalYear < $1.fiscalYear }) {
            let offset = period.fiscalYear - firstYear
            guard (0..<columnCount).contains(offset) else { continue }
            let col = column(offset: offset, firstColumn: firstColumn, columnCount: columnCount, newestFirst: newestFirst)
            var rows = MappingResolver.resolve(mapping, facts: facts, period: period)
            let checks = Validator.reconcile(mapping, rows: &rows, facts: facts, period: period)
            // Year with a failed check is left empty rather than half right.
            guard !checks.contains(where: { $0.status == .failed }) else {
                years.append(YearResult(fiscalYear: period.fiscalYear, column: A1.column(col), checks: checks, cells: 0))
                continue
            }
            // Literal formulas pointing at the previous year ({prev}) make no sense in the first column.
            let withData = MappingResolver.sheetsWithData(rows)
            let usable = rows.filter { withData.contains($0.spec.sheet) && (offset > 0 || $0.spec.formula == nil) }
            let columns = Dictionary(uniqueKeysWithValues: mapping.sheets.map { ($0, col) })
            let planned = SheetPlanner.plan(rows: usable, columns: columns, existing: [:], overwrite: true,
                                            newestFirst: newestFirst ? Set(mapping.sheets) : [])
                .filter { $0.action == .write }
            writes += planned
            // Opening values for formula rows of the first column (cash at beginning of period).
            if offset == 0 {
                for r in rows where r.spec.formula != nil && withData.contains(r.spec.sheet) {
                    let scale = r.spec.scale ?? mapping.defaults.scale
                    guard let fact = r.spec.opening?.lazy.compactMap({ facts.openingValue($0, period: period) }).first else { continue }
                    let v = NumberFormat.round(fact.value / scale, r.spec.decimals ?? mapping.defaults.decimals)
                    writes.append(PlannedWrite(sheet: r.spec.sheet, row: r.spec.row, column: A1.column(col), label: r.spec.label,
                                               content: .number(v), existing: nil, action: .write))
                }
            }
            years.append(YearResult(fiscalYear: period.fiscalYear, column: A1.column(col), checks: checks, cells: planned.count))
        }
        return Plan(writes: writes, years: years)
    }

    /// 0-based sloupec roku: `offset` = roky od nejstaršího v bloku.
    public static func column(offset: Int, firstColumn: Int, columnCount: Int, newestFirst: Bool) -> Int {
        newestFirst ? firstColumn + columnCount - 1 - offset : firstColumn + offset
    }
}
