import Foundation

/// Přehraje záznam výběru expertů (`ExpertTrace`) při různých velikostech cache a politikách.
///
/// Otázka, na kterou odpovídá: kolik by pomohlo držet experty v RAM, a jakým způsobem?
/// Místo spouštění modelu pro každou velikost cache se jeden záznam přehraje offline – routing
/// na cache nezávisí, takže výběr expertů je v každém přehrání stejný (kimi-k3-in-c, sekce 13).
///
/// - **LRU** – vyhodí nejdéle nepoužitého. Zhruba to, co dělá page cache iOS se streamovanými experty.
/// - **LFU** – vyhodí nejméně často použitého (četnost od začátku záznamu).
/// - **Belady** – vyhodí toho, kdo bude potřeba nejpozději. Zná budoucnost, takže to není
///   použitelná politika, ale strop: líp to při dané velikosti nejde.
/// - **Strop** – povinné výpadky: každého experta je potřeba aspoň jednou přečíst.
///
/// Velký rozdíl mezi LRU a Belady při stejné velikosti říká, že páka je v tom, *co* v RAM držet,
/// ne v tom, kolik RAM na to dát. Plochá LRU křivka pod velikostí jednoho tokenu je cyklický
/// průchod vrstvami: LRU menší než pracovní sada tokenu vyhodí experta vrstvy 0 těsně předtím,
/// než ho další token potřebuje, a zásah je nula.
///
/// Stejný výpočet dělá `tools/expert_cache_sim.py` – výsledky musí sedět.
enum ExpertCacheSimulator {
    enum Policy: String, CaseIterable, Sendable, Identifiable {
        case lru = "LRU"
        case lfu = "LFU"
        case belady = "Belady"

        var id: String { rawValue }
    }

    struct PhaseStats: Sendable {
        var requests = 0
        var hits = 0
        var missBytes = 0

        var hitRate: Double { requests > 0 ? Double(hits) / Double(requests) : 0 }

        mutating func record(hit: Bool, size: Int) {
            requests += 1
            if hit { hits += 1 } else { missBytes += size }
        }

        static func + (lhs: PhaseStats, rhs: PhaseStats) -> PhaseStats {
            PhaseStats(requests: lhs.requests + rhs.requests, hits: lhs.hits + rhs.hits, missBytes: lhs.missBytes + rhs.missBytes)
        }
    }

    struct Row: Sendable, Identifiable {
        let capacity: Int
        /// Kapacita na všechny experty v záznamu (= strop povinných výpadků).
        let isAll: Bool
        let hitRate: [Policy: Double]
        /// Kolik bajtů by se na vygenerovaný token četlo z úložiště (nil = záznam bez generování).
        let missBytesPerToken: [Policy: Double]?

        var id: Int { capacity }
    }

    struct Report: Sendable {
        let modelName: String
        let requests: Int
        let decodeRequests: Int
        let decodeTokens: Int
        let distinctExperts: Int
        let totalExperts: Int
        let distinctBytes: Int
        /// Zásah page cache naměřený v appce přes `mincore` (nil = neměřilo se).
        let measuredHitRate: Double?
        /// Podíl požadavků, které připadnou na nejčastějších 10 % expertů.
        let topTenthShare: Double?
        let ceilingHitRate: Double
        /// true = čísla jsou jen z generování (prefill jen zahřívá cache). false = záznam
        /// generování nemá, čísla jsou ze všeho.
        let decodeOnly: Bool
        let rows: [Row]
    }

    static let defaultCapacities: [Int] = [0.25, 0.5, 1, 1.5, 2, 3, 4, 6].map { Int($0 * 1_073_741_824) }

