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
