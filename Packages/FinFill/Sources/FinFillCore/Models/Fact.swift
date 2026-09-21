import Foundation

/// One numeric XBRL fact (value is already scaled to base units, e.g. USD, not millions).
public struct Fact: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case companyFacts(accession: String, form: String, filed: String)
        case inlineXBRL
    }

    public let concept: String          // prefixed, e.g. "us-gaap:Revenues"
    public let value: Double
    public let unit: String             // "USD", "shares", "USD/shares", ...
    public let start: String?           // yyyy-MM-dd, nil for instants
    public let end: String              // yyyy-MM-dd (instant date for instants)
    public let dimensions: [String: String] // axis -> member
    public let source: Source

    public init(concept: String, value: Double, unit: String, start: String?, end: String,
                dimensions: [String: String] = [:], source: Source) {
        self.concept = concept
        self.value = value
        self.unit = unit
        self.start = start
        self.end = end
        self.dimensions = dimensions
        self.source = source
    }

    public var isInstant: Bool { start == nil }

    /// Length of a duration fact in days (nil for instants).
    public var durationDays: Int? {
        guard let start, let s = DateOnly.parse(start), let e = DateOnly.parse(end) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: s, to: e).day
    }

    var accession: String? {
        if case let .companyFacts(accession, _, _) = source { return accession }
        return nil
    }

    var filed: String {
        if case let .companyFacts(_, _, filed) = source { return filed }
        return "9999-99-99" // iXBRL from the filing itself wins ties
    }
}

public enum PeriodType: String, Codable, Sendable {
    case duration
    case instant
}

/// The fiscal year being filled.
public struct FiscalPeriod: Sendable, Hashable {
    public let fiscalYear: Int      // label used in the template header row, e.g. 2026
    public let endDate: String      // yyyy-MM-dd, e.g. "2026-01-25"
    public let accession: String?   // 10-K accession number, preferred source for companyfacts

    public init(fiscalYear: Int, endDate: String, accession: String? = nil) {
        self.fiscalYear = fiscalYear
        self.endDate = endDate
        self.accession = accession
    }
}

enum DateOnly {
    static func parse(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    static func days(from a: String, to b: String) -> Int? {
        guard let x = parse(a), let y = parse(b) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: x, to: y).day
    }
}
