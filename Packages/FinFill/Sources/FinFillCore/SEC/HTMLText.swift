import Foundation

/// Minimal, dependency-free HTML → text helpers (NSAttributedString HTML import is slow and
/// main-thread only on iOS, and unavailable on Linux).
public enum HTMLText {
    public static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// Converts a filing to readable plain text: drops the hidden ix:header, scripts and styles,
    /// turns block elements into line breaks and table cells into " | ".
    public static func toPlainText(_ html: String) -> String {
        var s = html
        for pattern in [#"<ix:header>.*?</ix:header>"#, #"<script\b.*?</script>"#, #"<style\b.*?</style>"#,
                        #"<div[^>]*display:\s*none[^>]*>.*?</div>"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"</t[dh]>"#, with: " | ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/tr|/li|/h[1-6]|/table)\b[^>]*>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = stripTags(s)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\| *){2,}"#, with: "| ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "bull": "\u{2022}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "copy": "\u{00A9}", "sect": "\u{00A7}", "hellip": "\u{2026}",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                var decoded: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if body.hasPrefix("#") {
                    decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[String(body)]
                }
                if let decoded {
                    out += decoded
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}
