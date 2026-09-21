import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin client for SEC EDGAR public APIs.
/// SEC requires a descriptive User-Agent with contact e-mail ("Name email@domain") and ≤10 req/s.
public struct SECClient: Sendable {
    public struct Filing: Sendable, Hashable {
        public let form: String
        public let accessionNumber: String   // "0001045810-26-000021"
        public let filingDate: String
        public let reportDate: String        // period end, yyyy-MM-dd
        public let primaryDocument: String   // "nvda-20260125.htm"
        public let cik: Int

        public var documentURL: URL {
            let acc = accessionNumber.replacingOccurrences(of: "-", with: "")
            return URL(string: "https://www.sec.gov/Archives/edgar/data/\(cik)/\(acc)/\(primaryDocument)")!
        }
    }

    public enum SECError: Error, LocalizedError {
        case http(Int, URL)
        case tickerNotFound(String)
        case noAnnualReport(String)
        public var errorDescription: String? {
            switch self {
            case let .http(code, url): return "SEC HTTP \(code) for \(url.absoluteString)"
            case let .tickerNotFound(t): return "Ticker \(t) not found in SEC company_tickers.json"
            case let .noAnnualReport(t): return "No 10-K found for \(t)"
            }
        }
    }

    public let userAgent: String
    let http: HTTP

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.http = HTTP(session: session)
    }

    public static func paddedCIK(_ cik: Int) -> String { String(format: "%010d", cik) }

    public func cik(forTicker ticker: String) async throws -> (cik: Int, name: String) {
        struct Row: Decodable { let cik_str: Int; let ticker: String; let title: String }
        let data = try await get("https://www.sec.gov/files/company_tickers.json")
        let rows = try JSONDecoder().decode([String: Row].self, from: data)
        guard let r = rows.values.first(where: { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }) else {
            throw SECError.tickerNotFound(ticker)
        }
        return (r.cik_str, r.title)
    }

    public func companyFactsData(cik: Int) async throws -> Data {
        try await get("https://data.sec.gov/api/xbrl/companyfacts/CIK\(Self.paddedCIK(cik)).json")
    }

    /// Recent filings of the given forms, newest first.
    public func filings(cik: Int, forms: Set<String> = ["10-K"]) async throws -> [Filing] {
        struct Sub: Decodable {
            struct Filings: Decodable { let recent: Recent }
            struct Recent: Decodable {
                let accessionNumber: [String]; let filingDate: [String]; let reportDate: [String]
                let form: [String]; let primaryDocument: [String]
            }
            let filings: Filings
        }
        let data = try await get("https://data.sec.gov/submissions/CIK\(Self.paddedCIK(cik)).json")
        let r = try JSONDecoder().decode(Sub.self, from: data).filings.recent
        return r.form.indices.compactMap { i in
            guard forms.contains(r.form[i]) else { return nil }
            return Filing(form: r.form[i], accessionNumber: r.accessionNumber[i], filingDate: r.filingDate[i],
                          reportDate: r.reportDate[i], primaryDocument: r.primaryDocument[i], cik: cik)
        }.sorted { $0.filingDate > $1.filingDate }
    }

    public func document(_ filing: Filing) async throws -> String {
        let data = try await get(filing.documentURL.absoluteString)
        return String(decoding: data, as: UTF8.self)
    }

    func get(_ url: String) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        let (data, resp) = try await http.send(req)
        guard (200..<300).contains(resp.statusCode) else { throw SECError.http(resp.statusCode, req.url!) }
        return data
    }
}

/// URLSession wrapper that works on Apple platforms and Linux.
struct HTTP: @unchecked Sendable {
    let session: URLSession
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: URLError(.badServerResponse)); return
                }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }
}
