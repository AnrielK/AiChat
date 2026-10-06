import Foundation

/// A workbook stored as data (values, formulas, formatting) so the app can create new Google
/// Sheets from it. Generated from an .xlsx by `tools/finfill-template.py`.
public struct SpreadsheetTemplate: Codable, Sendable {
    public struct YearColumns: Codable, Sendable {
        public var first: Int          // 0-based column of the oldest year (G = 6)
        public var count: Int          // number of year columns (9)
        public var sheets: [String]    // statement sheets with year columns
    }

    public struct Style: Codable, Sendable {
        public var b: Bool?, i: Bool?, u: Bool?
        public var font: String?
        public var sz: Double?
        public var fc: String?         // "#RRGGBB" text color
        public var bg: String?         // "#RRGGBB" fill
        public var nf: String?         // number format pattern
        public var ha: String?         // LEFT / CENTER / RIGHT
        public var bt: String?, bb: String?, bl: String?, br: String?   // border styles
    }

    public struct Cell: Codable, Sendable {
        public var a: String           // A1 address
        public var f: String?          // formula
        public var v: String?          // text
        public var n: Double?          // number
        public var s: Int?             // style index
    }

    public struct Sheet: Codable, Sendable {
        public var title: String
        public var hideGridlines: Bool
        public var rowCount: Int
        public var columnCount: Int
        public var columnWidths: [String: Int]
        public var merges: [String]
        public var cells: [Cell]

        /// Grid big enough for every cell (styled-only cells too), merge and column width.
        /// Sheets rejects the whole batchUpdate if a single cell lies outside the grid.
        public var gridSize: (rows: Int, columns: Int) {
            var r = 0, c = 0
            for cell in cells { if let (row, col) = A1.parse(cell.a) { r = max(r, row + 1); c = max(c, col + 1) } }
            for m in merges {
                for part in m.split(separator: ":") { if let (row, col) = A1.parse(String(part)) { r = max(r, row + 1); c = max(c, col + 1) } }
            }
            for key in columnWidths.keys { c = max(c, A1.index(key) + 1) }
            return (max(rowCount, r + 10), max(columnCount, c))
        }
    }

    public var name: String
    public var headerRow: Int
    public var yearColumns: YearColumns
    public var placeholders: [String]
    public var styles: [Style]
    public var sheets: [Sheet]

    public static func load(from data: Data) throws -> SpreadsheetTemplate {
        try JSONDecoder().decode(SpreadsheetTemplate.self, from: data)
    }

    /// Universal valuation workbook (statements + DCF + WACC) for any US filer.
    public static func bundledUniversal() throws -> SpreadsheetTemplate {
        let url = Bundle.module.url(forResource: "valuation-universal", withExtension: "json")
            ?? Bundle.module.url(forResource: "valuation-universal", withExtension: "json", subdirectory: "templates")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try load(from: Data(contentsOf: url))
    }
}

/// Builds Google Sheets API requests that recreate a `SpreadsheetTemplate`.
public enum TemplateRequests {
    /// Body for `POST https://sheets.googleapis.com/v4/spreadsheets`.
    /// Locale en_US: template formulas use "," separators and "." decimals.
    public static func createBody(_ t: SpreadsheetTemplate, title: String) -> [String: Any] {
        [
            "properties": ["title": title, "locale": "en_US"],
            "sheets": t.sheets.enumerated().map { i, s in
                ["properties": [
                    "title": s.title,
                    "index": i,
                    "gridProperties": ["rowCount": s.gridSize.rows, "columnCount": s.gridSize.columns, "hideGridlines": s.hideGridlines],
                ] as [String: Any]]
            },
        ]
    }

