import Foundation

public struct CheckResult: Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let computed: Double
    public let reported: Double?
    public let tolerance: Double
    public var difference: Double? { reported.map { computed - $0 } }
    public var passed: Bool { difference.map { abs($0) <= tolerance } ?? false }
}

public struct ColumnDifference: Sendable, Identifiable {
    public var id: String { "\(sheet)!\(row)" }
    public let sheet: String
    public let row: Int
    public let label: String
    public let computed: Double
    public let existing: Double?
}

public enum Validator {
    /// Re-adds the mapped rows and compares them with the subtotals the company reports
    /// (Assets, LiabilitiesAndStockholdersEquity, CFO, ...). A failed check means the mapping
    /// misses or double counts a line, so nothing should be written.
    public static func run(_ mapping: TemplateMapping, rows: [ResolvedRow], facts: FactStore,
                           period: FiscalPeriod) -> [CheckResult] {
        let values = Dictionary(rows.map { ("\($0.spec.sheet)!\($0.spec.row)", $0.value) }, uniquingKeysWith: { a, _ in a })
        return mapping.checks.map { check in
            var sum = 0.0
            for item in check.rows {
                let sign: Double = item.hasPrefix("-") ? -1 : 1
                let row = Int(item.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) ?? 0
                sum += sign * ((values["\(check.sheet)!\(row)"] ?? nil) ?? 0)
            }
            let unit = check.unit ?? mapping.defaults.unit
            let reported = facts.value(check.concept, period: period, type: check.period, unit: unit)
                .map { NumberFormat.round($0.value / mapping.defaults.scale, mapping.defaults.decimals) }
            // Every rounded component can be off by 0.5.
            let tol = 0.5 * Double(check.rows.count + 1)
            return CheckResult(label: check.label, computed: sum, reported: reported, tolerance: tol)
        }
    }

    /// Backtest: run the mapping for a year the sheet already contains and compare with
    /// what is there. Differences are usually reclassifications, not errors — but they show
    /// where the mapping differs from how you filled the sheet by hand.
    public static func compare(rows: [ResolvedRow], existing: [String: [Int: Double]],
                               tolerance: Double = 0.5) -> [ColumnDifference] {
        rows.compactMap { r in
            guard let v = r.value else { return nil }
            let old = existing[r.spec.sheet]?[r.spec.row]
            if let old, abs(old - v) <= tolerance { return nil }
            return ColumnDifference(sheet: r.spec.sheet, row: r.spec.row, label: r.spec.label, computed: v, existing: old)
        }
    }
}
