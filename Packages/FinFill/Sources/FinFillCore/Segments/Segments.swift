import Foundation

/// Revenue by segment / market / region from inline XBRL (dimensional facts — companyfacts
/// JSON has none). One 10-K covers three fiscal years, older years come from older 10-Ks.
public struct SegmentGroup: Sendable, Identifiable {
    public struct Line: Sendable, Identifiable {
        public var id: String { member }
        public let member: String            // "nvda:DataCenterMember"
        public let name: String              // "Data Center"
        public var values: [Int: Double]     // fiscal year → USD
        /// Member whose value this line is part of (Compute + Networking = Data Center).
        public var parent: String?
    }

    public var id: String { axis }
    public let axis: String
    public let title: String
    public var lines: [Line]

    /// Lines that add up to total revenue (children excluded).
    public var topLevel: [Line] { lines.filter { $0.parent == nil } }
}

public enum SegmentExtractor {
    public static let axes: [(axis: String, title: String)] = [
        ("us-gaap:StatementBusinessSegmentsAxis", "Segmenty"),
        ("srt:ProductOrServiceAxis", "Trhy / produkty"),
        ("srt:StatementGeographicalAxis", "Regiony"),
    ]
    static let revenueConcepts: Set<String> = ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax",
                                               "us-gaap:SalesRevenueNet"]
    static let ignoredAxes: Set<String> = ["srt:ConsolidationItemsAxis"]

    /// Dimensional revenue facts worth keeping from a filing (everything else comes from companyfacts).
    public static func revenueFacts(_ facts: [Fact]) -> [Fact] {
        facts.filter { revenueConcepts.contains($0.concept) && !$0.dimensions.isEmpty && $0.unit == "USD" && !$0.isInstant }
    }

    /// - Parameter facts: dimensional revenue facts, newest filing first (its values win — restatements).
    public static func extract(facts: [Fact], periods: [FiscalPeriod]) -> [SegmentGroup] {
        axes.compactMap { axis, title in
            var lines: [String: SegmentGroup.Line] = [:]
            for f in facts {
                let dims = f.dimensions.filter { !ignoredAxes.contains($0.key) }
                guard dims.count == 1, let member = dims[axis],
                      let days = f.durationDays, (350...380).contains(days),
                      let period = periods.first(where: { $0.endDate == f.end }) else { continue }
                var line = lines[member] ?? .init(member: member, name: label(member), values: [:], parent: nil)
                if line.values[period.fiscalYear] == nil { line.values[period.fiscalYear] = f.value }
                lines[member] = line
            }
            guard lines.count >= 2 else { return nil }
            let latest = { (l: SegmentGroup.Line) -> Double in l.values.max { $0.key < $1.key }?.value ?? 0 }
            var sorted = lines.values.sorted { latest($0) > latest($1) }
            markChildren(&sorted)
            // Children right after their parent.
            var ordered: [SegmentGroup.Line] = []
            for l in sorted where l.parent == nil {
                ordered.append(l)
                ordered += sorted.filter { $0.parent == l.member }
            }
            return SegmentGroup(axis: axis, title: title, lines: ordered)
        }
    }

    /// A line equal to the sum of 2–3 other lines (in every year both have) is their parent.
    static func markChildren(_ lines: inout [SegmentGroup.Line]) {
        for pi in lines.indices {
            let parent = lines[pi]
            let others = lines.indices.filter { $0 != pi && lines[$0].parent == nil && lines[$0].member != parent.member }
            var found: [Int]?
            search: for size in 2...3 where others.count >= size {
                for combo in combinations(others, size) {
                    let years = parent.values.keys.filter { y in combo.allSatisfy { lines[$0].values[y] != nil } }
                    guard !years.isEmpty else { continue }
                    let fits = years.allSatisfy { y in
                        abs(combo.reduce(0) { $0 + lines[$1].values[y]! } - parent.values[y]!) <= max(1_000_000, abs(parent.values[y]!) * 1e-6)
                    }
                    if fits { found = combo; break search }
                }
            }
            if let found { for i in found { lines[i].parent = parent.member } }
        }
    }

    static func combinations(_ items: [Int], _ k: Int) -> [[Int]] {
        guard k > 0 else { return [[]] }
        guard items.count >= k else { return [] }
        if k == 1 { return items.map { [$0] } }
        var out: [[Int]] = []
        for (i, x) in items.enumerated() {
            for rest in combinations(Array(items[(i + 1)...]), k - 1) { out.append([x] + rest) }
        }
        return out
    }

    static let countries: [String: String] = [
        "US": "USA", "TW": "Tchaj-wan", "CN": "Čína", "JP": "Japonsko", "KR": "Jižní Korea", "DE": "Německo",
        "GB": "Velká Británie", "SG": "Singapur", "IE": "Irsko", "NL": "Nizozemsko", "IN": "Indie", "CA": "Kanada",
        "FR": "Francie", "IL": "Izrael", "CH": "Švýcarsko", "HK": "Hongkong", "MX": "Mexiko", "BR": "Brazílie",
    ]

    /// "nvda:ComputeAndNetworkingSegmentMember" → "Compute & Networking", "country:TW" → "Tchaj-wan".
    public static func label(_ member: String) -> String {
        let parts = member.split(separator: ":")
        var name = String(parts.last ?? Substring(member))
        if parts.first == "country" { return countries[name] ?? name }
        for suffix in ["SegmentMember", "SegmentsMember", "Member"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count)); break
        }
        // Split CamelCase, keep acronyms together: "OEMAndOther" → "OEM And Other".
        var words: [String] = []
        var current = ""
        let chars = Array(name)
        for (i, ch) in chars.enumerated() {
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let startsWord = ch.isUppercase && !current.isEmpty &&
                (!(current.last!.isUppercase) || (next.map { $0.isLowercase } ?? false))
            if startsWord || (ch.isNumber && !(current.last?.isNumber ?? true)) { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ").replacingOccurrences(of: " And ", with: " & ")
    }
}

