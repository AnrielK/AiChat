import XCTest
@testable import FinFillCore

final class MarketBriefTests: XCTestCase {
    func chart(_ closes: [Any], price: Double? = nil) -> Data {
        var meta: [String: Any] = ["symbol": "X"]
        if let price { meta["regularMarketPrice"] = price }
        let ts = (0..<closes.count).map { 1_760_900_000.0 + Double($0) * 86_400 }
        return try! JSONSerialization.data(withJSONObject: ["chart": ["result": [[
            "meta": meta, "timestamp": ts, "indicators": ["quote": [["close": closes]]],
        ]], "error": NSNull()]])
    }

    func testChartParsing() {
        let spx = MarketBrief.Instrument("^GSPC", "S&P 500", .index)
        let q = MarketBrief.parseChart(chart([6600.0, 6700.0, NSNull(), 6767.0]), instrument: spx)!
        XCTAssertEqual(q.last, 6767)
        XCTAssertEqual(q.previous, 6700)
        XCTAssertEqual(q.change, 0.01, accuracy: 1e-9)

        let tnx = MarketBrief.parseChart(chart([42.0, 41.5]), instrument: .init("^TNX", "10Y", .rates))!
        XCTAssertEqual(tnx.last, 4.15, accuracy: 1e-9)
        XCTAssertEqual(tnx.changeBps, -5, accuracy: 1e-6)

        let es = MarketBrief.parseChart(chart([6700.0, 6720.0], price: 6750), instrument: .init("ES=F", "ES", .futures))!
        XCTAssertEqual(es.last, 6750)        // aktuální cena místo rozpracované svíčky
        XCTAssertNil(MarketBrief.parseChart(Data("{}".utf8), instrument: spx))
    }

    func testRSSParsing() {
        let rss = """
        <?xml version="1.0"?><rss><channel><title>CNBC</title>
        <item><title><![CDATA[Stocks rally as Treasury yields fall &amp; tech jumps]]></title>
        <link>https://www.cnbc.com/a</link><pubDate>Mon, 19 Oct 2026 20:15:00 GMT</pubDate>
        <description><![CDATA[<p>The S&amp;P 500 rose 1%.</p>]]></description></item>
        <item><title>Fed&#8217;s Powell speaks</title><link>https://www.cnbc.com/b</link>
        <pubDate>Mon, 19 Oct 2026 14:00:00 -0400</pubDate></item>
        </channel></rss>
        """
        let items = MarketBrief.parseRSS(rss, source: "CNBC")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Stocks rally as Treasury yields fall & tech jumps")
        XCTAssertEqual(items[0].summary, "The S&P 500 rose 1%.")
        XCTAssertEqual(items[1].title, "Fed\u{2019}s Powell speaks")
        XCTAssertNotNil(items[1].date)

        let inv = MarketBrief.parseRSS("<rss><item><title>Asian AI stocks fall</title><link>https://i/1</link><pubDate>2026-10-18 07:19:27</pubDate></item></rss>", source: "Investing")
        XCTAssertEqual(inv.first?.date, MarketBrief.parseDate("Sun, 18 Oct 2026 07:19:27 GMT"))

        let atom = """
        <feed><entry><title>Atom title</title><link href="https://x.org/1"/><updated>2026-10-19T21:00:00Z</updated></entry></feed>
        """
        let a = MarketBrief.parseRSS(atom, source: "A")
        XCTAssertEqual(a.first?.link, "https://x.org/1")
        XCTAssertNotNil(a.first?.date)
    }

    func testSelectWindowAndDedupe() {
        // Úterý 20. 10. 2026 06:30 ET → okno 20 h.
        let now = MarketBrief.parseDate("Tue, 20 Oct 2026 10:30:00 GMT")!
        func h(_ t: String, _ hoursAgo: Double, _ src: String = "A") -> MarketBrief.Headline {
            .init(title: t, source: src, link: "", date: now.addingTimeInterval(-hoursAgo * 3600), summary: "")
        }
        let sel = MarketBrief.select([h("Old news", 30), h("Fed holds rates steady", 2), h("Fed holds rates steady!", 3, "B"),
                                      h("Nvidia jumps", 10)], now: now)
        XCTAssertEqual(sel.map(\.title), ["Fed holds rates steady", "Nvidia jumps"])
    }