    /// Náročnost roste s délkou záznamu × počtem velikostí × 3 politiky. Volat mimo hlavní vlákno.
    static func run(_ trace: ExpertTrace, capacities: [Int] = defaultCapacities) -> Report {
        let stream = RequestStream(trace)
        let next = nextUses(stream)
        let decodeOnly = stream.decode.contains(true)
        let pick: (PhaseResult) -> PhaseStats = { decodeOnly ? $0.decode : $0.decode + $0.prefill }

        // Různí experti v záznamu a kolik zaberou dohromady.
        var seen = [Bool](repeating: false, count: stream.keyCount)
        var distinct = 0
        var distinctBytes = 0
        for index in stream.keys.indices where !seen[stream.keys[index]] {
            seen[stream.keys[index]] = true
            distinct += 1
            distinctBytes += stream.sizes[index]
        }

        // Naměřený zásah (mincore v appce), ze stejné fáze jako simulace.
        var measuredRequested = 0
        var measuredResident = 0
        for event in trace.events where !decodeOnly || event.isDecode {
            guard let resident = event.resident else { continue }
            measuredRequested += event.experts.count
            measuredResident += resident
        }

        // Nerovnost: jak moc se požadavky soustředí na malou skupinu expertů.
        var counts = [Int](repeating: 0, count: stream.keyCount)
        for index in stream.keys.indices where !decodeOnly || stream.decode[index] {
            counts[stream.keys[index]] += 1
        }
        let used = counts.filter { $0 > 0 }.sorted(by: >)
        let total = used.reduce(0, +)
        let tenth = max(1, used.count / 10)
        let topTenthShare = total > 0 ? Double(used.prefix(tenth).reduce(0, +)) / Double(total) : nil

        let tokens = decodeTokens(trace)
        var sizes = Array(Set(capacities.filter { $0 > 0 && $0 < distinctBytes })).sorted()
        sizes.append(distinctBytes)
        let rows = sizes.map { capacity -> Row in
            var hitRate: [Policy: Double] = [:]
            var perToken: [Policy: Double] = [:]
            for policy in Policy.allCases {
                let stats = pick(simulate(stream, capacity: capacity, policy: policy, next: next))
                hitRate[policy] = stats.hitRate
                if decodeOnly, tokens > 0 { perToken[policy] = Double(stats.missBytes) / Double(tokens) }
            }
            return Row(
                capacity: capacity,
                isAll: capacity == distinctBytes,
                hitRate: hitRate,
                missBytesPerToken: decodeOnly && tokens > 0 ? perToken : nil
            )
        }

        return Report(
            modelName: trace.modelName,
            requests: stream.keys.count,
            decodeRequests: stream.decode.lazy.filter { $0 }.count,
            decodeTokens: tokens,
            distinctExperts: distinct,
            totalExperts: trace.expertCount * trace.sliceBytes.filter { $0 > 0 }.count,
            distinctBytes: distinctBytes,
            measuredHitRate: measuredRequested > 0 ? Double(measuredResident) / Double(measuredRequested) : nil,
            topTenthShare: topTenthShare,
            ceilingHitRate: pick(compulsory(stream)).hitRate,
            decodeOnly: decodeOnly,
            rows: rows
        )
    }

    // MARK: - Přehrání

    /// Záznam rozbalený na posloupnost požadavků. Klíč = vrstva × expertů + expert.
    private struct RequestStream {
        var keys: [Int] = []
        var sizes: [Int] = []
        var decode: [Bool] = []
        let keyCount: Int

        init(_ trace: ExpertTrace) {
            keyCount = max(1, trace.sliceBytes.count * trace.expertCount)
            for event in trace.events {
                let size = trace.sliceBytes[event.layer]
                for expert in event.experts {
                    keys.append(event.layer * trace.expertCount + Int(expert))
                    sizes.append(size)
                    decode.append(event.isDecode)
                }
            }
        }
    }

    private struct PhaseResult {
        var decode = PhaseStats()
        var prefill = PhaseStats()
    }

    /// Pro každý požadavek index dalšího požadavku na stejného experta (`keys.count` = už nikdy).
    private static func nextUses(_ stream: RequestStream) -> [Int] {
        let count = stream.keys.count
        var result = [Int](repeating: count, count: count)
        var last = [Int](repeating: count, count: stream.keyCount)
        for index in stride(from: count - 1, through: 0, by: -1) {
            let key = stream.keys[index]
            result[index] = last[key]
            last[key] = index
        }
        return result
    }

    /// Nekonečná cache: výpadek je jen první požadavek na každého experta.
    private static func compulsory(_ stream: RequestStream) -> PhaseResult {
        var result = PhaseResult()
        var seen = [Bool](repeating: false, count: stream.keyCount)
        for index in stream.keys.indices {
            let key = stream.keys[index]
            let hit = seen[key]
            seen[key] = true
            if stream.decode[index] {
                result.decode.record(hit: hit, size: stream.sizes[index])
            } else {
                result.prefill.record(hit: hit, size: stream.sizes[index])
            }
        }
        return result
    }

