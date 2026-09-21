import Foundation

/// Splits a 10-K into its Items (1 Business, 1A Risk Factors, 7 MD&A, ...).
public struct FilingSection: Sendable, Identifiable {
    public var id: String { item }
    public let item: String      // "1", "1A", "7", "7A"
    public let title: String
    public let text: String
}

public enum FilingSections {
    public static let defaultItems = ["1", "1A", "7", "7A"]

    static let titles: [String: String] = [
        "1": "Business", "1A": "Risk Factors", "1B": "Unresolved Staff Comments", "1C": "Cybersecurity",
        "2": "Properties", "3": "Legal Proceedings", "5": "Market for Registrant's Common Equity",
        "7": "Management's Discussion and Analysis", "7A": "Quantitative and Qualitative Disclosures About Market Risk",
        "8": "Financial Statements", "9A": "Controls and Procedures",
    ]

    /// Every "Item X." heading appears twice (table of contents + body). For each item we take
    /// the occurrence that yields the longest section, which is the body.
    public static func extract(plainText text: String, items: [String] = defaultItems) -> [FilingSection] {
        let ns = text as NSString
        let re = try! NSRegularExpression(
            pattern: #"(?m)^\s*Item\s+(\d{1,2}[A-C]?)\s*[\.:—–-]"#, options: [.caseInsensitive])
        let heads: [(item: String, loc: Int)] = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { (ns.substring(with: $0.range(at: 1)).uppercased(), $0.range.location) }
        guard !heads.isEmpty else { return [] }

        var best: [String: (start: Int, end: Int)] = [:]
        for (i, h) in heads.enumerated() {
            let end = i + 1 < heads.count ? heads[i + 1].loc : ns.length
            if end - h.loc > (best[h.item].map { $0.end - $0.start } ?? -1) { best[h.item] = (h.loc, end) }
        }
        return items.compactMap { item in
            guard let r = best[item], r.end - r.start > 500 else { return nil }
            let body = ns.substring(with: NSRange(location: r.start, length: r.end - r.start))
            return FilingSection(item: item, title: titles[item] ?? "Item \(item)", text: body)
        }
    }

    /// Splits text into chunks of at most `maxChars`, on paragraph boundaries where possible.
    public static func chunk(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n") {
            if current.count + para.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current); current = ""
            }
            if para.count > maxChars { // very long paragraph: hard split
                var rest = Substring(para)
                while rest.count > maxChars { chunks.append(String(rest.prefix(maxChars))); rest = rest.dropFirst(maxChars) }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + para
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
