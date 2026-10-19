import Foundation

/// Mřížka buněk pro `updateCells` (Google Sheets API) – sdílí ji listy Citlivost, Comps a Kvartály.
struct SheetGrid {
    /// 1-based řádek → 0-based sloupec → CellData
    private(set) var cells: [Int: [Int: [String: Any]]] = [:]
    private(set) var merges: [(row: Int, from: Int, to: Int)] = []

    mutating func text(_ row: Int, _ col: Int, _ s: String, _ fmt: [String: Any] = [:]) {
        var d: [String: Any] = ["userEnteredValue": ["stringValue": s]]
        if !fmt.isEmpty { d["userEnteredFormat"] = fmt }
        cells[row, default: [:]][col] = d
    }

    mutating func formula(_ row: Int, _ col: Int, _ f: String, _ fmt: [String: Any] = [:]) {
        var d: [String: Any] = ["userEnteredValue": ["formulaValue": f]]
        if !fmt.isEmpty { d["userEnteredFormat"] = fmt }
        cells[row, default: [:]][col] = d
    }

    mutating func number(_ row: Int, _ col: Int, _ v: Double, _ fmt: [String: Any] = [:]) {
        var d: [String: Any] = ["userEnteredValue": ["numberValue": v]]
        if !fmt.isEmpty { d["userEnteredFormat"] = fmt }
        cells[row, default: [:]][col] = d
    }

    mutating func style(_ row: Int, _ col: Int, _ fmt: [String: Any]) {
        if cells[row]?[col] == nil { cells[row, default: [:]][col] = ["userEnteredFormat": fmt] }
        else { cells[row]![col]!["userEnteredFormat"] = fmt }
    }

    /// Text přes několik sloupců (sloučené buňky, zalamování).
    mutating func paragraph(_ row: Int, from: Int, to: Int, _ s: String, _ fmt: [String: Any] = [:]) {
        var f = fmt
        f["wrapStrategy"] = "WRAP"
        f["verticalAlignment"] = "TOP"
        text(row, from, s, f)
        if to > from { merges.append((row, from, to)) }
    }

    var maxRow: Int { cells.keys.max() ?? 1 }
    var maxColumn: Int { cells.values.flatMap(\.keys).max() ?? 1 }

    /// updateCells + sloučení + šířky sloupců.
    func requests(sheetId: Int, widths: [(column: Int, px: Int)]) -> [[String: Any]] {
        let maxCol = maxColumn
        let rows: [[String: Any]] = (1...maxRow).map { r in
            ["values": (0...maxCol).map { c in cells[r]?[c] ?? [:] }]
        }
        var out: [[String: Any]] = [["updateCells": [
            "start": ["sheetId": sheetId, "rowIndex": 0, "columnIndex": 0],
            "rows": rows,
            "fields": "userEnteredValue,userEnteredFormat",
        ] as [String: Any]]]
        for m in merges {
            out.append(["mergeCells": [
                "range": ["sheetId": sheetId, "startRowIndex": m.row - 1, "endRowIndex": m.row,
                          "startColumnIndex": m.from, "endColumnIndex": m.to + 1],
                "mergeType": "MERGE_ALL",
            ] as [String: Any]])
        }
        for w in widths {
            out.append(["updateDimensionProperties": [
                "range": ["sheetId": sheetId, "dimension": "COLUMNS", "startIndex": w.column, "endIndex": w.column + 1],
                "properties": ["pixelSize": w.px], "fields": "pixelSize",
            ] as [String: Any]])
        }
        return out
    }

    /// Velikost listu s rezervou (addSheet musí mřížku pokrýt).
    var size: (rows: Int, columns: Int) { (maxRow + 20, max(maxColumn + 3, 26)) }

