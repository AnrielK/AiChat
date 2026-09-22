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

final class ReconcileAndColumnTests: XCTestCase {
    let f = FinFillCoreTests.filing

    func testNVDANeedsNoPlugs() {
        let checks = Validator.run(FinFillCoreTests.mapping, rows: MappingResolver.resolve(FinFillCoreTests.mapping, facts: f.facts, period: f.period),
                                   facts: f.facts, period: f.period)
        XCTAssertTrue(checks.allSatisfy { $0.status == .passed }, checks.map { "\($0.label) \($0.status)" }.joined(separator: "; "))
    }

    /// Another company: segment members of the template don't exist and SG&A is tagged differently.
    func testUnknownSegmentsAndMissingLineArePlugged() throws {
        var m = FinFillCoreTests.mapping
        for i in m.rows.indices {
            if m.rows[i].sheet == "IncomeStatement" && (m.rows[i].row == 3 || m.rows[i].row == 4) {
                m.rows[i].terms![0].dims = ["us-gaap:StatementBusinessSegmentsAxis": "amd:DataCenterSegmentMember"]
            }
            if m.rows[i].sheet == "IncomeStatement" && m.rows[i].row == 10 {
                m.rows[i].terms = [.init(c: ["us-gaap:DoesNotExist"], sign: nil, dims: nil, optional: nil)]
            }
        }
        var rows = MappingResolver.resolve(m, facts: f.facts, period: f.period)
        let checks = Validator.reconcile(m, rows: &rows, facts: f.facts, period: f.period)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(checks[0].status, .plugged(row: 3, amount: 215938))
        XCTAssertEqual(byID["IncomeStatement!3"]?.value, 215938)
        XCTAssertEqual(byID["IncomeStatement!4"]?.value, 0)
        XCTAssertEqual(checks[2].status, .plugged(row: 10, amount: 4579))   // operating income → SG&A row
        XCTAssertEqual(byID["IncomeStatement!10"]?.value, 4579)
        XCTAssertTrue(checks.allSatisfy(\.passed))
        XCTAssertEqual(MappingResolver.content(for: byID["IncomeStatement!3"]!, column: "L", previousColumn: "K"), .number(215938))
    }

    func testNotReportedTotalDoesNotBlock() {
        var m = FinFillCoreTests.mapping
        m.checks[8].concept = "us-gaap:NotTagged"   // Total liabilities
        m.checks[8].alt = nil
        let checks = Validator.run(m, rows: MappingResolver.resolve(m, facts: f.facts, period: f.period), facts: f.facts, period: f.period)
        XCTAssertEqual(checks[8].status, .notReported)
        XCTAssertTrue(checks.allSatisfy(\.passed))
    }

    func testReferencesCells() {
        XCTAssertFalse(SheetPlanner.referencesCells("=6283+1793"))
        XCTAssertFalse(SheetPlanner.referencesCells("=(-2489-238-278)"))
        XCTAssertTrue(SheetPlanner.referencesCells("=N3+N4"))
        XCTAssertTrue(SheetPlanner.referencesCells("=SUM(G5:N5)"))
        XCTAssertTrue(SheetPlanner.referencesCells("=IncomeStatement!J5"))
        XCTAssertTrue(SheetPlanner.referencesCells("=$N$3*2"))
        XCTAssertFalse(SheetPlanner.referencesCells("=IFERROR(__xludf.DUMMYFUNCTION(\"GOOGLEFINANCE(C4)\"),227.5)"))
        XCTAssertTrue(SheetPlanner.hasTypedNumbers("=(1112+6081+4500)-N12"))
        XCTAssertTrue(SheetPlanner.hasTypedNumbers("=6682-N21"))
        XCTAssertFalse(SheetPlanner.hasTypedNumbers("=SUM(N5:N8)"))
        XCTAssertFalse(SheetPlanner.hasTypedNumbers("=N2+1"))
        XCTAssertFalse(SheetPlanner.hasTypedNumbers("=IF(OR(ISBLANK(O14), O13 = 0), \"0%\", O14/O13)"))
    }

