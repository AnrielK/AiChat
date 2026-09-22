import Foundation

/// In-memory index of facts from one or more sources (companyfacts JSON + inline XBRL).
public struct FactStore: Sendable {
    public private(set) var facts: [Fact] = []
    private var byConcept: [String: [Fact]] = [:]

    /// Axes ignored when matching dimensions (e.g. NVIDIA tags segment revenue with
    /// ConsolidationItemsAxis=OperatingSegmentsMember in addition to the segment axis).
    public var ignoredAxes: Set<String> = ["srt:ConsolidationItemsAxis"]

    public init(_ facts: [Fact] = []) { add(facts) }

    public mutating func add(_ newFacts: [Fact]) {
        facts.append(contentsOf: newFacts)
        for f in newFacts { byConcept[f.concept, default: []].append(f) }
    }

    public var isEmpty: Bool { facts.isEmpty }
    public var conceptCount: Int { byConcept.count }

    /// Finds the value of `concept` for the fiscal period.
    /// - duration: end == period end and length 350...380 days (a full fiscal year)
    /// - instant:  date == period end
    /// Dimensions must match exactly (ignoring `ignoredAxes`). With no dims requested, only
    /// dimensionless facts match.
    public func value(_ concept: String, period: FiscalPeriod, type: PeriodType,
                      unit: String = "USD", dims: [String: String] = [:]) -> Fact? {
        guard let candidates = byConcept[concept] else { return nil }
        let wanted = dims
        let matches = candidates.filter { f in
            guard f.unit == unit, f.end == period.endDate else { return false }
            switch type {
            case .instant: guard f.isInstant else { return false }
            case .duration:
                guard let d = f.durationDays, (350...380).contains(d) else { return false }
            }
            let fd = f.dimensions.filter { !ignoredAxes.contains($0.key) }
            return fd == wanted
        }
        guard !matches.isEmpty else { return nil }
        // Prefer: the selected 10-K accession, then inline XBRL, then most recently filed.
        return matches.max { a, b in rank(a, period) < rank(b, period) }
    }

    private func rank(_ f: Fact, _ p: FiscalPeriod) -> (Int, String) {
        let preferred = (p.accession != nil && f.accession == p.accession) ? 2 : 0
        let inline = { if case .inlineXBRL = f.source { return 1 } else { return 0 } }()
        return (preferred + inline, f.filed)
    }

    /// Instant value at the end of the fiscal year before `period` (≈ 1 year earlier).
    public func openingValue(_ concept: String, period: FiscalPeriod, unit: String = "USD") -> Fact? {
        (byConcept[concept] ?? []).filter { f in
            f.isInstant && f.unit == unit && f.dimensions.filter { !ignoredAxes.contains($0.key) }.isEmpty &&
                (DateOnly.days(from: f.end, to: period.endDate).map { (350...380).contains($0) } ?? false)
        }.max { $0.filed < $1.filed }
    }

    /// Fiscal years available in the facts, newest first, up to `count` years back from `latest`.
    /// Fiscal year numbers follow from the distance to `latest` (52/53-week years stay aligned).
    public func annualPeriods(latest: FiscalPeriod, count: Int) -> [FiscalPeriod] {
        let concepts = ["us-gaap:NetIncomeLoss", "us-gaap:ProfitLoss", "us-gaap:Revenues",
                        "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax",
                        "us-gaap:NetCashProvidedByUsedInOperatingActivities"]
        var ends = Set<String>()
        for c in concepts {
            for f in byConcept[c] ?? [] where f.dimensions.isEmpty && f.end <= latest.endDate {
                if let d = f.durationDays, (350...380).contains(d) { ends.insert(f.end) }
            }
        }
        var byYear: [Int: String] = [:]
        for e in ends {
            guard let days = DateOnly.days(from: e, to: latest.endDate) else { continue }
            let back = Int((Double(days) / 365.25).rounded())
            guard back < count else { continue }
            let fy = latest.fiscalYear - back
            // Two end dates for the same year (e.g. restated calendar) → keep the later one.
            if let existing = byYear[fy], existing >= e { continue }
            byYear[fy] = e
        }
        return byYear.keys.sorted(by: >).map { fy in
            FiscalPeriod(fiscalYear: fy, endDate: byYear[fy]!, accession: fy == latest.fiscalYear ? latest.accession : nil)
        }
    }

    /// Latest annual period available for a concept (used to auto-detect the fiscal year end).
    public func latestAnnualEnd(of concept: String = "us-gaap:NetIncomeLoss") -> String? {
        byConcept[concept]?
            .filter { $0.dimensions.isEmpty && ($0.durationDays.map { (350...380).contains($0) } ?? false) }
            .map(\.end).max()
    }
}
