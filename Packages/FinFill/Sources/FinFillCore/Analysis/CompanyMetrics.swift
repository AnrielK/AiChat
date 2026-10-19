import Foundation

/// Pojmy US-GAAP pro ukazatele, které se počítají z companyfacts (Comps, kvartály).
public enum Concepts {
    public static let revenue = ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax",
                                 "us-gaap:RevenueFromContractWithCustomerIncludingAssessedTax", "us-gaap:SalesRevenueNet"]
    public static let grossProfit = ["us-gaap:GrossProfit"]
    public static let costOfRevenue = ["us-gaap:CostOfRevenue", "us-gaap:CostOfGoodsAndServicesSold"]
    public static let operatingIncome = ["us-gaap:OperatingIncomeLoss"]
    public static let netIncome = ["us-gaap:NetIncomeLoss", "us-gaap:NetIncomeLossAvailableToCommonStockholdersBasic", "us-gaap:ProfitLoss"]
    public static let epsDiluted = ["us-gaap:EarningsPerShareDiluted", "us-gaap:EarningsPerShareBasicAndDiluted"]
    public static let operatingCashFlow = ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                                           "us-gaap:NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"]
    public static let capex = ["us-gaap:PaymentsToAcquirePropertyPlantAndEquipment", "us-gaap:PaymentsToAcquireProductiveAssets"]
    public static let depreciation = ["us-gaap:DepreciationDepletionAndAmortization", "us-gaap:DepreciationAmortizationAndAccretionNet",
                                      "us-gaap:DepreciationAndAmortization", "us-gaap:Depreciation"]

    public static let cash = ["us-gaap:CashAndCashEquivalentsAtCarryingValue",
                              "us-gaap:CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"]
    public static let shortTermInvestments = ["us-gaap:ShortTermInvestments", "us-gaap:MarketableSecuritiesCurrent",
                                              "us-gaap:AvailableForSaleSecuritiesDebtSecuritiesCurrent"]
    /// Celkový dlouhodobý dluh včetně splatné části – když ho firma taguje.
    public static let totalLongTermDebt = ["us-gaap:LongTermDebt", "us-gaap:DebtInstrumentCarryingAmount"]
    public static let longTermDebtNoncurrent = ["us-gaap:LongTermDebtNoncurrent", "us-gaap:LongTermDebtAndCapitalLeaseObligations"]
    public static let longTermDebtCurrent = ["us-gaap:LongTermDebtCurrent", "us-gaap:DebtCurrent",
                                             "us-gaap:LongTermDebtAndCapitalLeaseObligationsCurrent"]
    public static let shortTermBorrowings = ["us-gaap:ShortTermBorrowings", "us-gaap:CommercialPaper"]
    public static let sharesOutstanding = ["dei:EntityCommonStockSharesOutstanding", "us-gaap:CommonStockSharesOutstanding"]
    public static let dilutedShares = ["us-gaap:WeightedAverageNumberOfDilutedSharesOutstanding"]
}

/// Jedna firma pro Comps: LTM výsledovka a cash flow, poslední rozvaha, počet akcií.
/// Všechno ze SEC (companyfacts); cenu doplní list živě přes GOOGLEFINANCE.
public struct CompanySnapshot: Sendable, Identifiable {
    public var id: String { ticker }
    public let ticker: String
    public let name: String
    /// Konec období LTM (poslední kvartál) a kolik kvartálů je sečteno (4; 0 = poslední celý rok).
    public let ltmEnd: String?
    public let ltmQuarters: Int
    public let revenue: Double?
    public let grossProfit: Double?
    public let ebit: Double?
    public let depreciation: Double?
    public let netIncome: Double?
    public let operatingCashFlow: Double?
    public let capex: Double?
    /// Meziroční růst tržeb (LTM vs. LTM o rok dřív, jinak poslední FY vs. předchozí FY).
    public let revenueGrowth: Double?
    public let balanceDate: String?
    public let cash: Double?            // hotovost + krátkodobé investice
    public let debt: Double?
    public let shares: Double?

    public var ebitda: Double? {
        guard let ebit else { return nil }
        return ebit + (depreciation ?? 0)
    }
    public var freeCashFlow: Double? {
        guard let cfo = operatingCashFlow, let capex else { return nil }
        return cfo - capex
    }
    public var netDebt: Double? {
        guard debt != nil || cash != nil else { return nil }
        return (debt ?? 0) - (cash ?? 0)
    }

    /// Co chybí pro základní multiply (zobrazí se v logu a v poznámce listu).
    public var missing: [String] {
        var m: [String] = []
        if revenue == nil { m.append("tržby") }
        if ebit == nil { m.append("EBIT") }
        if netIncome == nil { m.append("čistý zisk") }
        if shares == nil { m.append("počet akcií") }
        if balanceDate == nil { m.append("rozvaha") }
        return m
    }