    /// Smaže list stejného názvu (pokud je) a založí ho znovu na pozici `index`.
    static func replaceSheet(title: String, existingId: Int?, newId: Int, index: Int?,
                             size: (rows: Int, columns: Int), tab: [String: Double]? = nil) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let existingId { out.append(["deleteSheet": ["sheetId": existingId]]) }
        var props: [String: Any] = [
            "sheetId": newId, "title": title,
            "gridProperties": ["rowCount": size.rows, "columnCount": size.columns, "hideGridlines": true],
        ]
        if let index { props["index"] = index }
        if let tab { props["tabColorStyle"] = ["rgbColor": tab] }
        out.append(["addSheet": ["properties": props]])
        return out
    }
}

/// Formáty pro listy analýz (navazují na SegmentSheet.Fmt).
enum AFmt {
    typealias F = SegmentSheet.Fmt
    static let headerTitle = F.headerTitle
    static let header = F.header
    static let group = F.group
    static let child = F.child
    static let number = F.number
    static let percent = F.percent
    static let totalLabel = F.totalLabel
    static let teal = ["red": 0.0, "green": 0.47, "blue": 0.45]
    static let light = ["red": 0.93, "green": 0.95, "blue": 0.97]
    static let highlight = ["red": 1.0, "green": 0.95, "blue": 0.8]

    static let num1: [String: Any] = ["type": "NUMBER", "pattern": "#,##0.0;(#,##0.0)"]
    static let num2: [String: Any] = ["type": "NUMBER", "pattern": "#,##0.00;(#,##0.00)"]
    static let multiple: [String: Any] = ["type": "NUMBER", "pattern": "0.0\"x\""]
    static let pctFormat: [String: Any] = ["type": "PERCENT", "pattern": "0.0%;(0.0%)"]
    static let usd: [String: Any] = ["type": "CURRENCY", "pattern": "$#,##0.00"]

    static let price: [String: Any] = ["numberFormat": usd, "horizontalAlignment": "RIGHT"]
    static let priceBold: [String: Any] = ["numberFormat": usd, "horizontalAlignment": "RIGHT", "textFormat": ["bold": true],
                                           "backgroundColorStyle": ["rgbColor": highlight]]
    static let pct: [String: Any] = ["numberFormat": pctFormat, "horizontalAlignment": "RIGHT"]
    static let pctAxis: [String: Any] = ["numberFormat": pctFormat, "horizontalAlignment": "CENTER", "textFormat": ["bold": true],
                                         "backgroundColorStyle": ["rgbColor": light]]
    static let mult: [String: Any] = ["numberFormat": multiple, "horizontalAlignment": "RIGHT"]
    static let multBold: [String: Any] = ["numberFormat": multiple, "horizontalAlignment": "RIGHT", "textFormat": ["bold": true]]
    static let decimal2: [String: Any] = ["numberFormat": num2, "horizontalAlignment": "RIGHT"]
    static let derived: [String: Any] = ["numberFormat": SegmentSheet.Fmt.num, "horizontalAlignment": "RIGHT",
                                         "textFormat": ["italic": true, "foregroundColorStyle": ["rgbColor": SegmentSheet.Fmt.gray]]]
    static let derived2: [String: Any] = ["numberFormat": num2, "horizontalAlignment": "RIGHT",
                                          "textFormat": ["italic": true, "foregroundColorStyle": ["rgbColor": SegmentSheet.Fmt.gray]]]
    static let bold: [String: Any] = ["textFormat": ["bold": true]]
    static let boldRow: [String: Any] = ["textFormat": ["bold": true], "backgroundColorStyle": ["rgbColor": highlight]]
    static let note: [String: Any] = ["textFormat": ["italic": true, "fontSize": 9,
                                                     "foregroundColorStyle": ["rgbColor": SegmentSheet.Fmt.gray]]]
    static let status: [String: Any] = ["horizontalAlignment": "LEFT"]
    static let center: [String: Any] = ["horizontalAlignment": "CENTER", "textFormat": ["bold": true],
                                        "backgroundColorStyle": ["rgbColor": light]]
}
