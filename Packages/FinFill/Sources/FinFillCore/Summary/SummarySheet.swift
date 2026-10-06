import Foundation

/// List se souhrnem 10-K: vždy první v sešitu, nový souhrn ho celý přepíše.
///
/// Šablona (`SummaryBrief`), shora dolů:
///   název, datum · Teze · Klíčová čísla (tabulka z XBRL) · Co se změnilo · Tahouni byznysu ·
///   Hlavní rizika · Kapitál a akcionáři · Výhled vedení · Pro valuaci (DCF) ·
///   Podklady – souhrny kapitol 10-K (sbalená skupina řádků, rozbalí se tlačítkem +).
///
/// Rozložení: sloupec A úzký okraj, B široký text (zalamuje se), tabulka čísel B–E se skutečnými
/// čísly a formáty (dá se s nimi počítat).
public enum SummarySheet {
    public static let defaultTitle = "Souhrn"

    static let textWidth = 640
    static let numberWidth = 105

    /// Požadavky pro `spreadsheets.batchUpdate`.
    /// - Parameter existingSheetId: id listu stejného názvu – smaže se a vznikne znovu na prvním místě
    ///   (tak zmizí i staré skupiny řádků a formáty). nil = nový list.
    public static func requests(_ s: Summarizer.Result, company: String, title: String,
                                existingSheetId: Int?, newSheetId: Int, czech: Bool? = nil,
                                generated: Date = Date()) -> [[String: Any]] {
        let layout = content(s, company: company, czech: czech ?? s.isCzech, generated: generated)
        let grid: [String: Any] = ["rowCount": max(layout.rows.count + 20, 100), "columnCount": 6, "hideGridlines": true]

        var requests: [[String: Any]] = []
        if let existingSheetId {
            requests.append(["deleteSheet": ["sheetId": existingSheetId]])
        }
        requests.append(["addSheet": ["properties": [
            "sheetId": newSheetId, "title": title, "index": 0, "gridProperties": grid,
            "tabColorStyle": ["rgbColor": Fmt.navy],
        ] as [String: Any]]])

        let widths = [(0, 24), (1, textWidth), (2, numberWidth), (3, numberWidth), (4, numberWidth)]
        for (column, px) in widths {
            requests.append(["updateDimensionProperties": [
                "range": ["sheetId": newSheetId, "dimension": "COLUMNS", "startIndex": column, "endIndex": column + 1],
                "properties": ["pixelSize": px], "fields": "pixelSize",
            ] as [String: Any]])
        }
        requests.append(["updateCells": [
            "start": ["sheetId": newSheetId, "rowIndex": 0, "columnIndex": 0],
            "rows": layout.rows.map { ["values": $0] },
            "fields": "userEnteredValue,userEnteredFormat",
        ] as [String: Any]])

        // Podklady sbalit – nahoře zůstane jen šablona.
        if let group = layout.details {
            let range: [String: Any] = ["sheetId": newSheetId, "dimension": "ROWS",
                                        "startIndex": group.lowerBound, "endIndex": group.upperBound]
            requests.append(["addDimensionGroup": ["range": range]])
            requests.append(["updateDimensionGroup": [
                "dimensionGroup": ["range": range, "depth": 1, "collapsed": true] as [String: Any],
                "fields": "collapsed",
            ] as [String: Any]])
        }
        return requests
    }

    // MARK: - Obsah

    typealias Row = [[String: Any]]

