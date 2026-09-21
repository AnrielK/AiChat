import Foundation

/// Parser for https://data.sec.gov/api/xbrl/companyfacts/CIK##########.json
/// Note: companyfacts contains only dimensionless facts (no segments) — those come from
/// the inline XBRL document.
public enum CompanyFactsParser {
    struct Root: Decodable {
        let cik: Int?
        let entityName: String?
        let facts: [String: [String: Concept]]   // taxonomy -> concept -> data
    }
    struct Concept: Decodable {
        let units: [String: [Entry]]
    }
    struct Entry: Decodable {
        let start: String?
        let end: String
        let val: Double
        let accn: String
        let fy: Int?
        let fp: String?
        let form: String
        let filed: String
    }

    public struct Result: Sendable {
        public let entityName: String?
        public let facts: [Fact]
        /// 10-K accession → fiscal year label (from the "fy" field).
        public let annualReports: [String: Int]
    }

    /// - Parameter forms: which filing forms to keep (annual data only by default).
    public static func parse(_ data: Data, forms: Set<String> = ["10-K", "10-K/A", "20-F", "40-F"]) throws -> Result {
        let root = try JSONDecoder().decode(Root.self, from: data)
        var facts: [Fact] = []
        var annual: [String: Int] = [:]
        for (taxonomy, concepts) in root.facts {
            for (name, concept) in concepts {
                for (unit, entries) in concept.units {
                    for e in entries where forms.contains(e.form) {
                        facts.append(Fact(concept: "\(taxonomy):\(name)", value: e.val, unit: normalizeUnit(unit),
                                          start: e.start, end: e.end, dimensions: [:],
                                          source: .companyFacts(accession: e.accn, form: e.form, filed: e.filed)))
                        if e.fp == "FY", let fy = e.fy, e.form.hasPrefix("10-K") || e.form == "20-F" { annual[e.accn] = fy }
                    }
                }
            }
        }
        return Result(entityName: root.entityName, facts: facts, annualReports: annual)
    }

    static func normalizeUnit(_ u: String) -> String {
        // companyfacts uses "USD", "shares", "USD/shares", "pure"
        u
    }
}
