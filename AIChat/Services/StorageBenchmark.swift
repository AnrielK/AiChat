import Foundation
import os

/// Změří, jak rychle jde z úložiště číst náhodné bloky velkého souboru.
///
/// Proč to potřebujeme: u streamovaného MoE se na každý vygenerovaný token přečte
/// `expertů na vrstvu × vrstvy × velikost experta` bajtů (u Qwen3-30B-A3B v Q4_K_M
/// asi 1 GB při osmi expertech). Rychlost generování je pak přímo
/// `bajty na token ÷ propustnost flash` – bez toho čísla nejde rozhodnout, jestli má
/// smysl ladit přístupový vzor, nebo jestli zbývá jen číst na token míň bajtů.
///
/// Měří se **stejnou cestou, jakou čte engine**: soubor namapovaný přes `mmap`, čtení
/// ohlášené přes `F_RDADVISE` a stránky pak zpřístupněné dotykem. Dřívější verze měřila
/// `pread` s `F_NOCACHE` a dávala výrazně nižší čísla (1,6 GB/s proti 2,9 GB/s, kterých
/// generování reálně dosahuje): vypnutá cache vyřadí i readahead a slučování požadavků,
/// takže se neměřil strop flash, ale nejhorší možný přístupový vzor.
///
/// Čte se jen, nezapisuje se nic – na soubor modelu je to bezpečné.
enum StorageBenchmark {
    private static let log = EngineLog(category: "gguf")

    struct Result: Sendable, Identifiable {
        /// Kolik vláken četlo souběžně.
        let threads: Int
        let bytesPerSecond: Double
        /// Podíl výpadků stránek, které opravdu sáhly na flash. Když klesne, byly bloky
        /// v page cache a naměřila se z velké části rychlost RAM, ne úložiště.
        let coldShare: Double

        var id: Int { threads }
        var gigabytesPerSecond: Double { bytesPerSecond / 1_073_741_824 }
        /// Pod touhle hranicí je výsledek nadhodnocený a nedá se brát jako strop.
        var isCold: Bool { coldShare >= 0.7 }

        /// Kolik tokenů za sekundu by takováhle propustnost stačila obsloužit,
        /// když se na token přečte `bytesPerToken` bajtů.
        func tokensPerSecond(bytesPerToken: Int) -> Double {
            bytesPerToken > 0 ? bytesPerSecond / Double(bytesPerToken) : 0
        }
    }

    /// Velikost jednoho čtení. Odpovídá tomu, co při streamování čte jeden tenzor
    /// jednoho experta (u Qwen3-30B-A3B necelý 1 MB).
    static let blockBytes = 1_048_576
    /// Kolik se v jednom kole přečte celkem. Dost na ustálené číslo, dost málo na to,
    /// aby měření netrvalo minuty.
    static let roundBytes = 512 * 1_048_576
    static let threadCounts = [1, 2, 3, 4, 6, 8]

    /// Spustí měření pro každý počet vláken. Volat mimo hlavní vlákno.
    static func run(path: String) -> [Result] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            log.error("měření úložiště: soubor nejde otevřít")
            return []
        }
        defer { close(fd) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let blocks = size / blockBytes
        guard blocks > 64 else {
            log.error("měření úložiště: soubor je na měření moc malý")
            return []
        }

        guard let map = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else {
            log.error("měření úložiště: soubor nejde namapovat")
            return []
        }
        defer { munmap(map, size) }
        let base = UnsafeRawPointer(map)
        let pageSize = Int(getpagesize())

        var results: [Result] = []
        for threads in threadCounts {
            let reads = max(threads, roundBytes / blockBytes)
            // Náhodné pozice po celém souboru: u 18GB modelu se do page cache vejde
            // jen zlomek, takže drtivá většina bloků bude studená. Losuje se předem,
            // uvnitř měřené smyčky by se to počítalo do času.
            let offsets = (0..<reads).map { _ in Int.random(in: 0..<blocks) * blockBytes }
            // Zahodit vlastní mapování stránek z minulého kola.
            for offset in offsets {
                madvise(UnsafeMutableRawPointer(mutating: base + offset), blockBytes, MADV_DONTNEED)
            }

            let before = MemoryBudget.PageCounters.now
            let start = Date.now
            DispatchQueue.concurrentPerform(iterations: threads) { worker in
                var checksum: UInt8 = 0
                var index = worker
                while index < offsets.count {
                    let offset = offsets[index]
                    var advice = radvisory(ra_offset: off_t(offset), ra_count: Int32(blockBytes))
                    _ = fcntl(fd, F_RDADVISE, &advice)
                    var page = 0
                    while page < blockBytes {
                        checksum &+= base.load(fromByteOffset: offset + page, as: UInt8.self)
                        page += pageSize
                    }
                    index += threads
                }
                sink = checksum
            }
            let seconds = Date.now.timeIntervalSince(start)
            let pages = MemoryBudget.PageCounters.now.since(before)
            guard seconds > 0 else { continue }

            let result = Result(
                threads: threads,
                bytesPerSecond: Double(reads * blockBytes) / seconds,
                coldShare: pages.faults > 0 ? Double(pages.pageins) / Double(pages.faults) : 1
            )
            results.append(result)
            log.notice("""
                úložiště: \(threads) vláken · \(decimal(result.gigabytesPerSecond, digits: 2)) GB/s \
                (\(reads * blockBytes / 1_048_576) MB za \(decimal(seconds)) s) · \
                z flash \(decimal(result.coldShare * 100, digits: 0)) % výpadků
                """)
        }
        return results
    }

    /// Kolik bajtů se při streamování přečte na jeden vygenerovaný token.
    /// `expertBytes / expertCount` je jeden index experta přes všechny vrstvy dohromady,
    /// takže stačí vynásobit počtem expertů, které router na vrstvu vybírá.
    static func bytesPerToken(layout: GGUFLayout, expertUsed: Int) -> Int {
        guard layout.expertCount > 0, expertUsed > 0 else { return 0 }
        return layout.expertBytes / layout.expertCount * expertUsed
    }

    /// Zápis do globální proměnné je vedlejší efekt – překladač kvůli němu čtení stránek nevyhodí.
    nonisolated(unsafe) private static var sink: UInt8 = 0

    private static func decimal(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}
