import XCTest
@testable import FinFillCore

final class ResearchTests: XCTestCase {
    /// Submissions s kvartálními výsledky (8-K 2.02) v rytmu konec měsíce únor/květen/srpen/listopad.
    static let submissions: Data = {
        let rows: [(String, String, String, String)] = [
            // form, filingDate, reportDate, items
            ("8-K", "2026-10-10", "2026-10-09", "5.02"),
            ("4", "2026-10-09", "", ""),
            ("10-Q", "2026-08-28", "2026-07-26", ""),
            ("8-K", "2026-08-27", "2026-08-27", "2.02,9.01"),
            ("10-Q", "2026-05-29", "2026-04-26", ""),
            ("8-K", "2026-05-28", "2026-05-28", "2.02,9.01"),
            ("DEF 14A", "2026-05-08", "", ""),
            ("10-K", "2026-02-26", "2026-01-25", ""),
            ("8-K", "2026-02-25", "2026-02-25", "2.02,9.01"),
            ("10-Q", "2025-11-20", "2025-10-26", ""),
            ("8-K", "2025-11-19", "2025-11-19", "2.02,9.01"),
            ("10-Q", "2025-08-28", "2025-07-27", ""),
        ]
        let json: [String: Any] = ["name": "TESTCO", "filings": ["recent": [
            "form": rows.map(\.0), "filingDate": rows.map(\.1), "reportDate": rows.map(\.2), "items": rows.map(\.3),
            "accessionNumber": rows.indices.map { "0000000001-26-\(String(format: "%06d", $0))" },
            "acceptanceDateTime": rows.map { $0.1 + "T16:00:00.000Z" },
            "primaryDocument": rows.map { _ in "doc.htm" }, "primaryDocDescription": rows.map { _ in "" },
        ]]]
        return try! JSONSerialization.data(withJSONObject: json)
    }()

    var filings: [SECFiling] { try! SECClient.parseSubmissions(Self.submissions, cik: 1).filings }

    func testParseSubmissions() throws {
        let (name, f) = try SECClient.parseSubmissions(Self.submissions, cik: 1)
        XCTAssertEqual(name, "TESTCO")
        XCTAssertEqual(f.count, 12)
        XCTAssertEqual(f.first?.filingDate, "2026-10-10")
        XCTAssertEqual(f.filter(\.isEarningsRelease).count, 4)
        XCTAssertEqual(f.first?.summary, "Změna ve vedení / odměny")
        XCTAssertEqual(f.first { $0.form == "8-K" && $0.items.contains("2.02") }?.importance, 5)
    }

    func testNextEarningsFromYearAgo() {
        // Loni 19. 11. 2025 → letos 18. 11. 2026 (stejný den v týdnu).
        let e = FilingCalendar.nextEarnings(filings, today: "2026-10-19")
        XCTAssertEqual(e?.date, "2026-11-18")
        XCTAssertTrue(e?.basis.contains("2025-11-19") ?? false)
        XCTAssertEqual(FilingCalendar.nextPeriodicReport(filings, today: "2026-10-19")?.form, "10-Q")
        XCTAssertEqual(FilingCalendar.nextProxy(filings, today: "2026-10-19"), "2027-05-07")   // loňská DEF 14A + 52 týdnů
        let c = CompanyData(ticker: "TST", cik: 1, name: "TestCo", facts: [], filings: filings)
        XCTAssertFalse(ResearchSkills.catalysts(for: c, today: "2026-10-19", horizonDays: 60).contains { $0.event.contains("DEF 14A") })
    }

    func testCatalystCalendar() {
        let c = CompanyData(ticker: "TST", cik: 1, name: "TestCo", facts: [], filings: filings)
        let events = ResearchSkills.catalysts(for: c, today: "2026-10-19", horizonDays: 60)
        XCTAssertTrue(events.contains { $0.event == "Výsledky hospodaření" && $0.date == "2026-11-18" && $0.estimated })
        XCTAssertTrue(events.contains { $0.event == "Změna ve vedení / odměny" && !$0.estimated })   // nedávný 8-K
        XCTAssertFalse(events.contains { $0.event.contains("Form 4") })                            // nízká váha
        let md = ResearchSkills.calendarMarkdown(events, tickers: ["TST"], today: "2026-10-19", horizonDays: 60)
        XCTAssertTrue(md.contains("| st 18. 11. 2026-11-18 | TST | Výsledky hospodaření | V |"), md)
        XCTAssertTrue(md.contains("## Posledních 14 dní"))
    }

