import XCTest
@testable import FinFillCore

/// Syntetická firma s kalendářním fiskálním rokem: FY2023, FY2024 (10-K) a Q1–Q3 2025 (10-Q).
/// Výsledovka má tříměsíční i YTD údaje, cash flow jen YTD (jako skutečné 10-Q).
enum SyntheticFacts {
    typealias E = (start: String?, end: String, val: Double, form: String, filed: String)

    static let m = 1_000_000.0

    static var entries: [String: [String: [E]]] {
        let k24 = ("10-K", "2025-02-20"), q125 = ("10-Q", "2025-05-01"), q225 = ("10-Q", "2025-08-01"), q325 = ("10-Q", "2025-11-01")
        let k23 = ("10-K", "2024-02-20")
        func e(_ s: String?, _ end: String, _ v: Double, _ f: (String, String)) -> E { (s, end, v * m, f.0, f.1) }
        return [
            "us-gaap": [
                "Revenues": [
                    e("2023-01-01", "2023-12-31", 350, k23),
                    e("2024-01-01", "2024-12-31", 400, k24),
                    // 10-Q 2025 se srovnáním s rokem 2024
                    e("2025-01-01", "2025-03-31", 110, q125), e("2024-01-01", "2024-03-31", 90, q125),
                    e("2025-04-01", "2025-06-30", 120, q225), e("2024-04-01", "2024-06-30", 100, q225),
                    e("2025-01-01", "2025-06-30", 230, q225), e("2024-01-01", "2024-06-30", 190, q225),
                    e("2025-07-01", "2025-09-30", 130, q325), e("2024-07-01", "2024-09-30", 100, q325),
                    e("2025-01-01", "2025-09-30", 360, q325), e("2024-01-01", "2024-09-30", 290, q325),
                ],
                "OperatingIncomeLoss": [
                    e("2024-01-01", "2024-12-31", 80, k24),
                    e("2025-01-01", "2025-03-31", 25, q125), e("2024-01-01", "2024-03-31", 15, q125),
                    e("2025-04-01", "2025-06-30", 28, q225), e("2024-04-01", "2024-06-30", 20, q225),
                    e("2025-07-01", "2025-09-30", 32, q325), e("2024-07-01", "2024-09-30", 20, q325),
                    e("2024-01-01", "2024-09-30", 55, q325),
                ],
                "NetIncomeLoss": [
                    e("2024-01-01", "2024-12-31", 60, k24),
                    e("2025-01-01", "2025-03-31", 20, q125), e("2025-04-01", "2025-06-30", 21, q225),
                    e("2025-07-01", "2025-09-30", 24, q325), e("2024-07-01", "2024-09-30", 15, q325),
                    e("2024-01-01", "2024-09-30", 44, q325),
                ],
                "NetCashProvidedByUsedInOperatingActivities": [
                    e("2024-01-01", "2024-12-31", 130, k24),
                    e("2025-01-01", "2025-03-31", 30, q125), e("2024-01-01", "2024-03-31", 20, q125),
                    e("2025-01-01", "2025-06-30", 70, q225), e("2024-01-01", "2024-06-30", 50, q225),
                    e("2025-01-01", "2025-09-30", 120, q325), e("2024-01-01", "2024-09-30", 90, q325),
                ],
                "PaymentsToAcquirePropertyPlantAndEquipment": [
                    e("2024-01-01", "2024-12-31", 40, k24),
                    e("2025-01-01", "2025-09-30", 33, q325), e("2024-01-01", "2024-09-30", 30, q325),
                    e("2025-01-01", "2025-06-30", 22, q225), e("2025-01-01", "2025-03-31", 10, q125),
                ],
                "DepreciationDepletionAndAmortization": [
                    e("2024-01-01", "2024-12-31", 20, k24),
                    e("2025-01-01", "2025-09-30", 18, q325), e("2024-01-01", "2024-09-30", 15, q325),
                    e("2025-01-01", "2025-06-30", 12, q225), e("2025-01-01", "2025-03-31", 6, q125),
                ],
                "Assets": [e(nil, "2024-12-31", 900, k24), e(nil, "2025-09-30", 1000, q325)],
                "CashAndCashEquivalentsAtCarryingValue": [e(nil, "2024-12-31", 40, k24), e(nil, "2025-09-30", 50, q325)],
                "ShortTermInvestments": [e(nil, "2025-09-30", 20, q325)],
                "LongTermDebtNoncurrent": [e(nil, "2025-09-30", 100, q325)],
                "LongTermDebtCurrent": [e(nil, "2025-09-30", 10, q325)],
            ],
        ]
    }

