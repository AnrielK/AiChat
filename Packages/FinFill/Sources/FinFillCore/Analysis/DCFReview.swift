import Foundation

/// Rozložení listu DCF z univerzální šablony (`valuation-universal.json`). Citlivost i kontrola se
/// odkazují na tyto buňky; když sešit má jiný DCF (popisky nesedí), obojí se přeskočí.
public enum DCFLayout {
    public static let sheet = "DCF"
    /// Popisky ve sloupci B, podle kterých se pozná, že jde o DCF ze šablony.
    static let labels: [Int: String] = [
        18: "WACC", 19: "TGR", 22: "Revenue", 28: "EBIT", 39: "D&A",
        48: "Unlevered FCF", 51: "Terminal Value", 53: "Enterprise Value", 58: "Share Price",
    ]
    static let wacc = "C18", tgr = "C19"
    static let fcfColumns = ["I", "J", "K", "L", "M"]      // roky projekce 1–5
    static let fcfRow = 48
    static let terminalValue = "M51", pvTerminalValue = "M52", enterpriseValue = "M53"
    static let cash = "M54", debt = "M55", shares = "M57", sharePrice = "M58"
    static let currentPrice = "H5", upside = "H6"
    static let ebitTerminal = "M28", daTerminal = "M39"
    static let historicalMargins = "D29:H29", projectedMargins = "I29:M29"
    static let historicalGrowth = "E23:H23", firstYearGrowth = "I23"

    /// Ověří popisky ve sloupci B (hodnoty z `batchGet` rozsahu A1:M60, řádky od 1).
    public static func matches(_ values: [[Any]]) -> Bool {
        labels.allSatisfy { row, label in
            guard let cells = values[safe: row - 1], let v = cells[safe: 1] as? String else { return false }
            return v.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(label) == .orderedSame
        }
    }
}

