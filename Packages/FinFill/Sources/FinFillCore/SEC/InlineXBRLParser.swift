import Foundation

/// Parses numeric facts (ix:nonFraction) and document info (dei:*) from an inline XBRL filing
/// such as `nvda-20260125.htm`. Unlike companyfacts JSON, this includes dimensional facts
/// (segments, geography, products).
public struct InlineXBRLDocument: Sendable {
    public let facts: [Fact]
    public let dei: [String: String]     // e.g. "dei:DocumentFiscalYearFocus" -> "2026"

    public var fiscalYear: Int? { dei["dei:DocumentFiscalYearFocus"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public var cik: String? { dei["dei:EntityCentralIndexKey"] }
    public var ticker: String? { dei["dei:TradingSymbol"] }
    public var registrantName: String? { dei["dei:EntityRegistrantName"] }
    public var documentType: String? { dei["dei:DocumentType"] }
}

public enum InlineXBRLParser {
    public enum ParseError: Error, LocalizedError {
        case noFacts
        public var errorDescription: String? { "No inline XBRL facts found in the document." }
    }

    public static func parse(html: String) throws -> InlineXBRLDocument {
        let ns = html as NSString
        let contexts = parseContexts(ns)
        let units = parseUnits(ns)

        var facts: [Fact] = []
        let fracRe = try! NSRegularExpression(pattern: #"<ix:nonFraction\b([^>]*)>(.*?)</ix:nonFraction>"#,
                                              options: [.dotMatchesLineSeparators, .caseInsensitive])
        for m in fracRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = attributes(ns.substring(with: m.range(at: 1)))
            guard let name = attrs["name"], let ctxRef = attrs["contextRef"], let ctx = contexts[ctxRef] else { continue }
            if attrs["xsi:nil"] == "true" { continue }
            let text = HTMLText.decodeEntities(HTMLText.stripTags(ns.substring(with: m.range(at: 2))))
            guard var value = numericValue(text, format: attrs["format"] ?? "") else { continue }
            if let scale = attrs["scale"].flatMap(Int.init) { value *= pow(10, Double(scale)) }
            if attrs["sign"] == "-" { value = -value }
            let unit = attrs["unitRef"].flatMap { units[$0] } ?? attrs["unitRef"] ?? ""
            facts.append(Fact(concept: name, value: value, unit: unit,
                              start: ctx.start, end: ctx.end, dimensions: ctx.dims, source: .inlineXBRL))
        }
        guard !facts.isEmpty else { throw ParseError.noFacts }

        // dei:* document information (ix:nonNumeric).
        var dei: [String: String] = [:]
        let nonNumRe = try! NSRegularExpression(pattern: #"<ix:nonNumeric\b([^>]*name="dei:[^"]+"[^>]*)>(.*?)</ix:nonNumeric>"#,
                                                options: [.dotMatchesLineSeparators, .caseInsensitive])
        for m in nonNumRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = attributes(ns.substring(with: m.range(at: 1)))
            guard let name = attrs["name"], dei[name] == nil else { continue }
            let text = HTMLText.decodeEntities(HTMLText.stripTags(ns.substring(with: m.range(at: 2))))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            dei[name] = text
        }
        return InlineXBRLDocument(facts: facts, dei: dei)
    }

    // MARK: - Contexts & units

    struct Context { let start: String?; let end: String; let dims: [String: String] }

    static func parseContexts(_ ns: NSString) -> [String: Context] {
        let s = ns as String
        let ctxRe = try! NSRegularExpression(pattern: #"<xbrli:context\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</xbrli:context>"#,
                                             options: [.dotMatchesLineSeparators])
        let startRe = try! NSRegularExpression(pattern: #"<xbrli:startDate>\s*([^<\s]+)"#)
        let endRe = try! NSRegularExpression(pattern: #"<xbrli:endDate>\s*([^<\s]+)"#)
        let instRe = try! NSRegularExpression(pattern: #"<xbrli:instant>\s*([^<\s]+)"#)
        let dimRe = try! NSRegularExpression(pattern: #"<xbrldi:explicitMember[^>]*dimension="([^"]+)"[^>]*>\s*([^<\s]+)"#)

        var out: [String: Context] = [:]
        for m in ctxRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let b = body as NSString
            let full = NSRange(location: 0, length: b.length)
            func first(_ re: NSRegularExpression) -> String? {
                re.firstMatch(in: body, range: full).map { b.substring(with: $0.range(at: 1)) }
            }
            var dims: [String: String] = [:]
            for d in dimRe.matches(in: body, range: full) {
                dims[b.substring(with: d.range(at: 1))] = b.substring(with: d.range(at: 2))
            }
            if let inst = first(instRe) {
                out[id] = Context(start: nil, end: inst, dims: dims)
            } else if let st = first(startRe), let en = first(endRe) {
                out[id] = Context(start: st, end: en, dims: dims)
            }
        }
        return out
    }

    static func parseUnits(_ ns: NSString) -> [String: String] {
        let s = ns as String
        let unitRe = try! NSRegularExpression(pattern: #"<xbrli:unit\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</xbrli:unit>"#,
                                              options: [.dotMatchesLineSeparators])
        let measureRe = try! NSRegularExpression(pattern: #"<xbrli:measure>\s*([^<\s]+)"#)
        var out: [String: String] = [:]
        for m in unitRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2)) as NSString
            let measures = measureRe.matches(in: body as String, range: NSRange(location: 0, length: body.length))
                .map { normalizeMeasure(body.substring(with: $0.range(at: 1))) }
            out[id] = measures.joined(separator: "/") // divide -> "USD/shares"
        }
        return out
    }

    static func normalizeMeasure(_ m: String) -> String {
        // "iso4217:USD" -> "USD", "xbrli:shares" -> "shares", "xbrli:pure" -> "pure"
        String(m.split(separator: ":").last ?? Substring(m))
    }

    // MARK: - Values

    static func numericValue(_ text: String, format: String) -> Double? {
        let t = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if format.contains("zero") || ["—", "–", "-", ""].contains(t) { return 0 }
        if let v = Double(t) { return v }
        if format.contains("numwordsen") || format.contains("num-word") {
            let words = ["none": 0, "no": 0, "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                         "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
            return words[t.lowercased()].map(Double.init)
        }
        return nil
    }

    static func attributes(_ s: String) -> [String: String] {
        let re = try! NSRegularExpression(pattern: #"([\w:.-]+)\s*=\s*"([^"]*)""#)
        let ns = s as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }
}