    static var json: Data {
        var facts: [String: Any] = [:]
        for (tax, concepts) in entries {
            var c: [String: Any] = [:]
            for (name, list) in concepts {
                c[name] = ["units": ["USD": list.map { e -> [String: Any] in
                    var d: [String: Any] = ["end": e.end, "val": e.val, "accn": "acc-\(e.filed)", "form": e.form, "filed": e.filed]
                    if let s = e.start { d["start"] = s }
                    return d
                }]]
            }
            facts[tax] = c
        }
        facts["dei"] = ["EntityCommonStockSharesOutstanding": ["units": ["shares": [
            ["end": "2025-10-25", "val": 10 * m, "accn": "acc-q3", "form": "10-Q", "filed": "2025-11-01"],
        ]]]]
        facts["us-gaap"] = (facts["us-gaap"] as! [String: Any]).merging([
            "EarningsPerShareDiluted": ["units": ["USD/shares": [
                ["start": "2025-07-01", "end": "2025-09-30", "val": 2.4, "accn": "a", "form": "10-Q", "filed": "2025-11-01"],
                ["start": "2024-07-01", "end": "2024-09-30", "val": 1.5, "accn": "a", "form": "10-Q", "filed": "2025-11-01"],
            ]]],
        ]) { a, _ in a }
        return try! JSONSerialization.data(withJSONObject: ["cik": 1, "entityName": "TestCo", "facts": facts])
    }

    static var facts: [Fact] {
        try! CompanyFactsParser.parse(json, forms: CompanyFactsParser.annualAndQuarterlyForms).facts
    }
}

final class QuarterHistoryTests: XCTestCase {
    let m = SyntheticFacts.m

    func testDiscreteQuartersFromYTD() {
        let h = QuarterHistory(facts: SyntheticFacts.facts)
        let rev = h.quarters(Concepts.revenue)
        XCTAssertEqual(rev.first?.quarter.label, "Q3 FY25")
        XCTAssertEqual(rev.first?.value, 130 * m)
        XCTAssertEqual(rev.first?.derived, false)
        // Q4 2024 = FY 400 − 9M 290
        let q4 = rev.first { $0.quarter.end == "2024-12-31" }
        XCTAssertEqual(q4?.value, 110 * m)
        XCTAssertEqual(q4?.derived, true)
        XCTAssertEqual(q4?.quarter.label, "Q4 FY24")

        // Cash flow je jen YTD → Q3 = 9M − 6M, Q2 = 6M − 3M, Q1 = 3M (přímo).
        let cfo = h.quarters(Concepts.operatingCashFlow)
        XCTAssertEqual(cfo.first { $0.quarter.end == "2025-09-30" }?.value, 50 * m)
        XCTAssertEqual(cfo.first { $0.quarter.end == "2025-06-30" }?.value, 40 * m)
        XCTAssertEqual(cfo.first { $0.quarter.end == "2025-03-31" }?.value, 30 * m)
        XCTAssertEqual(cfo.first { $0.quarter.end == "2024-12-31" }?.value, 40 * m)
    }

    func testLTM() {
        let h = QuarterHistory(facts: SyntheticFacts.facts)
        let rev = h.ltm(Concepts.revenue)
        XCTAssertEqual(rev?.value, 470 * m)       // 110 + 110 + 120 + 130
        XCTAssertEqual(rev?.quarters, 4)
        XCTAssertEqual(rev?.end, "2025-09-30")
        XCTAssertEqual(h.ltm(Concepts.operatingCashFlow)?.value, 160 * m)   // 40 + 30 + 40 + 50
        // LTM o rok dřív nemá 4 kvartály (chybí Q4 2023) → roční záloha
        XCTAssertEqual(h.ltm(Concepts.revenue, offsetYears: 1)?.quarters, 0)
    }

