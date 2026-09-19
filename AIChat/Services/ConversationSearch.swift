import Foundation
import SwiftData

/// Vyhledání v historii, předané do pipeline. Vrací hotový blok pro prompt (nebo prázdný text).
typealias HistoryLookup = @Sendable (String) async -> String

/// Fulltext nad uloženými konverzacemi.
///
/// `@ModelActor` si drží vlastní `ModelContext` nad stejným kontejnerem, takže hledání
/// běží mimo hlavní vlákno a nesahá na kontext, se kterým pracuje UI. Actor je `Sendable`,
/// dá se tedy zachytit do uzávěru, který se posílá poskytovateli.
@ModelActor
actor ConversationSearch {
    /// Kolik zpráv se nejvýš načte. Historie bývá v jednotkách tisíc zpráv; s tímhle stropem
    /// je hledání pod 100 ms a starší chaty stejně vypadnou přes řazení podle data.
    private static let fetchLimit = 3_000

    /// Úryvky z minulých chatů k dotazu. Prázdný text = nic relevantního.
    ///
    /// - Parameters:
    ///   - excluding: probíhající konverzace (vlastní historii si model vidí v promptu)
    ///   - characterBudget: kolik znaků smí blok zabrat
    func excerpts(
        for query: String,
        excluding: UUID?,
        characterBudget: Int = 2_500,
        limit: Int = 4
    ) -> String {
        let terms = Self.searchTerms(in: query)
        guard !terms.isEmpty else { return "" }

        var descriptor = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = Self.fetchLimit
        if let window = Self.dateWindow(in: query) {
            let start = window.start
            let end = window.end
            descriptor.predicate = #Predicate<ChatMessage> { $0.createdAt >= start && $0.createdAt < end }
        }
        guard let messages = try? modelContext.fetch(descriptor), !messages.isEmpty else { return "" }

        // Skóre zprávy = kolik různých hledaných kmenů obsahuje, s bonusem za opakování.
        // Jednoduché počítání stačí: hledá se v desítkách zpráv, ne v milionech.
        struct Hit {
            let message: ChatMessage
            let score: Double
        }
        var hits: [Hit] = []
        for message in messages {
            guard let conversation = message.conversation, conversation.id != excluding else { continue }
            guard !message.text.isEmpty else { continue }
            var counts: [String: Int] = [:]
            for term in Terms.stems(of: message.text) where terms.contains(term) {
                counts[term, default: 0] += 1
            }
            guard !counts.isEmpty else { continue }
            let coverage = Double(counts.count) / Double(terms.count)
            let density = counts.values.reduce(0, +)
            hits.append(Hit(message: message, score: coverage * 10 + log(1 + Double(density))))
        }
        guard !hits.isEmpty else { return "" }

        hits.sort { $0.score > $1.score }

        var blocks: [String] = []
        var seenConversations = Set<UUID>()
        var used = 0
        for hit in hits {
            guard blocks.count < limit else { break }
            guard let conversation = hit.message.conversation else { continue }
            // Z jednoho chatu jeden úryvek – jinak se odpověď zaplní jedinou konverzací.
            guard seenConversations.insert(conversation.id).inserted else { continue }

            let block = Self.block(around: hit.message, in: conversation)
            guard used + block.count <= characterBudget else { continue }
            used += block.count
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Nalezená zpráva i s protějškem – otázka bez odpovědi (nebo naopak) k ničemu není.
    private static func block(around message: ChatMessage, in conversation: Conversation) -> String {
        let sorted = conversation.sortedMessages
        let index = sorted.firstIndex { $0.id == message.id } ?? 0
        var pair: [ChatMessage] = [message]
        if message.role == .user, index + 1 < sorted.count, sorted[index + 1].role == .assistant {
            pair.append(sorted[index + 1])
        } else if message.role == .assistant, index > 0, sorted[index - 1].role == .user {
            pair.insert(sorted[index - 1], at: 0)
        }

        let date = message.createdAt.formatted(.dateTime.day().month().year())
        let header = "[\(date) · chat „\(conversation.title)“]"
        let body = pair.map { line in
            let who = line.role == .user ? "Uživatel" : "Asistent"
            let text = line.text.count > 600
                ? String(line.text.prefix(600)) + " […]"
                : line.text
            return "\(who): \(text)"
        }
        return ([header] + body).joined(separator: "\n")
    }

    // MARK: - Rozpoznání dotazu

    /// Ptá se uživatel na něco, co už probírali dřív?
    ///
    /// Bere se to opatrně: samotné „minulý týden“ může být součástí úkolu nad přílohou
    /// („co se stalo minulý týden podle téhle zprávy“), proto se hledání v historii pouští
    /// jen v chatu bez dokumentů – o to se stará `RetrievalPipeline`.
    nonisolated static func isHistoryQuestion(_ text: String) -> Bool {
        let normalized = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "cs"))
        let phrases = [
            "co jsme", "jsme resili", "resili jsme", "bavili jsme", "psali jsme", "uz jsme",
            "ptal jsem se", "ptala jsem se", "rikal jsi", "rikala jsi", "poradil jsi",
            "minulem chatu", "predchozim chatu", "minule jsme", "v jakem chatu", "ve kterem chatu",
            "nasi konverzaci", "nasich konverzaci", "did we discuss", "we talked about"
        ]
        if phrases.contains(where: { normalized.contains($0) }) { return true }

        let words = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let reference = ["minul", "posledn", "predtim", "nedavno", "historii", "historie",
                         "kdysi", "tenkrat", "onehdy", "drive"]
        return words.contains { word in reference.contains { word.hasPrefix($0) } }
    }

    /// Kmeny, ve kterých se má hledat – bez slov, kterými se uživatel ptá na historii.
    /// Bez tohohle kroku by dotaz „co jsme řešili minulý týden kolem faktury“ hledal
    /// hlavně „minul“ a „tyden“, což je v historii úplně všude.
    private static func searchTerms(in query: String) -> Set<String> {
        let noise: Set<String> = [
            "minul", "posledn", "predtim", "nedavn", "histor", "kdysi", "tenkra", "drive",
            "resil", "resen", "bavil", "psali", "ptal", "ptala", "rikal", "rikala",
            "tyden", "tydne", "mesic", "mesici", "vcera", "dnes", "loni", "letos",
            "chatu", "chatev", "konver", "zprav", "talked", "discus", "chat"
        ]
        return Set(Terms.stems(of: query).filter { !noise.contains($0) })
    }

    // MARK: - Časové vymezení

    /// Období zmíněné v dotazu („včera“, „minulý týden“, „v červnu“, „2025“).
    /// nil = hledá se v celé historii.
    static func dateWindow(in query: String) -> (start: Date, end: Date)? {
        let text = query.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "cs"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "cs_CZ")
        calendar.firstWeekday = 2  // pondělí
        let now = Date.now

        func range(_ component: Calendar.Component, offset: Int) -> (Date, Date)? {
            guard let interval = calendar.dateInterval(of: component, for: now),
                  let start = calendar.date(byAdding: component, value: offset, to: interval.start),
                  let end = calendar.date(byAdding: component, value: 1, to: start)
            else { return nil }
            return (start, end)
        }

        if text.contains("dnes") { return range(.day, offset: 0) }
        if text.contains("vcera") { return range(.day, offset: -1) }
        if text.contains("predevcir") { return range(.day, offset: -2) }
        if text.contains("minuly tyden") || text.contains("minuleho tydne") || text.contains("last week") {
            return range(.weekOfYear, offset: -1)
        }
        if text.contains("tento tyden") || text.contains("tenhle tyden") { return range(.weekOfYear, offset: 0) }
        if text.contains("minuly mesic") || text.contains("minuleho mesice") || text.contains("last month") {
            return range(.month, offset: -1)
        }
        if text.contains("tento mesic") || text.contains("tenhle mesic") { return range(.month, offset: 0) }
        if text.contains("loni") || text.contains("lonskeho") { return range(.year, offset: -1) }

        // Konkrétní rok („v roce 2025“, „2025“) – jen čtyřmístná čísla, ať se nechytí částky.
        if let match = try? NSRegularExpression(pattern: #"\b(20\d{2})\b"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let yearRange = Range(match.range(at: 1), in: text),
           let year = Int(text[yearRange]),
           let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let end = calendar.date(byAdding: .year, value: 1, to: start) {
            return (start, end)
        }

        // Název měsíce bez roku = nejbližší minulý takový měsíc.
        let months = ["lednu": 1, "unoru": 2, "breznu": 3, "dubnu": 4, "kvetnu": 5, "cervnu": 6,
                      "cervenci": 7, "srpnu": 8, "zari": 9, "rijnu": 10, "listopadu": 11, "prosinci": 12]
        for (name, month) in months where text.contains(name) {
            let currentYear = calendar.component(.year, from: now)
            let currentMonth = calendar.component(.month, from: now)
            let year = month > currentMonth ? currentYear - 1 : currentYear
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            return (start, end)
        }
        return nil
    }
}