/// Kontrola DCF podle skillu dcf-model (anthropics/financial-services): TGR < WACC, podíl terminální
/// hodnoty na EV, pásmo WACC, implikovaný exit multiple, marže a růst proti historii.
public struct DCFReview: Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case ok, info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        public var symbol: String {
            switch self {
            case .ok: "✓"
            case .info: "ℹ︎"
            case .warning: "⚠︎"
            case .error: "✗"
            }
        }
    }

    public struct Finding: Sendable, Identifiable {
        public var id: String { title }
        public let severity: Severity
        public let title: String
        public let detail: String
    }

    /// Hranice – stejné čísla jdou do vzorců listu Citlivost.
    public struct Thresholds: Sendable {
        public var waccMin = 0.06, waccMax = 0.15
        public var tgrMax = 0.04
        public var tvShareLow = 0.40, tvShareHigh = 0.75, tvShareMax = 0.85
        public var exitMultipleMin = 5.0, exitMultipleMax = 30.0
        public var marginExpansion = 0.05
        public var growthAboveHistory = 0.15
        public var upsideHigh = 1.0, upsideLow = -0.5
        public init() {}
    }

    /// Hodnoty přečtené z listu DCF (USD mil. jako v šabloně, cena v USD).
    public struct Inputs: Sendable {
        public var wacc: Double?
        public var tgr: Double?
        public var fcf: [Double?] = []              // roky 1–5
        public var terminalValue: Double?
        public var pvTerminalValue: Double?
        public var enterpriseValue: Double?
        public var cash: Double?
        public var debt: Double?
        public var shares: Double?
        public var sharePrice: Double?
        public var currentPrice: Double?
        public var ebitTerminal: Double?
        public var daTerminal: Double?
        public var historicalMargins: [Double] = []
        public var terminalMargin: Double?
        public var historicalGrowth: [Double] = []
        public var firstYearGrowth: Double?
        public init() {}

        public var tvShare: Double? {
            guard let pv = pvTerminalValue, let ev = enterpriseValue, ev != 0 else { return nil }
            return pv / ev
        }
        public var exitMultiple: Double? {
            guard let tv = terminalValue, let e = ebitTerminal else { return nil }
            let ebitda = e + (daTerminal ?? 0)
            return ebitda > 0 ? tv / ebitda : nil
        }
        public var upside: Double? {
            guard let p = sharePrice, let c = currentPrice, c > 0 else { return nil }
            return p / c - 1
        }

        /// Z hodnot `batchGet(["DCF!A1:M60"], render: .unformatted)`.
        public static func read(_ values: [[Any]]) -> Inputs {
            func v(_ a1: String) -> Double? {
                guard let (row, col) = A1.parseCell(a1), let cell = values[safe: row]?[safe: col] else { return nil }
                if let d = cell as? Double { return d }
                if let i = cell as? Int { return Double(i) }
                return nil
            }
            func range(_ r: String) -> [Double] {
                let parts = r.split(separator: ":").map(String.init)
                guard parts.count == 2, let (r1, c1) = A1.parseCell(parts[0]), let (_, c2) = A1.parseCell(parts[1]) else { return [] }
                return (c1...c2).compactMap { c in v("\(A1.column(c))\(r1 + 1)") }
            }
            var i = Inputs()
            i.wacc = v(DCFLayout.wacc); i.tgr = v(DCFLayout.tgr)
            i.fcf = DCFLayout.fcfColumns.map { v("\($0)\(DCFLayout.fcfRow)") }
            i.terminalValue = v(DCFLayout.terminalValue); i.pvTerminalValue = v(DCFLayout.pvTerminalValue)
            i.enterpriseValue = v(DCFLayout.enterpriseValue)
            i.cash = v(DCFLayout.cash); i.debt = v(DCFLayout.debt); i.shares = v(DCFLayout.shares)
            i.sharePrice = v(DCFLayout.sharePrice); i.currentPrice = v(DCFLayout.currentPrice)
            i.ebitTerminal = v(DCFLayout.ebitTerminal); i.daTerminal = v(DCFLayout.daTerminal)
            i.historicalMargins = range(DCFLayout.historicalMargins)
            i.terminalMargin = range(DCFLayout.projectedMargins).last
            i.historicalGrowth = range(DCFLayout.historicalGrowth)
            i.firstYearGrowth = v(DCFLayout.firstYearGrowth)
            return i
        }
    }

    public let inputs: Inputs
    public let findings: [Finding]

    public var worst: Severity { findings.map(\.severity).max() ?? .ok }

    public init(inputs: Inputs, thresholds t: Thresholds = .init()) {
        self.inputs = inputs
        var f: [Finding] = []
        func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
        func add(_ s: Severity, _ title: String, _ detail: String) { f.append(Finding(severity: s, title: title, detail: detail)) }

        if let w = inputs.wacc {
            if w < t.waccMin || w > t.waccMax {
                add(.warning, "WACC \(pct(w))", "Mimo obvyklé pásmo \(pct(t.waccMin))–\(pct(t.waccMax)). Zkontroluj betu, bezrizikovou sazbu a prémii.")
            }
            if let g = inputs.tgr {
                if g >= w {
                    add(.error, "TGR \(pct(g)) ≥ WACC", "Terminální růst musí být nižší než WACC, jinak terminální hodnota nedává smysl.")
                } else if g > t.tgrMax {
                    add(.warning, "TGR \(pct(g))", "Nad \(pct(t.tgrMax)) – dlouhodobě rychlejší růst než ekonomika obhájí jen tržní lídr.")
                }
            }
        } else {
            add(.error, "WACC chybí", "Buňka DCF!C18 je prázdná nebo v chybě (WACC!D22, GOOGLEFINANCE).")
        }

        if let s = inputs.tvShare {
            if s > t.tvShareMax {
                add(.error, "TV = \(pct(s)) EV", "Valuace stojí skoro celá na terminální hodnotě – výsledek je hlavně volba WACC a TGR.")
            } else if s > t.tvShareHigh {
                add(.warning, "TV = \(pct(s)) EV", "Nad \(pct(t.tvShareHigh)): vysoká závislost na terminálních předpokladech (zdravé 50–70 %).")
            } else if s < t.tvShareLow {
                add(.info, "TV = \(pct(s)) EV", "Pod \(pct(t.tvShareLow)): terminální předpoklady mohou být příliš konzervativní.")
            }
        }

        if let last = inputs.fcf.last ?? nil, last <= 0 {
            add(.error, "Záporné FCF v posledním roce", "Terminální hodnota z nekladného FCF nedává smysl – uprav marže, capex nebo pracovní kapitál.")
        }

        if let m = inputs.exitMultiple, m < t.exitMultipleMin || m > t.exitMultipleMax {
            add(.warning, String(format: "Implikovaný exit %.1fx EBITDA", m),
                String(format: "Mimo obvyklých %.0f–%.0fx. Porovnej s mediánem EV/EBITDA v Comps.", t.exitMultipleMin, t.exitMultipleMax))
        }

        if let tm = inputs.terminalMargin, let hmax = inputs.historicalMargins.max(), tm > hmax + t.marginExpansion {
            add(.warning, "Marže na konci \(pct(tm))", "Nad historickým maximem \(pct(hmax)) o víc než \(pct(t.marginExpansion)) – rozšíření marže potřebuje zdůvodnění.")
        }

        if let g1 = inputs.firstYearGrowth, !inputs.historicalGrowth.isEmpty {
            let avg = inputs.historicalGrowth.reduce(0, +) / Double(inputs.historicalGrowth.count)
            if g1 > avg + t.growthAboveHistory {
                add(.info, "Růst 1. roku \(pct(g1))", "Výrazně nad historickým průměrem \(pct(avg)).")
            }
        }

        if inputs.shares == nil || (inputs.shares ?? 0) <= 0 {
            add(.error, "Počet akcií chybí", "DCF!M57 je prázdné – cena na akcii nejde spočítat.")
        }
        if inputs.cash == nil || inputs.debt == nil {
            add(.warning, "Hotovost nebo dluh chybí", "Most z EV na hodnotu vlastního kapitálu (DCF!M54, M55) není úplný.")
        }

        if let u = inputs.upside {
            if u > t.upsideHigh {
                add(.info, String(format: "Potenciál %+.0f %%", u * 100), "Přes +\(Int(t.upsideHigh * 100)) % vůči trhu – zkontroluj předpoklady, než mu uvěříš.")
            } else if u < t.upsideLow {
                add(.info, String(format: "Potenciál %+.0f %%", u * 100), "Hluboko pod tržní cenou – trh nejspíš počítá s vyšším růstem nebo maržemi.")
            }
        }

        if f.isEmpty {
            add(.ok, "DCF prošel kontrolami", "TGR < WACC, podíl TV, exit multiple, marže i růst v obvyklých mezích.")
        }
        self.findings = f.sorted { $0.severity > $1.severity }
    }

    public var logLines: [String] {
        findings.map { "\($0.severity.symbol) \($0.title): \($0.detail)" }
    }

    public func markdown() -> String {
        findings.map { "- \($0.severity.symbol) **\($0.title)** – \($0.detail)" }.joined(separator: "\n")
    }
}