    func testQuoteBoards() {
        var nvda = MarketBrief.Quote(instrument: .init("NVDA", "NVDA", .watchlist), last: 217.09, previous: 214.13, date: "2026-10-19")
        nvda.longName = "NVIDIA Corporation"; nvda.currency = "USD"; nvda.instrumentType = "EQUITY"
        let spx = MarketBrief.Quote(instrument: .init("^GSPC", "S&P 500", .index), last: 6767.1, previous: 6740, date: "2026-10-19")
        let tnx = MarketBrief.Quote(instrument: .init("^TNX", "Výnos 10Y UST", .rates), last: 4.15, previous: 4.11, date: "2026-10-19")
        let b = MarketBrief(quotes: [spx, tnx, nvda], headlines: [], failed: [], generated: Date())
        let boards = b.quoteBoards()
        XCTAssertEqual(boards.map(\.title), ["Indexy", "Výnosy a dolar", "Watchlist"])
        let row = boards[2].rows[0]
        XCTAssertEqual(row.symbol, "NVDA")
        XCTAssertEqual(row.name, "NVIDIA Corporation")
        XCTAssertEqual(row.unit, "US$")
        XCTAssertEqual(row.url, "https://finance.yahoo.com/quote/NVDA")
        XCTAssertEqual(row.changeAbs!, 2.96, accuracy: 1e-9)
        XCTAssertNil(boards[1].rows[0].changeAbs)       // výnos: jen bazické body
        XCTAssertEqual(boards[0].rows[0].symbol, "S&P 500")
        XCTAssertNil(boards[0].rows[0].unit)
        XCTAssertEqual(boards[1].rows[0].unit, "%")
        XCTAssertEqual(boards[1].rows[0].changeBps!, 4, accuracy: 1e-6)
        XCTAssertEqual(boards[0].subtitle, "zavření po 19. 10.")
        let block = boards[2].markdownBlock
        XCTAssertTrue(block.hasPrefix("```aichat-quotes\n"))
        let json = block.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        XCTAssertEqual(QuoteBoard.decode(json), boards[2])
    }

    func testPromptAndSources() {
        let q = MarketBrief.Quote(instrument: .init("^GSPC", "S&P 500", .index), last: 6767, previous: 6700, date: "2026-10-19")
        let b = MarketBrief(quotes: [q], headlines: [.init(title: "A", source: "CNBC", link: "https://a", date: nil, summary: ""),
                                                      .init(title: "B", source: "MW", link: "https://b", date: nil, summary: "")],
                            failed: [], generated: Date())
        XCTAssertTrue(b.promptData().contains("S&P 500: 6767 (+67.00 (+1.00 %)) close 2026-10-19"), b.promptData())
        XCTAssertEqual(b.sourcesMarkdown(for: "text [2] a"), "**Zdroje:** [2] [MW](https://b)\n")
        XCTAssertTrue(b.quotesMarkdown().contains("| S&P 500 | 6767 | +67.00 (+1.00 %) |"))
        XCTAssertTrue(MarketBrief.prompt(data: "x", language: "Czech").contains("## Včerejší obchodování"))

        let oil = MarketBrief.Quote(instrument: .init("CL=F", "Ropa WTI", .commodity), last: 60, previous: 63, date: "2026-10-20")
        let b2 = MarketBrief(quotes: [q, oil], headlines: [], failed: [], generated: Date())
        XCTAssertTrue(b2.quotesMarkdown().contains("**Komodity a krypto** · teď (obchoduje se i v noci)"), b2.quotesMarkdown())
        XCTAssertTrue(b2.quotesMarkdown().contains("**Indexy** · zavření 2026-10-19"))
        XCTAssertTrue(b2.promptData().contains("Ropa WTI: 60.00 (-3.00 (-4.76 %)) now"), b2.promptData())
    }

