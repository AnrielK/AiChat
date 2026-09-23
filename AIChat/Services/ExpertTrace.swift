import Foundation
import os

/// Záznam toho, které experty MoE router v jednotlivých vrstvách vybral (trace).
///
/// Nápad z kimi-k3-in-c (sekce „How big should that cache be? Ask the trace“): **routing
/// nezávisí na cache**. Stejný prompt vybere stejné experty ve stejném pořadí, ať cache dělá
/// cokoli. Stačí tedy jednou zaznamenat, na které experty se sahalo, a záznam pak přehrát
/// offline při libovolné velikosti cache a s libovolnou politikou – bez spouštění modelu.
/// To dělá `ExpertCacheSimulator` v appce a `tools/expert_cache_sim.py` na počítači.
///
/// Soubor `.axtr` (little-endian):
///
///     "AXTR"            4 B   magic
///     version           u16   4 (1 = bez odhadu, 2 = bez rezidence po expertech,
///                             3 = bez odhadu o dvě vrstvy; všechny se čtou dál)
///     expertCount       u16   expertů na vrstvu
///     layerCount        u16   nejvyšší index vrstvy + 1
///     flags             u16   bit 0 = u událostí je změřená rezidence (mincore)
///                             bit 1 = u událostí generování je odhad z routeru předchozí vrstvy
///                             bit 2 = i odhad o dvě vrstvy dopředu (verze 4)
///     sliceBytes        u32 × layerCount   bajty jednoho experta ve vrstvě (0 = vrstva bez expertů)
///     nameLength        u16
///     name              UTF-8 (název souboru modelu)
///     události až do konce souboru:
///       layer           u16
///       tokens          u16   tokenů v dávce (1 = generování, víc = prefill), max 65535
///       count           u16   počet vybraných expertů (unikátní přes celou dávku)
///       resident        u16   kolik z nich leželo celých v page cache, 0xFFFF = neměřeno
///       predictedCount  u16   jen verze 2+: délka odhadu (0 = bez odhadu)
///       predicted2Count u16   jen verze 4+: délka odhadu o dvě vrstvy dopředu
///       experts         u16 × count, vzestupně
///       predicted       u16 × predictedCount, jen verze 2+: odhad `RouterPredictor` udělaný
///                             o vrstvu dřív, seřazený od nejvyššího skóre routeru
///       predicted2      u16 × predicted2Count, jen verze 4+: odhad udělaný o dvě vrstvy dřív
///                             (router této vrstvy nad vstupem MoE vrstvy o dvě níž)
///
/// Od verze 3 nese horní bit (0x8000) čísla experta v `experts` i `predicted`, že expert ležel
/// celý v page cache (měřeno u rezidence ≠ 0xFFFF). Simulátor tak ví, *kteří* experti chyběli,
/// ne jen kolik – předpověď má smysl hodnotit jen na výpadcích.
///
/// U prefillu se ukládá sjednocení výběru přes celou dávku – pořadí po tokenech se v callbacku
/// nedá levně zachovat a pro cache na něm nezáleží (dávka se počítá naráz).
struct ExpertTrace: Sendable {
    static let magic: [UInt8] = Array("AXTR".utf8)
    static let version: UInt16 = 4
    static let residentBit: UInt16 = 0x8000
    static let unmeasured: UInt16 = 0xFFFF
    static let fileExtension = "axtr"

    struct Event: Sendable {
        let layer: Int
        let tokens: Int
        /// nil = rezidence se neměřila.
        let resident: Int?
        let experts: [UInt16]
        /// Odhad z routeru o vrstvu dřív, seřazený podle skóre. Prázdné = bez odhadu.
        let predicted: [UInt16]
        /// Odhad o dvě vrstvy dřív (verze 4). Prázdné = bez odhadu.
        let predicted2: [UInt16]
        /// Kteří z `experts` a `predicted` leželi celí v page cache (verze 3). nil = neví se.
        let residentSet: Set<UInt16>?

        var isDecode: Bool { tokens == 1 }
    }

    let expertCount: Int
    /// Bajty jednoho experta podle vrstvy (součet přes up/gate/down tenzory).
    let sliceBytes: [Int]
    let modelName: String
    let residencyMeasured: Bool
    let hasPredictions: Bool
    let hasPredictions2: Bool
    let events: [Event]