/// Builds the "Segments" sheet: revenue per line, total vs. income statement, YoY change, share.
public enum SegmentSheet {
    public static let title = "Segments"

    /// - Parameters:
    ///   - yearColumns: fiscal year → 0-based column (same columns as the statements, header row 2).
    ///   - scale: USD per displayed unit (millions).
    public static func updateCells(sheetId: Int, groups: [SegmentGroup], yearColumns: [Int: Int],
                                   incomeSheet: String = "IncomeStatement", revenueRow: Int = 5,
                                   scale: Double = 1_000_000) -> [[String: Any]] {
        let years = yearColumns.keys.sorted()
        let cols = years.map { yearColumns[$0]! }
        var grid: [Int: [Int: [String: Any]]] = [:]     // 1-based row → 0-based col → CellData
        func put(_ r: Int, _ c: Int, _ cell: [String: Any]) { grid[r, default: [:]][c] = cell }
        func label(_ r: Int, _ text: String, _ fmt: [String: Any] = [:]) { put(r, 1, text.cell(fmt)) }
        func letter(_ c: Int) -> String { A1.column(c) }

        label(1, "Tržby podle segmentů, trhů a regionů (USD mil.)", Fmt.title)
        for (y, c) in zip(years, cols) {
            put(2, c, ["userEnteredValue": ["formulaValue": "=\(incomeSheet)!\(letter(c))2"], "userEnteredFormat": Fmt.header])
            _ = y
        }
        put(2, 1, "".cell(Fmt.header))

        var r = 4
        for g in groups {
            label(r, g.title, Fmt.group); r += 1
            var lineRows: [(line: SegmentGroup.Line, row: Int)] = []
            for line in g.lines {
                label(r, line.parent == nil ? line.name : "   " + line.name, line.parent == nil ? [:] : Fmt.child)
                for (y, c) in zip(years, cols) {
                    if let v = line.values[y] { put(r, c, NumberFormat.round(v / scale, 0).cell(line.parent == nil ? Fmt.number : Fmt.childNumber)) }
                }
                lineRows.append((line, r)); r += 1
            }
            let totalRow = r
            label(r, "Celkem", Fmt.totalLabel)
            let top = lineRows.filter { $0.line.parent == nil }.map(\.row)
            for c in cols {
                let l = letter(c)
                put(r, c, "=IF(COUNT(\(top.map { "\(l)\($0)" }.joined(separator: ",")))=0,\"\",\(top.map { "N(\(l)\($0))" }.joined(separator: "+")))".formula(Fmt.total))
            }
            r += 1
            label(r, "Tržby ve výsledovce", Fmt.child)
            for c in cols { put(r, c, "=\(incomeSheet)!\(letter(c))\(revenueRow)".formula(Fmt.childNumber)) }
            let isRow = r; r += 1
            label(r, "Rozdíl (eliminace, nezařazeno)", Fmt.child)
            for c in cols {
                let l = letter(c)
                put(r, c, "=IF(OR(\(l)\(totalRow)=\"\",\(l)\(isRow)=\"\"),\"\",\(l)\(totalRow)-\(l)\(isRow))".formula(Fmt.childNumber))
            }
            r += 2

            label(r, "\(g.title) – meziroční změna", Fmt.group); r += 1
            for (line, row) in lineRows + [(SegmentGroup.Line(member: "total", name: "Celkem", values: [:], parent: nil), totalRow)] {
                label(r, line.member == "total" ? "Celkem" : (line.parent == nil ? line.name : "   " + line.name),
                      line.member == "total" ? Fmt.totalLabel : (line.parent == nil ? [:] : Fmt.child))
                for (i, c) in cols.enumerated() where i > 0 {
                    let cur = "\(letter(c))\(row)", prev = "\(letter(cols[i - 1]))\(row)"
                    put(r, c, "=IF(OR(\(prev)=\"\",\(cur)=\"\",N(\(prev))=0),\"\",\(cur)/\(prev)-1)".formula(line.member == "total" ? Fmt.totalPercent : Fmt.percent))
                }
                r += 1
            }
            r += 1

            label(r, "\(g.title) – podíl na tržbách", Fmt.group); r += 1
            for (line, row) in lineRows {
                label(r, line.parent == nil ? line.name : "   " + line.name, line.parent == nil ? [:] : Fmt.child)
                for c in cols {
                    let l = letter(c)
                    put(r, c, "=IF(OR(\(l)\(row)=\"\",N(\(l)\(totalRow))=0),\"\",\(l)\(row)/\(l)\(totalRow))".formula(Fmt.percent))
                }
                r += 1
            }
            r += 2
        }

        let maxRow = grid.keys.max() ?? 1
        let maxCol = max(cols.max() ?? 1, 1)
        let rows: [[String: Any]] = (1...maxRow).map { row in
            ["values": (0...maxCol).map { c in grid[row]?[c] ?? [:] }]
        }
        var requests: [[String: Any]] = [["updateCells": [
            "start": ["sheetId": sheetId, "rowIndex": 0, "columnIndex": 0],
            "rows": rows,
            "fields": "userEnteredValue,userEnteredFormat",
        ] as [String: Any]]]
        let widths: [(Int, Int)] = [(0, 20), (1, 260)] + (2..<(cols.min() ?? 2)).map { ($0, 8) } + cols.map { ($0, 90) }
        for (c, px) in widths {
            requests.append(["updateDimensionProperties": [
                "range": ["sheetId": sheetId, "dimension": "COLUMNS", "startIndex": c, "endIndex": c + 1],
                "properties": ["pixelSize": px], "fields": "pixelSize",
            ] as [String: Any]])
        }
        return requests
    }

