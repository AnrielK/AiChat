import XCTest
@testable import FinFillCore

final class FinFillCoreTests: XCTestCase {
    static let html: String = {
        let url = Bundle.module.url(forResource: "nvda-20260125", withExtension: "htm", subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }()
    static let filing = try! PreparedFiling.local(html: html)
    static let mapping = try! TemplateMapping.bundledNVDA()

    func testInlineXBRL() throws {
        let doc = try InlineXBRLParser.parse(html: Self.html)
        XCTAssertGreaterThan(doc.facts.count, 1000)
        XCTAssertEqual(doc.fiscalYear, 2026)
        XCTAssertEqual(doc.ticker, "NVDA")
        let f = Self.filing
        XCTAssertEqual(f.period.endDate, "2026-01-25")
        XCTAssertEqual(f.prior?.endDate, "2025-01-26")
        XCTAssertEqual(f.facts.value("us-gaap:Revenues", period: f.period, type: .duration)?.value, 215_938_000_000)
        XCTAssertEqual(f.facts.value("us-gaap:EarningsPerShareDiluted", period: f.period, type: .duration, unit: "USD/shares")?.value, 4.90)
    }

    func testFY2026AllChecksPass() {
        let f = Self.filing
        let rows = MappingResolver.resolve(Self.mapping, facts: f.facts, period: f.period)
        XCTAssertTrue(rows.allSatisfy(\.isComplete), rows.filter { !$0.isComplete }.map(\.id).joined(separator: ","))
        let checks = Validator.run(Self.mapping, rows: rows, facts: f.facts, period: f.period)
        XCTAssertEqual(checks.count, 14)
        for c in checks { XCTAssertTrue(c.passed, "\(c.label): \(c.computed) vs \(String(describing: c.reported))") }

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["IncomeStatement!3"]?.value, 22459)
        XCTAssertEqual(byID["IncomeStatement!4"]?.value, 193479)
        XCTAssertEqual(byID["CashFlowStatement!16"]?.value, -14535) // incl. Groq $13.0B
        XCTAssertEqual(MappingResolver.content(for: byID["BalanceSheets!22"]!, column: "O", previousColumn: "N"), .formula("=21352-O21"))
        XCTAssertEqual(MappingResolver.content(for: byID["CashFlowStatement!17"]!, column: "O", previousColumn: "N"),
                       .formula("=11226+15157+84-40616-17502"))
        XCTAssertEqual(MappingResolver.content(for: byID["CashFlowStatement!28"]!, column: "O", previousColumn: "N"), .formula("=N30"))
        XCTAssertEqual(MappingResolver.content(for: byID["IncomeStatement!20"]!, column: "O", previousColumn: "N"), .number(4.9))
    }

    /// FY2025 from the new 10-K vs. the values typed by hand into column N of the template.
    func testBacktestAgainstTemplateColumnN() {
        let f = Self.filing
        let rows = MappingResolver.resolve(Self.mapping, facts: f.facts, period: f.prior!)
        let existing: [String: [Int: Double]] = [
            "IncomeStatement": [3: 14304, 4: 116193, 6: 32639, 9: 12914, 10: 3491, 12: 2573, 14: 11146, 19: 2.97, 20: 2.94, 22: 24555, 23: 24804],
            "BalanceSheets": [3: 8589, 4: 34621, 6: 23065, 7: 10080, 8: 3771, 10: 8076, 11: 5188, 13: 18211, 18: 6310, 19: 0, 20: 0,
                              21: 288, 22: 11449, 24: 8463, 25: 1519, 26: 4245, 30: 11261, 31: 68038, 32: 0, 33: 28],
            "CashFlowStatement": [3: 72880, 4: 1864, 5: 4737, 6: -6009, 8: -13063, 9: -4781, 10: 3357, 11: 5104, 15: -3236, 16: -1007,
                                  17: -16178, 21: -834, 22: 0, 23: -1250, 24: -40636, 25: 361, 29: 1309],
        ]
        let diffs = Validator.compare(rows: rows, existing: existing)
        // Only reclassifications inside the balance sheet (totals are identical, see checks):
        //  12/13 long-term equity investments split out of "other", 21/22 lease (not re-tagged for FY2025
        //  in the FY2026 10-K; companyfacts supplies it online), 29/30 common stock split from APIC.
        XCTAssertEqual(Set(diffs.map(\.id)), ["BalanceSheets!12", "BalanceSheets!13", "BalanceSheets!21",
                                              "BalanceSheets!22", "BalanceSheets!29", "BalanceSheets!30"])
    }