    /// Sheet ends with 2022 in column K (like the AMD workbook on the screenshot); FY2023 is wanted.
    func testColumnCreationCopiesFormulasAndClearsInputs() throws {
        let header: [Any] = ["x", "Income Statement", "", "", "", "", 2018.0, 2019.0, 2020.0, 2021.0, 2022.0]
        var source: [Any?] = Array(repeating: nil, count: 26)
        source[1] = "=J2+1"            // row 2 header formula
        source[2] = 15868.0            // 3 mapped
        source[3] = 11046.0            // 4 mapped
        source[4] = "=K3+K4"           // 5 total → keep
        source[5] = 9439.0             // 6 mapped
        source[6] = "=K6"              // 7 keep
        source[7] = "=K5-K7"           // 8 keep
        source[9] = "=2166+0"          // 10 mapped (constant formula)
        source[15] = "=K13-K14"        // 16 keep
        source[18] = 2.0               // 19 mapped
        source[24] = "note"            // 25 typed text, unmapped → clear
        source[25] = "=12*3"           // 26 constant formula, unmapped → clear
        let mapped = Set(FinFillCoreTests.mapping.rows.filter { $0.sheet == "IncomeStatement" }.map(\.row))
        let c = try SheetPlanner.columnCreation(sheet: "IncomeStatement", sheetId: 42, header: header, year: 2023,
                                                headerRow: 2, sourceColumn: source, mappedRows: mapped)
        XCTAssertEqual(c.sourceColumn, "K")
        XCTAssertEqual(c.column, "L")
        XCTAssertFalse(c.setHeader)                         // =K2+1 after the copy gives 2023
        XCTAssertEqual(c.clearRows, [3, 4, 6, 9, 10, 12, 14, 19, 20, 22, 23, 25, 26])
        let req = c.requests()
        let insert = (req[0]["insertDimension"] as! [String: Any])["range"] as! [String: Any]
        XCTAssertEqual(insert["startIndex"] as? Int, 11)
        XCTAssertEqual(insert["sheetId"] as? Int, 42)
        let copy = req[1]["copyPaste"] as! [String: Any]
        XCTAssertEqual((copy["source"] as! [String: Any])["startColumnIndex"] as? Int, 10)
        XCTAssertEqual(copy["pasteType"] as? String, "PASTE_NORMAL")

        // Typed-in header year → written explicitly.
        source[1] = 2022.0
        XCTAssertTrue(try SheetPlanner.columnCreation(sheet: "IncomeStatement", sheetId: 42, header: header, year: 2023,
                                                      headerRow: 2, sourceColumn: source, mappedRows: mapped).setHeader)
        // A gap is refused with a readable message.
        XCTAssertThrowsError(try SheetPlanner.columnCreation(sheet: "IncomeStatement", sheetId: 42, header: header, year: 2025,
                                                             headerRow: 2, sourceColumn: source, mappedRows: mapped)) { e in
            XCTAssertTrue(e.localizedDescription.contains("2023, 2024"), e.localizedDescription)
        }
    }

    func testPlanForNewColumnWritesEverything() {
        var rows = MappingResolver.resolve(FinFillCoreTests.mapping, facts: f.facts, period: f.period)
        Validator.reconcile(FinFillCoreTests.mapping, rows: &rows, facts: f.facts, period: f.period)
        let plan = SheetPlanner.plan(rows: rows, columns: ["IncomeStatement": 11, "BalanceSheets": 11, "CashFlowStatement": 11],
                                     existing: [:], overwrite: false)
        XCTAssertTrue(plan.allSatisfy { $0.action == .write })
        XCTAssertEqual(plan.first { $0.id == "'CashFlowStatement'!L28" }?.content, .formula("=K30"))
        XCTAssertEqual(plan.first { $0.id == "'BalanceSheets'!L22" }?.content, .formula("=21352-L21"))
    }