    /// Grid size needed by `updateCells` (rows, columns), with room to spare.
    public static func gridSize(groups: [SegmentGroup], yearColumns: [Int: Int]) -> (rows: Int, columns: Int) {
        let lines = groups.reduce(0) { $0 + $1.lines.count }
        return (4 + groups.count * 12 + lines * 3 + 20, max((yearColumns.values.max() ?? 14) + 6, 26))
    }

    enum Fmt {
        static let dark = ["red": 0.267, "green": 0.329, "blue": 0.416]
        static let white = ["red": 1.0, "green": 1.0, "blue": 1.0]
        static let gray = ["red": 0.4, "green": 0.4, "blue": 0.4]
        static let line: [String: Any] = ["style": "SOLID", "colorStyle": ["rgbColor": ["red": 0, "green": 0, "blue": 0]]]
        static let num: [String: Any] = ["type": "NUMBER", "pattern": "#,##0;(#,##0)"]
        static let pct: [String: Any] = ["type": "PERCENT", "pattern": "0.0%;(0.0%)"]

        static let title: [String: Any] = ["textFormat": ["bold": true, "fontSize": 13]]
        static let header: [String: Any] = ["backgroundColorStyle": ["rgbColor": dark], "horizontalAlignment": "RIGHT",
                                            "textFormat": ["bold": true, "foregroundColorStyle": ["rgbColor": white]]]
        static let group: [String: Any] = ["textFormat": ["bold": true], "borders": ["bottom": line]]
        static let child: [String: Any] = ["textFormat": ["italic": true, "foregroundColorStyle": ["rgbColor": gray]]]
        static let number: [String: Any] = ["numberFormat": num, "horizontalAlignment": "RIGHT"]
        static let childNumber: [String: Any] = ["numberFormat": num, "horizontalAlignment": "RIGHT",
                                                 "textFormat": ["italic": true, "foregroundColorStyle": ["rgbColor": gray]]]
        static let totalLabel: [String: Any] = ["textFormat": ["bold": true], "borders": ["top": line]]
        static let total: [String: Any] = ["numberFormat": num, "horizontalAlignment": "RIGHT", "textFormat": ["bold": true], "borders": ["top": line]]
        static let percent: [String: Any] = ["numberFormat": pct, "horizontalAlignment": "RIGHT"]
        static let totalPercent: [String: Any] = ["numberFormat": pct, "horizontalAlignment": "RIGHT", "textFormat": ["bold": true]]
    }
}

private extension String {
    func cell(_ fmt: [String: Any]) -> [String: Any] {
        var d: [String: Any] = ["userEnteredValue": ["stringValue": self]]
        if !fmt.isEmpty { d["userEnteredFormat"] = fmt }
        return d
    }
    func formula(_ fmt: [String: Any]) -> [String: Any] {
        ["userEnteredValue": ["formulaValue": self], "userEnteredFormat": fmt]
    }
}

private extension Double {
    func cell(_ fmt: [String: Any]) -> [String: Any] {
        ["userEnteredValue": ["numberValue": self], "userEnteredFormat": fmt]
    }
}
