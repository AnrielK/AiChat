import Foundation
import Observation

/// Kolik zbývá z limitů tarifu – podle hlaviček poslední odpovědi API.
///
/// - OpenAI: `x-ratelimit-remaining-requests` / `-tokens`, obnova jako doba („6m0s“, „1.5s“).
///   U free tieru s denním limitem dotazů (RPD) hlavička dotazů hlásí ten přísnější – poznat to jde
///   podle doby do obnovy (hodiny místo sekund).
/// - Claude: `anthropic-ratelimit-requests-remaining` / `-input-tokens-remaining`, obnova jako čas (RFC 3339).
/// - Gemini zbývající limity neposílá – zůstane jen počet odeslaných dotazů.
struct RateLimitSnapshot: Codable, Equatable, Sendable {
    var remainingRequests: Int?
    var limitRequests: Int?
    var requestsResetAt: Date?
    var remainingTokens: Int?
    var limitTokens: Int?
    var tokensResetAt: Date?
    var date: Date

    /// Limit dotazů se obnovuje po dnech (free tier: 50 za den), ne po minutách.
    var requestsAreDaily: Bool {
        guard let reset = requestsResetAt else { return false }
        return reset.timeIntervalSince(date) > 5 * 60
    }
}

@MainActor
@Observable
final class RateLimitStatusStore {
    static let shared = RateLimitStatusStore()

    private(set) var snapshots: [String: RateLimitSnapshot] = [:]
    /// Časy odeslaných dotazů za posledních 24 h (klíč poskytovatel:model).
    private(set) var requestLog: [String: [Date]] = [:]

    private static let snapshotsKey = "rateLimitSnapshots"
    private static let logKey = "rateLimitRequestLog"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.snapshotsKey),
           let decoded = try? JSONDecoder().decode([String: RateLimitSnapshot].self, from: data) {
            snapshots = decoded
        }
        if let data = defaults.data(forKey: Self.logKey),
           let decoded = try? JSONDecoder().decode([String: [Date]].self, from: data) {
            requestLog = decoded.mapValues { $0.filter { $0.timeIntervalSinceNow > -86_400 } }
        }
    }

    private static func key(_ provider: AIProvider, _ model: String) -> String {
        provider.rawValue + ":" + model
    }

    func snapshot(provider: AIProvider, model: String) -> RateLimitSnapshot? {
        snapshots[Self.key(provider, model)]
    }

    /// Kolik dotazů na model appka odeslala za posledních `seconds` sekund.
    func sentCount(provider: AIProvider, model: String, within seconds: TimeInterval) -> Int {
        (requestLog[Self.key(provider, model)] ?? []).filter { $0.timeIntervalSinceNow > -seconds }.count
    }

    /// Krátký řádek do menu titulku: „Zbývá 47/50 dotazů · obnova za 2 h 10 min“.
    func summary(provider: AIProvider, model: String, now: Date = .now) -> String? {
        guard let snapshot = self.snapshot(provider: provider, model: model),
              let left = snapshot.requestsLeft(now: now) else {
            let sent = sentCount(provider: provider, model: model, within: 86_400)
            return sent > 0 ? "Odesláno za 24 h: \(sent) dotazů" : nil
        }
        var text = "Zbývá \(left)" + (snapshot.limitRequests.map { "/\($0)" } ?? "")
        text += snapshot.requestsAreDaily ? " dotazů dnes" : " dotazů za min."
        if left != snapshot.limitRequests, let reset = RateLimitSnapshot.countdown(to: snapshot.requestsResetAt, now: now) {
            text += " · obnova \(reset)"
        }
        return text
    }

    /// Zapíše jeden odeslaný dotaz a stav limitů z hlaviček jeho odpovědi (i chybové).
    func record(provider: AIProvider, model: String, response: HTTPURLResponse) {
        let key = Self.key(provider, model)
        let now = Date.now
        var log = (requestLog[key] ?? []).filter { $0.timeIntervalSinceNow > -86_400 }
        log.append(now)
        requestLog[key] = log

        if let snapshot = Self.parse(provider: provider, response: response, now: now) {
            snapshots[key] = snapshot
        }
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(snapshots), forKey: Self.snapshotsKey)
        defaults.set(try? JSONEncoder().encode(requestLog), forKey: Self.logKey)
    }

    // MARK: - Hlavičky

    private static func parse(provider: AIProvider, response: HTTPURLResponse, now: Date) -> RateLimitSnapshot? {
        func header(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces)
        }
        func int(_ name: String) -> Int? { header(name).flatMap { Int($0) } }

        var snapshot = RateLimitSnapshot(date: now)
        switch provider {
        case .openai:
            snapshot.remainingRequests = int("x-ratelimit-remaining-requests")
            snapshot.limitRequests = int("x-ratelimit-limit-requests")
            snapshot.requestsResetAt = header("x-ratelimit-reset-requests").flatMap(duration).map { now.addingTimeInterval($0) }
            snapshot.remainingTokens = int("x-ratelimit-remaining-tokens")
            snapshot.limitTokens = int("x-ratelimit-limit-tokens")
            snapshot.tokensResetAt = header("x-ratelimit-reset-tokens").flatMap(duration).map { now.addingTimeInterval($0) }
        case .claude:
            let iso = ISO8601DateFormatter()
            snapshot.remainingRequests = int("anthropic-ratelimit-requests-remaining")
            snapshot.limitRequests = int("anthropic-ratelimit-requests-limit")
            snapshot.requestsResetAt = header("anthropic-ratelimit-requests-reset").flatMap { iso.date(from: $0) }
            snapshot.remainingTokens = int("anthropic-ratelimit-input-tokens-remaining")
            snapshot.limitTokens = int("anthropic-ratelimit-input-tokens-limit")
            snapshot.tokensResetAt = header("anthropic-ratelimit-input-tokens-reset").flatMap { iso.date(from: $0) }
        default:
            return nil
        }
        guard snapshot.remainingRequests != nil || snapshot.remainingTokens != nil else { return nil }
        return snapshot
    }

    /// Doba ve formátu OpenAI: „20ms“, „1s“, „6m0s“, „1h2m3.5s“.
    nonisolated static func duration(_ text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var matched = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isNumber || char == "." {
                number.append(char)
                index += 1
                continue
            }
            var unit = String(char)
            if char == "m", index + 1 < chars.count, chars[index + 1] == "s" {
                unit = "ms"
                index += 1
            }
            guard let value = Double(number) else { return nil }
            switch unit {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case "ms": total += value / 1000
            default: return nil
            }
            matched = true
            number = ""
            index += 1
        }
        if !number.isEmpty, let value = Double(number) { total += value; matched = true }
        return matched ? total : nil
    }
}

extension RateLimitSnapshot {
    /// „za 3 h 12 min“, „za 45 s“, „obnoveno“.
    static func countdown(to date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        if seconds <= 0 { return "obnoveno" }
        if seconds < 60 { return "za \(seconds) s" }
        if seconds < 3600 { return "za \(seconds / 60) min \(seconds % 60) s" }
        return "za \(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    /// Zbývající dotazy k danému okamžiku – po uplynutí obnovy je limit zase celý.
    func requestsLeft(now: Date = .now) -> Int? {
        if let reset = requestsResetAt, reset <= now { return limitRequests ?? remainingRequests }
        return remainingRequests
    }

    func tokensLeft(now: Date = .now) -> Int? {
        if let reset = tokensResetAt, reset <= now { return limitTokens ?? remainingTokens }
        return remainingTokens
    }
}
