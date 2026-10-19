import Foundation

/// Fiskální kvartál: konec období + pořadí ve fiskálním roce (FY = rok, ve kterém fiskální rok končí –
/// NVIDIA FY2026 končí v lednu 2026, Apple FY2025 v září 2025).
public struct FiscalQuarter: Sendable, Hashable, Comparable, Identifiable {
    public var id: String { end }
    public let end: String          // yyyy-MM-dd
    public let fiscalYear: Int
    public let quarter: Int         // 1...4

    public init(end: String, fiscalYear: Int, quarter: Int) {
        self.end = end
        self.fiscalYear = fiscalYear
        self.quarter = quarter
    }

    /// „Q3 FY26“
    public var label: String { "Q\(quarter) FY\(String(format: "%02d", fiscalYear % 100))" }

    public static func < (a: FiscalQuarter, b: FiscalQuarter) -> Bool { a.end < b.end }
}

/// Hodnota za jeden kvartál. `derived` = dopočtená (YTD − předchozí YTD, Q4 = FY − 9M),
/// ne přímo vykázaná za tři měsíce.
public struct QuarterValue: Sendable, Hashable {
    public let quarter: FiscalQuarter
    public let value: Double
    public let derived: Bool
}

/// Kumulativní (YTD) a roční údaje z companyfacts (10-K + 10-Q) → samostatné kvartály a LTM.
///
/// 10-Q vykazuje výsledovku za 3 měsíce i od začátku roku, cash flow jen od začátku roku, 10-K jen
/// celý rok. Kvartál se proto bere přímo, když je vykázaný, jinak jako rozdíl dvou kumulativních
/// údajů se stejným začátkem fiskálního roku (Q4 = celý rok − 9 měsíců).
public struct QuarterHistory: Sendable {
    struct Key: Hashable { let start: String; let end: String }

    /// concept|unit → (start, end) → fakt (při duplicitě vyhrává později podaný = případně přepočtený).
    private var durations: [String: [Key: Fact]] = [:]
    private var instants: [String: [String: Fact]] = [:]
    /// Začátky fiskálních let (z ročních údajů, YTD údajů a konců let + 1 den).
    private(set) var fiscalYearStarts: [String] = []

    public init(facts: [Fact]) {
        var starts = Set<String>()
        for f in facts where f.dimensions.isEmpty {
            let k = "\(f.concept)|\(f.unit)"
            if let start = f.start {
                guard let days = f.durationDays, (60...390).contains(days) else { continue }
                let key = Key(start: start, end: f.end)
                if let old = durations[k]?[key], old.filed >= f.filed { continue }
                durations[k, default: [:]][key] = f
                if days >= 170 { starts.insert(start) }
                if (350...380).contains(days), let next = Self.addDays(f.end, 1) { starts.insert(next) }
            } else {
                if let old = instants[k]?[f.end], old.filed >= f.filed { continue }
                instants[k, default: [:]][f.end] = f
            }
        }
        fiscalYearStarts = starts.sorted()
    }

    // MARK: - Kvartály

    /// Samostatné kvartály, nejnovější první. Pojmy jsou v pořadí priority; pro každý kvartál se vezme
    /// první pojem, který ho má (firmy mezi lety mění např. Revenues ↔ RevenueFromContract…).
    public func quarters(_ concepts: [String], unit: String = "USD") -> [QuarterValue] {
        var byEnd: [String: QuarterValue] = [:]
        for c in concepts {
            for q in quarters(concept: c, unit: unit) where byEnd[q.quarter.end] == nil {
                byEnd[q.quarter.end] = q
            }
        }
        return byEnd.values.sorted { $0.quarter.end > $1.quarter.end }
    }

    func quarters(concept: String, unit: String) -> [QuarterValue] {
        guard let all = durations["\(concept)|\(unit)"] else { return [] }
        var out: [String: QuarterValue] = [:]

        // 1) Přímo vykázané tříměsíční údaje.
        for (key, f) in all {
            guard let d = f.durationDays, (80...100).contains(d), let q = fiscalQuarter(end: key.end) else { continue }
            out[key.end] = QuarterValue(quarter: q, value: f.value, derived: false)
        }

        // 2) Rozdíly kumulativních údajů se stejným začátkem (6M − 3M, 9M − 6M, 12M − 9M).
        var groups: [String: [Int: Fact]] = [:]
        for (key, f) in all {
            guard let d = f.durationDays, (80...380).contains(d) else { continue }
            let k = Int((Double(d) / 91.3).rounded())
            guard (1...4).contains(k) else { continue }
            groups[key.start, default: [:]][k] = f
        }
        for (_, cum) in groups {
            for k in 2...4 {
                guard let cur = cum[k], let prev = cum[k - 1], out[cur.end] == nil,
                      let q = fiscalQuarter(end: cur.end) else { continue }
                out[cur.end] = QuarterValue(quarter: q, value: cur.value - prev.value, derived: true)
            }
        }
        return Array(out.values)
    }