    public static func compute(ticker: String, name: String, facts: [Fact]) -> CompanySnapshot {
        let h = QuarterHistory(facts: facts)
        let rev = h.ltm(Concepts.revenue)
        let gp = h.ltm(Concepts.grossProfit)?.value ?? {
            guard let r = rev?.value, let c = h.ltm(Concepts.costOfRevenue)?.value else { return nil }
            return r - c
        }()
        var growth: Double?
        if let cur = rev, let prev = h.ltm(Concepts.revenue, offsetYears: 1), cur.quarters == prev.quarters, prev.value > 0 {
            growth = cur.value / prev.value - 1
        } else {
            let years = h.annual(Concepts.revenue)
            if years.count >= 2, years[1].value > 0 { growth = years[0].value / years[1].value - 1 }
        }

        let date = h.latestBalanceDate()
        var cash: Double?, debt: Double?
        if let date {
            let c = h.instant(Concepts.cash, at: date)
            let sti = h.instant(Concepts.shortTermInvestments, at: date)
            if c != nil || sti != nil { cash = (c ?? 0) + (sti ?? 0) }
            let borrowings = h.instant(["us-gaap:ShortTermBorrowings"], at: date) ?? 0
            let paper = h.instant(["us-gaap:CommercialPaper"], at: date) ?? 0
            if let total = h.instant(Concepts.totalLongTermDebt, at: date) {
                debt = total + borrowings + paper
            } else {
                let nc = h.instant(Concepts.longTermDebtNoncurrent, at: date)
                let cur = h.instant(Concepts.longTermDebtCurrent, at: date)
                if nc != nil || cur != nil || borrowings != 0 || paper != 0 {
                    debt = (nc ?? 0) + (cur ?? 0) + borrowings + paper
                } else {
                    debt = 0   // rozvaha je, dluh žádný netagovaný → bez dluhu
                }
            }
        }
        let shares = h.latestInstant(Concepts.sharesOutstanding, unit: "shares")?.value
            ?? h.quarters(Concepts.dilutedShares, unit: "shares").first(where: { !$0.derived })?.value

        return CompanySnapshot(
            ticker: ticker.uppercased(), name: name,
            ltmEnd: rev?.end, ltmQuarters: rev?.quarters ?? 0,
            revenue: rev?.value, grossProfit: gp,
            ebit: h.ltm(Concepts.operatingIncome)?.value,
            depreciation: h.ltm(Concepts.depreciation)?.value,
            netIncome: h.ltm(Concepts.netIncome)?.value,
            operatingCashFlow: h.ltm(Concepts.operatingCashFlow)?.value,
            capex: h.ltm(Concepts.capex)?.value,
            revenueGrowth: growth,
            balanceDate: date, cash: cash, debt: debt, shares: shares)
    }
}

/// Posledních až 8 kvartálů cílové firmy pro list „Kvartály“ a earnings review.
public struct QuarterlyFigures: Sendable {
    public enum Metric: String, CaseIterable, Sendable {
        case revenue, grossProfit, operatingIncome, netIncome, eps, operatingCashFlow, capex, freeCashFlow

        public var title: String {
            switch self {
            case .revenue: "Tržby"
            case .grossProfit: "Hrubý zisk"
            case .operatingIncome: "Provozní zisk (EBIT)"
            case .netIncome: "Čistý zisk"
            case .eps: "EPS zředěný (USD)"
            case .operatingCashFlow: "Provozní cash flow"
            case .capex: "Investice (capex)"
            case .freeCashFlow: "Volné cash flow (FCF)"
            }
        }

        public var englishTitle: String {
            switch self {
            case .revenue: "Revenue"
            case .grossProfit: "Gross profit"
            case .operatingIncome: "Operating income"
            case .netIncome: "Net income"
            case .eps: "Diluted EPS"
            case .operatingCashFlow: "Operating cash flow"
            case .capex: "Capex"
            case .freeCashFlow: "Free cash flow"
            }
        }

        var isPerShare: Bool { self == .eps }
    }

    public struct Column: Sendable, Identifiable {
        public var id: String { quarter.end }
        public let quarter: FiscalQuarter
        public var values: [Metric: QuarterValue]
        public func value(_ m: Metric) -> Double? { values[m]?.value }
    }

    /// Nejnovější kvartál první.
    public let columns: [Column]

    public var latest: Column? { columns.first }
    public var isEmpty: Bool { columns.isEmpty }