    func testDriveListParsing() {
        let json = """
        {"files":[{"id":"1abc","name":"NVDA Valuation - 5y","modifiedTime":"2026-09-20T18:01:02.123Z","owners":[{"displayName":"Anriel"}]},
                  {"id":"2def","name":"AMD DCF"}]}
        """
        let files = GoogleDriveClient.parse(Data(json.utf8))
        XCTAssertEqual(files.map(\.name), ["NVDA Valuation - 5y", "AMD DCF"])
        XCTAssertEqual(files[0].owner, "Anriel")
        XCTAssertNotNil(files[0].modified)
        XCTAssertNil(files[1].modified)
    }
}

final class TemplateTests: XCTestCase {
    let f = FinFillCoreTests.filing

    func testUniversalTemplateLoadsAndIsEmpty() throws {
        let t = try SpreadsheetTemplate.bundledUniversal()
        XCTAssertEqual(t.sheets.map(\.title), ["DCF", "WACC", "IncomeStatement", "BalanceSheets", "CashFlowStatement"])
        XCTAssertEqual(t.yearColumns.first, 6)
        XCTAssertEqual(t.yearColumns.count, 9)
        // No NVIDIA numbers left in the year columns of the statements, only totals / ratios.
        for s in t.sheets where t.yearColumns.sheets.contains(s.title) {
            for c in s.cells {
                guard let (r, col) = A1.parse(c.a), (6...14).contains(col), r >= 2 else { continue }
                XCTAssertNil(c.n, "\(s.title)!\(c.a) = \(c.n!)")
                if let fm = c.f { XCTAssertFalse(SheetPlanner.hasTypedNumbers(fm), "\(s.title)!\(c.a) \(fm)") }
            }
        }
        let dcf = t.sheets.first { $0.title == "DCF" }!
        XCTAssertEqual(dcf.cells.first { $0.a == "C4" }?.v, "{{TICKER}}")
        XCTAssertEqual(dcf.cells.first { $0.a == "D21" }?.f, "=MAX(IncomeStatement!$G$2:$Z$2)-4")
        XCTAssertEqual(dcf.cells.first { $0.a == "H22" }?.f, "=INDEX(IncomeStatement!$G$5:$Z$5,MATCH(H$21,IncomeStatement!$G$2:$Z$2,0))")
        XCTAssertEqual(dcf.cells.first { $0.a == "H5" }?.f, "=GOOGLEFINANCE(C4)")
    }

