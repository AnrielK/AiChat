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

    /// Latest annual period available for a concept (used to auto-detect the fiscal year end).
    public func latestAnnualEnd(of concept: String = "us-gaap:NetIncomeLoss") -> String? {
        byConcept[concept]?
            .filter { $0.dimensions.isEmpty && ($0.durationDays.map { (350...380).contains($0) } ?? false) }
            .map(\.end).max()
    }
}