    public static func compute(facts: [Fact], count: Int = 8) -> QuarterlyFigures {
        let h = QuarterHistory(facts: facts)
        var series: [Metric: [QuarterValue]] = [
            .revenue: h.quarters(Concepts.revenue),
            .operatingIncome: h.quarters(Concepts.operatingIncome),
            .netIncome: h.quarters(Concepts.netIncome),
            .eps: h.quarters(Concepts.epsDiluted, unit: "USD/shares"),
            .operatingCashFlow: h.quarters(Concepts.operatingCashFlow),
            .capex: h.quarters(Concepts.capex),
        ]
        let gp = h.quarters(Concepts.grossProfit)
        if !gp.isEmpty {
            series[.grossProfit] = gp
        } else {
            let cost = Dictionary(h.quarters(Concepts.costOfRevenue).map { ($0.quarter.end, $0) }, uniquingKeysWith: { a, _ in a })
            series[.grossProfit] = (series[.revenue] ?? []).compactMap { r in
                cost[r.quarter.end].map { QuarterValue(quarter: r.quarter, value: r.value - $0.value, derived: true) }
            }
        }
        var cols: [String: Column] = [:]
        for (m, list) in series {
            for q in list {
                cols[q.quarter.end, default: Column(quarter: q.quarter, values: [:])].values[m] = q
            }
        }
        for key in cols.keys {
            if let cfo = cols[key]?.values[.operatingCashFlow], let capex = cols[key]?.values[.capex] {
                cols[key]?.values[.freeCashFlow] = QuarterValue(quarter: cfo.quarter, value: cfo.value - capex.value,
                                                                derived: cfo.derived || capex.derived)
            }
        }
        // Jen kvartály s tržbami nebo ziskem (samotný capex z jiného období není kvartál výsledků).
        let list = cols.values
            .filter { $0.values[.revenue] != nil || $0.values[.netIncome] != nil }
            .sorted { $0.quarter.end > $1.quarter.end }
        return QuarterlyFigures(columns: Array(list.prefix(count)))
    }

    /// Kvartál o rok dřív (stejné pořadí, předchozí fiskální rok).
    public func yearAgo(of c: Column) -> Column? {
        columns.first { $0.quarter.quarter == c.quarter.quarter && $0.quarter.fiscalYear == c.quarter.fiscalYear - 1 }
    }

    /// Předchozí kvartál.
    public func previous(of c: Column) -> Column? {
        guard let i = columns.firstIndex(where: { $0.quarter.end == c.quarter.end }), i + 1 < columns.count else { return nil }
        return columns[i + 1]
    }

    public static func change(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, b != 0 else { return nil }
        return a / abs(b) - (b < 0 ? -1 : 1)
    }

    static func money(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        return abs(v) >= 1e9 ? String(format: "$%.2fB", v / 1e9) : String(format: "$%.0fM", v / 1e6)
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        return String(format: "%+.0f%%", v * 100)
    }

    func format(_ m: Metric, _ v: Double?) -> String {
        guard let v else { return "n/a" }
        return m.isPerShare ? String(format: "$%.2f", v) : Self.money(v)
    }

    /// Ověřená čísla posledního kvartálu pro prompt (model nesmí čísla vymýšlet).
    public func promptTable() -> String {
        guard let cur = latest else { return "" }
        let ya = yearAgo(of: cur), prev = previous(of: cur)
        var lines: [String] = []
        for m in Metric.allCases {
            guard let v = cur.value(m) else { continue }
            var s = "- \(m.englishTitle) \(cur.quarter.label): \(format(m, v))"
            if let p = ya?.value(m) { s += "; \(ya!.quarter.label) \(format(m, p)) (YoY \(Self.pct(Self.change(v, p))))" }
            if let p = prev?.value(m), m != .eps { s += "; prior quarter \(format(m, p)) (QoQ \(Self.pct(Self.change(v, p))))" }
            lines.append(s)
        }
        if let r = cur.value(.revenue), r != 0 {
            if let g = cur.value(.grossProfit) { lines.append(String(format: "- Gross margin %@: %.1f%%", cur.quarter.label, g / r * 100)) }
            if let o = cur.value(.operatingIncome) { lines.append(String(format: "- Operating margin %@: %.1f%%", cur.quarter.label, o / r * 100)) }
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown tabulka posledních kvartálů (náhled v appce).
    public func markdown(maxColumns: Int = 5) -> String {
        let cols = Array(columns.prefix(maxColumns))
        guard !cols.isEmpty else { return "" }
        var rows = ["| | " + cols.map(\.quarter.label).joined(separator: " | ") + " |",
                    "|---|" + cols.map { _ in "---:" }.joined(separator: "|") + "|"]
        for m in Metric.allCases where cols.contains(where: { $0.value(m) != nil }) {
            rows.append("| \(m.title) | " + cols.map { c in
                let s = format(m, c.value(m))
                return (c.values[m]?.derived ?? false) && m == .eps ? "≈" + s : s
            }.joined(separator: " | ") + " |")
        }
        if let cur = cols.first, yearAgo(of: cur) != nil {
            rows.append("| Tržby YoY | " + cols.map { c in
                Self.pct(Self.change(c.value(.revenue), yearAgo(of: c)?.value(.revenue)))
            }.joined(separator: " | ") + " |")
        }
        return rows.joined(separator: "\n")
    }
}
