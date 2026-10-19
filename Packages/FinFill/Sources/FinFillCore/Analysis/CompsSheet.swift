import Foundation

/// List „Comps“: srovnání s peery podle skillu comps-analysis (anthropics/financial-services).
///
/// Provozní čísla (LTM) a rozvaha jsou ze SEC jako hodnoty, cena živě z GOOGLEFINANCE a všechno
/// odvozené – tržní kapitalizace, EV, marže, multiply, statistiky a implikovaná cena – jsou vzorce,
/// takže list sám reaguje na změnu ceny. Statistiky (max, kvartily, medián, min) jsou jen z peerů.
public enum CompsSheet {
    public static let title = "Comps"

    enum C {
        static let name = 1, ticker = 2, price = 3, shares = 4, marketCap = 5, netDebt = 6, ev = 7
        static let revenue = 8, growth = 9, ebitda = 10, ebit = 11, netIncome = 12, fcf = 13
        static let ebitdaMargin = 14, ebitMargin = 15, evRevenue = 16, evEbitda = 17, pe = 18, fcfYield = 19, ltm = 20
        static let last = ltm
    }

    static let headers: [(Int, String)] = [
        (C.name, "Firma"), (C.ticker, "Ticker"), (C.price, "Cena (USD)"), (C.shares, "Akcie (mil.)"),
        (C.marketCap, "Tržní kap."), (C.netDebt, "Čistý dluh"), (C.ev, "EV"), (C.revenue, "Tržby LTM"),
        (C.growth, "Růst tržeb"), (C.ebitda, "EBITDA LTM"), (C.ebit, "EBIT LTM"), (C.netIncome, "Čistý zisk LTM"),
        (C.fcf, "FCF LTM"), (C.ebitdaMargin, "EBITDA marže"), (C.ebitMargin, "EBIT marže"), (C.evRevenue, "EV / Tržby"),
        (C.evEbitda, "EV / EBITDA"), (C.pe, "P / E"), (C.fcfYield, "FCF výnos"), (C.ltm, "LTM do"),
    ]

    /// Sloupce se statistikami (max, kvartily, medián, min).
    static let statColumns: [(Int, [String: Any])] = [
        (C.growth, AFmt.pct), (C.ebitdaMargin, AFmt.pct), (C.ebitMargin, AFmt.pct),
        (C.evRevenue, AFmt.mult), (C.evEbitda, AFmt.mult), (C.pe, AFmt.mult), (C.fcfYield, AFmt.pct),
    ]

    static func L(_ c: Int) -> String { A1.column(c) }