    /// Řádky listu (každý = buňky od sloupce A) a 0-based rozsah řádků s podklady.
    static func content(_ s: Summarizer.Result, company: String, czech: Bool,
                        generated: Date) -> (rows: [Row], details: Range<Int>?) {
        var rows: [Row] = []
        func text(_ value: String, _ format: [String: Any] = Fmt.body) {
            let margin: [String: Any] = [:]
            let cell: [String: Any] = ["userEnteredValue": ["stringValue": value], "userEnteredFormat": format]
            rows.append([margin, cell])
        }
        func blank() { if let last = rows.last, !last.isEmpty { rows.append([]) } }
        func bullets(_ items: [String]) {
            if items.isEmpty { text("—", Fmt.muted) }
            for item in items { text("•  " + item) }
        }

        let fy = s.keyFigures.fiscalYear
        text("\(company) — 10-K FY\(fy)", Fmt.title)
        text(czech ? "Souhrn \(dateText(generated)) · čísla spočítaná z XBRL, text napsal model"
                   : "Summary \(dateText(generated)) · figures computed from XBRL, text written by the model", Fmt.note)
        blank()

        let brief = s.brief
        if let brief {
            text(SummaryBrief.Section.thesis.title(czech: czech), Fmt.heading)
            let thesis = brief[.thesis].joined(separator: " ")
            text(thesis.isEmpty ? "—" : thesis, Fmt.lead)
            blank()
        } else {
            text(czech ? "Shrnutí" : "Summary", Fmt.heading)
            for line in SummarySheet.markdownLines(s.executiveSummary) { text(line.text, line.format) }
            blank()
        }

        let figures = s.keyFigures.briefLines
        if !figures.isEmpty {
            text(czech ? "Klíčová čísla (z XBRL)" : "Key figures (from XBRL)", Fmt.heading)
            let margin: [String: Any] = [:]
            rows.append([margin, header(czech ? "Ukazatel" : "Metric", left: true), header("FY\(fy)"),
                         header("FY\(fy - 1)"), header(czech ? "Změna" : "Change")])
            for (i, line) in figures.enumerated() {
                let shade = i % 2 == 1
                rows.append([margin,
                             cell(KeyFigures.displayName(line.name, czech: czech), Fmt.tableLabel(shaded: shade)),
                             number(line.current, line.kind, shaded: shade),
                             number(line.prior, line.kind, shaded: shade),
                             change(line, czech: czech, shaded: shade)])
            }
            blank()
        }

        if let brief {
            for section in SummaryBrief.Section.allCases where section != .thesis {
                text(section.title(czech: czech), Fmt.heading)
                bullets(brief[section])
                blank()
            }
        }

        // Podklady: souhrny jednotlivých kapitol 10-K, sbalené.
        var details: Range<Int>?
        if !s.sections.isEmpty {
            text(czech ? "Podklady – souhrny kapitol 10-K (rozbalíš tlačítkem + vlevo)"
                       : "Details – section summaries of the 10-K (expand with + on the left)", Fmt.detailsHeading)
            let start = rows.count
            for section in s.sections {
                text("Item \(section.item) — \(section.title)", Fmt.subheading)
                for line in markdownLines(section.summary) { text(line.text, line.format) }
                rows.append([])
            }
            details = start..<rows.count
        }
        return (rows, details)
    }

