import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Co je dnes na programu: ekonomická data a projevy (ForexFactory), výsledky velkých firem
/// (Nasdaq) a aukce státních dluhopisů (TreasuryDirect). Bez API klíčů; co se nenačte, vynechá se.
public struct MarketCalendar: Sendable, Equatable {
    public struct EconEvent: Sendable, Equatable {
        public let title: String
        public let country: String
        public let date: Date
        public let impact: String          // High / Medium / Low / Holiday
        public let forecast: String
        public let previous: String
        public var isSpeech: Bool {
            let t = title.lowercased()
            return t.contains("speaks") || t.contains("testifies") || t.contains("press conference") || t.contains("speech")
        }
    }

    public struct Earnings: Sendable, Equatable {
        public let symbol: String
        public let name: String
        public let time: String            // „před otevřením“ / „po zavření“ / „neuvedeno“
        public let marketCap: Double
        public let epsForecast: String
    }

    public struct Auction: Sendable, Equatable {
        public let security: String        // „10-Year Note“
        public let amount: Double?         // USD
    }

    /// Den, pro který se kalendář skládá (NY), a jestli je to dnešek.
    public var day: String
    public var econ: [EconEvent] = []
    public var earnings: [Earnings] = []
    public var auctions: [Auction] = []

    public var isEmpty: Bool { econ.isEmpty && earnings.isEmpty && auctions.isEmpty }

    // MARK: - Den

    static var ny: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    /// Obchodní den: dnes v NY, o víkendu pondělí.
    public static func tradingDay(_ now: Date) -> String {
        let cal = ny
        var d = now
        while [1, 7].contains(cal.component(.weekday, from: d)) { d = cal.date(byAdding: .day, value: 1, to: d)! }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func nyDay(_ d: Date) -> String {
        let c = ny.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - Parsování

    /// ForexFactory týden: [{title, country, date (ISO s posunem), impact, forecast, previous}].
    /// Bere USD (vše kromě Low bez prognózy) a z ostatních jen High (ECB, BoE, Čína…).
    public static func parseForexFactory(_ data: Data, day: String) -> [EconEvent] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return rows.compactMap { r -> EconEvent? in
            guard let title = r["title"] as? String, let country = r["country"] as? String,
                  let ds = r["date"] as? String, let date = iso.date(from: ds) else { return nil }
            let e = EconEvent(title: title, country: country, date: date, impact: r["impact"] as? String ?? "",
                              forecast: r["forecast"] as? String ?? "", previous: r["previous"] as? String ?? "")
            guard nyDay(date) == day else { return nil }
            if country == "USD" { return e.impact == "Holiday" || e.impact != "Low" || e.isSpeech || !e.forecast.isEmpty ? e : nil }
            return e.impact == "High" ? e : nil
        }.sorted { $0.date < $1.date }
    }

    /// Nasdaq earnings calendar: data.rows [{symbol, name, time, marketCap „$1,234,567“, epsForecast}].
    public static func parseNasdaqEarnings(_ data: Data, limit: Int = 12, watchlist: [String] = []) -> [Earnings] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = ((json["data"] as? [String: Any])?["rows"] as? [[String: Any]]) else { return [] }
        let all = rows.compactMap { r -> Earnings? in
            guard let symbol = r["symbol"] as? String else { return nil }
            let cap = Double((r["marketCap"] as? String ?? "").filter { $0.isNumber || $0 == "." }) ?? 0
            let time: String
            switch r["time"] as? String ?? "" {
            case "time-pre-market": time = "před otevřením"
            case "time-after-hours": time = "po zavření"
            default: time = "neuvedeno"
            }
            return Earnings(symbol: symbol, name: r["name"] as? String ?? symbol, time: time, marketCap: cap,
                            epsForecast: r["epsForecast"] as? String ?? "")
        }
        let watch = Set(watchlist.map { $0.uppercased() })
        let mine = all.filter { watch.contains($0.symbol) }
        let big = all.filter { !watch.contains($0.symbol) }.sorted { $0.marketCap > $1.marketCap }
        return mine + big.prefix(max(limit - mine.count, 0))
    }