    /// Fiskální rok a pořadí kvartálu pro konec období.
    func fiscalQuarter(end: String) -> FiscalQuarter? {
        guard let start = fiscalYearStarts.last(where: { s in
            s <= end && (Self.days(s, end).map { $0 <= 380 } ?? false)
        }), let days = Self.days(start, end) else { return nil }
        let q = min(max(Int((Double(days) / 91.3).rounded()), 1), 4)
        guard let yearEnd = Self.addDays(start, 364), let fy = Int(yearEnd.prefix(4)) else { return nil }
        return FiscalQuarter(end: end, fiscalYear: fy, quarter: q)
    }

    // MARK: - LTM

    public struct LTM: Sendable {
        public let value: Double
        public let end: String
        /// 4 = součet posledních čtyř kvartálů, 0 = poslední celý fiskální rok (kvartály chybí).
        public let quarters: Int
    }

    /// Posledních 12 měsíců = součet čtyř po sobě jdoucích kvartálů; když nejsou, poslední celý rok.
    /// `offsetYears` 1 = LTM o rok dřív (pro meziroční růst).
    public func ltm(_ concepts: [String], unit: String = "USD", offsetYears: Int = 0) -> LTM? {
        let qs = quarters(concepts, unit: unit)
        if let latest = qs.first {
            let anchor: String? = offsetYears == 0 ? latest.quarter.end : Self.addDays(latest.quarter.end, -364 * offsetYears)
            if let anchor, let window = Self.consecutive(qs, endingNear: anchor) {
                return LTM(value: window.reduce(0) { $0 + $1.value }, end: window[0].quarter.end, quarters: 4)
            }
        }
        // Záloha: celé fiskální roky.
        let years = annual(concepts, unit: unit)
        guard years.count > offsetYears else { return nil }
        let y = years[offsetYears]
        return LTM(value: y.value, end: y.end, quarters: 0)
    }

    /// Čtyři po sobě jdoucí kvartály, z nichž poslední končí do ±20 dní od `anchor`.
    static func consecutive(_ qs: [QuarterValue], endingNear anchor: String) -> [QuarterValue]? {
        guard let i = qs.firstIndex(where: { abs(days($0.quarter.end, anchor) ?? 999) <= 20 }), i + 3 < qs.count else { return nil }
        let window = Array(qs[i...(i + 3)])
        for j in 0..<3 {
            guard let gap = days(window[j + 1].quarter.end, window[j].quarter.end), (75...105).contains(gap) else { return nil }
        }
        return window
    }

    /// Roční (350–380 dní) údaje, nejnovější první.
    public func annual(_ concepts: [String], unit: String = "USD") -> [(end: String, value: Double)] {
        var byEnd: [String: Double] = [:]
        for c in concepts {
            for (key, f) in durations["\(c)|\(unit)"] ?? [:] {
                guard let d = f.durationDays, (350...380).contains(d), byEnd[key.end] == nil else { continue }
                byEnd[key.end] = f.value
            }
        }
        return byEnd.sorted { $0.key > $1.key }.map { (end: $0.key, value: $0.value) }
    }

    // MARK: - Rozvaha

    /// Datum poslední rozvahy (podle celkových aktiv).
    public func latestBalanceDate() -> String? {
        for c in ["us-gaap:Assets", "us-gaap:LiabilitiesAndStockholdersEquity", "us-gaap:CashAndCashEquivalentsAtCarryingValue"] {
            if let d = instants["\(c)|USD"]?.keys.max() { return d }
        }
        return nil
    }

    /// Hodnota k datu (první pojem, který ji má).
    public func instant(_ concepts: [String], at date: String, unit: String = "USD") -> Double? {
        concepts.lazy.compactMap { instants["\($0)|\(unit)"]?[date]?.value }.first
    }

    /// Nejnovější hodnota bez ohledu na datum (počet akcií z titulní strany 10-Q/10-K).
    public func latestInstant(_ concepts: [String], unit: String) -> (end: String, value: Double)? {
        for c in concepts {
            if let (end, f) = instants["\(c)|\(unit)"]?.max(by: { $0.key < $1.key }) { return (end, f.value) }
        }
        return nil
    }

    // MARK: - Datum

    static func days(_ a: String, _ b: String) -> Int? { DateOnly.days(from: a, to: b) }

    static func addDays(_ s: String, _ n: Int) -> String? {
        guard let d = DateOnly.parse(s) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let r = cal.date(byAdding: .day, value: n, to: d) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: r)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

extension Fact {
    /// Formulář, ze kterého fakt pochází (companyfacts); nil u inline XBRL.
    public var form: String? {
        if case let .companyFacts(_, form, _) = source { return form }
        return nil
    }
}