    func testSnapshot() {
        let s = CompanySnapshot.compute(ticker: "tst", name: "TestCo", facts: SyntheticFacts.facts)
        XCTAssertEqual(s.ticker, "TST")
        XCTAssertEqual(s.revenue, 470 * m)
        XCTAssertEqual(s.ebit, (80 - 55 + 25 + 28 + 32) * m)     // Q4'24 25 + 85
        XCTAssertEqual(s.depreciation, (5 + 18) * m)             // Q4'24 (20 − 15) + 9M'25 18
        XCTAssertEqual(s.ebitda, (110 + 23) * m)
        XCTAssertEqual(s.freeCashFlow, (160 - (10 + 33)) * m)    // capex LTM = Q4'24 10 + 9M'25 33
        XCTAssertEqual(s.cash, 70 * m)
        XCTAssertEqual(s.debt, 110 * m)
        XCTAssertEqual(s.netDebt, 40 * m)
        XCTAssertEqual(s.shares, 10 * m)
        XCTAssertEqual(s.balanceDate, "2025-09-30")
        // LTM a LTM o rok dřív nejsou srovnatelné → FY2024 / FY2023
        XCTAssertEqual(s.revenueGrowth!, 400.0 / 350.0 - 1, accuracy: 1e-9)
        XCTAssertTrue(s.missing.isEmpty, "\(s.missing)")
    }

    func testQuarterlyFigures() {
        let q = QuarterlyFigures.compute(facts: SyntheticFacts.facts)
        XCTAssertEqual(q.latest?.quarter.label, "Q3 FY25")
        XCTAssertEqual(q.latest?.value(.freeCashFlow), (50 - 11) * m)
        let ya = q.yearAgo(of: q.latest!)
        XCTAssertEqual(ya?.quarter.label, "Q3 FY24")
        XCTAssertEqual(q.previous(of: q.latest!)?.quarter.label, "Q2 FY25")
        XCTAssertEqual(QuarterlyFigures.change(130, 100)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(QuarterlyFigures.change(-5, -10)!, 0.5, accuracy: 1e-9)   // ztráta se zmenšila
        let table = q.promptTable()
        XCTAssertTrue(table.contains("Revenue Q3 FY25: $130M; Q3 FY24 $100M (YoY +30%)"), table)
        XCTAssertTrue(table.contains("Diluted EPS Q3 FY25: $2.40"), table)
        XCTAssertTrue(q.markdown().contains("| Tržby YoY |"))
    }

    func testQuarterSheetFormulas() {
        let figures = QuarterlyFigures.compute(facts: SyntheticFacts.facts)
        let review = QuarterlyReview(company: "TestCo", figures: figures, filing: nil,
                                     text: "HEADLINE: Strong quarter.\nRESULTS:\n- Revenue +30%\nGUIDANCE:\n- n/a\nMODEL:\n- Raise growth",
                                     language: "Czech")
        XCTAssertEqual(review.brief?["RESULTS"], ["Revenue +30%"])
        XCTAssertEqual(review.brief?["GUIDANCE"], [])
        let g = QuarterSheet.grid(review, newestFirst: true)
        // C = Q3 FY25, G = Q3 FY24 (4 sloupce vpravo) → YoY tržeb odkazuje na G5
        XCTAssertEqual(text(g, 2, 2), "Q3 FY25")
        let yoy = formulas(g).first { $0.contains("(C5-G5)/ABS(G5)") }
        XCTAssertNotNil(yoy)
        XCTAssertTrue(review.markdown().contains("## Výsledky"))
    }

    func testTickerMatch() {
        XCTAssertTrue(FinFillPipeline.sameTicker("NVDA", "nvda"))
        XCTAssertTrue(FinFillPipeline.sameTicker("NASDAQ:NVDA", "NVDA"))
        XCTAssertTrue(FinFillPipeline.sameTicker("BRK-B", "brk.b"))
        XCTAssertFalse(FinFillPipeline.sameTicker("AMD", "NVDA"))
        XCTAssertEqual(AnalysisError.tickerMismatch(workbook: "AMD", requested: "NVDA").errorDescription?.hasPrefix("Vybraný sešit patří k AMD"), true)
    }

    func testSpreadsheetNameMatch() {
        XCTAssertTrue(SpreadsheetMatch.name("NVDA Valuation FY2026", contains: "NVDA"))
        XCTAssertTrue(SpreadsheetMatch.name("valuace-nvda (kopie)", contains: "nvda"))
        XCTAssertFalse(SpreadsheetMatch.name("AMD Valuation FY2025", contains: "NVDA"))
        XCTAssertFalse(SpreadsheetMatch.name("NVDAX model", contains: "NVDA"))
        XCTAssertTrue(SpreadsheetMatch.name("BRK.B DCF", contains: "BRK.B"))
        let now = Date()
        let files = [GoogleDriveClient.File(id: "1", name: "NVDA old", modified: now.addingTimeInterval(-1000)),
                     GoogleDriveClient.File(id: "2", name: "AMD Valuation", modified: now),
                     GoogleDriveClient.File(id: "3", name: "NVDA Valuation FY2026", modified: now)]
        XCTAssertEqual(SpreadsheetMatch.candidates(files, ticker: "NVDA").map(\.id), ["3", "1"])
    }

    func testPeerNormalization() {
        XCTAssertEqual(FinFillPipeline.normalizedPeers(["amd, AVGO;intc  nvda", "AMD"], excluding: "NVDA"), ["AMD", "AVGO", "INTC"])
    }
}

final class DCFReviewTests: XCTestCase {
    /// Hodnoty jako z batchGet DCF!A1:M60 (řádky od 0, sloupce od A).
    func grid(wacc: Double, tgr: Double, pvTV: Double, ev: Double, lastFCF: Double = 120) -> [[Any]] {
        var rows = Array(repeating: [Any](repeating: "", count: 13), count: 60)
        func set(_ a1: String, _ v: Any) { let (r, c) = A1.parseCell(a1)!; rows[r][c] = v }
        for (row, label) in DCFLayout.labels { set("B\(row)", label) }
        set("C18", wacc); set("C19", tgr)
        for (i, c) in ["I", "J", "K", "L", "M"].enumerated() { set("\(c)48", 100.0 + Double(i) * 5) }
        set("M48", lastFCF)
        set("M51", 3000.0); set("M52", pvTV); set("M53", ev)
        set("M54", 50.0); set("M55", 20.0); set("M57", 10.0); set("M58", (ev + 30) / 10)
        set("H5", 100.0)
        set("M28", 200.0); set("M39", 50.0)
        for (c, v) in zip(["D", "E", "F", "G", "H"], [0.20, 0.22, 0.21, 0.23, 0.24]) { set("\(c)29", v) }
        for c in ["I", "J", "K", "L"] { set("\(c)29", 0.25) }
        set("M29", 0.26)
        for c in ["E", "F", "G", "H"] { set("\(c)23", 0.10) }
        set("I23", 0.12)
        return rows
    }

