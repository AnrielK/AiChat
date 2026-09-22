import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies an OAuth 2 access token with scope https://www.googleapis.com/auth/spreadsheets.
/// On iOS implement it with GoogleSignIn (see Integration/GoogleSignInTokenProvider.swift).
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

/// For testing: a token pasted from OAuth Playground (valid ~1 h).
public struct StaticTokenProvider: AccessTokenProvider {
    public let token: String
    public init(_ token: String) { self.token = token }
    public func accessToken() async throws -> String { token }
}

/// Minimal Google Sheets API v4 client (values + addSheet), no SDK needed.
public struct GoogleSheetsClient: Sendable {
    public enum RenderOption: String, Sendable { case formatted = "FORMATTED_VALUE", unformatted = "UNFORMATTED_VALUE", formula = "FORMULA" }

    public enum SheetsError: Error, LocalizedError {
        case http(Int, String)
        public var errorDescription: String? {
            switch self { case let .http(code, body): return "Google Sheets HTTP \(code): \(body.prefix(400))" }
        }
    }

    public let spreadsheetID: String
    let tokens: AccessTokenProvider
    let http: HTTP
    let base = "https://sheets.googleapis.com/v4/spreadsheets/"

    public init(spreadsheetID: String, tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.spreadsheetID = spreadsheetID
        self.tokens = tokens
        self.http = HTTP(session: session)
    }

    /// Accepts an ID or a full URL (https://docs.google.com/spreadsheets/d/<ID>/edit...).
    public static func spreadsheetID(from input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"/spreadsheets/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) {
            return String(s[r]).components(separatedBy: "/").last ?? s
        }
        return s
    }

    public func sheetTitles() async throws -> [String] {
        struct Resp: Decodable { struct S: Decodable { struct P: Decodable { let title: String }; let properties: P }; let sheets: [S] }
        let data = try await request("GET", "\(spreadsheetID)?fields=sheets.properties.title")
        return try JSONDecoder().decode(Resp.self, from: data).sheets.map(\.properties.title)
    }

    /// Returns one 2-D array per range. Values are String / Double / Bool.
    public func batchGet(_ ranges: [String], render: RenderOption) async throws -> [[[Any]]] {
        var comps = URLComponents()
        comps.queryItems = ranges.map { URLQueryItem(name: "ranges", value: $0) } +
            [URLQueryItem(name: "valueRenderOption", value: render.rawValue),
             URLQueryItem(name: "majorDimension", value: "ROWS")]
        let q = comps.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
        let data = try await request("GET", "\(spreadsheetID)/values:batchGet?\(q)")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let valueRanges = json?["valueRanges"] as? [[String: Any]] ?? []
        return valueRanges.map { ($0["values"] as? [[Any]]) ?? [] }
    }

    /// Writes single cells; formulas are entered as if typed (valueInputOption USER_ENTERED).
    public func batchUpdate(_ cells: [(range: String, value: Any)]) async throws {
        let body: [String: Any] = [
            "valueInputOption": "USER_ENTERED",
            "data": cells.map { ["range": $0.range, "values": [[$0.value]]] },
        ]
        _ = try await request("POST", "\(spreadsheetID)/values:batchUpdate", json: body)
    }

    public func writeColumn(range: String, lines: [String]) async throws {
        let body: [String: Any] = ["valueInputOption": "RAW", "data": [["range": range, "values": lines.map { [$0] }]]]
        _ = try await request("POST", "\(spreadsheetID)/values:batchUpdate", json: body)
    }

    public func clear(range: String) async throws {
        let enc = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "!:'"))) ?? range
        _ = try await request("POST", "\(spreadsheetID)/values/\(enc):clear", json: [:])
    }

    public func addSheet(title: String) async throws {
        let body: [String: Any] = ["requests": [["addSheet": ["properties": ["title": title]]]]]
        _ = try await request("POST", "\(spreadsheetID):batchUpdate", json: body)
    }

    public struct SheetInfo: Sendable {
        public let title: String
        public let sheetId: Int
        public let columnCount: Int
    }

    /// Title, numeric sheetId (needed by structural requests) and grid width of every tab.
    public func sheetInfo() async throws -> [SheetInfo] {
        struct Resp: Decodable {
            struct S: Decodable {
                struct P: Decodable {
                    struct G: Decodable { let columnCount: Int? }
                    let title: String; let sheetId: Int; let gridProperties: G?
                }
                let properties: P
            }
            let sheets: [S]
        }
        let data = try await request("GET", "\(spreadsheetID)?fields=properties.title,sheets.properties(title,sheetId,gridProperties.columnCount)")
        return try JSONDecoder().decode(Resp.self, from: data).sheets.map {
            SheetInfo(title: $0.properties.title, sheetId: $0.properties.sheetId,
                      columnCount: $0.properties.gridProperties?.columnCount ?? 26)
        }
    }

    /// Spreadsheet title (for showing a manually entered ID).
    public func title() async throws -> String {
        let data = try await request("GET", "\(spreadsheetID)?fields=properties.title")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["properties"] as? [String: Any])?["title"] as? String) ?? spreadsheetID
    }

    public struct Created: Sendable {
        public let spreadsheetID: String
        public let url: URL
        public let sheetIds: [String: Int]
    }

    /// Creates a new spreadsheet (lands in the root of the user's Drive) — `spreadsheetID` of this
    /// client is ignored. Body from `TemplateRequests.createBody`.
    public static func create(body: [String: Any], tokens: AccessTokenProvider,
                              session: URLSession = .shared) async throws -> Created {
        var req = URLRequest(url: URL(string: "https://sheets.googleapis.com/v4/spreadsheets")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await HTTP(session: session).send(req)
        guard (200..<300).contains(resp.statusCode) else {
            throw SheetsError.http(resp.statusCode, String(decoding: data, as: UTF8.self))
        }
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let id = json["spreadsheetId"] as? String else { throw SheetsError.http(resp.statusCode, "missing spreadsheetId") }
        var ids: [String: Int] = [:]
        for s in (json["sheets"] as? [[String: Any]]) ?? [] {
            if let p = s["properties"] as? [String: Any], let t = p["title"] as? String, let sid = p["sheetId"] as? Int { ids[t] = sid }
        }
        let url = (json["spreadsheetUrl"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit")!
        return Created(spreadsheetID: id, url: url, sheetIds: ids)
    }

    /// spreadsheets.batchUpdate with raw requests (insertDimension, copyPaste, ...), applied atomically.
    public func structuralUpdate(_ requests: [[String: Any]]) async throws {
        guard !requests.isEmpty else { return }
        _ = try await request("POST", "\(spreadsheetID):batchUpdate", json: ["requests": requests])
    }

    func request(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await http.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            throw SheetsError.http(resp.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

public enum A1 {
    /// 0 → "A", 25 → "Z", 26 → "AA"
    public static func column(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    /// "A" → 0, "O" → 14, "AA" → 26
    public static func index(_ column: String) -> Int {
        column.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    public static func quote(_ sheet: String) -> String { "'\(sheet.replacingOccurrences(of: "'", with: "''"))'" }

    public static func cell(_ sheet: String, _ column: String, _ row: Int) -> String { "\(quote(sheet))!\(column)\(row)" }
}