    func testPlanner() {
        let f = Self.filing
        let rows = MappingResolver.resolve(Self.mapping, facts: f.facts, period: f.period)
        let existing: [String: [Int: Any]] = ["IncomeStatement": [19: 0.0, 20: "0", 9: 123.0]]
        let plan = SheetPlanner.plan(rows: rows, columns: ["IncomeStatement": 14, "BalanceSheets": 14, "CashFlowStatement": 14],
                                     existing: existing, overwrite: false)
        let byRange = Dictionary(uniqueKeysWithValues: plan.map { ($0.range, $0) })
        XCTAssertEqual(byRange["'IncomeStatement'!O19"]?.action, .write)     // 0 placeholder → fill
        XCTAssertEqual(byRange["'IncomeStatement'!O9"]?.action, .skipNotEmpty)
        XCTAssertEqual(byRange["'IncomeStatement'!O3"]?.action, .write)
        XCTAssertEqual(SheetPlanner.yearColumn(headerRow: ["x", "Income Statement", "", "", "", "", 2018.0, 2019.0, 2020.0, 2021.0,
                                                           2022.0, 2023.0, 2024.0, 2025.0, 2026.0], year: 2026), 14)
    }

    func testSectionsAndChunks() {
        let text = HTMLText.toPlainText(Self.html)
        let sections = FilingSections.extract(plainText: text)
        XCTAssertEqual(sections.map(\.item), ["1", "1A", "7", "7A"])
        for s in sections { XCTAssertGreaterThan(s.text.count, 1500, s.item) }
        XCTAssertTrue(sections[1].text.contains("Risk Factors"))
        let chunks = FilingSections.chunk(sections[1].text, maxChars: 12_000)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 12_000 })
        XCTAssertLessThanOrEqual(abs(chunks.joined().count - sections[1].text.count), chunks.count)
    }

    func testSummarizerWithMockEngine() async throws {
        actor Calls { var prompts: [Int] = []; func add(_ n: Int) { prompts.append(n) } }
        struct Mock: LLMEngine {
            let calls: Calls
            var contextTokens: Int { 8_192 }
            func generate(system: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
                await calls.add(prompt.count)
                return "<think>hmm</think>- point about \(prompt.prefix(20).count) chars"
            }
        }
        let calls = Calls()
        let f = Self.filing
        let kf = KeyFigures.compute(facts: f.facts, period: f.period, prior: f.prior)
        XCTAssertTrue(kf.table().contains("Revenue: FY2026 $215.9B; FY2025 $130.5B (+65%)"), kf.table())
        let res = try await Summarizer(engine: Mock(calls: calls)).summarize(filingHTML: Self.html, company: "NVIDIA", keyFigures: kf)
        XCTAssertEqual(res.sections.count, 4)
        XCTAssertFalse(res.executiveSummary.contains("<think>"))
        let sizes = await calls.prompts
        // 8k context → chunks of ~22k chars; every prompt must stay well inside the context window.
        XCTAssertTrue(sizes.allSatisfy { $0 < 8_192 * 4 }, "\(sizes.max()!)")
        XCTAssertGreaterThan(sizes.count, 8)
    }

    func testCompanyFactsParser() throws {
        let json = """
        {"cik":1045810,"entityName":"NVIDIA CORP","facts":{"us-gaap":{"Revenues":{"label":"Revenues","units":{"USD":[
          {"start":"2024-01-29","end":"2025-01-26","val":130497000000,"accn":"0001045810-25-000023","fy":2025,"fp":"FY","form":"10-K","filed":"2025-02-26"},
          {"start":"2024-10-28","end":"2025-01-26","val":39331000000,"accn":"0001045810-25-000023","fy":2025,"fp":"FY","form":"10-K","filed":"2025-02-26"},
          {"start":"2024-07-29","end":"2024-10-27","val":35082000000,"accn":"0001045810-24-000316","fy":2025,"fp":"Q3","form":"10-Q","filed":"2024-11-20"}
        ]}}}}}
        """
        let r = try CompanyFactsParser.parse(Data(json.utf8))
        XCTAssertEqual(r.facts.count, 2) // 10-Q dropped
        XCTAssertEqual(r.annualReports["0001045810-25-000023"], 2025)
        let store = FactStore(r.facts)
        let p = FiscalPeriod(fiscalYear: 2025, endDate: "2025-01-26", accession: "0001045810-25-000023")
        XCTAssertEqual(store.value("us-gaap:Revenues", period: p, type: .duration)?.value, 130_497_000_000) // not the Q4 figure
    }

    func testHelpers() {
        XCTAssertEqual(A1.column(14), "O")
        XCTAssertEqual(A1.column(26), "AA")
        XCTAssertEqual(A1.index("O"), 14)
        XCTAssertEqual(A1.index("AA"), 26)
        XCTAssertEqual(GoogleSheetsClient.spreadsheetID(from: "https://docs.google.com/spreadsheets/d/1AbC-d_E/edit#gid=0"), "1AbC-d_E")
        XCTAssertEqual(LLMOutput.clean("<think>x\ny</think>\nHello"), "Hello")
        XCTAssertEqual(LLMOutput.clean("Hi <think>unterminated"), "Hi")
        XCTAssertEqual(HTMLText.decodeEntities("A&#160;&amp;&#8217;B&nbsp;"), "A\u{00A0}&\u{2019}B\u{00A0}")
    }
}
