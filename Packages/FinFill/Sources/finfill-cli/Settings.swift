import Foundation

/// Nastavení CLI, aby stačilo `finfill new AMD`.
///
/// Pořadí: přepínač na příkazové řádce > proměnná prostředí `FINFILL_<KLÍČ>` > soubor
/// `~/.config/finfill/config.json` (jiná cesta přes `FINFILL_CONFIG`).
///
/// Klíče: ua, token, token_command, sheet, llm, model, ctx, language, quarterly, sensitivity, peers.
/// `token_command` je příkaz, který vypíše OAuth token (např. `gcloud auth print-access-token`) –
/// token z OAuth Playground platí jen hodinu, příkaz dá vždy čerstvý.
struct CLISettings {
    static let keys: [(key: String, help: String)] = [
        ("ua", "SEC User-Agent, např. \"Jméno email@x.cz\""),
        ("token", "OAuth token Google (platí ~1 h)"),
        ("token_command", "příkaz, který vypíše OAuth token (má přednost před token)"),
        ("sheet", "výchozí sešit pro run/analyze (ID nebo URL)"),
        ("llm", "OpenAI-kompatibilní server pro souhrn, např. http://localhost:8080/v1"),
        ("model", "název modelu na serveru (výchozí \"default\")"),
        ("ctx", "kontext modelu v tokenech (výchozí 32768)"),
        ("language", "jazyk souhrnu: English / Czech"),
        ("quarterly", "list Kvartály: true / false (výchozí false)"),
        ("sensitivity", "list Citlivost + kontrola DCF: true / false (výchozí true)"),
    ]

    static let boolKeys: Set<String> = ["quarterly", "sensitivity"]

    var values: [String: Any] = [:]

    static var path: URL {
        if let p = ProcessInfo.processInfo.environment["FINFILL_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/finfill/config.json")
    }

    static func load() -> CLISettings {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return CLISettings() }
        return CLISettings(values: json)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.path)
    }

    /// Proměnná prostředí FINFILL_UA, FINFILL_TOKEN… má přednost před souborem.
    func string(_ key: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["FINFILL_" + key.uppercased()], !env.isEmpty { return env }
        if let s = values[key] as? String, !s.isEmpty { return s }
        if let n = values[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let s = string(key)?.lowercased() else { return values[key] as? Bool }
        if ["1", "true", "yes", "ano", "on"].contains(s) { return true }
        if ["0", "false", "no", "ne", "off"].contains(s) { return false }
        return nil
    }

    func peers(for ticker: String) -> String? {
        (values["peers"] as? [String: String])?[ticker.uppercased()]
    }

    mutating func set(_ key: String, _ value: String) {
        switch value.lowercased() {
        case "true", "ano", "yes": values[key] = true
        case "false", "ne", "no": values[key] = false
        default: values[key] = value
        }
    }

    mutating func setPeers(_ ticker: String, _ list: String) {
        var p = values["peers"] as? [String: String] ?? [:]
        if list.isEmpty { p[ticker.uppercased()] = nil } else { p[ticker.uppercased()] = list.uppercased() }
        values["peers"] = p
    }

    /// OAuth token: `token_command` (čerstvý) > `token`.
    func oauthToken() -> String? {
        if let cmd = string("token_command") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let out = Pipe()
            p.standardOutput = out
            do {
                try p.run()
                p.waitUntilExit()
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0, !s.isEmpty { return s }
                FileHandle.standardError.write("token_command skončil s chybou \(p.terminationStatus)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("token_command: \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
        return string("token")
    }

    /// Výpis pro `finfill config` (token zkrácený).
    func describe() -> String {
        var lines = ["Soubor: \(Self.path.path)"]
        for (key, help) in Self.keys {
            let isBool = Self.boolKeys.contains(key)
            var v = isBool ? (bool(key).map { $0 ? "ano" : "ne" } ?? "—") : (string(key) ?? "—")
            if key == "token", v.count > 12 { v = String(v.prefix(6)) + "…" + String(v.suffix(4)) }
            lines.append("  \(key.padding(toLength: 14, withPad: " ", startingAt: 0)) \(v)   (\(help))")
        }
        let peers = (values["peers"] as? [String: String]) ?? [:]
        lines.append("  peers" + (peers.isEmpty ? "          —   (finfill config peers NVDA AMD,AVGO)" : ""))
        for (t, p) in peers.sorted(by: { $0.key < $1.key }) { lines.append("    \(t): \(p)") }
        return lines.joined(separator: "\n")
    }
}