    /// Jedno přehrání. Po každém požadavku je expert v cache a vyhazuje se, dokud se
    /// nevejde – politika může vyhodit i právě vloženého (to je obejití cache).
    private static func simulate(_ stream: RequestStream, capacity: Int, policy: Policy, next: [Int]) -> PhaseResult {
        var result = PhaseResult()
        let keyCount = stream.keyCount
        var resident = [Bool](repeating: false, count: keyCount)
        var residentSize = [Int](repeating: 0, count: keyCount)
        var used = 0

        // LRU: dvojitě provázaný seznam rezidentních v polích, zarážka = keyCount.
        // Za zarážkou nejstarší, před ní nejnovější.
        let sentinel = keyCount
        var previous = [Int](repeating: sentinel, count: keyCount + 1)
        var following = [Int](repeating: sentinel, count: keyCount + 1)
        func unlink(_ key: Int) {
            following[previous[key]] = following[key]
            previous[following[key]] = previous[key]
        }
        func append(_ key: Int) {
            let newest = previous[sentinel]
            following[newest] = key
            previous[key] = newest
            following[key] = sentinel
            previous[sentinel] = key
        }

        // LFU a Belady: halda s líným mazáním – zastaralé položky se přeskočí při výběru.
        var frequency = [Int](repeating: 0, count: keyCount)
        var lastUse = [Int](repeating: 0, count: keyCount)
        var nextUse = [Int](repeating: 0, count: keyCount)
        var heap = MinHeap()

        for index in stream.keys.indices {
            let key = stream.keys[index]
            let size = stream.sizes[index]
            let hit = resident[key]
            if stream.decode[index] {
                result.decode.record(hit: hit, size: size)
            } else {
                result.prefill.record(hit: hit, size: size)
            }

            // Evidence politiky – i u zásahu.
            switch policy {
            case .lru:
                if hit { unlink(key) }
                append(key)
            case .lfu:
                frequency[key] += 1
                lastUse[key] = index
                heap.push(MinHeap.Entry(primary: frequency[key], secondary: index, key: key))
            case .belady:
                nextUse[key] = next[index]
                heap.push(MinHeap.Entry(primary: -next[index], secondary: 0, key: key))
            }

            if !hit {
                resident[key] = true
                residentSize[key] = size
                used += size
            }

            evict: while used > capacity {
                let victim: Int
                switch policy {
                case .lru:
                    victim = following[sentinel]
                    guard victim != sentinel else { break evict }
                    unlink(victim)
                case .lfu:
                    guard let entry = heap.pop() else { break evict }
                    guard resident[entry.key], frequency[entry.key] == entry.primary,
                          lastUse[entry.key] == entry.secondary else { continue evict }
                    victim = entry.key
                case .belady:
                    guard let entry = heap.pop() else { break evict }
                    guard resident[entry.key], nextUse[entry.key] == -entry.primary else { continue evict }
                    victim = entry.key
                }
                resident[victim] = false
                used -= residentSize[victim]
            }
        }
        return result
    }

    /// Kolik tokenů se vygenerovalo: události generování v nejnižší vrstvě s experty.
    private static func decodeTokens(_ trace: ExpertTrace) -> Int {
        guard let first = trace.events.lazy.filter(\.isDecode).map(\.layer).min() else { return 0 }
        return trace.events.lazy.filter { $0.isDecode && $0.layer == first }.count
    }
}

/// Binární min-halda nad trojicí (primary, secondary, key), porovnávanou lexikograficky –
/// stejné pořadí jako n-tice v `heapq` Python nástroje, ať se shodne i rozhodování remíz.
private struct MinHeap {
    struct Entry {
        let primary: Int
        let secondary: Int
        let key: Int

        static func < (lhs: Entry, rhs: Entry) -> Bool {
            if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
            if lhs.secondary != rhs.secondary { return lhs.secondary < rhs.secondary }
            return lhs.key < rhs.key
        }
    }

    private var items: [Entry] = []

    mutating func push(_ entry: Entry) {
        items.append(entry)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child] < items[parent] else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Entry? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        guard !items.isEmpty else { return top }
        items[0] = last
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left] < items[smallest] { smallest = left }
            if right < items.count, items[right] < items[smallest] { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
