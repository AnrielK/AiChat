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

    func testPromptAndSources() {
        let q = MarketBrief.Quote(instrument: .init("^GSPC", "S&P 500", .index), last: 6767, previous: 6700, date: "2026-10-19")
        let b = MarketBrief(quotes: [q], headlines: [.init(title: "A", source: "CNBC", link: "https://a", date: nil, summary: ""),
                                                      .init(title: "B", source: "MW", link: "https://b", date: nil, summary: "")],
                            failed: [], generated: Date())
        XCTAssertTrue(b.promptData().contains("S&P 500: 6767 (+1.00 %) close 2026-10-19"), b.promptData())
        XCTAssertEqual(b.sourcesMarkdown(for: "text [2] a"), "**Zdroje:** [2] [MW](https://b)\n")
        XCTAssertTrue(b.quotesMarkdown().contains("| S&P 500 | 6767 | +1.00 % |"))
        XCTAssertTrue(MarketBrief.prompt(data: "x", language: "Czech").contains("## Včerejší obchodování"))

        let oil = MarketBrief.Quote(instrument: .init("CL=F", "Ropa WTI", .commodity), last: 60, previous: 63, date: "2026-10-20")
        let b2 = MarketBrief(quotes: [q, oil], headlines: [], failed: [], generated: Date())
        XCTAssertTrue(b2.quotesMarkdown().contains("**Komodity a krypto** · teď (obchoduje se i v noci)"), b2.quotesMarkdown())
        XCTAssertTrue(b2.quotesMarkdown().contains("**Indexy** · zavření 2026-10-19"))
        XCTAssertTrue(b2.promptData().contains("Ropa WTI: 60.00 (-4.76 %) now"), b2.promptData())
    }
}
