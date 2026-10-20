import Foundation

/// Podání ze SEC submissions (posledních ~1000) včetně položek 8-K – podklad pro kalendář
/// katalyzátorů, ranní poznámku a termín výsledků.
public struct SECFiling: Sendable, Hashable, Identifiable {
    public var id: String { accessionNumber }
    public let form: String
    public let accessionNumber: String
    public let filingDate: String          // yyyy-MM-dd
    public let reportDate: String          // konec období (10-Q/10-K), u 8-K datum události
    public let acceptance: String          // ISO, čas přijetí („2026-08-27T16:20:31.000Z“)
    public let items: [String]             // 8-K: ["2.02", "9.01"]
    public let primaryDocument: String
    public let description: String
    public let cik: Int

    public var documentURL: URL {
        let acc = accessionNumber.replacingOccurrences(of: "-", with: "")
        return URL(string: "https://www.sec.gov/Archives/edgar/data/\(cik)/\(acc)/\(primaryDocument)")!
    }

    /// Podání s výsledky (8-K položka 2.02 = tisková zpráva o výsledcích).
    public var isEarningsRelease: Bool { form.hasPrefix("8-K") && items.contains("2.02") }

    /// Lidsky čitelný popis podání.
    public var summary: String {
        switch form {
        case "10-K", "10-K/A": return "Výroční zpráva (\(form))"
        case "10-Q", "10-Q/A": return "Kvartální zpráva (\(form))"
        case "DEF 14A": return "Pozvánka na valnou hromadu (DEF 14A)"
        case "4": return "Obchod insidera (Form 4)"
        case "SC 13D", "SC 13D/A", "SCHEDULE 13D", "SCHEDULE 13D/A": return "Aktivní podíl nad 5 % (13D)"
        case "SC 13G", "SC 13G/A", "SCHEDULE 13G", "SCHEDULE 13G/A": return "Pasivní podíl nad 5 % (13G)"
        case "S-3", "S-3ASR", "424B2", "424B5": return "Emise cenných papírů (\(form))"
        default:
            if form.hasPrefix("8-K") {
                let names = items.compactMap { Self.itemNames[$0] }
                return names.isEmpty ? "Průběžná informace (8-K)" : names.joined(separator: " · ")
            }
            return form
        }
    }

    /// Položky 8-K (bez 9.01 = jen přílohy).
    public static let itemNames: [String: String] = [
        "1.01": "Významná smlouva", "1.02": "Ukončení významné smlouvy", "1.03": "Insolvence",
        "1.05": "Kybernetický incident",
        "2.01": "Dokončená akvizice / prodej", "2.02": "Výsledky hospodaření", "2.03": "Nový dluh",
        "2.05": "Restrukturalizace", "2.06": "Odpis aktiv",
        "3.01": "Problém s kotací", "3.02": "Neregistrovaná emise akcií", "3.03": "Změna práv akcionářů",
        "4.01": "Změna auditora", "4.02": "Neplatnost dřívějších výkazů",
        "5.01": "Změna kontroly", "5.02": "Změna ve vedení / odměny", "5.03": "Změna stanov",
        "5.07": "Hlasování akcionářů", "7.01": "Regulace FD (prezentace)", "8.01": "Jiná událost",
    ]

    /// Váha pro ranní poznámku a kalendář (vyšší = důležitější).
    public var importance: Int {
        if isEarningsRelease { return 5 }
        if form.hasPrefix("10-K") || form.hasPrefix("10-Q") { return 4 }
        if form.hasPrefix("8-K") {
            let high: Set<String> = ["1.01", "1.03", "1.05", "2.01", "2.05", "2.06", "4.01", "4.02", "5.01", "5.02"]
            return items.contains(where: high.contains) ? 4 : (items.contains("7.01") || items.contains("8.01") ? 2 : 1)
        }
        if form.hasPrefix("SC 13D") || form.hasPrefix("SCHEDULE 13D") { return 3 }
        if form == "4" { return 1 }
        return 1
    }
}