    /// Složka se záznamy – v Documents, takže je vidět v aplikaci Soubory a jde poslat na Mac.
    static var directory: URL {
        URL.documentsDirectory.appending(path: "ExpertTraces", directoryHint: .isDirectory)
    }

    // MARK: - Čtení

    enum ParseError: LocalizedError {
        case notATrace
        case unsupportedVersion(Int)
        case truncated

        var errorDescription: String? {
            switch self {
            case .notATrace: "Soubor není záznam expertů (.axtr)."
            case .unsupportedVersion(let version): "Nepodporovaná verze záznamu (\(version))."
            case .truncated: "Záznam je useknutý."
            }
        }
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        var reader = ByteReader(data: data)
        guard let magic = reader.bytes(4), magic == Self.magic else { throw ParseError.notATrace }
        guard let version = reader.u16() else { throw ParseError.truncated }
        guard (1...4).contains(version) else { throw ParseError.unsupportedVersion(Int(version)) }
        guard let expertCount = reader.u16(), let layerCount = reader.u16(), let flags = reader.u16() else {
            throw ParseError.truncated
        }
        var slices: [Int] = []
        slices.reserveCapacity(Int(layerCount))
        for _ in 0..<layerCount {
            guard let value = reader.u32() else { throw ParseError.truncated }
            slices.append(Int(value))
        }
        guard let nameLength = reader.u16(), let nameBytes = reader.bytes(Int(nameLength)) else {
            throw ParseError.truncated
        }

        var events: [Event] = []
        while !reader.isAtEnd {
            // Useknutý konec (appka spadla uprostřed zápisu) – vezme se, co je celé.
            guard let layer = reader.u16(), let tokens = reader.u16(),
                  let count = reader.u16(), let resident = reader.u16() else { break }
            var predictedCount: UInt16 = 0
            var predicted2Count: UInt16 = 0
            if version >= 2 {
                guard let value = reader.u16() else { break }
                predictedCount = value
            }
            if version >= 4 {
                guard let value = reader.u16() else { break }
                predicted2Count = value
            }
            guard var experts = reader.u16Array(Int(count)),
                  var predicted = reader.u16Array(Int(predictedCount)),
                  var predicted2 = reader.u16Array(Int(predicted2Count)) else { break }
            var residentSet: Set<UInt16>?
            if version >= 3, resident != Self.unmeasured {
                var set = Set<UInt16>()
                for index in experts.indices where experts[index] & Self.residentBit != 0 {
                    experts[index] &= ~Self.residentBit
                    set.insert(experts[index])
                }
                for index in predicted.indices where predicted[index] & Self.residentBit != 0 {
                    predicted[index] &= ~Self.residentBit
                    set.insert(predicted[index])
                }
                for index in predicted2.indices where predicted2[index] & Self.residentBit != 0 {
                    predicted2[index] &= ~Self.residentBit
                    set.insert(predicted2[index])
                }
                residentSet = set
            } else if version >= 3 {
                experts = experts.map { $0 & ~Self.residentBit }
                predicted = predicted.map { $0 & ~Self.residentBit }
                predicted2 = predicted2.map { $0 & ~Self.residentBit }
            }
            // Poškozená událost (vrstva nebo expert mimo rozsah) by simulátor shodila – přeskočit.
            guard Int(layer) < slices.count,
                  (experts + predicted + predicted2).allSatisfy({ Int($0) < Int(expertCount) }) else { continue }
            events.append(Event(
                layer: Int(layer),
                tokens: Int(tokens),
                resident: resident == Self.unmeasured ? nil : Int(resident),
                experts: experts,
                predicted: predicted,
                predicted2: predicted2,
                residentSet: residentSet
            ))
        }

        self.expertCount = Int(expertCount)
        self.sliceBytes = slices
        self.modelName = String(decoding: nameBytes, as: UTF8.self)
        self.residencyMeasured = flags & 1 != 0
        self.hasPredictions = flags & 2 != 0
        self.hasPredictions2 = flags & 4 != 0
        self.events = events
    }
}

/// Průběžný zápis záznamu. Události se sbírají v paměti a na disk jdou po odpovědi
/// (`flush`), ať se v callbacku výpočtu nečeká na zápis.
final class ExpertTraceWriter: @unchecked Sendable {
    private static let log = EngineLog(category: "gguf")
    /// Při větším bufferu se zapíše hned – dlouhý prefill jinak nemá strop.
    private static let flushThreshold = 4 * 1_048_576