    static func grid(target: CompanySnapshot, peers: [CompanySnapshot], hasDCF: Bool, scale: Double = 1_000_000) -> SheetGrid {
        var g = SheetGrid()
        g.text(2, C.name, "Comps – \(target.name) (\(target.ticker)) vs. peery · USD mil.", AFmt.headerTitle)
        for c in (C.name + 1)...C.last { g.text(2, c, "", AFmt.header) }
        g.paragraph(3, from: C.name, to: C.last, "LTM = součet posledních 4 kvartálů z 10-Q/10-K (SEC companyfacts); „FY“ = kvartály chybí, "
                    + "bere se poslední celý rok. Čistý dluh = dluh − hotovost a krátkodobé investice k poslední rozvaze. "
                    + "Cena živě z GOOGLEFINANCE. Multiply se záporným jmenovatelem se nepočítají (prázdné). "
                    + "Statistiky jsou jen z peerů, bez cílové firmy.", AFmt.note)

        let headRow = 5
        let headFmt: [String: Any] = ["textFormat": ["bold": true], "wrapStrategy": "WRAP", "horizontalAlignment": "CENTER",
                                      "verticalAlignment": "MIDDLE", "borders": ["bottom": SegmentSheet.Fmt.line]]
        for (c, h) in headers { g.text(headRow, c, h, headFmt) }

        let targetRow = headRow + 1
        put(&g, row: targetRow, target, scale: scale, highlight: true)
        let firstPeer = targetRow + 2
        for (i, p) in peers.enumerated() { put(&g, row: firstPeer + i, p, scale: scale, highlight: false) }
        let lastPeer = firstPeer + max(peers.count, 1) - 1

        // Statistiky peerů.
        var r = lastPeer + 2
        let stats: [(String, (String) -> String)] = [
            ("Maximum", { "MAX(\($0))" }), ("75. percentil", { "QUARTILE(\($0),3)" }), ("Medián", { "MEDIAN(\($0))" }),
            ("25. percentil", { "QUARTILE(\($0),1)" }), ("Minimum", { "MIN(\($0))" }),
        ]
        var statRow: [String: Int] = [:]
        for (label, fn) in stats {
            g.text(r, C.name, label, label == "Medián" ? AFmt.bold : AFmt.child)
            for (c, fmt) in statColumns {
                let range = "\(L(c))\(firstPeer):\(L(c))\(lastPeer)"
                var f = fmt
                if label == "Medián" { f["textFormat"] = ["bold": true] }
                g.formula(r, c, "=IF(COUNT(\(range))=0,\"\",\(fn(range)))", f)
            }
            statRow[label] = r
            r += 1
        }

        // Implikovaná cena cílové firmy z multiplů peerů.
        r += 1
        let t = targetRow
        g.text(r, C.name, "Implikovaná cena \(target.ticker) (USD)", AFmt.group)
        let pctCols = [("25. percentil", C.ticker), ("Medián", C.price), ("75. percentil", C.shares)]
        for (label, c) in pctCols { g.text(r, c, label, AFmt.group.merging(["horizontalAlignment": "RIGHT"]) { $1 }) }
        g.text(r, C.marketCap, "Medián vs. cena", AFmt.group.merging(["horizontalAlignment": "RIGHT"]) { $1 })
        r += 1
        let methods: [(String, Int, (String) -> String)] = [
            ("EV / Tržby", C.evRevenue, { m in "(\(m)*$\(L(C.revenue))$\(t)-N($\(L(C.netDebt))$\(t)))/$\(L(C.shares))$\(t)" }),
            ("EV / EBITDA", C.evEbitda, { m in "(\(m)*$\(L(C.ebitda))$\(t)-N($\(L(C.netDebt))$\(t)))/$\(L(C.shares))$\(t)" }),
            ("P / E", C.pe, { m in "\(m)*$\(L(C.netIncome))$\(t)/$\(L(C.shares))$\(t)" }),
        ]
        let firstMethodRow = r
        for (label, multCol, implied) in methods {
            g.text(r, C.name, label)
            for (statLabel, c) in pctCols {
                let m = "$\(L(multCol))$\(statRow[statLabel]!)"
                g.formula(r, c, "=IFERROR(IF(OR(\(m)=\"\",N($\(L(C.shares))$\(t))<=0),\"\",\(implied(m))),\"\")",
                          statLabel == "Medián" ? AFmt.priceBold : AFmt.price)
            }
            let med = "\(L(C.price))\(r)"
            g.formula(r, C.marketCap, "=IFERROR(IF(\(med)=\"\",\"\",\(med)/$\(L(C.price))$\(t)-1),\"\")", AFmt.pct)
            r += 1
        }
        let lastMethodRow = r - 1
        g.text(r, C.name, "Průměr metod (medián)", AFmt.totalLabel)
        g.formula(r, C.price, "=IFERROR(AVERAGE(\(L(C.price))\(firstMethodRow):\(L(C.price))\(lastMethodRow)),\"\")",
                  AFmt.priceBold.merging(["borders": ["top": SegmentSheet.Fmt.line]]) { $1 })
        g.formula(r, C.marketCap, "=IFERROR(\(L(C.price))\(r)/$\(L(C.price))$\(t)-1,\"\")", AFmt.pct)
        r += 2
        g.text(r, C.name, "Aktuální cena")
        g.formula(r, C.price, "=\(L(C.price))\(t)", AFmt.price)
        r += 1
        if hasDCF {
            g.text(r, C.name, "Cena z DCF (DCF!H4)")
            g.formula(r, C.price, "=IFERROR(DCF!H4,\"\")", AFmt.price)
            g.formula(r, C.marketCap, "=IFERROR(\(L(C.price))\(r)/$\(L(C.price))$\(t)-1,\"\")", AFmt.pct)
            r += 1
        }

        let missing = ([target] + peers).filter { !$0.missing.isEmpty }
        if !missing.isEmpty {
            r += 1
            g.paragraph(r, from: C.name, to: C.last, "Chybí v SEC datech: " + missing.map { "\($0.ticker) (\($0.missing.joined(separator: ", ")))" }
                        .joined(separator: "; ") + ".", AFmt.note)
        }
        return g
    }

