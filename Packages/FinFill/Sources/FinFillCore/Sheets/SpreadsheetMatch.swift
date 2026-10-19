import Foundation

/// Patří sešit k firmě? Podle názvu souboru: ticker jako samostatné slovo
/// („NVDA Valuation FY2026“, „valuace-nvda“ ano; „NVDAX model“ ne).
public enum SpreadsheetMatch {
    public static func name(_ name: String, contains ticker: String) -> Bool {
        let t = ticker.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: t)
        return name.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Soubory s tickerem v názvu, nejnověji upravené první.
    public static func candidates(_ files: [GoogleDriveClient.File], ticker: String, limit: Int = 8) -> [GoogleDriveClient.File] {
        Array(files.filter { name($0.name, contains: ticker) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(limit))
    }
}

public extension GoogleDriveClient.File {
    init(id: String, name: String, modified: Date? = nil) {
        self.init(id: id, name: name, modified: modified, owner: nil)
    }
}