    let url: URL
    private let header: Data
    /// `uncheckedState`: FileHandle se v zámku jen zapisuje a zavírá, ven se nedostane.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private struct State {
        var pending = Data()
        var handle: FileHandle?
        var failed = false
        var events = 0
    }

    init(modelName: String, expertCount: Int, sliceBytes: [Int], residencyMeasured: Bool, predictions: Bool) {
        // Odhad o dvě vrstvy jde se stejným prediktorem jako o jednu.
        let predictions2 = predictions
        let stamp = Self.stampFormatter.string(from: .now)
        let stem = (modelName as NSString).deletingPathExtension
        url = ExpertTrace.directory.appending(path: "\(stem)-\(stamp).\(ExpertTrace.fileExtension)")

        var data = Data(ExpertTrace.magic)
        data.appendLE(ExpertTrace.version)
        data.appendLE(UInt16(clamping: expertCount))
        data.appendLE(UInt16(clamping: sliceBytes.count))
        data.appendLE(UInt16((residencyMeasured ? 1 : 0) | (predictions ? 2 : 0) | (predictions2 ? 4 : 0)))
        for bytes in sliceBytes { data.appendLE(UInt32(clamping: bytes)) }
        let name = Data(modelName.utf8.prefix(1_024))
        data.appendLE(UInt16(name.count))
        data.append(name)
        header = data
    }

    deinit {
        flush()
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }

    /// Volá se z callbacku výpočtu – jen přidá do bufferu.
    /// `resident` = kteří z `experts` a `predicted` leží celí v page cache (nil = neměřeno).
    func append(layer: Int, tokens: Int, experts: [Int], predicted: [Int], predicted2: [Int], resident: Set<Int>?) {
        let residentCount = resident.map { set in experts.filter { set.contains($0) }.count }
        let encode = { (expert: Int) -> UInt16 in
            let id = UInt16(clamping: expert) & ~ExpertTrace.residentBit
            return resident?.contains(expert) == true ? id | ExpertTrace.residentBit : id
        }
        let encodedExperts = experts.map(encode)
        let encodedPredicted = predicted.map(encode)
        let encodedPredicted2 = predicted2.map(encode)
        let shouldFlush = state.withLock { (state: inout State) -> Bool in
            guard !state.failed else { return false }
            state.pending.appendLE(UInt16(clamping: layer))
            state.pending.appendLE(UInt16(clamping: tokens))
            state.pending.appendLE(UInt16(clamping: experts.count))
            state.pending.appendLE(residentCount.map { UInt16(clamping: min($0, 0xFFFE)) } ?? ExpertTrace.unmeasured)
            state.pending.appendLE(UInt16(clamping: predicted.count))
            state.pending.appendLE(UInt16(clamping: predicted2.count))
            for expert in encodedExperts { state.pending.appendLE(expert) }
            for expert in encodedPredicted { state.pending.appendLE(expert) }
            for expert in encodedPredicted2 { state.pending.appendLE(expert) }
            state.events += 1
            return state.pending.count >= Self.flushThreshold
        }
        if shouldFlush { flush() }
    }

    /// Zapíše nasbírané události. Soubor se založí až s první událostí.
    func flush() {
        state.withLock { state in
            guard !state.failed, !state.pending.isEmpty else { return }
            do {
                if state.handle == nil {
                    try FileManager.default.createDirectory(at: ExpertTrace.directory, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: header)
                    state.handle = try FileHandle(forWritingTo: url)
                    try state.handle?.seekToEnd()
                    Self.log.notice("záznam expertů: \(url.lastPathComponent)")
                }
                try state.handle?.write(contentsOf: state.pending)
                state.pending.removeAll(keepingCapacity: true)
            } catch {
                state.failed = true
                state.pending = Data()
                Self.log.error("záznam expertů nejde zapsat: \(error.localizedDescription)")
            }
        }
    }

    var eventCount: Int { state.withLock { $0.events } }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

// MARK: - Pomocníci

private struct ByteReader {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func u16() -> UInt16? {
        guard offset + 2 <= data.endIndex else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    mutating func u16Array(_ count: Int) -> [UInt16]? {
        guard count >= 0, offset + 2 * count <= data.endIndex else { return nil }
        var result: [UInt16] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(u16()!) }
        return result
    }

    mutating func u32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        defer { offset += 4 }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(data[offset + index]) << (8 * UInt32(index)) }
        return value
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}
