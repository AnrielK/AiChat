import Foundation

/// Čitelný text z HTML. U velkých dokumentů (výroční zpráva ze SEC, uložená stránka)
/// tvoří značky klidně 80 % souboru – bez tohohle kroku by se do promptu poslal celý
/// zdroj, model by v něm utonul a delší soubory by navíc narazily na limit znaků.
enum HTMLText {
    static func extract(from html: String) -> String {
        var text = html

        // Skripty, styly a komentáře nenesou nic, co by model měl číst.
        for pattern in [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<head\b[^>]*>.*?</head>"#,
            #"(?s)<!--.*?-->"#,
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // Buňky tabulky oddělit tabulátorem, bloky koncem řádku – jinak se sousední
        // odstavce i čísla ve výkazech slijí do jedné věty.
        text = text.replacingOccurrences(
            of: #"(?i)</t[dh]\s*>"#, with: "\t", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|table|section|article|blockquote)\s*>"#,
            with: "\n", options: .regularExpression)

        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return normalized(decodingEntities(text))
    }

    // MARK: - Entity

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "euro": "€", "pound": "£", "yen": "¥",
    ]

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)

        while let start = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<start]
            let after = rest.index(after: start)
            // Entita je nejvýš pár znaků; delší úsek bez středníku je obyčejný ampersand.
            let limit = rest.index(after, offsetBy: 10, limitedBy: rest.endIndex) ?? rest.endIndex
            guard let end = rest[after..<limit].firstIndex(of: ";") else {
                result.append("&")
                rest = rest[after...]
                continue
            }
            let body = rest[after..<end]
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += rest[start...end]
                }
            } else if let replacement = named[String(body).lowercased()] {
                result += replacement
            } else {
                result += rest[start...end]
            }
            rest = rest[rest.index(after: end)...]
        }
        result += rest
        return result
    }

    // MARK: - Úklid

    /// Sloučí mezery uvnitř řádků, zahodí prázdné řádky a nechá nejvýš jeden oddělovač
    /// mezi odstavci. Bez toho zbyde po značkách víc bílého místa než textu.
    private static func normalized(_ text: String) -> String {
        var lines: [String] = []
        var blank = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !blank, !lines.isEmpty { lines.append("") }
                blank = true
            } else {
                lines.append(line)
                blank = false
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
