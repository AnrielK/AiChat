import Foundation

/// Verze sestavení, jak ji do bundlu zapsal `make-ipa.sh`.
///
/// `CFBundleShortVersionString` je marketingová verze z posledního tagu `v*`,
/// `CFBundleVersion` je počet commitů – monotónně roste a je stejný na Macu i na CI,
/// takže dvě IPA se stejným číslem jsou opravdu stejný kód. `GitCommit` a `BuildDate`
/// tam skript dopíše sám; v buildu z Xcode chybí a řetězec je pak bez nich.
enum AppVersion {
    static var short: String {
        let marketing = string("CFBundleShortVersionString") ?? "?"
        let build = string("CFBundleVersion") ?? "?"
        return "\(marketing) (\(build))"
    }

    /// Commit, ze kterého build vznikl. `+` na konci znamená, že strom nebyl čistý.
    static var commit: String? { string("GitCommit") }

    /// Kdy build vznikl, v místním čase.
    static var built: String? {
        guard let raw = string("BuildDate") else { return nil }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Jeden řádek do patičky Nastavení.
    static var summary: String {
        var parts = [short]
        if let commit { parts.append("commit \(commit)") }
        if let built { parts.append(built) }
        return parts.joined(separator: " · ")
    }

    private static func string(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces)
            .nilWhenEmpty
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