    func testRequestsSubstitutePlaceholdersAndKeepFormats() throws {
        let t = try SpreadsheetTemplate.bundledUniversal()
        let body = TemplateRequests.createBody(t, title: "AMD Valuation")
        XCTAssertEqual((body["properties"] as! [String: Any])["locale"] as? String, "en_US")
        let ids = Dictionary(uniqueKeysWithValues: t.sheets.enumerated().map { ($1.title, $0 + 100) })
        let req = TemplateRequests.contentRequests(t, sheetIds: ids,
                                                   values: ["TICKER": "AMD", "FY_FIRST": "2017", "TODAY": "DATE(2026,9,21)", "FYEND": "DATE(2025,12,27)"])
        let updates = req.compactMap { $0["updateCells"] as? [String: Any] }
        XCTAssertEqual(updates.count, 5)

        // Every written row / column must fit into the grid created by createBody
        // (Sheets: "Attempting to write row: 68, beyond the last requested row of: 67").
        let grids = Dictionary(uniqueKeysWithValues: ((body["sheets"] as! [[String: Any]]).map { s -> (String, (Int, Int)) in
            let p = s["properties"] as! [String: Any], g = p["gridProperties"] as! [String: Any]
            return (p["title"] as! String, (g["rowCount"] as! Int, g["columnCount"] as! Int))
        }))
        for sheet in t.sheets {
            let u = updates.first { (($0["start"] as! [String: Any])["sheetId"] as! Int) == ids[sheet.title]! }!
            let rows = u["rows"] as! [[String: Any]]
            let cols = rows.map { ($0["values"] as! [[String: Any]]).count }.max() ?? 0
            XCTAssertLessThanOrEqual(rows.count, grids[sheet.title]!.0, sheet.title)
            XCTAssertLessThanOrEqual(cols, grids[sheet.title]!.1, sheet.title)
        }
        for m in req.compactMap({ $0["mergeCells"] as? [String: Any] }) {
            let r = m["range"] as! [String: Any]
            let title = ids.first { $0.value == r["sheetId"] as! Int }!.key
            XCTAssertLessThanOrEqual(r["endRowIndex"] as! Int, grids[title]!.0)
        }
        XCTAssertGreaterThan(req.filter { $0["mergeCells"] != nil }.count, 10)

        func cell(_ sheet: String, _ a: String) -> [String: Any] {
            let u = updates.first { (($0["start"] as! [String: Any])["sheetId"] as! Int) == ids[sheet]! }!
            let (r, c) = A1.parse(a)!
            return ((u["rows"] as! [[String: Any]])[r]["values"] as! [[String: Any]])[c]
        }
        XCTAssertEqual((cell("DCF", "C4")["userEnteredValue"] as? [String: Any])?["stringValue"] as? String, "AMD")
        XCTAssertEqual((cell("DCF", "C6")["userEnteredValue"] as? [String: Any])?["formulaValue"] as? String, "=DATE(2025,12,27)")
        XCTAssertEqual((cell("IncomeStatement", "G2")["userEnteredValue"] as? [String: Any])?["numberValue"] as? Double, 2017)
        XCTAssertEqual((cell("IncomeStatement", "H2")["userEnteredValue"] as? [String: Any])?["formulaValue"] as? String, "=G2+1")
        let fmt = cell("IncomeStatement", "O5")["userEnteredFormat"] as? [String: Any]
        XCTAssertEqual((fmt?["numberFormat"] as? [String: Any])?["pattern"] as? String, "#,##0;(#,##0)")
    }

    func testAnnualPeriodsAndMultiYearPlan() throws {
        let periods = f.facts.annualPeriods(latest: f.period, count: 9)
        XCTAssertEqual(periods.map(\.fiscalYear), [2026, 2025, 2024])
        XCTAssertEqual(periods.map(\.endDate), ["2026-01-25", "2025-01-26", "2024-01-28"])

        let plan = WorkbookFiller.plan(mapping: try TemplateMapping.bundledUniversal(), facts: f.facts, periods: periods,
                                       firstYear: 2018, firstColumn: 6, columnCount: 9)
        XCTAssertEqual(plan.years.map(\.column), ["M", "N", "O"])
        XCTAssertTrue(plan.years.allSatisfy { $0.failed == 0 && $0.plugged == 0 })
        let byRange = Dictionary(plan.writes.map { ($0.range, $0.content) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byRange["'IncomeStatement'!O3"], .number(215938))     // total revenue in row 3
        XCTAssertEqual(byRange["'IncomeStatement'!M3"], .number(60922))
        XCTAssertEqual(byRange["'CashFlowStatement'!O28"], .formula("=N30"))
        XCTAssertNil(byRange["'BalanceSheets'!M3"])                           // FY2024 balance sheet not in this 10-K
        XCTAssertNotNil(byRange["'CashFlowStatement'!M3"])

        // Newest year as the first column → opening cash instead of "={prev}30".
        let first = WorkbookFiller.plan(mapping: try TemplateMapping.bundledUniversal(), facts: f.facts, periods: periods,
                                        firstYear: 2026, firstColumn: 6, columnCount: 1)
        let fr = Dictionary(first.writes.map { ($0.range, $0.content) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(fr["'CashFlowStatement'!G28"], .number(8589))
    }
}
