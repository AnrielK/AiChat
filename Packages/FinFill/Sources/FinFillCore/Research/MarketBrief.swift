import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ranní přehled trhu: včerejší obchodování (indexy, sektory, výnosy, dolar, komodity, futures)
/// a důležité zprávy hlavně z USA. Zdroje bez API klíče: Yahoo Finance (kurzy) a RSS
/// (CNBC, MarketWatch, Yahoo Finance, Federal Reserve). Model shrnuje jen to, co ve zdrojích je.
public struct MarketBrief: Sendable {
    // MARK: - Kurzy

    public struct Instrument: Sendable, Hashable {
        public let symbol: String
        public let name: String
        public let group: Group
        public enum Group: String, Sendable, CaseIterable {
            case index = "Indexy", sector = "Sektory (ETF)", rates = "Výnosy a dolar", commodity = "Komodity a krypto",
                 futures = "Futures teď", watchlist = "Watchlist"
        }
        public init(_ symbol: String, _ name: String, _ group: Group) { self.symbol = symbol; self.name = name; self.group = group }
    }

    public static let instruments: [Instrument] = [
        .init("^GSPC", "S&P 500", .index), .init("^IXIC", "Nasdaq Composite", .index), .init("^DJI", "Dow Jones", .index),
        .init("^RUT", "Russell 2000", .index), .init("^VIX", "VIX", .index),
        .init("XLK", "Technologie", .sector), .init("XLC", "Komunikace", .sector), .init("XLY", "Zbytná spotřeba", .sector),
        .init("XLF", "Finance", .sector), .init("XLV", "Zdravotnictví", .sector), .init("XLI", "Průmysl", .sector),
        .init("XLE", "Energie", .sector), .init("XLP", "Základní spotřeba", .sector), .init("XLU", "Utility", .sector),
        .init("XLB", "Materiály", .sector), .init("XLRE", "Reality", .sector),
        .init("^TNX", "Výnos 10Y UST", .rates), .init("^FVX", "Výnos 5Y UST", .rates), .init("DX-Y.NYB", "Dolarový index", .rates),
        .init("EURUSD=X", "EUR/USD", .rates),
        .init("CL=F", "Ropa WTI", .commodity), .init("GC=F", "Zlato", .commodity), .init("BTC-USD", "Bitcoin", .commodity),
        .init("ES=F", "S&P 500 futures", .futures), .init("NQ=F", "Nasdaq 100 futures", .futures),
    ]

    public struct Quote: Sendable, Hashable {
        public let instrument: Instrument
        public let last: Double
        public let previous: Double
        public let date: String           // den posledního sloupce (NY)
        public var change: Double { previous != 0 ? last / previous - 1 : 0 }
        /// U výnosů se mění v bazických bodech.
        public var changeBps: Double { (last - previous) * 100 }
        public var isYield: Bool { instrument.symbol == "^TNX" || instrument.symbol == "^FVX" }
    }