    static func put(_ g: inout SheetGrid, row r: Int, _ s: CompanySnapshot, scale: Double, highlight: Bool) {
        let base: [String: Any] = highlight ? ["backgroundColorStyle": ["rgbColor": AFmt.highlight]] : [:]
        func fmt(_ f: [String: Any]) -> [String: Any] { f.merging(base) { a, _ in a } }
        func num(_ c: Int, _ v: Double?, _ f: [String: Any] = AFmt.number) {
            if let v { g.number(r, c, NumberFormat.round(v / scale, 0), fmt(f)) } else { g.style(r, c, fmt(f)) }
        }
        func cell(_ c: Int) -> String { "\(L(c))\(r)" }

        g.text(r, C.name, s.name, fmt(highlight ? AFmt.bold : [:]))
        g.text(r, C.ticker, s.ticker, fmt(highlight ? AFmt.bold : [:]))
        g.formula(r, C.price, "=IFERROR(GOOGLEFINANCE(\"\(s.ticker)\"),\"\")", fmt(AFmt.price))
        if let sh = s.shares { g.number(r, C.shares, NumberFormat.round(sh / scale, 1), fmt(AFmt.decimal2)) } else { g.style(r, C.shares, fmt(AFmt.decimal2)) }
        g.formula(r, C.marketCap, "=IF(OR(\(cell(C.price))=\"\",\(cell(C.shares))=\"\"),\"\",\(cell(C.price))*\(cell(C.shares)))", fmt(AFmt.number))
        num(C.netDebt, s.netDebt)
        g.formula(r, C.ev, "=IF(\(cell(C.marketCap))=\"\",\"\",\(cell(C.marketCap))+N(\(cell(C.netDebt))))", fmt(AFmt.number))
        num(C.revenue, s.revenue)
        if let gr = s.revenueGrowth { g.number(r, C.growth, (gr * 10_000).rounded() / 10_000, fmt(AFmt.pct)) } else { g.style(r, C.growth, fmt(AFmt.pct)) }
        num(C.ebitda, s.ebitda)
        num(C.ebit, s.ebit)
        num(C.netIncome, s.netIncome)
        num(C.fcf, s.freeCashFlow)
        func ratio(_ c: Int, _ a: Int, _ b: Int, _ f: [String: Any]) {
            g.formula(r, c, "=IF(OR(\(cell(a))=\"\",N(\(cell(b)))<=0),\"\",\(cell(a))/\(cell(b)))", fmt(f))
        }
        ratio(C.ebitdaMargin, C.ebitda, C.revenue, AFmt.pct)
        ratio(C.ebitMargin, C.ebit, C.revenue, AFmt.pct)
        ratio(C.evRevenue, C.ev, C.revenue, AFmt.mult)
        ratio(C.evEbitda, C.ev, C.ebitda, AFmt.mult)
        ratio(C.pe, C.marketCap, C.netIncome, AFmt.mult)
        g.formula(r, C.fcfYield, "=IF(OR(\(cell(C.fcf))=\"\",N(\(cell(C.marketCap)))<=0),\"\",\(cell(C.fcf))/\(cell(C.marketCap)))", fmt(AFmt.pct))
        let ltm = s.ltmEnd.map { $0 + (s.ltmQuarters == 4 ? "" : " (FY)") } ?? "—"
        g.text(r, C.ltm, ltm, fmt(AFmt.child))
    }

    public static func requests(sheetId: Int, target: CompanySnapshot, peers: [CompanySnapshot], hasDCF: Bool) -> [[String: Any]] {
        let widths: [(column: Int, px: Int)] = [(0, 20), (C.name, 210), (C.ticker, 70)] +
            ((C.price)...(C.fcfYield)).map { (column: $0, px: 92) } + [(column: C.ltm, px: 110)]
        return grid(target: target, peers: peers, hasDCF: hasDCF).requests(sheetId: sheetId, widths: widths)
            + [["updateSheetProperties": [
                // Jen řádky: sloučená poznámka v ř. 3 by zamrznutí sloupců zablokovala (API to odmítne).
                "properties": ["sheetId": sheetId, "gridProperties": ["frozenRowCount": 5]],
                "fields": "gridProperties.frozenRowCount",
            ] as [String: Any]]]
    }

    public static func size(peers: Int) -> (rows: Int, columns: Int) {
        (40 + peers, C.last + 4)
    }

    /// Mediány multiplů a implikované ceny (pro náhled v appce, bez ceny – ta je jen v listu).
    public static func summary(target: CompanySnapshot, peers: [CompanySnapshot]) -> String {
        func med(_ xs: [Double]) -> Double? {
            let s = xs.sorted(); guard !s.isEmpty else { return nil }
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let growth = med(peers.compactMap(\.revenueGrowth))
        let margin = med(peers.compactMap { p in p.ebitda.flatMap { e in p.revenue.flatMap { $0 > 0 ? e / $0 : nil } } })
        var lines = ["| | \(target.ticker) | medián peerů |", "|---|---:|---:|"]
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f %%", $0 * 100) } ?? "—" }
        let tMargin = target.ebitda.flatMap { e in target.revenue.flatMap { $0 > 0 ? e / $0 : nil } }
        lines.append("| Růst tržeb | \(pct(target.revenueGrowth)) | \(pct(growth)) |")
        lines.append("| EBITDA marže | \(pct(tMargin)) | \(pct(margin)) |")
        return lines.joined(separator: "\n")
    }
}