/// List „Citlivost“: implikovaná cena na akcii pro WACC × TGR (vzorce nad DCF, živé), potenciál
/// proti aktuální ceně a blok „Kontrola modelu“ se stejnými hranicemi jako `DCFReview`.
public enum SensitivitySheet {
    public static let title = "Citlivost"

    /// Kroky os: střed = předpoklad z DCF (vybraný scénář), ±0,5 a ±1 p.b.
    static let steps: [Double] = [-0.01, -0.005, 0, 0.005, 0.01]

    static func grid(thresholds t: DCFReview.Thresholds = .init()) -> SheetGrid {
        var g = SheetGrid()
        let d = DCFLayout.self
        let firstCol = 2                                    // C
        let cols = steps.indices.map { firstCol + $0 }
        let centerCol = A1.column(cols[2])

        g.text(2, 1, "Citlivost DCF – implikovaná cena na akcii (USD)", AFmt.headerTitle)
        for c in cols { g.text(2, c, "", AFmt.header) }
        g.paragraph(3, from: 1, to: cols.last!, "Řádky: WACC, sloupce: terminální růst (TGR). Střed = předpoklady listu DCF pro vybraný scénář – "
                    + "musí se rovnat ceně v DCF!M58. Volné cash flow let 1–5 se bere z DCF (na WACC a TGR nezávisí).", AFmt.note)

        // Tabulka 1: cena na akcii.
        let axisRow = 5
        g.text(axisRow, 1, "WACC ↓  TGR →", AFmt.bold)
        for (i, c) in cols.enumerated() {
            g.formula(axisRow, c, "=DCF!$C$19" + signed(steps[i]), AFmt.pctAxis)
        }
        let firstRow = axisRow + 1
        for (j, step) in steps.enumerated() {
            let r = firstRow + j
            g.formula(r, 1, "=DCF!$C$18" + signed(step), AFmt.pctAxis)
            for c in cols {
                let w = "$B\(r)", gr = "\(A1.column(c))$\(axisRow)"
                let pv = d.fcfColumns.enumerated().map { k, col in "DCF!$\(col)$\(d.fcfRow)/(1+\(w))^\(k + 1)" }.joined(separator: "+")
                let tv = "DCF!$M$\(d.fcfRow)*(1+\(gr))/(\(w)-\(gr))/(1+\(w))^5"
                let f = "=IF(\(w)<=\(gr),\"n/a\",IFERROR((\(pv)+\(tv)+DCF!$M$54-DCF!$M$55)/DCF!$M$57,\"\"))"
                g.formula(r, c, f, (j == 2 && c == cols[2]) ? AFmt.priceBold : AFmt.price)
            }
        }

        // Tabulka 2: potenciál vs. aktuální cena.
        let upTitle = firstRow + steps.count + 1
        g.text(upTitle, 1, "Potenciál vs. aktuální cena (DCF!H5)", AFmt.group)
        let upAxis = upTitle + 1
        g.text(upAxis, 1, "WACC ↓  TGR →", AFmt.bold)
        for c in cols { g.formula(upAxis, c, "=\(A1.column(c))\(axisRow)", AFmt.pctAxis) }
        for j in steps.indices {
            let r = upAxis + 1 + j
            g.formula(r, 1, "=B\(firstRow + j)", AFmt.pctAxis)
            for c in cols {
                let price = "\(A1.column(c))\(firstRow + j)"
                g.formula(r, c, "=IFERROR(IF(ISNUMBER(\(price)),\(price)/DCF!$H$5-1,\"\"),\"\")", AFmt.pct)
            }
        }

        // Kontrola modelu (živé vzorce, stejné hranice jako v aplikaci).
        var r = upAxis + steps.count + 2
        g.text(r, 1, "Kontrola modelu", AFmt.group)
        g.text(r, 2, "Hodnota", AFmt.group); g.text(r, 3, "Stav", AFmt.group)
        for c in 4...cols.last! { g.text(r, c, "", AFmt.group) }
        r += 1
        func n(_ x: Double) -> String { String(x) }
        let waccRow = r
        let checks: [(String, String, [String: Any], String, String)] = [
            ("WACC", "=IFERROR(DCF!C18,\"\")", AFmt.pct,
             "=IF(C{r}=\"\",\"✗ chybí\",IF(OR(C{r}<\(n(t.waccMin)),C{r}>\(n(t.waccMax))),\"⚠︎ mimo obvyklé pásmo\",\"✓\"))",
             "obvykle 6–15 % (velké stabilní firmy 7–9 %)"),
            ("Terminální růst (TGR)", "=IFERROR(DCF!C19,\"\")", AFmt.pct,
             "=IF(C{r}=\"\",\"\",IF(C{r}>=C\(waccRow),\"✗ TGR ≥ WACC\",IF(C{r}>\(n(t.tgrMax)),\"⚠︎ nad dlouhodobým růstem ekonomiky\",\"✓\")))",
             "< WACC, konzervativně 2–3 %"),
            ("Podíl terminální hodnoty na EV", "=IFERROR(DCF!M52/DCF!M53,\"\")", AFmt.pct,
             "=IF(C{r}=\"\",\"\",IF(C{r}>\(n(t.tvShareMax)),\"✗ valuace stojí skoro jen na TV\",IF(C{r}>\(n(t.tvShareHigh)),\"⚠︎ vysoká závislost na TV\",IF(C{r}<\(n(t.tvShareLow)),\"ℹ︎ nízký podíl TV\",\"✓\"))))",
             "zdravé 50–70 %, nad 75 % pozor"),
            ("Implikovaný exit multiple (EV/EBITDA)", "=IFERROR(DCF!M51/(DCF!M28+DCF!M39),\"\")", AFmt.mult,
             "=IF(C{r}=\"\",\"\",IF(OR(C{r}<\(n(t.exitMultipleMin)),C{r}>\(n(t.exitMultipleMax))),\"⚠︎ neobvyklý – porovnej s Comps\",\"✓\"))",
             "obvykle 8–15x, krajně 5–30x"),
            ("FCF v posledním roce projekce (USD mil.)", "=IFERROR(DCF!M48,\"\")", AFmt.number,
             "=IF(C{r}=\"\",\"\",IF(C{r}<=0,\"✗ záporné FCF – TV nedává smysl\",\"✓\"))",
             "musí být kladné"),
            ("Provozní marže na konci projekce", "=IFERROR(DCF!M29,\"\")", AFmt.pct,
             "=IF(C{r}=\"\",\"\",IF(C{r}>MAX(DCF!$D$29:$H$29)+\(n(t.marginExpansion)),\"⚠︎ nad historickým maximem\",\"✓\"))",
             "historické maximum + 5 p.b."),
            ("Růst tržeb v 1. roce projekce", "=IFERROR(DCF!I23,\"\")", AFmt.pct,
             "=IF(C{r}=\"\",\"\",IF(C{r}>IFERROR(AVERAGE(DCF!$E$23:$H$23),0)+\(n(t.growthAboveHistory)),\"ℹ︎ výrazně nad historickým průměrem\",\"✓\"))",
             "historický průměr + 15 p.b."),
            ("Implikovaný potenciál", "=IFERROR(DCF!H6,\"\")", AFmt.pct,
             "=IF(C{r}=\"\",\"\",IF(C{r}>\(n(t.upsideHigh)),\"ℹ︎ přes +100 % – ověř předpoklady\",IF(C{r}<\(n(t.upsideLow)),\"ℹ︎ pod −50 % – ověř předpoklady\",\"✓\")))",
             "extrémy obvykle znamenají chybu v předpokladech"),
            ("Kontrola tabulky (střed = DCF!M58)", "=IFERROR(\(centerCol)\(firstRow + 2)-DCF!M58,\"\")", AFmt.decimal2,
             "=IF(C{r}=\"\",\"\",IF(ABS(C{r})<0.01,\"✓\",\"✗ citlivost nesedí s DCF\"))",
             "rozdíl musí být 0"),
        ]
        for (label, value, fmt, status, hint) in checks {
            g.text(r, 1, label)
            g.formula(r, 2, value, fmt)
            g.formula(r, 3, status.replacingOccurrences(of: "{r}", with: String(r)))
            g.text(r, 4, hint, AFmt.note)
            r += 1
        }
        r += 1
        g.paragraph(r, from: 1, to: cols.last! + 2, "Hranice podle skillu dcf-model z anthropics/financial-services. "
                    + "Kontrola v aplikaci (FinFill) používá stejná čísla a ukáže výsledek po zápisu.", AFmt.note)
        return g
    }

    static func signed(_ step: Double) -> String {
        if step == 0 { return "" }
        return step > 0 ? "+\(step)" : "\(step)"
    }

    public static func requests(sheetId: Int, thresholds: DCFReview.Thresholds = .init()) -> [[String: Any]] {
        grid(thresholds: thresholds).requests(sheetId: sheetId, widths: [(0, 20), (1, 290), (2, 95), (3, 95), (4, 95), (5, 95), (6, 95)])
    }

    public static var size: (rows: Int, columns: Int) { grid().size }
}

extension A1 {
    /// „M58“ → (řádek 57, sloupec 12), 0-based.
    static func parseCell(_ s: String) -> (Int, Int)? {
        let letters = s.prefix { $0.isLetter }
        guard !letters.isEmpty, let row = Int(s.dropFirst(letters.count)), row > 0 else { return nil }
        return (row - 1, index(String(letters)))
    }
}
