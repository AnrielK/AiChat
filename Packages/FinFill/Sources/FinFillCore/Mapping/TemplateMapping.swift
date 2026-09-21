import Foundation

/// Declarative mapping "template cell ← XBRL concepts". Loaded from JSON
/// (see Resources/nvda-valuation-5y.json). One file per spreadsheet template.
public struct TemplateMapping: Codable, Sendable {
    public struct Defaults: Codable, Sendable {
        public var unit: String = "USD"
        public var scale: Double = 1_000_000
        public var decimals: Int = 0
    }

    public struct Term: Codable, Sendable {
        /// Concept alternatives — the first one that exists for the period is used.
        public var c: [String]
        public var sign: Double?
        public var dims: [String: String]?
        public var optional: Bool?
    }

    public struct Ref: Codable, Sendable {
        /// Another row of the same sheet in the target column, e.g. `-O21`.
        public var row: Int
        public var sign: Double?
    }

    public struct Row: Codable, Sendable {
        public var sheet: String
        public var row: Int
        public var label: String
        public var period: PeriodType?
        public var unit: String?
        public var scale: Double?
        public var decimals: Int?
        public var terms: [Term]?
        public var refs: [Ref]?
        /// Literal formula; `{col}` = target column, `{prev}` = previous column. E.g. "={prev}30".
        public var formula: String?
    }

    public struct Check: Codable, Sendable {
        public var label: String
        public var sheet: String
        public var rows: [String]         // "+3", "-6"
        public var concept: String
        public var period: PeriodType
        public var unit: String?
    }

    public var name: String
    public var description: String?
    public var headerRow: Int
    public var defaults: Defaults
    public var rows: [Row]
    public var checks: [Check]

    public var sheets: [String] {
        var seen = Set<String>()
        return rows.map(\.sheet).filter { seen.insert($0).inserted }
    }

    public static func load(from data: Data) throws -> TemplateMapping {
        try JSONDecoder().decode(TemplateMapping.self, from: data)
    }

    /// The bundled mapping for "NVDA Valuation - 5y".
    public static func bundledNVDA() throws -> TemplateMapping {
        guard let url = Bundle.module.url(forResource: "nvda-valuation-5y", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: Data(contentsOf: url))
    }
}

// MARK: - Resolution

public struct ResolvedRow: Sendable, Identifiable {
    public struct Component: Sendable {
        public let concept: String
        public let value: Double      // scaled + rounded, sign applied
    }
    public var id: String { "\(spec.sheet)!\(spec.row)" }
    public let spec: TemplateMapping.Row
    public let components: [Component]
    public let missing: [String]            // required concepts not found
    public let missingOptional: [String]
    /// Numeric value of the cell including refs (nil for literal formulas or unresolved rows).
    public internal(set) var value: Double?

    public var isComplete: Bool { missing.isEmpty }
}

/// What will be written into one cell.
public enum CellContent: Sendable, Equatable {
    case number(Double)
    case formula(String)

    public var sheetsValue: Any {
        switch self {
        case let .number(v): return v
        case let .formula(f): return f
        }
    }

    public var display: String {
        switch self {
        case let .number(v): return NumberFormat.plain(v)
        case let .formula(f): return f
        }
    }
}

public enum MappingResolver {
    public static func resolve(_ mapping: TemplateMapping, facts: FactStore, period: FiscalPeriod) -> [ResolvedRow] {
        var rows: [ResolvedRow] = mapping.rows.map { spec in
            guard spec.formula == nil, let terms = spec.terms, let type = spec.period else {
                return ResolvedRow(spec: spec, components: [], missing: [], missingOptional: [], value: nil)
            }
            let unit = spec.unit ?? mapping.defaults.unit
            let scale = spec.scale ?? mapping.defaults.scale
            let decimals = spec.decimals ?? mapping.defaults.decimals
            var comps: [ResolvedRow.Component] = []
            var missing: [String] = []
            var missingOpt: [String] = []
            for t in terms {
                let fact = t.c.lazy.compactMap { facts.value($0, period: period, type: type, unit: unit, dims: t.dims ?? [:]) }.first
                if let fact {
                    let v = NumberFormat.round(fact.value / scale, decimals) * (t.sign ?? 1)
                    comps.append(.init(concept: fact.concept, value: v))
                } else if t.optional == true {
                    missingOpt.append(t.c[0])
                } else {
                    missing.append(t.c[0])
                }
            }
            let sum = comps.reduce(0) { $0 + $1.value }
            return ResolvedRow(spec: spec, components: comps, missing: missing, missingOptional: missingOpt,
                               value: missing.isEmpty ? NumberFormat.round(sum, decimals) : nil)
        }
        // Second pass: add refs (e.g. "accrued − current lease").
        let index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ("\($1.spec.sheet)!\($1.spec.row)", $0) })
        for i in rows.indices {
            guard let refs = rows[i].spec.refs, var v = rows[i].value else { continue }
            for r in refs {
                let refValue = index["\(rows[i].spec.sheet)!\(r.row)"].flatMap { rows[$0].value } ?? 0
                v += (r.sign ?? 1) * refValue
            }
            rows[i].value = v
        }
        return rows
    }

    /// Renders the cell content in the template's style: a plain number for a single concept,
    /// otherwise a formula that keeps the components visible, e.g. `=807+10979+3038` or `=21352-O21`.
    public static func content(for row: ResolvedRow, column: String, previousColumn: String) -> CellContent? {
        if let f = row.spec.formula {
            return .formula(f.replacingOccurrences(of: "{col}", with: column)
                             .replacingOccurrences(of: "{prev}", with: previousColumn))
        }
        guard row.isComplete, row.spec.terms != nil else { return nil }
        let refs = row.spec.refs ?? []
        if row.components.count <= 1 && refs.isEmpty {
            return .number(row.components.first?.value ?? 0)
        }
        let parts = row.components.filter { $0.value != 0 }
        if parts.count <= 1 && refs.isEmpty {
            return .number(parts.first?.value ?? 0)
        }
        var expr = ""
        for (i, c) in parts.enumerated() {
            let s = NumberFormat.plain(abs(c.value))
            if i == 0 { expr += c.value < 0 ? "-\(s)" : s } else { expr += c.value < 0 ? "-\(s)" : "+\(s)" }
        }
        if expr.isEmpty { expr = "0" }
        for r in refs { expr += ((r.sign ?? 1) < 0 ? "-" : "+") + "\(column)\(r.row)" }
        return .formula("=" + expr)
    }
}

public enum NumberFormat {
    public static func round(_ v: Double, _ decimals: Int) -> Double {
        let p = pow(10, Double(decimals))
        return (v * p).rounded() / p
    }

    /// "10979", "-3236", "4.93" — no grouping, dot decimal separator (formula-safe in any locale).
    public static func plain(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