    func testCalendar() throws {
        let ff = """
        [{"title":"Housing Starts","country":"USD","date":"2026-10-20T08:30:00-04:00","impact":"Low","forecast":"1.30M","previous":"1.28M"},
         {"title":"ADP Weekly Employment Change","country":"USD","date":"2026-10-20T08:15:00-04:00","impact":"Low","forecast":"","previous":"24.8K"},
         {"title":"Fed Chair Powell Speaks","country":"USD","date":"2026-10-20T13:00:00-04:00","impact":"High","forecast":"","previous":""},
         {"title":"BOE Gov Bailey Speaks","country":"GBP","date":"2026-10-20T11:00:00-04:00","impact":"High","forecast":"","previous":""},
         {"title":"German PPI m/m","country":"EUR","date":"2026-10-20T02:00:00-04:00","impact":"Low","forecast":"0.1%","previous":"0.2%"},
         {"title":"Unemployment Claims","country":"USD","date":"2026-10-22T08:30:00-04:00","impact":"Medium","forecast":"200K","previous":"199K"}]
        """
        let econ = MarketCalendar.parseForexFactory(Data(ff.utf8), day: "2026-10-20")
        XCTAssertEqual(econ.map(\.title), ["Housing Starts", "BOE Gov Bailey Speaks", "Fed Chair Powell Speaks"])
        XCTAssertTrue(econ[2].isSpeech)

        let nq = """
        {"data":{"rows":[
          {"symbol":"NFLX","name":"Netflix, Inc.","time":"time-after-hours","marketCap":"$300,123,000,000","epsForecast":"$5.12"},
          {"symbol":"KO","name":"Coca-Cola","time":"time-pre-market","marketCap":"$290,000,000,000","epsForecast":"$0.78"},
          {"symbol":"TINY","name":"Tiny","time":"time-not-supplied","marketCap":"$100,000,000","epsForecast":""},
          {"symbol":"MU","name":"Micron","time":"time-after-hours","marketCap":"$90,000,000,000","epsForecast":"$3.00"}]}}
        """
        let earn = MarketCalendar.parseNasdaqEarnings(Data(nq.utf8), limit: 3, watchlist: ["mu"])
        XCTAssertEqual(earn.map(\.symbol), ["MU", "NFLX", "KO"])        // watchlist první, pak největší
        XCTAssertEqual(earn[1].time, "po zavření")

        let td = """
        [{"securityType":"Note","securityTerm":"20-Year","auctionDate":"2026-10-20T00:00:00","offeringAmount":"13000000000"},
         {"securityType":"Bill","securityTerm":"6-Week","auctionDate":"2026-10-21T00:00:00","offeringAmount":"80000000000"}]
        """
        let auctions = MarketCalendar.parseAuctions(Data(td.utf8), day: "2026-10-20")
        XCTAssertEqual(auctions.map(\.security), ["20-Year Note"])

        let cal = MarketCalendar(day: "2026-10-20", econ: econ, earnings: earn, auctions: auctions)
        let md = cal.markdown(today: true)
        XCTAssertTrue(md.contains("| 19:00 (13:00 ET) | **🎙 Fed Chair Powell Speaks** | — | — | vysoký |"), md)
        XCTAssertTrue(md.contains("| 14:30 (8:30 ET) | Housing Starts | 1.30M | 1.28M | nízký |"), md)
        XCTAssertTrue(md.contains("**Aukce dluhopisů:** 20-Year Note (13 mld. $)"), md)
        XCTAssertTrue(md.contains("NFLX (po zavření, EPS odhad $5.12)"), md)
        XCTAssertTrue(cal.promptData().contains("Fed Chair Powell Speaks [impact High]"))

        // Sobota → pondělí.
        XCTAssertEqual(MarketCalendar.tradingDay(MarketBrief.parseDate("Sat, 24 Oct 2026 12:00:00 GMT")!), "2026-10-26")
        XCTAssertEqual(MarketCalendar.tradingDay(MarketBrief.parseDate("Tue, 20 Oct 2026 05:30:00 GMT")!), "2026-10-20")
    }
}