    /// `spreadsheets.batchUpdate` requests: column widths, merges, cell values + formats.
    /// - Parameter values: placeholder values, e.g. ["TICKER": "AMD", "FY_FIRST": "2016"].
    public static func contentRequests(_ t: SpreadsheetTemplate, sheetIds: [String: Int],
                                       values: [String: String]) -> [[String: Any]] {
        var requests: [[String: Any]] = []
        for sheet in t.sheets {
            guard let id = sheetIds[sheet.title] else { continue }
            for (col, px) in sheet.columnWidths.sorted(by: { $0.key < $1.key }) {
                let c = A1.index(col)
                requests.append(["updateDimensionProperties": [
                    "range": ["sheetId": id, "dimension": "COLUMNS", "startIndex": c, "endIndex": c + 1],
                    "properties": ["pixelSize": px],
                    "fields": "pixelSize",
                ] as [String: Any]])
            }

            // Cells grouped into a dense grid starting at A1.
            var grid: [Int: [Int: [String: Any]]] = [:]
            var maxRow = 0, maxCol = 0
            for cell in sheet.cells {
                guard let (r, c) = A1.parse(cell.a) else { continue }
                grid[r, default: [:]][c] = cellData(cell, style: cell.s.flatMap { t.styles[safe: $0] }, values: values)
                maxRow = max(maxRow, r); maxCol = max(maxCol, c)
            }
            let rows: [[String: Any]] = (0...maxRow).map { r in
                ["values": (0...maxCol).map { c in grid[r]?[c] ?? [:] }]
            }
            requests.append(["updateCells": [
                "start": ["sheetId": id, "rowIndex": 0, "columnIndex": 0],
                "rows": rows,
                "fields": "userEnteredValue,userEnteredFormat",
            ] as [String: Any]])

            for m in sheet.merges {
                let parts = m.split(separator: ":").map(String.init)
                guard parts.count == 2, let (r1, c1) = A1.parse(parts[0]), let (r2, c2) = A1.parse(parts[1]) else { continue }
                requests.append(["mergeCells": [
                    "range": ["sheetId": id, "startRowIndex": r1, "endRowIndex": r2 + 1, "startColumnIndex": c1, "endColumnIndex": c2 + 1],
                    "mergeType": "MERGE_ALL",
                ] as [String: Any]])
            }
        }
        return requests
    }

    static func substitute(_ s: String, _ values: [String: String]) -> String {
        guard s.contains("{{") else { return s }
        var out = s
        for (k, v) in values { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }

    static func cellData(_ cell: SpreadsheetTemplate.Cell, style: SpreadsheetTemplate.Style?,
                         values: [String: String]) -> [String: Any] {
        var data: [String: Any] = [:]
        if let f = cell.f {
            data["userEnteredValue"] = ["formulaValue": substitute(f, values)]
        } else if let n = cell.n {
            data["userEnteredValue"] = ["numberValue": n]
        } else if let v = cell.v {
            let text = substitute(v, values)
            if v.contains("{{"), let number = Double(text) {
                data["userEnteredValue"] = ["numberValue": number]
            } else {
                data["userEnteredValue"] = ["stringValue": text]
            }
        }
        if let style { data["userEnteredFormat"] = format(style) }
        return data
    }

    static func format(_ s: SpreadsheetTemplate.Style) -> [String: Any] {
        var f: [String: Any] = [:]
        var text: [String: Any] = [:]
        if s.b == true { text["bold"] = true }
        if s.i == true { text["italic"] = true }
        if s.u == true { text["underline"] = true }
        if let font = s.font { text["fontFamily"] = font }
        if let sz = s.sz { text["fontSize"] = sz }
        if let fc = s.fc.flatMap(rgb) { text["foregroundColorStyle"] = ["rgbColor": fc] }
        if !text.isEmpty { f["textFormat"] = text }
        if let bg = s.bg.flatMap(rgb) { f["backgroundColorStyle"] = ["rgbColor": bg] }
        if let nf = s.nf {
            let lower = nf.lowercased()
            let type = (lower.contains("yy") || lower.contains("dd")) ? "DATE" : nf.contains("%") ? "PERCENT" : "NUMBER"
            f["numberFormat"] = ["type": type, "pattern": nf]
        }
        if let ha = s.ha { f["horizontalAlignment"] = ha }
        var borders: [String: Any] = [:]
        for (key, value) in [("top", s.bt), ("bottom", s.bb), ("left", s.bl), ("right", s.br)] {
            guard let value else { continue }
            // "SOLID" or "SOLID#44546A" (border in the header fill color)
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            let color = parts.count == 2 ? rgb(parts[1]) : nil
            borders[key] = ["style": parts[0], "colorStyle": ["rgbColor": color ?? ["red": 0, "green": 0, "blue": 0]]]
        }
        if !borders.isEmpty { f["borders"] = borders }
        return f
    }

    static func rgb(_ hex: String) -> [String: Double]? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return ["red": Double((v >> 16) & 0xFF) / 255, "green": Double((v >> 8) & 0xFF) / 255, "blue": Double(v & 0xFF) / 255]
    }
}

public extension A1 {
    /// "B21" → (row 20, column 1), 0-based.
    static func parse(_ address: String) -> (Int, Int)? {
        let letters = address.prefix { $0.isLetter }
        guard !letters.isEmpty, let row = Int(address.dropFirst(letters.count)), row > 0 else { return nil }
        return (row - 1, index(String(letters)))
    }
}

// MARK: - Nejnovější rok vlevo

