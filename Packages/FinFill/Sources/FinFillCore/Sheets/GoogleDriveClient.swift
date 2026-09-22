import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lists the user's Google Sheets files (Drive API v3) for the spreadsheet picker.
/// Needs scope `https://www.googleapis.com/auth/drive.metadata.readonly` (names only, no content).
public struct GoogleDriveClient: Sendable {
    public static let scope = "https://www.googleapis.com/auth/drive.metadata.readonly"

    public struct File: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let modified: Date?
        public let owner: String?
    }

    public enum DriveError: Error, LocalizedError {
        case missingScope
        case http(Int, String)
        public var errorDescription: String? {
            switch self {
            case .missingScope:
                return "Chybí oprávnění ke čtení seznamu souborů na Disku Google. Odhlas se a přihlas znovu (Nastavení › Google účet)."
            case let .http(code, body):
                return "Google Drive HTTP \(code): \(body.prefix(300))"
            }
        }
    }

    let tokens: AccessTokenProvider
    let http: HTTP

    public init(tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.tokens = tokens
        self.http = HTTP(session: session)
    }

    /// Google Sheets files, most recently modified first. `search` filters by name.
    /// An .xlsx uploaded to Drive is not listed — the Sheets API can only edit native Google Sheets
    /// (File › Save as Google Sheets).
    public func spreadsheets(search: String = "", limit: Int = 100) async throws -> [File] {
        var q = "mimeType='application/vnd.google-apps.spreadsheet' and trashed=false"
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            q += " and name contains '\(term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
        }
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "q", value: q),
            .init(name: "orderBy", value: "modifiedTime desc"),
            .init(name: "pageSize", value: String(limit)),
            .init(name: "fields", value: "files(id,name,modifiedTime,owners(displayName))"),
            .init(name: "includeItemsFromAllDrives", value: "true"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await http.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            if resp.statusCode == 403, body.contains("insufficient") || body.contains("SCOPE") { throw DriveError.missingScope }
            throw DriveError.http(resp.statusCode, body)
        }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [File] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ((json?["files"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            let owner = ((f["owners"] as? [[String: Any]])?.first?["displayName"]) as? String
            return File(id: id, name: name, modified: (f["modifiedTime"] as? String).flatMap(iso.date(from:)), owner: owner)
        }
    }
}
