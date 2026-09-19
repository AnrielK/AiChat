import Foundation

/// Rozděluje streamovaný výstup lokálních modelů na přemýšlení (`<think>…</think>`) a odpověď.
/// Značky mohou přijít rozdělené mezi dva kousky streamu, proto se konec bufferu,
/// který by mohl být začátkem značky, drží do dalšího volání.
struct ThinkTagParser {
    private static let open = "<think>"
    private static let close = "</think>"

    private var buffer = ""
    private var inThink = false
    private var sawTag = false
    private var trimLeadingText = false

    mutating func feed(_ chunk: String) -> [StreamEvent] {
        buffer += chunk
        var events: [StreamEvent] = []

        while true {
            if inThink {
                guard let range = buffer.range(of: Self.close) else { break }
                emit(String(buffer[..<range.lowerBound]), into: &events)
                buffer = String(buffer[range.upperBound...])
                inThink = false
                trimLeadingText = true
                continue
            }

            let openRange = buffer.range(of: Self.open)
            let closeRange = sawTag ? nil : buffer.range(of: Self.close)

            // `</think>` bez otevření: šablona otevřela přemýšlení už v promptu.
            if let closeRange, openRange.map({ closeRange.lowerBound < $0.lowerBound }) ?? true {
                emit(String(buffer[..<closeRange.lowerBound]), into: &events)
                events.append(.promoteTextToReasoning)
                buffer = String(buffer[closeRange.upperBound...])
                sawTag = true
                trimLeadingText = true
                continue
            }
            if let openRange {
                emit(String(buffer[..<openRange.lowerBound]), into: &events)
                buffer = String(buffer[openRange.upperBound...])
                inThink = true
                sawTag = true
                continue
            }
            break
        }

        // Pošli všechno kromě konce, který může být začátkem značky.
        let tags = inThink ? [Self.close] : (sawTag ? [Self.open] : [Self.open, Self.close])
        let keep = Self.partialTagLength(in: buffer, tags: tags)
        if buffer.count > keep {
            emit(String(buffer.dropLast(keep)), into: &events)
            buffer = String(buffer.suffix(keep))
        }
        return events
    }

    mutating func flush() -> [StreamEvent] {
        var events: [StreamEvent] = []
        emit(buffer, into: &events)
        buffer = ""
        return events
    }

    private mutating func emit(_ text: String, into events: inout [StreamEvent]) {
        guard !text.isEmpty else { return }
        if inThink {
            events.append(.reasoning(text))
            return
        }
        var output = Substring(text)
        if trimLeadingText {
            output = output.drop(while: \.isWhitespace)
            guard !output.isEmpty else { return }
            trimLeadingText = false
        }
        events.append(.text(String(output)))
    }

    private static func partialTagLength(in text: String, tags: [String]) -> Int {
        let longest = tags.map(\.count).max() ?? 0
        for length in stride(from: min(text.count, longest - 1), through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if tags.contains(where: { $0.hasPrefix(suffix) }) { return length }
        }
        return 0
    }
}