    func testLayoutAndHealthyModel() {
        let values = grid(wacc: 0.09, tgr: 0.03, pvTV: 600, ev: 1000)
        XCTAssertTrue(DCFLayout.matches(values))
        let inputs = DCFReview.Inputs.read(values)
        XCTAssertEqual(inputs.wacc, 0.09)
        XCTAssertEqual(inputs.fcf.count, 5)
        XCTAssertEqual(inputs.tvShare!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(inputs.exitMultiple!, 12, accuracy: 1e-9)
        XCTAssertEqual(inputs.historicalMargins.count, 5)
        XCTAssertEqual(inputs.terminalMargin, 0.26)
        let r = DCFReview(inputs: inputs)
        XCTAssertEqual(r.worst, .ok, r.logLines.joined(separator: "\n"))
    }

    func testRedFlags() {
        var values = grid(wacc: 0.08, tgr: 0.085, pvTV: 900, ev: 1000, lastFCF: -5)
        values[28][12] = 0.40            // M29 marže na konci 40 % (historie max. 24 %)
        let r = DCFReview(inputs: .read(values))
        let titles = r.findings.map(\.title)
        XCTAssertEqual(r.worst, .error)
        XCTAssertTrue(titles.contains { $0.hasPrefix("TGR") && $0.hasSuffix("≥ WACC") }, "\(titles)")
        XCTAssertTrue(titles.contains { $0.hasPrefix("TV = 90") }, "\(titles)")
        XCTAssertTrue(titles.contains("Záporné FCF v posledním roce"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("Marže na konci") })
        XCTAssertEqual(r.findings.first?.severity, .error)       // seřazeno od nejhoršího
    }

    func testForeignDCFIsNotTouched() {
        var values = grid(wacc: 0.09, tgr: 0.03, pvTV: 600, ev: 1000)
        values[47][1] = "Free cash flow"
        XCTAssertFalse(DCFLayout.matches(values))
    }

    func testSensitivityFormulasMirrorDCF() {
        let g = SensitivitySheet.grid()
        // Osy: střed = předpoklad z DCF.
        XCTAssertEqual(formula(g, 5, 4), "=DCF!$C$19")
        XCTAssertEqual(formula(g, 5, 2), "=DCF!$C$19-0.01")
        XCTAssertEqual(formula(g, 8, 1), "=DCF!$C$18")
        XCTAssertEqual(formula(g, 6, 1), "=DCF!$C$18-0.01")
        // Střed tabulky (E8): stejné diskontování jako DCF!I49:M52, most k vlastnímu kapitálu a /akcie.
        let center = formula(g, 8, 4)!
        XCTAssertTrue(center.contains("DCF!$I$48/(1+$B8)^1+DCF!$J$48/(1+$B8)^2"), center)
        XCTAssertTrue(center.contains("DCF!$M$48*(1+E$5)/($B8-E$5)/(1+$B8)^5"), center)
        XCTAssertTrue(center.contains("+DCF!$M$54-DCF!$M$55)/DCF!$M$57"), center)
        XCTAssertTrue(center.hasPrefix("=IF($B8<=E$5,\"n/a\""), center)
        // Kontrola tabulky odkazuje na střed.
        XCTAssertTrue(formulas(g).contains("=IFERROR(E8-DCF!M58,\"\")"))
        // Hranice z Thresholds jsou ve vzorcích.
        XCTAssertTrue(formulas(g).contains { $0.contains("C21<0.06") && $0.contains("C21>0.15") }, formulas(g).joined(separator: "\n"))
    }
}

final class CompsTests: XCTestCase {
    func testCompsSheet() {
        let target = CompanySnapshot.compute(ticker: "TST", name: "TestCo", facts: SyntheticFacts.facts)
        let peer = CompanySnapshot.compute(ticker: "PEER", name: "Peer Inc", facts: SyntheticFacts.facts)
        let g = CompsSheet.grid(target: target, peers: [peer, peer], hasDCF: true)
        // Cílová firma v řádku 6, peery od 8.
        XCTAssertEqual(text(g, 6, CompsSheet.C.ticker), "TST")
        XCTAssertEqual(formula(g, 6, CompsSheet.C.price), "=IFERROR(GOOGLEFINANCE(\"TST\"),\"\")")
        XCTAssertEqual(number(g, 6, CompsSheet.C.revenue), 470)
        XCTAssertEqual(number(g, 6, CompsSheet.C.shares), 10)
        XCTAssertEqual(formula(g, 8, CompsSheet.C.evEbitda), "=IF(OR(H8=\"\",N(K8)<=0),\"\",H8/K8)")
        // Statistiky jen z peerů (řádky 8–9), medián EV/EBITDA → implikovaná cena.
        let all = formulas(g)
        XCTAssertTrue(all.contains("=IF(COUNT(R8:R9)=0,\"\",MEDIAN(R8:R9))"), all.joined(separator: "\n"))
        XCTAssertTrue(all.contains("=IF(COUNT(R8:R9)=0,\"\",QUARTILE(R8:R9,1))"))
        XCTAssertTrue(all.contains { $0.contains("*$K$6-N($G$6))/$E$6") }, all.joined(separator: "\n"))
        XCTAssertTrue(all.contains("=IFERROR(DCF!H4,\"\")"))
        XCTAssertNotNil(CompsSheet.requests(sheetId: 7, target: target, peers: [peer], hasDCF: false).first?["updateCells"])
    }
}

// MARK: - Pomocníci pro čtení SheetGrid

private func value(_ g: SheetGrid, _ row: Int, _ col: Int) -> [String: Any]? {
    g.cells[row]?[col]?["userEnteredValue"] as? [String: Any]
}
func text(_ g: SheetGrid, _ row: Int, _ col: Int) -> String? { value(g, row, col)?["stringValue"] as? String }
func formula(_ g: SheetGrid, _ row: Int, _ col: Int) -> String? { value(g, row, col)?["formulaValue"] as? String }
func number(_ g: SheetGrid, _ row: Int, _ col: Int) -> Double? { value(g, row, col)?["numberValue"] as? Double }
func formulas(_ g: SheetGrid) -> [String] {
    g.cells.values.flatMap { $0.values }.compactMap { ($0["userEnteredValue"] as? [String: Any])?["formulaValue"] as? String }
}
