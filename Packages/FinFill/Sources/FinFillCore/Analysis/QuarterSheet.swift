import Foundation

/// List „Kvartály“: posledních až 8 kvartálů z XBRL (USD mil.), marže, YoY / QoQ a pod tím
/// earnings review posledního 10-Q modelem. List se při každém běhu vytvoří znovu.
public enum QuarterSheet {
    public static let title = "Kvartály"

    static let rows: [(QuarterlyFigures.Metric, Int)] = [
        (.revenue, 5), (.grossProfit, 6), (.operatingIncome, 7), (.netIncome, 8),
        (.eps, 9), (.operatingCashFlow, 10), (.capex, 11), (.freeCashFlow, 12),
    ]

    /// - Parameter newestFirst: nejnovější kvartál vlevo (jako výkazy v novém sešitu).
    static func grid(_ review: QuarterlyReview, newestFirst: Bool = true, scale: Double = 1_000_000) -> SheetGrid {
        var g = SheetGrid()
        let cols = newestFirst ? review.figures.columns : review.figures.columns.reversed()
        let first = 2                                   // C
        func col(_ i: Int) -> Int { first + i }
        func letter(_ i: Int) -> String { A1.column(col(i)) }
        let last = max(cols.count - 1, 0)

        g.text(2, 1, "Kvartály – \(review.company) (USD mil., EPS v USD)", AFmt.headerTitle)
        for (i, c) in cols.enumerated() { g.text(2, col(i), c.quarter.label, AFmt.header) }
        g.text(3, 1, "Konec kvartálu", AFmt.child)
        for (i, c) in cols.enumerated() { g.text(3, col(i), c.quarter.end, AFmt.child.merging(["horizontalAlignment": "RIGHT"]) { $1 }) }

        g.text(4, 1, "Výsledky", AFmt.group)
        for (m, r) in rows {
            g.text(r, 1, m.title, m == .freeCashFlow ? AFmt.totalLabel : [:])
            for (i, c) in cols.enumerated() {
                guard let q = c.values[m] else { continue }
                if m == .eps {
                    g.number(r, col(i), (q.value * 100).rounded() / 100, q.derived ? AFmt.derived2 : AFmt.decimal2)
                } else {
                    g.number(r, col(i), NumberFormat.round(q.value / scale, 0), q.derived ? AFmt.derived : AFmt.number)
                }
            }
        }

        var r = 14
        g.text(r, 1, "Marže", AFmt.group); r += 1
        for (label, num) in [("Hrubá marže", 6), ("Provozní marže", 7), ("Čistá marže", 8), ("FCF marže", 12)] {
            g.text(r, 1, label)
            for i in 0...last where !cols.isEmpty {
                let l = letter(i)
                g.formula(r, col(i), "=IF(OR(\(l)\(num)=\"\",N(\(l)5)=0),\"\",\(l)\(num)/\(l)5)", AFmt.pct)
            }
            r += 1
        }

        // YoY: stejný kvartál o rok dřív – sloupec se dohledá podle štítku, ne podle pozice (mezery v datech).
        r += 1
        g.text(r, 1, "Meziroční změna (YoY)", AFmt.group); r += 1
        for (label, num) in [("Tržby", 5), ("Provozní zisk", 7), ("Čistý zisk", 8), ("EPS", 9), ("FCF", 12)] {
            g.text(r, 1, label)
            for (i, c) in cols.enumerated() {
                guard let j = cols.firstIndex(where: { $0.quarter.quarter == c.quarter.quarter && $0.quarter.fiscalYear == c.quarter.fiscalYear - 1 })
                else { continue }
                let cur = "\(letter(i))\(num)", prev = "\(letter(j))\(num)"
                g.formula(r, col(i), "=IF(OR(\(cur)=\"\",\(prev)=\"\",N(\(prev))=0),\"\",(\(cur)-\(prev))/ABS(\(prev)))", AFmt.pct)
            }
            r += 1
        }

        r += 1
        g.text(r, 1, "Mezikvartální změna (QoQ)", AFmt.group); r += 1
        for (label, num) in [("Tržby", 5), ("Provozní zisk", 7)] {
            g.text(r, 1, label)
            for (i, c) in cols.enumerated() {
                guard let prev = review.figures.previous(of: c),
                      let j = cols.firstIndex(where: { $0.quarter.end == prev.quarter.end }) else { continue }
                let cur = "\(letter(i))\(num)", p = "\(letter(j))\(num)"
                g.formula(r, col(i), "=IF(OR(\(cur)=\"\",\(p)=\"\",N(\(p))=0),\"\",(\(cur)-\(p))/ABS(\(p)))", AFmt.pct)
            }
            r += 1
        }

        r += 1
        g.paragraph(r, from: 1, to: col(last), "Kurzívou = dopočteno z kumulativních údajů (YTD − předchozí YTD, Q4 = celý rok − 9 měsíců); "
                    + "u EPS je Q4 jen přibližné. Zdroj: SEC companyfacts (10-Q a 10-K). Konsenzus analytiků v datech SEC není – "
                    + "srovnání je se stejným kvartálem loni a s předchozím kvartálem.", AFmt.note)
        r += 2

        // Earnings review modelem.
        let czech = review.isCzech
        if let f = review.filing {
            g.text(r, 1, czech ? "Earnings review – \(f.form) za období do \(f.reportDate)" : "Earnings review – \(f.form) for the period ended \(f.reportDate)", AFmt.group)
            r += 1
            g.formula(r, 1, "=HYPERLINK(\"\(f.documentURL.absoluteString)\",\"\(f.form) podaný \(f.filingDate) (EDGAR)\")", AFmt.child)
            r += 2
        }
        if let brief = review.brief {
            for block in brief.sheetBlocks(czech: czech) {
                g.text(r, 1, block.title, AFmt.bold); r += 1
                for line in block.lines {
                    g.paragraph(r, from: 1, to: max(col(last), 7), block.paragraph ? line : "• " + line)
                    r += 1
                }
                r += 1
            }
        } else if let text = review.text, !text.isEmpty {
            for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                g.paragraph(r, from: 1, to: max(col(last), 7), line); r += 1
            }
        } else if review.filing != nil {
            g.text(r, 1, czech ? "Text modelem se nevytvořil (zapni „Souhrn modelem“)." : "No model text (turn on the model summary).", AFmt.note)
        }
        return g
    }

    public static func requests(sheetId: Int, review: QuarterlyReview, newestFirst: Bool = true) -> [[String: Any]] {
        let g = grid(review, newestFirst: newestFirst)
        let n = review.figures.columns.count
        let widths: [(column: Int, px: Int)] = [(0, 20), (1, 230)] + (0..<max(n, 6)).map { (column: 2 + $0, px: 95) }
        return g.requests(sheetId: sheetId, widths: widths)
    }

    public static func size(review: QuarterlyReview) -> (rows: Int, columns: Int) { grid(review).size }
}