    func testMorningSince() {
        XCTAssertEqual(ResearchSkills.morningSince(today: "2026-10-19"), "2026-10-16")   // pondělí → pátek
        XCTAssertEqual(ResearchSkills.morningSince(today: "2026-10-21"), "2026-10-20")   // středa → úterý
        XCTAssertEqual(FilingCalendar.czechDay("2026-10-19"), "po 19. 10.")
    }

    func testScenarios() {
        let q = QuarterlyFigures.compute(facts: SyntheticFacts.facts)
        let sc = ResearchSkills.scenarios(q)
        XCTAssertEqual(sc.map(\.name), ["Optimistický", "Základní", "Pesimistický"])
        // QoQ za poslední 4: 130/120, 120/110, 110/110, 110/100
        XCTAssertEqual(sc[0].growthQoQ, 0.1, accuracy: 1e-9)
        XCTAssertEqual(sc[2].growthQoQ, 0, accuracy: 1e-9)
        XCTAssertEqual(sc[2].revenue, 130 * SyntheticFacts.m, accuracy: 1)
        XCTAssertGreaterThan(sc[0].revenue, sc[1].revenue)
    }

    func testThesisEditsAndKPIs() throws {
        var t = Thesis(ticker: "tst")
        let today = "2026-10-19"
        XCTAssertEqual(ThesisEdit.parse(["long", "Datová centra", "táhnou", "růst"]).apply(to: &t, today: today),
                       "Teze: Long – Datová centra táhnou růst")
        _ = ThesisEdit.parse(["pilíř", "Tržby", "rostou", "přes", "20 %"]).apply(to: &t, today: today)
        _ = ThesisEdit.parse(["riziko", "Konkurence"]).apply(to: &t, today: today)
        XCTAssertEqual(ThesisEdit.parse(["kpi", "růst", "tržeb", ">", "20", "%"]),
                       .kpi(.init(metric: .revenueGrowth, above: true, threshold: 0.2)))
        _ = ThesisEdit.parse(["kpi", "provozní", "marže", ">=25%"]).apply(to: &t, today: today)
        _ = ThesisEdit.parse(["kpi", "růst", "tržeb", ">", "20"]).apply(to: &t, today: today)
        _ = ThesisEdit.parse(["cíl", "250,5"]).apply(to: &t, today: today)
        if case .invalid = ThesisEdit.parse(["kpi", "počet", "zákazníků", ">", "5"]) {} else { XCTFail("neznámý ukazatel") }
        XCTAssertEqual(t.pillars, ["Tržby rostou přes 20 %"])
        XCTAssertEqual(t.target, 250.5)

        // Q3 FY25: tržby 130 (YoY +30 %), EBIT 32 → marže 24,6 % (< 25 %)
        let results = t.evaluate(QuarterlyFigures.compute(facts: SyntheticFacts.facts))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].met, false)          // provozní marže > 25 %
        XCTAssertEqual(results[1].met, true)           // růst tržeb > 20 %
        let md = t.markdown(results: results, assessment: nil)
        XCTAssertTrue(md.contains("| 2 | Růst tržeb YoY | > 20.0 % | 30.0 % | ✓ |"), md)

        _ = ThesisEdit.parse(["odebrat", "pilíř", "1"]).apply(to: &t, today: today)
        XCTAssertTrue(t.pillars.isEmpty)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theses-\(UUID().uuidString).json")
        let store = ThesisStore(url: url)
        try store.save(t)
        XCTAssertEqual(store.get("TST"), t)
        try store.delete("TST")
        XCTAssertNil(store.get("TST"))
    }

    func testValuationCrossCheck() {
        let comps: [[Any]] = [["Medián", 1, 2], ["EV / Tržby", "", 180.0], ["P / E", "", 120],
                              ["Průměr metod (medián)", "", 150.0]]
        let read = ValuationReview.readComps(comps)
        XCTAssertEqual(read.avg, 150)
        XCTAssertEqual(read.methods.map(\.0), ["EV / Tržby", "P / E"])

        var r = ValuationReview()
        r.dcfPrice = 40; r.compsPrice = 150; r.currentPrice = 140
        r.wacc = (rf: 0.01, beta: 1.2, mrp: 0.045, costOfDebt: 0.005, wacc: 0.09)
        r.crossCheck()
        let titles = r.findings.map(\.title)
        XCTAssertTrue(titles.contains { $0.hasPrefix("DCF vs. Comps -73") }, "\(titles)")
        XCTAssertTrue(titles.contains("Bezriziková sazba 1.0 %"), "\(titles)")
        XCTAssertEqual(r.worst, .warning)
        let md = r.markdown(ticker: "TST", sheet: "TST Valuation", commentary: nil)
        XCTAssertTrue(md.contains("| DCF (DCF!H4) | $40.00 | -71 % |"), md)
    }
}