    /// Markdown modelu → řádky: nadpisy tučně, odrážky „•“, bez `**`; víc prázdných řádků za sebou se sloučí.
    static func markdownLines(_ markdown: String) -> [(text: String, format: [String: Any])] {
        var out: [(text: String, format: [String: Any])] = []
        var lastBlank = true
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lastBlank { out.append((text: "", format: Fmt.body)) }
                lastBlank = true
                continue
            }
            lastBlank = false
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            if line.hasPrefix("#") {
                out.append((text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), format: Fmt.subheading))
            } else if let bullet = ["- ", "* ", "• "].first(where: { line.hasPrefix($0) }) {
                out.append((text: "•  " + String(line.dropFirst(bullet.count)), format: Fmt.body))
            } else {
                out.append((text: line, format: Fmt.body))
            }
        }
        while let last = out.last, last.text.isEmpty { out.removeLast() }
        return out
    }

    // MARK: - Buňky tabulky

    static func cell(_ text: String, _ format: [String: Any]) -> [String: Any] {
        ["userEnteredValue": ["stringValue": text], "userEnteredFormat": format]
    }

    static func number(_ value: Double?, _ kind: KeyFigures.Line.Kind, shaded: Bool) -> [String: Any] {
        guard let value else { return cell("n/a", Fmt.number("@", shaded: shaded)) }
        var shown = value
        let pattern: String
        switch kind {
        case .money:
            shown = value / 1e9
            pattern = ##""$"#,##0.0"B""##
        case .percent:
            pattern = "0.0%"
        case .perShare:
            pattern = #""$"0.00"#
        }
        return ["userEnteredValue": ["numberValue": shown], "userEnteredFormat": Fmt.number(pattern, shaded: shaded)]
    }

    /// Částky: změna v %, marže: v procentních bodech. Růst zeleně, pokles červeně.
    static func change(_ line: KeyFigures.Line, czech: Bool, shaded: Bool) -> [String: Any] {
        let points = czech ? "p.b." : "pp"
        if let value = line.change {
            return ["userEnteredValue": ["numberValue": value],
                    "userEnteredFormat": Fmt.number("+0%;-0%;0%", shaded: shaded, color: value >= 0 ? Fmt.green : Fmt.red)]
        }
        if let value = line.marginChange {
            return ["userEnteredValue": ["numberValue": value * 100],
                    "userEnteredFormat": Fmt.number(#"+0.0" \#(points)";-0.0" \#(points)";0.0" \#(points)""#,
                                                    shaded: shaded, color: value >= 0 ? Fmt.green : Fmt.red)]
        }
        return cell("", Fmt.number("@", shaded: shaded))
    }

    static func header(_ text: String, left: Bool = false) -> [String: Any] {
        var format = Fmt.tableHeader
        format["horizontalAlignment"] = left ? "LEFT" : "RIGHT"
        return cell(text, format)
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "d. M. yyyy HH:mm"
        return f.string(from: date)
    }

    // MARK: - Formáty

    enum Fmt {
        static let navy: [String: Double] = ["red": 0.267, "green": 0.329, "blue": 0.416]
        static let gray: [String: Double] = ["red": 0.45, "green": 0.45, "blue": 0.45]
        static let shade: [String: Double] = ["red": 0.95, "green": 0.96, "blue": 0.97]
        static let green: [String: Double] = ["red": 0.13, "green": 0.53, "blue": 0.26]
        static let red: [String: Double] = ["red": 0.75, "green": 0.18, "blue": 0.16]

        static func text(size: Double = 10, bold: Bool = false, italic: Bool = false,
                         color: [String: Double]? = nil) -> [String: Any] {
            var t: [String: Any] = ["fontSize": size, "bold": bold, "italic": italic]
            if let color { t["foregroundColorStyle"] = ["rgbColor": color] }
            return ["textFormat": t, "wrapStrategy": "WRAP", "verticalAlignment": "TOP"]
        }

        static let title = text(size: 16, bold: true, color: navy)
        static let note = text(size: 9, italic: true, color: gray)
        static let heading: [String: Any] = {
            var f = text(size: 11, bold: true, color: navy)
            f["borders"] = ["bottom": ["style": "SOLID", "colorStyle": ["rgbColor": navy]]]
            f["padding"] = ["top": 10, "bottom": 2]
            return f
        }()
        static let detailsHeading: [String: Any] = {
            var f = text(size: 10, bold: true, color: gray)
            f["padding"] = ["top": 10, "bottom": 2]
            return f
        }()
        static let lead = text(size: 11)
        static let subheading = text(size: 10, bold: true)
        static let body = text()
        static let muted = text(color: gray)

        static func tableLabel(shaded: Bool) -> [String: Any] {
            var f = text()
            if shaded { f["backgroundColorStyle"] = ["rgbColor": shade] }
            return f
        }

        static let tableHeader: [String: Any] = {
            var f = text(bold: true, color: ["red": 1, "green": 1, "blue": 1])
            f["backgroundColorStyle"] = ["rgbColor": navy]
            return f
        }()

        static func number(_ pattern: String, shaded: Bool = false, color: [String: Double]? = nil) -> [String: Any] {
            var f = text(color: color)
            f["numberFormat"] = ["type": pattern == "@" ? "TEXT" : "NUMBER", "pattern": pattern]
            f["horizontalAlignment"] = "RIGHT"
            if shaded { f["backgroundColorStyle"] = ["rgbColor": shade] }
            return f
        }
    }
}
