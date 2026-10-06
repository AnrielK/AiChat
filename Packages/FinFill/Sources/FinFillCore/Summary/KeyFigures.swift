import Foundation

/// Headline numbers computed in code from XBRL (never by the model). They are passed to the
/// model as the only numbers it may quote, and shown in the summary sheet.
public struct KeyFigures: Sendable {
    public struct Line: Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let current: Double?
        public let prior: Double?
        public let kind: Kind
        public enum Kind: Sendable { case money, percent, perShare }

        public var change: Double? {
            guard kind == .money || kind == .perShare, let c = current, let p = prior, p != 0 else { return nil }
            return c / p - 1
        }

        /// Marže: rozdíl v procentních bodech (0.711 − 0.750 = −0.039).
        public var marginChange: Double? {
            guard kind == .percent, let c = current, let p = prior else { return nil }
            return c - p
        }
    }

    public let fiscalYear: Int
    public let lines: [Line]

    public static func compute(facts: FactStore, period: FiscalPeriod, prior: FiscalPeriod?,
                               segments: [(name: String, dims: [String: String])] = []) -> KeyFigures {
        func v(_ c: [String], _ p: FiscalPeriod?, _ t: PeriodType = .duration, unit: String = "USD",
               dims: [String: String] = [:]) -> Double? {
            guard let p else { return nil }
            return c.lazy.compactMap { facts.value($0, period: p, type: t, unit: unit, dims: dims)?.value }.first
        }
        let revenueC = ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"]
        func block(_ p: FiscalPeriod?) -> [String: Double?] {
            let rev = v(revenueC, p)
            let gp = v(["us-gaap:GrossProfit"], p)
            let op = v(["us-gaap:OperatingIncomeLoss"], p)
            let ni = v(["us-gaap:NetIncomeLoss"], p)
            let cfo = v(["us-gaap:NetCashProvidedByUsedInOperatingActivities"], p)
            let capex = v(["us-gaap:PaymentsToAcquireProductiveAssets", "us-gaap:PaymentsToAcquirePropertyPlantAndEquipment"], p)
            let cash = v(["us-gaap:CashAndCashEquivalentsAtCarryingValue"], p, .instant)
            let sti = v(["nvda:MarketableSecuritiesAndEquitySecuritiesFVNI", "us-gaap:ShortTermInvestments", "us-gaap:MarketableSecuritiesCurrent"], p, .instant)
            let debt = [v(["us-gaap:LongTermDebtNoncurrent"], p, .instant), v(["us-gaap:LongTermDebtCurrent", "us-gaap:DebtCurrent"], p, .instant)]
                .compactMap { $0 }.reduce(0, +)
            func ratio(_ a: Double?, _ b: Double?) -> Double? { (a != nil && b != nil && b! != 0) ? a! / b! : nil }
            return [
                "Revenue": rev, "Gross margin": ratio(gp, rev), "Operating income": op, "Operating margin": ratio(op, rev),
                "Net income": ni, "Diluted EPS": v(["us-gaap:EarningsPerShareDiluted"], p, unit: "USD/shares"),
                "Operating cash flow": cfo, "Capital expenditures": capex,
                "Free cash flow": (cfo != nil && capex != nil) ? cfo! - capex! : nil,
                "Cash + short-term investments": (cash ?? 0) + (sti ?? 0), "Total debt": debt,
            ]
        }
        let cur = block(period), pri = block(prior)
        let order: [(String, Line.Kind)] = [
            ("Revenue", .money), ("Gross margin", .percent), ("Operating income", .money), ("Operating margin", .percent),
            ("Net income", .money), ("Diluted EPS", .perShare), ("Operating cash flow", .money),
            ("Capital expenditures", .money), ("Free cash flow", .money), ("Cash + short-term investments", .money),
            ("Total debt", .money),
        ]
        var lines = order.map { Line(name: $0.0, current: cur[$0.0] ?? nil, prior: pri[$0.0] ?? nil, kind: $0.1) }
        for s in segments {
            lines.append(Line(name: "Revenue – \(s.name)", current: v(revenueC, period, dims: s.dims),
                              prior: v(revenueC, prior, dims: s.dims), kind: .money))
        }
        return KeyFigures(fiscalYear: period.fiscalYear, lines: lines.filter { $0.current != nil })
    }

    /// „$215.9B“, „71.1%“, „$4.90“, „n/a“.
    static func format(_ v: Double?, _ k: Line.Kind) -> String {
        guard let v else { return "n/a" }
        switch k {
        case .money: return String(format: "$%.1fB", v / 1e9)
        case .percent: return String(format: "%.1f%%", v * 100)
        case .perShare: return String(format: "$%.2f", v)
        }
    }

    /// Meziroční změna: částky v %, marže v procentních bodech.
    static func changeText(_ l: Line) -> String {
        if let c = l.change { return String(format: "%+.0f%%", c * 100) }
        if let d = l.marginChange { return String(format: "%+.1f p.b.", d * 100) }
        return ""
    }

    /// Plain-text table used in prompts and in the summary sheet.
    public func table() -> String {
        func fmt(_ v: Double?, _ k: Line.Kind) -> String {
            guard let v else { return "n/a" }
            switch k {
            case .money: return String(format: "$%.1fB", v / 1e9)
            case .percent: return String(format: "%.1f%%", v * 100)
            case .perShare: return String(format: "$%.2f", v)
            }
        }
        return lines.map { l in
            var s = "- \(l.name): FY\(fiscalYear) \(fmt(l.current, l.kind)); FY\(fiscalYear - 1) \(fmt(l.prior, l.kind))"
            if let c = l.change { s += String(format: " (%+.0f%%)", c * 100) }
            return s
        }.joined(separator: "\n")
    }
}
