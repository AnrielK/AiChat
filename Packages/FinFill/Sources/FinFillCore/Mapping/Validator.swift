import Foundation

public struct CheckResult: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        case passed
        /// Difference absorbed by `row` (e.g. "Other current assets") — shown to the user.
        case plugged(row: Int, amount: Double)
        /// The company does not tag this total; nothing to compare with.
        case notReported
        /// Some lines of the check have no data for this year (e.g. no balance sheet in the
        /// filing); nothing is plugged and those cells stay empty.
        case incomplete
        case failed
    }

    public var id: String { label }
    public let label: String
    public let sheet: String
    public let computed: Double          // before the plug
    public let reported: Double?
    public let tolerance: Double
    public let status: Status

    public var difference: Double? { reported.map { computed - $0 } }
    /// Writing is allowed unless a check really failed.
    public var passed: Bool { status != .failed }
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
    /// Re-adds the mapped rows and compares them with the totals the company reports
    /// (Assets, LiabilitiesAndStockholdersEquity, CFO, ...), in the order of `mapping.checks`.
    ///
    /// When a check has `plugRow`, a difference is put into that row ("other …" line), so a
    /// company whose statement has more lines than the template (AMD: amortization,
    /// restructuring, licensing gain) still adds up. Later checks see the plugged value.
    /// Without `plugRow` a difference fails the check and blocks writing.
    @discardableResult
    public static func reconcile(_ mapping: TemplateMapping, rows: inout [ResolvedRow], facts: FactStore,
                                 period: FiscalPeriod) -> [CheckResult] {
        var index: [String: Int] = [:]
        for (i, r) in rows.enumerated() { index["\(r.spec.sheet)!\(r.spec.row)"] = i }
        let decimals = mapping.defaults.decimals

        return mapping.checks.map { check in
            var sum = 0.0
            for item in check.rows {
                let sign: Double = item.hasPrefix("-") ? -1 : 1
                let row = Int(item.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) ?? 0
                sum += sign * (index["\(check.sheet)!\(row)"].flatMap { rows[$0].value } ?? 0)
            }
            sum = NumberFormat.round(sum, decimals)
            let unit = check.unit ?? mapping.defaults.unit
            let reported = check.concepts.lazy
                .compactMap { facts.value($0, period: period, type: check.period, unit: unit) }.first
                .map { NumberFormat.round($0.value / mapping.defaults.scale, decimals) }
            // Every rounded component can be off by 0.5.
            let tol = 0.5 * Double(check.rows.count + 1)

            let checkRows = check.rows.compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) }
            // Missing data in the plug row itself is exactly what the plug fills (a line the company
            // doesn't report); missing data elsewhere means the statement isn't there for this year.
            let incomplete = checkRows.contains { r in
                r != check.plugRow && (index["\(check.sheet)!\(r)"].map { !rows[$0].isComplete } ?? false)
            }
            let status: CheckResult.Status
            if incomplete {
                status = .incomplete
            } else if let reported {
                let diff = NumberFormat.round(reported - sum, decimals)
                if abs(diff) <= tol {
                    status = .passed
                } else if let plug = check.plugRow, let i = index["\(check.sheet)!\(plug)"],
                          check.rows.contains(where: { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) == plug }) {
                    // The plug row enters the check with its sign ("-6" for cost of revenue).
                    let sign: Double = check.rows.contains("-\(plug)") ? -1 : 1
                    let amount = sign * diff
                    rows[i].adjustment += amount
                    rows[i].adjustedBy.append(check.label)
                    rows[i].value = NumberFormat.round((rows[i].value ?? 0) + amount, decimals)
                    status = .plugged(row: plug, amount: amount)
                } else {
                    status = .failed
                }
            } else {
                status = .notReported
            }
            return CheckResult(label: check.label, sheet: check.sheet, computed: sum, reported: reported,
                               tolerance: tol, status: status)
        }
    }

    /// Checks without modifying rows (for display / tests).
    public static func run(_ mapping: TemplateMapping, rows: [ResolvedRow], facts: FactStore,
                           period: FiscalPeriod) -> [CheckResult] {
        var copy = rows
        return reconcile(mapping, rows: &copy, facts: facts, period: period)
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
