import Foundation
import os

/// Log enginu, který jde přečíst v appce.
///
/// `OSLogStore` vrací u sideloadovaných buildů místo textu často jen `<compose failure [UUID]>`:
/// zpráva se ukládá jako formátovací řetězec + argumenty a text se skládá až při čtení
/// z metadat binárky, která systém pro přepodepsanou appku nemusí mít. Proto se každá zpráva
/// složí rovnou v appce, zapíše do vlastního kruhového bufferu a souboru v Caches
/// (přežije i pád appky – je vidět, co se dělo těsně před ním) a pro Konzoli jde i do os_log.
struct EngineLog: Sendable {
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: "cz.aichat", category: category)
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        EngineLogStore.shared.append(level: .notice, category: category, message: message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        EngineLogStore.shared.append(level: .error, category: category, message: message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        EngineLogStore.shared.append(level: .error, category: category, message: message)
    }

    /// Jen do os_log a jako soukromé – obsah promptu do logu v appce nepatří.
    func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .private)")
    }
}

/// Posledních 500 záznamů v paměti + textový soubor pro záznamy z minulých spuštění.
final class EngineLogStore: Sendable {
    static let shared = EngineLogStore()

    private static let capacity = 500
    private static let maxFileBytes = 512 * 1024

    private struct State {
        var entries: [AppLogEntry] = []
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fileURL = URL.cachesDirectory.appending(path: "engine-log.txt")

    private init() {
        let previous = Self.readFile(fileURL)
        state.withLock { state in
            state.entries = Array(previous.suffix(Self.capacity))
            state.nextID = state.entries.count
        }
    }

    func append(level: AppLogEntry.Level, category: String, message: String) {
        let date = Date.now
        state.withLock { state in
            let entry = AppLogEntry(id: state.nextID, date: date, category: category, level: level, message: message)
            state.nextID += 1
            state.entries.append(entry)
            if state.entries.count > Self.capacity {
                state.entries.removeFirst(state.entries.count - Self.capacity)
            }
            writeLine(entry)
        }
    }

    /// Nejnovější nahoře.
    func entries() -> [AppLogEntry] {
        state.withLock { Array($0.entries.reversed()) }
    }

    func clear() {
        state.withLock { state in
            state.entries.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Soubor

    private static let separator: Character = "\t"
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Volá se pod zámkem. Formát řádku: čas (ISO 8601) TAB úroveň TAB kategorie TAB zpráva.
    private func writeLine(_ entry: AppLogEntry) {
        let message = entry.message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(entry.date.formatted(Self.dateStyle))\t\(entry.level.rawValue)\t\(entry.category)\t\(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: fileURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(Self.maxFileBytes) {
            // Nechat novější polovinu souboru.
            try? handle.seek(toOffset: size / 2)
            let tail = (try? handle.readToEnd()) ?? Data()
            let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: tail[start...])
        }
        try? handle.write(contentsOf: data)
    }

    private static func readFile(_ url: URL) -> [AppLogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [AppLogEntry] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            let parts = line.split(separator: separator, maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let date = try? dateStyle.parse(String(parts[0])),
                  let level = AppLogEntry.Level(rawValue: String(parts[1])) else { continue }
            entries.append(AppLogEntry(id: index, date: date, category: String(parts[2]), level: level, message: String(parts[3])))
        }
        return entries
    }
}