    /// TreasuryDirect upcoming: [{securityType, securityTerm, auctionDate „2026-10-20T00:00:00“, offeringAmount}].
    public static func parseAuctions(_ data: Data, day: String) -> [Auction] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let date = r["auctionDate"] as? String, date.hasPrefix(day) else { return nil }
            let term = r["securityTerm"] as? String ?? ""
            let type = r["securityType"] as? String ?? ""
            let amount = (r["offeringAmount"] as? String).flatMap(Double.init) ?? (r["offeringAmount"] as? Double)
            return Auction(security: "\(term) \(type)".trimmingCharacters(in: .whitespaces), amount: amount)
        }
    }

    // MARK: - Načtení

    public static func load(now: Date = Date(), watchlist: [String] = [], session: URLSession = .shared,
                            failed: inout [String]) async -> MarketCalendar {
        let day = tradingDay(now)
        let http = HTTP(session: session)
        @Sendable func get(_ url: String, headers: [String: String] = [:]) async -> Data? {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.timeoutInterval = 20
            req.setValue(MarketBrief.browserUA, forHTTPHeaderField: "User-Agent")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, resp) = try? await http.send(req), (200..<300).contains(resp.statusCode) else { return nil }
            return data
        }
        async let ff = get("https://nfs.faireconomy.media/ff_calendar_thisweek.json")
        async let nq = get("https://api.nasdaq.com/api/calendar/earnings?date=\(day)",
                           headers: ["Accept": "application/json, text/plain, */*", "Origin": "https://www.nasdaq.com",
                                     "Referer": "https://www.nasdaq.com/"])
        async let td = get("https://www.treasurydirect.gov/TA_WS/securities/upcoming?format=json")
        var cal = MarketCalendar(day: day)
        if let d = await ff { cal.econ = parseForexFactory(d, day: day) } else { failed.append("kalendář ForexFactory") }
        if let d = await nq { cal.earnings = parseNasdaqEarnings(d, watchlist: watchlist) } else { failed.append("výsledky Nasdaq") }
        if let d = await td { cal.auctions = parseAuctions(d, day: day) } else { failed.append("aukce TreasuryDirect") }
        return cal
    }

    // MARK: - Výstup

    /// „14:30 (8:30 ET)“
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.timeZone = TimeZone(identifier: "Europe/Prague")
        f.dateFormat = "H:mm"
        let e = DateFormatter()
        e.locale = Locale(identifier: "en_US_POSIX")
        e.timeZone = TimeZone(identifier: "America/New_York")
        e.dateFormat = "H:mm"
        return "\(f.string(from: d)) (\(e.string(from: d)) ET)"
    }

    static let impactCZ = ["High": "vysoký", "Medium": "střední", "Low": "nízký", "Holiday": "svátek"]

    static func money(_ v: Double) -> String {
        v >= 1e12 ? String(format: "%.2f bil. $", v / 1e12) : v >= 1e9 ? String(format: "%.0f mld. $", v / 1e9) : String(format: "%.0f mil. $", v / 1e6)
    }

    public func markdown(today: Bool) -> String {
        guard !isEmpty else { return "" }
        var md = "## Kalendář \(today ? "dne" : "na \(FilingCalendar.czechDay(day))") (čas Praha)\n\n"
        if !econ.isEmpty {
            md += "| Čas | Událost | Prognóza | Minule | Dopad |\n|---|---|---:|---:|---|\n"
            for e in econ {
                let flag = e.country == "USD" ? "" : "\(e.country): "
                let title = e.isSpeech ? "🎙 \(flag)\(e.title)" : "\(flag)\(e.title)"
                md += "| \(Self.time(e.date)) | \(e.impact == "High" ? "**\(title)**" : title) | \(e.forecast.isEmpty ? "—" : e.forecast) | "
                    + "\(e.previous.isEmpty ? "—" : e.previous) | \(Self.impactCZ[e.impact] ?? e.impact) |\n"
            }
            md += "\n"
        }
        if !auctions.isEmpty {
            md += "**Aukce dluhopisů:** " + auctions.map { a in a.security + (a.amount.map { " (\(Self.money($0)))" } ?? "") }
                .joined(separator: ", ") + "\n\n"
        }
        if !earnings.isEmpty {
            md += "**Výsledky:** " + earnings.map { e in
                "\(e.symbol) (\(e.time)\(e.epsForecast.isEmpty ? "" : ", EPS odhad \(e.epsForecast)"))"
            }.joined(separator: " · ") + "\n\n"
        }
        return md
    }

    public func promptData() -> String {
        guard !isEmpty else { return "TODAY'S CALENDAR: (none loaded)" }
        var lines: [String] = []
        for e in econ {
            lines.append("- \(Self.time(e.date)) \(e.country) \(e.title) [impact \(e.impact)]"
                         + (e.forecast.isEmpty ? "" : " forecast \(e.forecast)") + (e.previous.isEmpty ? "" : " previous \(e.previous)"))
        }
        for a in auctions { lines.append("- Treasury auction: \(a.security)") }
        for e in earnings {
            lines.append("- Earnings \(e.symbol) (\(e.name)) \(e.time)" + (e.epsForecast.isEmpty ? "" : ", consensus EPS \(e.epsForecast)")
                         + (e.marketCap > 0 ? ", market cap \(Self.money(e.marketCap))" : ""))
        }
        return "TODAY'S CALENDAR (\(day), times Prague with ET):\n" + lines.joined(separator: "\n")
    }
}