public extension SpreadsheetTemplate {
    /// Stejný sešit s obráceným pořadím let ve výkazech: nejnovější rok v prvním sloupci bloku
    /// (G), starší doprava. Buňky, šířky a sloučení v blocích let se zrcadlí a odkazy ve vzorcích
    /// se přepíšou, takže „tento rok − předchozí“ (`=H37-G37`) míří dál na předchozí rok (`=N37-O37`).
    ///
    /// Rozsahy přes celý blok (`IncomeStatement!$G$5:$Z$5` v DCF – hledání podle roku) zůstanou,
    /// jen začnou o sloupec dřív (`$F$5:$Z$5`, sloupec F je ve výkazech prázdný). Nový rok se
    /// v takovém sešitu vkládá do G a Sheets rozsah rozšíří jen o sloupec *uvnitř* rozsahu –
    /// vložení na jeho začátek by rozsah jen posunulo a DCF by nový rok neviděl.
    func newestFirst() -> SpreadsheetTemplate {
        var t = self
        let first = yearColumns.first, last = yearColumns.first + yearColumns.count - 1
        let yearSheets = Set(yearColumns.sheets)
        func mirror(_ c: Int) -> Int { (first...last).contains(c) ? first + last - c : c }

        for i in t.sheets.indices {
            let own = t.sheets[i].title
            let isYearSheet = yearSheets.contains(own)
            t.sheets[i].cells = t.sheets[i].cells.map { cell in
                var cell = cell
                if isYearSheet, let (row, col) = A1.parse(cell.a) { cell.a = A1.column(mirror(col)) + String(row + 1) }
                if let f = cell.f {
                    cell.f = Self.mirrorFormula(f, ownSheet: own, yearSheets: yearSheets, first: first, last: last)
                }
                return cell
            }
            guard isYearSheet else { continue }
            var widths: [String: Int] = [:]
            for (column, px) in t.sheets[i].columnWidths { widths[A1.column(mirror(A1.index(column)))] = px }
            t.sheets[i].columnWidths = widths
            t.sheets[i].merges = t.sheets[i].merges.map { merge in
                let parts = merge.split(separator: ":").map(String.init)
                guard parts.count == 2, let (r1, c1) = A1.parse(parts[0]), let (r2, c2) = A1.parse(parts[1]) else { return merge }
                let (m1, m2) = (mirror(c1), mirror(c2))
                return "\(A1.column(min(m1, m2)))\(r1 + 1):\(A1.column(max(m1, m2)))\(r2 + 1)"
            }
        }
        return t
    }

    /// Odkaz na buňku nebo rozsah, volitelně s listem (`DCF!M55`, `'Cash Flow'!$G$2:$Z$2`).
    /// Názvy funkcí (`LOG10(`) a text v uvozovkách se nepřepisují.
    internal static let referencePattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_.$'!])((?:'(?:[^']|'')+'|[A-Za-z_][A-Za-z0-9_]*)!)?(\$?)([A-Z]{1,3})(\$?)([0-9]+)(?::(\$?)([A-Z]{1,3})(\$?)([0-9]+))?(?![A-Za-z0-9_(])"#)

    internal static func mirrorFormula(_ formula: String, ownSheet: String, yearSheets: Set<String>,
                                       first: Int, last: Int) -> String {
        formula.components(separatedBy: "\"").enumerated().map { i, part in
            i % 2 == 0 ? mirrorReferences(part, ownSheet: ownSheet, yearSheets: yearSheets, first: first, last: last) : part
        }
        .joined(separator: "\"")
    }

    private static func mirrorReferences(_ text: String, ownSheet: String, yearSheets: Set<String>,
                                         first: Int, last: Int) -> String {
        let ns = text as NSString
        var out = text
        for match in referencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let prefix = group(1) ?? ""
            var sheet = ownSheet
            if !prefix.isEmpty {
                sheet = String(prefix.dropLast())
                if sheet.hasPrefix("'") { sheet = String(sheet.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            }
            guard yearSheets.contains(sheet), let col1 = group(3), let row1 = group(5) else { continue }
            let c1 = A1.index(col1)
            let replacement: String
            if let col2 = group(7), let row2 = group(9) {
                let c2 = A1.index(col2)
                let (lo, hi) = (min(c1, c2), max(c1, c2))
                var start = c1, end = c2
                if first <= lo, hi <= last {
                    // Rozsah uvnitř bloku let: zrcadlit oba konce, levý konec zůstane vlevo.
                    let (m1, m2) = (first + last - c1, first + last - c2)
                    (start, end) = (min(m1, m2), max(m1, m2))
                } else if lo <= first, hi >= last, c1 == first, first > 0 {
                    start = first - 1
                } else {
                    continue
                }
                replacement = "\(prefix)\(group(2) ?? "")\(A1.column(start))\(group(4) ?? "")\(row1):"
                    + "\(group(6) ?? "")\(A1.column(end))\(group(8) ?? "")\(row2)"
            } else {
                guard first <= c1, c1 <= last else { continue }
                replacement = "\(prefix)\(group(2) ?? "")\(A1.column(first + last - c1))\(group(4) ?? "")\(row1)"
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return out
    }
}