    /// Yahoo chart API (range 5d, interval 1d): poslední dvě denní zavírací ceny.
    public static func parseChart(_ data: Data, instrument: Instrument) -> Quote? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let ts = result["timestamp"] as? [Double],
              let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first,
              let closes = quote["close"] as? [Any] else { return nil }
        var points: [(t: Double, c: Double)] = []
        for (i, c) in closes.enumerated() {
            guard i < ts.count, let v = (c as? Double) ?? (c as? Int).map(Double.init) else { continue }
            points.append((ts[i], v))
        }
        // Futures mají i dnešní rozpracovanou svíčku; meta.regularMarketPrice je nejčerstvější cena.
        if let meta = result["meta"] as? [String: Any], let rmp = meta["regularMarketPrice"] as? Double,
           instrument.group == .futures, let lastT = points.last?.t {
            points[points.count - 1] = (lastT, rmp)
        }
        guard points.count >= 2 else { return nil }
        var last = points[points.count - 1].c, prev = points[points.count - 2].c
        // ^TNX dřív v desetinách procenta (42.5 = 4,25 %).
        if instrument.symbol == "^TNX" || instrument.symbol == "^FVX", last > 20 { last /= 10; prev /= 10 }
        return Quote(instrument: instrument, last: last, previous: prev, date: day(points[points.count - 1].t))
    }

    static func day(_ unix: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: unix))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - Zprávy

    public struct Headline: Sendable, Hashable {
        public let title: String
        public let source: String
        public let link: String
        public let date: Date?
        public let summary: String
    }

    public struct Feed: Sendable {
        public let name: String
        public let url: String
        public init(_ name: String, _ url: String) { self.name = name; self.url = url }
    }

    public static let feeds: [Feed] = [
        .init("CNBC Markets", "https://www.cnbc.com/id/15839069/device/rss/rss.html"),
        .init("CNBC Economy", "https://www.cnbc.com/id/20910258/device/rss/rss.html"),
        .init("CNBC Top News", "https://www.cnbc.com/id/100003114/device/rss/rss.html"),
        .init("Investing.com Akcie", "https://www.investing.com/rss/news_25.rss"),
        .init("Investing.com Ekonomika", "https://www.investing.com/rss/news_14.rss"),
        .init("Nasdaq", "https://www.nasdaq.com/feed/rssoutbound?category=Markets"),
        .init("Google News", "https://news.google.com/rss/search?q=%28%22stock%20market%22%20OR%20%22Wall%20Street%22%20OR%20%22Federal%20Reserve%22%20OR%20Treasury%20yields%29%20when%3A1d&hl=en-US&gl=US&ceid=US%3Aen"),
        .init("MarketWatch", "https://feeds.content.dowjones.io/public/rss/mw_topstories"),
        .init("Federal Reserve", "https://www.federalreserve.gov/feeds/press_all.xml"),
    ]

    /// RSS 2.0 i Atom, bez XMLParser (funguje stejně na iOS i Linuxu).
    public static func parseRSS(_ xml: String, source: String) -> [Headline] {
        let itemRe = try! NSRegularExpression(pattern: #"<(item|entry)\b[^>]*>(.*?)</\1>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = xml as NSString
        return itemRe.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let body = ns.substring(with: m.range(at: 2))
            func tag(_ name: String) -> String? {
                guard let r = body.range(of: "<\(name)\\b[^>]*>(.*?)</\(name)>", options: [.regularExpression, .caseInsensitive]) else { return nil }
                var s = String(body[r])
                s = s.replacingOccurrences(of: "^<[^>]+>", with: "", options: .regularExpression)
                s = s.replacingOccurrences(of: "</[^>]+>$", with: "", options: .regularExpression)
                s = s.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
                s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                s = HTMLText.decodeEntities(s).replacingOccurrences(of: "\u{00A0}", with: " ")
                return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            }
            guard let title = tag("title"), !title.isEmpty else { return nil }
            var link = tag("link") ?? ""
            if link.isEmpty, let r = body.range(of: #"<link[^>]*href="([^"]+)""#, options: .regularExpression) {
                link = String(body[r]).components(separatedBy: "href=\"").last?.dropLast().description ?? ""
            }
            let dateText = tag("pubDate") ?? tag("published") ?? tag("updated") ?? tag("dc:date")
            let summary = String((tag("description") ?? tag("summary") ?? "").prefix(280))
            return Headline(title: title, source: source, link: link, date: dateText.flatMap(parseDate), summary: summary)
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        for f in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z"] {
            rfc.dateFormat = f
            if let d = rfc.date(from: s) { return d }
        }
        // Investing.com: „2026-10-18 07:19:27“ bez zóny (GMT).
        rfc.timeZone = TimeZone(identifier: "UTC")
        rfc.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = rfc.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }

    /// Okno zpráv: od zavření předposledního obchodního dne (v pondělí od pátku odpoledne), max. 80 položek,
    /// bez duplicit (stejný začátek titulku z více zdrojů).
    public static func select(_ items: [Headline], now: Date, limit: Int = 80) -> [Headline] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let weekday = cal.component(.weekday, from: now)          // 1 = neděle, 2 = pondělí
        let hours: Double = weekday == 2 ? 66 : (weekday == 1 ? 48 : (weekday == 7 ? 30 : 20))
        let from = now.addingTimeInterval(-hours * 3600)
        var seen = Set<String>()
        return items
            .filter { ($0.date ?? now) >= from && ($0.date ?? now) <= now.addingTimeInterval(3600) }
            .sorted { ($0.date ?? now) > ($1.date ?? now) }
            .filter { h in
                let key = String(h.title.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(40))
                return seen.insert(key).inserted
            }
            .prefix(limit).map { $0 }
    }

    // MARK: - Načtení

    public let quotes: [Quote]
    public let headlines: [Headline]
    public let failed: [String]
    public let generated: Date

    public init(quotes: [Quote], headlines: [Headline], failed: [String], generated: Date) {
        self.quotes = quotes; self.headlines = headlines; self.failed = failed; self.generated = generated
    }

    static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    public static func load(watchlist: [String] = [], session: URLSession = .shared,
                            log: @escaping @Sendable (String) -> Void = { _ in }) async -> MarketBrief {
        let http = HTTP(session: session)
        let all = instruments + watchlist.prefix(15).map { Instrument($0.uppercased(), $0.uppercased(), .watchlist) }
        func get(_ url: String) async -> Data? {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.timeoutInterval = 20
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await http.send(req), (200..<300).contains(resp.statusCode) else { return nil }
            return data
        }

        log("Kurzy: \(all.count) instrumentů…")
        var quotes: [Quote] = [], failed: [String] = []
        await withTaskGroup(of: (Instrument, Quote?).self) { group in
            for i in all {
                group.addTask {
                    let sym = i.symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? i.symbol
                    let data = await get("https://query1.finance.yahoo.com/v8/finance/chart/\(sym)?range=5d&interval=1d")
                    return (i, data.flatMap { parseChart($0, instrument: i) })
                }
            }
            for await (i, q) in group { if let q { quotes.append(q) } else { failed.append(i.name) } }
        }
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.symbol, $0) })
        quotes.sort { (order[$0.instrument.symbol] ?? 0) < (order[$1.instrument.symbol] ?? 0) }

        log("Zprávy: \(feeds.count) zdrojů…")
        var items: [Headline] = []
        var tickerFeeds = feeds
        if !watchlist.isEmpty {
            let s = watchlist.prefix(10).joined(separator: ",")
            tickerFeeds.append(.init("Yahoo Finance (watchlist)", "https://feeds.finance.yahoo.com/rss/2.0/headline?s=\(s)&region=US&lang=en-US"))
        }
        await withTaskGroup(of: (Feed, [Headline]?).self) { group in
            for f in tickerFeeds {
                group.addTask {
                    guard let data = await get(f.url) else { return (f, nil) }
                    return (f, parseRSS(String(decoding: data, as: UTF8.self), source: f.name))
                }
            }
            for await (f, list) in group { if let list { items += list } else { failed.append(f.name) } }
        }
        let now = Date()
        return MarketBrief(quotes: quotes, headlines: select(items, now: now), failed: failed.sorted(), generated: now)
    }

    // MARK: - Výstup

    func format(_ q: Quote) -> (value: String, change: String) {
        if q.isYield { return (String(format: "%.2f %%", q.last), String(format: "%+.0f bb", q.changeBps)) }
        let v: String
        switch q.instrument.symbol {
        case "EURUSD=X": v = String(format: "%.4f", q.last)
        case "^VIX": v = String(format: "%.2f", q.last)
        default: v = q.last >= 1000 ? String(format: "%.0f", q.last) : String(format: "%.2f", q.last)
        }
        return (v, String(format: "%+.2f %%", q.change * 100))
    }

    /// Den posledního zavření akciového trhu (podle S&P 500).
    var sessionDate: String? { quotes.first { $0.instrument.symbol == "^GSPC" }?.date ?? quotes.first { $0.instrument.group == .index }?.date }

    /// Měny, komodity, krypto a futures se obchodují i v noci – jejich poslední „den“ je už dnešek.
    func isLive(_ q: Quote) -> Bool {
        q.instrument.group == .futures || (sessionDate.map { q.date > $0 } ?? false)
    }

    /// Tabulky kurzů podle skupin (sektory seřazené od nejlepšího).
    public func quotesMarkdown() -> String {
        var md = ""
        for g in Instrument.Group.allCases {
            var list = quotes.filter { $0.instrument.group == g }
            guard !list.isEmpty else { continue }
            if g == .sector || g == .watchlist { list.sort { $0.change > $1.change } }
            let day = list.first.map { $0.date } ?? ""
            let live = g != .futures && list.allSatisfy(isLive)
            md += "**\(g.rawValue)**" + (g == .futures ? "" : live ? " · teď (obchoduje se i v noci)" : " · zavření \(day)")
            md += "\n\n| | Hodnota | Změna |\n|---|---:|---:|\n"
            for q in list {
                let f = format(q)
                md += "| \(q.instrument.name) | \(f.value) | \(f.change) |\n"
            }
            md += "\n"
        }
        return md
    }

    /// Kurzy a titulky pro model.
    public func promptData() -> String {
        let q = quotes.map { q -> String in
            let f = format(q)
            return "- [\(q.instrument.group.rawValue)] \(q.instrument.name): \(f.value) (\(f.change)) \(isLive(q) ? "now, trades overnight – change since yesterday" : "close \(q.date)")"
        }.joined(separator: "\n")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/New_York")
        df.dateFormat = "EEE HH:mm"
        let h = headlines.enumerated().map { i, h in
            "[\(i + 1)] \(h.date.map { df.string(from: $0) + " ET" } ?? "") \(h.source): \(h.title)"
                + (h.summary.isEmpty ? "" : " — \(h.summary.prefix(200))")
        }.joined(separator: "\n")
        return "MARKET DATA:\n\(q)\n\nHEADLINES (newest first):\n\(h)"
    }

    public static func prompt(data: String, language: String) -> String {
        """
        You are writing a pre-market morning briefing for a private investor in Europe who trades US stocks. \
        Write in \(language). Use ONLY the market data and headlines below – do not add facts, numbers, events or \
        scheduled releases that are not there. Cite headlines with their number in square brackets, e.g. [3]. \
        Prefer US market-moving news: Fed and rates, inflation and jobs data, big-tech and earnings, policy and tariffs, \
        oil and geopolitics. Skip lifestyle, personal finance and opinion pieces. Be concise and specific.

        Output exactly these markdown headings:

        ## Včerejší obchodování
        3–4 sentences: how the main indexes closed, which sectors led and lagged, what yields, the dollar, oil and VIX did, \
        and the most likely reason according to the headlines. Items marked "now" trade overnight – say "ráno" for them, \
        do not explain data dates.
        ## Co hýbe trhem
        - 5–8 bullets, most important first, each max 25 words with [n] citations; group makro/Fed first, then companies, then the rest
        ## Dnes
        - 2–4 bullets: futures now, earnings or data due today ONLY if a headline mentions them
        ## Na co dát pozor
        - 1–2 bullets: the key risk or question for today's session

        \(data)
        """
    }

    /// Zdroje citované jako [n] → odkazy.
    public func sourcesMarkdown(for text: String) -> String {
        let cited = Set((try? NSRegularExpression(pattern: #"\[(\d{1,2})\]"#))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) } } ?? [])
        let list = headlines.enumerated().filter { cited.contains($0.offset + 1) }
        guard !list.isEmpty else { return "" }
        return "**Zdroje:** " + list.map { "[\($0.offset + 1)] [\($0.element.source)](\($0.element.link))" }.joined(separator: " · ") + "\n"
    }

    /// Bez modelu: kurzy + nejnovější titulky.
    public func plainMarkdown(limit: Int = 15) -> String {
        var md = quotesMarkdown()
        md += "**Zprávy**\n\n" + headlines.prefix(limit).map { "- [\($0.title)](\($0.link)) · _\($0.source)_" }.joined(separator: "\n") + "\n"
        return md
    }
}

extension ResearchSkills {
    /// /market-brief: včerejší obchodování + zprávy, text modelem.
    public func marketBrief(watchlist: [String], session: URLSession = .shared) async throws -> String {
        let brief = await MarketBrief.load(watchlist: watchlist, session: session, log: log)
        let df = DateFormatter()
        df.locale = Locale(identifier: "cs_CZ")
        df.timeZone = TimeZone(identifier: "Europe/Prague")
        df.dateFormat = "EEEE d. M. HH:mm"
        var md = "# Přehled trhu — \(df.string(from: brief.generated))\n\n"
        guard !brief.quotes.isEmpty || !brief.headlines.isEmpty else {
            return md + "Kurzy ani zprávy se nepodařilo načíst (\(brief.failed.joined(separator: ", "))). Zkus to za chvíli znovu."
        }
        if let writer {
            log("Píšu přehled…")
            let text = LLMOutput.clean(try await writer.write(MarketBrief.prompt(data: brief.promptData(), language: options.language),
                                                              maxTokens: 1_400))
            md += text + "\n\n" + brief.sourcesMarkdown(for: text) + "\n"
            md += "## Kurzy\n\n" + brief.quotesMarkdown()
        } else {
            md += brief.plainMarkdown()
        }
        if !brief.failed.isEmpty { md += "\n_Nenačteno: \(brief.failed.joined(separator: ", "))._\n" }
        md += "\n_Kurzy: Yahoo Finance (zavírací ceny, futures aktuálně). Zprávy (RSS): CNBC, Investing.com, Nasdaq, Google News, MarketWatch, Yahoo Finance (watchlist), Federal Reserve. Není to investiční doporučení._\n"
        return md
    }
}