public extension SECClient {
    /// Poslední podání firmy (submissions JSON, část „recent“), nejnovější první.
    func recentFilings(cik: Int) async throws -> (name: String, filings: [SECFiling]) {
        let data = try await get("https://data.sec.gov/submissions/CIK\(Self.paddedCIK(cik)).json")
        return try Self.parseSubmissions(data, cik: cik)
    }

    static func parseSubmissions(_ data: Data, cik: Int) throws -> (name: String, filings: [SECFiling]) {
        struct Sub: Decodable {
            struct Filings: Decodable { let recent: Recent }
            struct Recent: Decodable {
                let accessionNumber: [String]; let filingDate: [String]; let reportDate: [String]
                let acceptanceDateTime: [String]?; let form: [String]; let items: [String]?
                let primaryDocument: [String]; let primaryDocDescription: [String]?
            }
            let name: String?
            let filings: Filings
        }
        let s = try JSONDecoder().decode(Sub.self, from: data)
        let r = s.filings.recent
        let list = r.form.indices.map { i in
            SECFiling(form: r.form[i], accessionNumber: r.accessionNumber[i], filingDate: r.filingDate[i],
                      reportDate: r.reportDate[safe: i] ?? "", acceptance: r.acceptanceDateTime?[safe: i] ?? "",
                      items: (r.items?[safe: i] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                          .filter { !$0.isEmpty },
                      primaryDocument: r.primaryDocument[safe: i] ?? "", description: r.primaryDocDescription?[safe: i] ?? "",
                      cik: cik)
        }
        return (s.name ?? "", list.sorted { ($0.filingDate, $0.acceptance) > ($1.filingDate, $1.acceptance) })
    }
}

/// Odhady termínů z historie podání (SEC termíny výsledků neoznamuje).
public enum FilingCalendar {
    /// Den výsledků: 8-K 2.02 o rok dřív + 364 dní (stejný den v týdnu), jinak poslední 2.02 + 91.
    /// Vrací (datum, podle čeho).
    public static func nextEarnings(_ filings: [SECFiling], today: String) -> (date: String, basis: String)? {
        let releases = filings.filter(\.isEarningsRelease).map(\.filingDate).sorted(by: >)
        guard let last = releases.first else { return nil }
        // Kandidáti: každý loňský termín + 364 dní, který je v budoucnu.
        let fromYearAgo = releases.compactMap { QuarterHistory.addDays($0, 364) }.filter { $0 > today }.sorted()
        if let next = fromYearAgo.first, (DateOnly.days(from: today, to: next) ?? 999) <= 120 {
            let src = QuarterHistory.addDays(next, -364) ?? ""
            return (next, "loni \(src) + 52 týdnů")
        }
        var d = last
        for _ in 0..<12 where d <= today { d = QuarterHistory.addDays(d, 91) ?? d }
        return d > today ? (d, "poslední výsledky \(last) + 13 týdnů") : nil
    }

    /// Další 10-Q / 10-K podle loňského podání za stejné období + 364 dní.
    public static func nextPeriodicReport(_ filings: [SECFiling], today: String) -> (date: String, form: String)? {
        filings.filter { $0.form == "10-Q" || $0.form == "10-K" }
            .compactMap { f in QuarterHistory.addDays(f.filingDate, 364).map { ($0, f.form) } }
            .filter { $0.0 > today }
            .min { $0.0 < $1.0 }
            .map { (date: $0.0, form: $0.1) }
    }

    /// Valná hromada: loňská DEF 14A + 364 dní (pozvánka chodí ~4–6 týdnů před ní).
    public static func nextProxy(_ filings: [SECFiling], today: String) -> String? {
        filings.filter { $0.form == "DEF 14A" }.compactMap { QuarterHistory.addDays($0.filingDate, 364) }
            .filter { $0 > today }.min()
    }

    public static func today(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// „út 27. 10.“
    public static func czechDay(_ ymd: String) -> String {
        guard let d = DateOnly.parse(ymd) else { return ymd }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.weekday, .day, .month], from: d)
        let names = ["ne", "po", "út", "st", "čt", "pá", "so"]
        return "\(names[(c.weekday ?? 1) - 1]) \(c.day!). \(c.month!)."
    }
}
