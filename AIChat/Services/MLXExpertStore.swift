#if canImport(MLXLLM)
import Compression
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

/// Experti MoE z úložiště pro MLX (experiment, fáze 1).
///
/// Hustá část modelu se načte normálně, routovaní experti (`…mlp.switch_mlp.*`) se z vah
/// vynechají a čtou se až podle výběru routeru do pevných slotů v paměti GPU:
/// - každá MoE vrstva má pro každý tenzor experta (gate/up/down × weight/scales/biases)
///   jedno MLX pole `[sloty, …]`, alokované při načtení modelu;
/// - chybějící expert se přečte `pread` s vypnutou page cache (`F_NOCACHE`) přímo do paměti
///   slotu – sdílená paměť CPU a GPU, žádná další kopie ani dvojí cache;
/// - výpočet běží nad sloty (`gatherQuantizedMM` s indexy slotů);
/// - vyhazuje se nejdéle nepoužitý slot (LRU).
///
/// Zapisovat do paměti MLX pole je mimo jeho smlouvu (pole jsou neměnná). Je to bezpečné jen
/// proto, že se do slotů vrstvy zapisuje až po synchronizaci (výběr routeru té vrstvy) a slot,
/// který se přepisuje, žádný rozpracovaný výpočet nečte – viz `StreamedQwen3MoESparseBlock`.
final class MLXExpertStore: @unchecked Sendable {
    private static let log = EngineLog(category: "mlx")

    /// Jména tenzorů experta v rámci `switch_mlp` (pořadí je pevné).
    static let tensorNames = [
        "gate_proj.weight", "gate_proj.scales", "gate_proj.biases",
        "up_proj.weight", "up_proj.scales", "up_proj.biases",
        "down_proj.weight", "down_proj.scales", "down_proj.biases",
    ]

    struct Quantization: Sendable {
        let groupSize: Int
        let bits: Int
    }

    struct TensorRef {
        let fd: Int32
        /// Offset experta 0 v souboru.
        let offset: Int
        /// Bajty jednoho experta.
        let sliceBytes: Int
        /// Tvar jednoho experta (bez první osy).
        let shape: [Int]
        let dtype: DType
    }

    final class LayerPool {
        let refs: [TensorRef]
        let arrays: [MLXArray]
        let addresses: [Int]
        var slotOf: [Int: Int] = [:]
        var expertIn: [Int]
        var lastUse: [UInt64]
        /// Slot naplněný předčítáním, který ještě nikdo nepoužil (statistika přesnosti odhadu).
        var prefetched: [Bool]
        /// Rozběhnuté předčítání do slotů této vrstvy – `ensure` na ně počká.
        let group = DispatchGroup()

        init(refs: [TensorRef], arrays: [MLXArray], addresses: [Int], slots: Int) {
            self.refs = refs
            self.arrays = arrays
            self.addresses = addresses
            self.expertIn = [Int](repeating: -1, count: slots)
            self.lastUse = [UInt64](repeating: 0, count: slots)
            self.prefetched = [Bool](repeating: false, count: slots)
        }
    }

    struct Stats: Sendable {
        var requests = 0
        var hits = 0
        var misses = 0
        var bytes = 0
        var readSeconds = 0.0
        /// Předčítání podle odhadu: kolik expertů se načetlo dopředu a kolik z nich se pak použilo.
        var prefetchedExperts = 0
        var prefetchUseful = 0
        var prefetchBytes = 0
        var prefetchSeconds = 0.0
        /// Kolik času výpočet čekal na nedočtené předčítání.
        var waitSeconds = 0.0
    }

    let slots: Int
    let expertBytes: Int
    /// Předčítat experty další vrstvy podle odhadu z jejího routeru (nastavuje engine mezi odpověďmi).
    var prefetchEnabled = true
    /// Při chybějících expertech počítat přítomné na GPU, zatímco se chybějící čtou (fáze 3b).
    var overlapReads = true
    let quantization: [Int: [String: Quantization]]
    private let defaultQuantization: Quantization
    private var pools: [Int: LayerPool] = [:]
    private var descriptors: [Int32] = []
    private var clock: UInt64 = 0
    private let statsLock = OSAllocatedUnfairLock(initialState: Stats())
    /// Chrání obsazení slotů – předčítání do další vrstvy běží na pozadí.
    private let slotLock = NSLock()
    private let aheadQueue = DispatchQueue(label: "cz.aichat.mlx-experts-ahead", qos: .userInitiated)

    // MARK: - Plán (před načtením modelu)

    /// Co je potřeba vědět o souborech modelu, než se vytvoří.
    struct Plan: Sendable {
        let directory: URL
        let cacheBytes: Int
        /// Číst přes page cache (druhá úroveň cache v volné RAM systému) místo `F_NOCACHE`.
        let pageCache: Bool
        /// Tenzory `switch_mlp` podle vrstvy: jméno (z `tensorNames`) → soubor, offset, bajty, tvar, dtype.
        let tensors: [Int: [String: (file: URL, offset: Int, bytes: Int, shape: [Int], dtype: String)]]
        let expertCount: Int
        let totalBytes: Int
        let expertTensorBytes: Int
        let quantization: [Int: [String: Quantization]]
        let defaultQuantization: Quantization

        /// Kolik zabere v paměti: hustá část + cache expertů.
        var residentBytes: Int { totalBytes - expertTensorBytes + cacheBytes }
    }

    /// Přečte hlavičky safetensors a config.json. nil = model streamovat nejde (jiný formát,
    /// chybí `switch_mlp`, nepodporovaná kvantizace).
    static func plan(directory: URL, cacheBytes: Int, pageCache: Bool = false) -> Plan? {
        guard let configData = try? Data(contentsOf: directory.appending(path: "config.json")),
              let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any],
              let experts = (config["num_experts"] as? NSNumber)?.intValue, experts > 0 else { return nil }
        let quantConfig = (config["quantization"] ?? config["quantization_config"]) as? [String: Any]
        guard let quantConfig,
              let groupSize = (quantConfig["group_size"] as? NSNumber)?.intValue,
              let bits = (quantConfig["bits"] as? NSNumber)?.intValue else { return nil }
        if let mode = quantConfig["mode"] as? String, mode != "affine" { return nil }
        let defaultQuantization = Quantization(groupSize: groupSize, bits: bits)

        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "safetensors" }
        var tensors: [Int: [String: (file: URL, offset: Int, bytes: Int, shape: [Int], dtype: String)]] = [:]
        var total = 0
        var expertTotal = 0
        var quantization: [Int: [String: Quantization]] = [:]
        for file in files {
            guard let header = readHeader(file) else { return nil }
            for (name, info) in header.entries {
                total += info.bytes
                guard let range = name.range(of: ".mlp.switch_mlp.") else { continue }
                let prefix = name[..<range.lowerBound]
                guard let layerText = prefix.split(separator: ".").last, let layer = Int(layerText) else { continue }
                let local = String(name[range.upperBound...])
                guard tensorNames.contains(local) else { continue }
                expertTotal += info.bytes
                tensors[layer, default: [:]][local] = (file, header.dataStart + info.begin, info.bytes, info.shape, info.dtype)
                // Kvantizace po vrstvách („model.layers.3.mlp.switch_mlp.gate_proj“: {bits, group_size}).
                // „.weight“, „.scales“ i „.biases“ mají 7 znaků.
                let module = String(name.dropLast(7))
                if let override = quantConfig[module] as? [String: Any],
                   let g = (override["group_size"] as? NSNumber)?.intValue,
                   let b = (override["bits"] as? NSNumber)?.intValue {
                    let projection = String(local.split(separator: ".").first ?? "")
                    quantization[layer, default: [:]][projection] = Quantization(groupSize: g, bits: b)
                }
            }
        }
        // Každá MoE vrstva musí mít všech devět tenzorů, jinak to není formát, který umíme.
        guard !tensors.isEmpty, tensors.values.allSatisfy({ $0.count == tensorNames.count }) else { return nil }
        return Plan(
            directory: directory, cacheBytes: cacheBytes, pageCache: pageCache, tensors: tensors, expertCount: experts,
            totalBytes: total, expertTensorBytes: expertTotal,
            quantization: quantization, defaultQuantization: defaultQuantization
        )
    }

    private struct Header {
        let dataStart: Int
        let entries: [String: (begin: Int, bytes: Int, shape: [Int], dtype: String)]
    }

    private static func readHeader(_ url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let sizeData = try? handle.read(upToCount: 8), sizeData.count == 8 else { return nil }
        let size = sizeData.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        guard size > 0, size < 100_000_000, let json = try? handle.read(upToCount: size), json.count == size,
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        var entries: [String: (begin: Int, bytes: Int, shape: [Int], dtype: String)] = [:]
        for (name, value) in object where name != "__metadata__" {
            guard let info = value as? [String: Any],
                  let offsets = info["data_offsets"] as? [NSNumber], offsets.count == 2,
                  let shape = info["shape"] as? [NSNumber],
                  let dtype = info["dtype"] as? String else { continue }
            let begin = offsets[0].intValue
            entries[name] = (begin, offsets[1].intValue - begin, shape.map(\.intValue), dtype)
        }
        return Header(dataStart: 8 + size, entries: entries)
    }

    private static func dtype(_ name: String) -> DType? {
        switch name {
        case "U32": .uint32
        case "BF16": .bfloat16
        case "F16": .float16
        case "F32": .float32
        default: nil
        }
    }

    // MARK: - Vytvoření

    init(plan: Plan, expertsPerToken: Int) throws {
        defaultQuantization = plan.defaultQuantization
        quantization = plan.quantization
        var fds: [URL: Int32] = [:]
        func descriptor(_ url: URL) throws -> Int32 {
            if let fd = fds[url] { return fd }
            let fd = open(url.path(percentEncoded: false), O_RDONLY)
            guard fd >= 0 else { throw ProviderError.engine("Soubor vah \(url.lastPathComponent) nejde otevřít.") }
            // Bez page cache: experti mají vlastní cache ve slotech a systém je nedrží podruhé.
            // S page cache: expert vyhozený ze slotu často ještě leží ve volné RAM systému
            // (čisté stránky souboru se do limitu appky nepočítají) a místo flash stačí kopie.
            if !plan.pageCache { _ = fcntl(fd, F_NOCACHE, 1) }
            fds[url] = fd
            return fd
        }

        let perExpert = plan.tensors.values.first.map { layer in
            layer.values.reduce(0) { $0 + $1.bytes / plan.expertCount }
        } ?? 1
        expertBytes = perExpert
        let layerCount = max(1, plan.tensors.count)
        slots = min(plan.expertCount, max(expertsPerToken, plan.cacheBytes / max(1, perExpert * layerCount)))

        for (layer, layerTensors) in plan.tensors {
            var refs: [TensorRef] = []
            var arrays: [MLXArray] = []
            var addresses: [Int] = []
            for name in Self.tensorNames {
                guard let tensor = layerTensors[name], let dtype = Self.dtype(tensor.dtype),
                      tensor.shape.first == plan.expertCount else {
                    throw ProviderError.engine("Tenzor \(name) vrstvy \(layer) má nečekaný formát.")
                }
                let slice = tensor.bytes / plan.expertCount
                let shape = Array(tensor.shape.dropFirst())
                refs.append(TensorRef(fd: try descriptor(tensor.file), offset: tensor.offset,
                                      sliceBytes: slice, shape: shape, dtype: dtype))
                // Vlastní souvislý buffer (kopie nul) – do něj se pak čte přímo.
                let pool = MLXArray(Data(count: slots * slice), [slots] + shape, dtype: dtype)
                eval(pool)
                let address = pool.asData(access: .noCopy).data.withUnsafeBytes { Int(bitPattern: $0.baseAddress) }
                guard address != 0 else { throw ProviderError.engine("Slot expertů nejde namapovat.") }
                arrays.append(pool)
                addresses.append(address)
            }
            pools[layer] = LayerPool(refs: refs, arrays: arrays, addresses: addresses, slots: slots)
        }
        descriptors = Array(fds.values)
        Self.log.notice("""
            MoE z úložiště (MLX): \(slots) slotů na vrstvu × \(layerCount) vrstev · \
            expert \(perExpert / 1024) kB · cache \(slots * perExpert * layerCount / 1_048_576) MB
            """)
    }

    deinit {
        for fd in descriptors { close(fd) }
    }

    func quantization(layer: Int, projection: String) -> Quantization {
        quantization[layer]?[projection] ?? defaultQuantization
    }

    /// Pole slotů vrstvy v pořadí `tensorNames`.
    func arrays(layer: Int) -> [MLXArray] { pools[layer]?.arrays ?? [] }

    // MARK: - Výběr a čtení

    /// Zajistí, že experti leží ve slotech vrstvy, a vrátí expert → slot.
    /// Počet expertů nesmí překročit `slots`. Chybějící se přečtou paralelně ze souboru.
    func ensure(layer: Int, experts: [Int]) -> [Int: Int] {
        let (map, pending) = lookup(layer: layer, experts: experts)
        load(layer: layer, pending)
        return map
    }

    /// Jako `ensure`, ale chybějící experty jen zapíše do obsazení slotů a vrátí je – přečíst
    /// je musí volající přes `load`. Mezitím může GPU počítat s experty, kteří už ve slotech jsou.
    func lookup(layer: Int, experts: [Int]) -> (map: [Int: Int], pending: [(expert: Int, slot: Int)]) {
        guard let pool = pools[layer] else { return ([:], []) }
        // Předčítání do téhle vrstvy (spuštěné o vrstvu dřív) musí doběhnout.
        let waitStart = Date.now
        pool.group.wait()
        let waited = Date.now.timeIntervalSince(waitStart)

        slotLock.lock()
        clock &+= 1
        let now = clock
        var map: [Int: Int] = [:]
        var missing: [Int] = []
        var useful = 0
        for expert in experts where map[expert] == nil {
            if let slot = pool.slotOf[expert] {
                map[expert] = slot
                pool.lastUse[slot] = now
                if pool.prefetched[slot] {
                    useful += 1
                    pool.prefetched[slot] = false
                }
            } else if !missing.contains(expert) {
                missing.append(expert)
            }
        }
        let jobs = reserve(pool, experts: missing, now: now, prefetch: false)
        for job in jobs { map[job.expert] = job.slot }
        slotLock.unlock()

        let hits = map.count - jobs.count
        statsLock.withLock {
            $0.requests += 1
            $0.hits += hits
            $0.misses += jobs.count
            $0.prefetchUseful += useful
            $0.waitSeconds += waited
        }
        return (map, jobs)
    }

    /// Přečte experty vrácené z `lookup` do jejich slotů (blokuje).
    func load(layer: Int, _ jobs: [(expert: Int, slot: Int)]) {
        guard let pool = pools[layer], !jobs.isEmpty else { return }
        let (bytes, seconds) = read(pool, jobs)
        statsLock.withLock {
            $0.bytes += bytes
            $0.readSeconds += seconds
        }
    }

    /// Načte experty do slotů vrstvy na pozadí (odhad z routeru o vrstvu dřív). Nevyhazuje
    /// experty, kteří byli ve vrstvě použití v posledním tokenu – ti mají největší šanci znovu.
    func prefetch(layer: Int, experts: [Int]) {
        guard let pool = pools[layer], !experts.isEmpty else { return }
        slotLock.lock()
        let now = clock
        let missing = experts.filter { pool.slotOf[$0] == nil }
        let jobs = reserve(pool, experts: missing, now: now, prefetch: true)
        slotLock.unlock()
        guard !jobs.isEmpty else { return }
        pool.group.enter()
        aheadQueue.async { [self] in
            let (bytes, seconds) = read(pool, jobs)
            statsLock.withLock {
                $0.prefetchedExperts += jobs.count
                $0.prefetchBytes += bytes
                $0.prefetchSeconds += seconds
            }
            pool.group.leave()
        }
    }

    /// Najde sloty pro experty (volné, jinak nejdéle nepoužité) a zapíše je do obsazení.
    /// Volat pod `slotLock`. Předčítání sahá jen na sloty starší než poslední token vrstvy.
    private func reserve(_ pool: LayerPool, experts: [Int], now: UInt64, prefetch: Bool) -> [(expert: Int, slot: Int)] {
        var jobs: [(expert: Int, slot: Int)] = []
        var newest = UInt64(0)
        if prefetch { newest = pool.lastUse.max() ?? 0 }
        for expert in experts where pool.slotOf[expert] == nil {
            var victim = -1
            var oldest = UInt64.max
            for slot in 0 ..< slots where pool.lastUse[slot] != now {
                if prefetch, pool.expertIn[slot] >= 0, pool.lastUse[slot] >= newest, newest > 0 { continue }
                if pool.expertIn[slot] < 0 { victim = slot; break }
                if pool.lastUse[slot] < oldest { oldest = pool.lastUse[slot]; victim = slot }
            }
            guard victim >= 0 else { break }
            if pool.expertIn[victim] >= 0 { pool.slotOf[pool.expertIn[victim]] = nil }
            pool.expertIn[victim] = expert
            pool.slotOf[expert] = victim
            pool.lastUse[victim] = prefetch ? max(1, now) : now
            pool.prefetched[victim] = prefetch
            jobs.append((expert, victim))
        }
        return jobs
    }

    /// Přečte experty ze souboru přímo do jejich slotů, paralelně po tenzorech.
    private func read(_ pool: LayerPool, _ jobs: [(expert: Int, slot: Int)]) -> (bytes: Int, seconds: Double) {
        guard !jobs.isEmpty else { return (0, 0) }
        let refs = pool.refs
        let addresses = pool.addresses
        let start = Date.now
        // Každé čtení jako samostatná úloha: `concurrentPerform` pouští jen tolik vláken, kolik je
        // jader (~6), a u krátkých čtení z flash je potřeba víc souběžných požadavků – jinak se
        // čeká na latenci jednoho po druhém (fáze 1–2: ~1,1 GB/s místo ~3,5 GB/s).
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for item in 0 ..< jobs.count * refs.count {
            queue.async(group: group) {
                let job = jobs[item / refs.count]
                let ref = refs[item % refs.count]
                guard let target = UnsafeMutableRawPointer(bitPattern: addresses[item % refs.count] + job.slot * ref.sliceBytes) else { return }
                var done = 0
                while done < ref.sliceBytes {
                    let count = pread(ref.fd, target + done, ref.sliceBytes - done, off_t(ref.offset + job.expert * ref.sliceBytes + done))
                    if count <= 0 { break }
                    done += count
                }
            }
        }
        group.wait()
        return (jobs.count * refs.reduce(0) { $0 + $1.sliceBytes }, Date.now.timeIntervalSince(start))
    }

    /// Počká na předčítání ve všech vrstvách (před uvolněním modelu).
    func waitForPrefetch() {
        for pool in pools.values { pool.group.wait() }
    }

    func takeStats() -> Stats {
        statsLock.withLock { current in
            defer { current = Stats() }
            return current
        }
    }
}

// MARK: - Test čtení

extension MLXExpertStore {
    struct ReadBenchmark: Sendable {
        /// GB/s: experti tak, jak leží v souborech (9 kousků), stejné čtení jako engine.
        let scattered: Double
        /// GB/s: stejný objem na experta jako jeden souvislý blok zarovnaný na stránku.
        let contiguous: Double
        /// GB/s: souvislý blok rozdělený na 4 souběžné kousky.
        let contiguousSplit: Double
        let experts: Int
        let expertBytes: Int
    }

    /// Změří, jak rychle jde číst experty z flash bez page cache: jako teď (po tenzorech, 9 kousků
    /// na experta, z toho 6 malých škál a posunů) a jako jeden souvislý blok stejné velikosti –
    /// tak by četl přebalený soubor s experty za sebou. Rozhoduje, jestli má smysl přebalit.
    static func benchmarkReads(plan: Plan, experts count: Int = 240, concurrent: Int = 6) -> ReadBenchmark? {
        guard let anyLayer = plan.tensors.values.first else { return nil }
        var fds: [URL: Int32] = [:]
        defer { for fd in fds.values { close(fd) } }
        func descriptor(_ url: URL) -> Int32 {
            if let fd = fds[url] { return fd }
            let fd = open(url.path(percentEncoded: false), O_RDONLY)
            if fd >= 0 { _ = fcntl(fd, F_NOCACHE, 1) }
            fds[url] = fd
            return fd
        }
        let layers = Array(plan.tensors.keys)
        let perExpert = anyLayer.values.reduce(0) { $0 + $1.bytes / plan.expertCount }
        let page = Int(getpagesize())
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: concurrent * (perExpert + page), alignment: page)
        defer { buffer.deallocate() }
        let base = Int(bitPattern: buffer)

        // Náhodné (vrstva, expert) – stejné pro všechny tři způsoby, ale každý čte jinou část
        // souboru, ať si nepomáhají zbytky v cache disku.
        var generator = SystemRandomNumberGenerator()
        let picks = (0 ..< count).map { _ in
            (layers.randomElement(using: &generator) ?? 0, Int.random(in: 0 ..< plan.expertCount, using: &generator))
        }

        func run(_ reads: [(fd: Int32, offset: Int, bytes: Int, slot: Int, into: Int)]) -> Double {
            let start = Date.now
            var total = 0
            var index = 0
            // Po skupinách `concurrent` expertů, jako předčítání jedné vrstvy.
            while index < reads.count {
                let slotBase = reads[index].slot
                var end = index
                while end < reads.count, reads[end].slot < slotBase + concurrent { end += 1 }
                let batch = Array(reads[index ..< end])
                let group = DispatchGroup()
                for read in batch {
                    DispatchQueue.global(qos: .userInitiated).async(group: group) {
                        guard let target = UnsafeMutableRawPointer(bitPattern: base + (read.slot % concurrent) * (perExpert + page) + read.into) else { return }
                        var done = 0
                        while done < read.bytes {
                            let n = pread(read.fd, target + done, read.bytes - done, off_t(read.offset + done))
                            if n <= 0 { break }
                            done += n
                        }
                    }
                }
                group.wait()
                total += batch.reduce(0) { $0 + $1.bytes }
                index = end
            }
            let seconds = Date.now.timeIntervalSince(start)
            return seconds > 0 ? Double(total) / seconds / 1_073_741_824 : 0
        }

        // 1. Jako engine: 9 kousků na experta.
        var scattered: [(fd: Int32, offset: Int, bytes: Int, slot: Int, into: Int)] = []
        for (slot, pick) in picks.enumerated() {
            guard let layer = plan.tensors[pick.0] else { continue }
            var into = 0
            for name in tensorNames {
                guard let tensor = layer[name] else { continue }
                let slice = tensor.bytes / plan.expertCount
                scattered.append((descriptor(tensor.file), tensor.offset + pick.1 * slice, slice, slot, into))
                into += slice
            }
        }
        // 2. a 3. Souvislý blok velikosti experta v oblasti vah (jiný expert, ať se nečte totéž).
        var contiguous: [(fd: Int32, offset: Int, bytes: Int, slot: Int, into: Int)] = []
        var split: [(fd: Int32, offset: Int, bytes: Int, slot: Int, into: Int)] = []
        for (slot, pick) in picks.enumerated() {
            guard let tensor = plan.tensors[pick.0]?["down_proj.weight"] else { continue }
            let span = max(0, tensor.bytes - perExpert - page)
            let offset = (tensor.offset + Int.random(in: 0 ... max(0, span), using: &generator)) / page * page
            contiguous.append((descriptor(tensor.file), offset, perExpert, slot, 0))
            let other = (tensor.offset + Int.random(in: 0 ... max(0, span), using: &generator)) / page * page
            let quarter = (perExpert / 4 + page - 1) / page * page
            var done = 0
            while done < perExpert {
                let bytes = min(quarter, perExpert - done)
                split.append((descriptor(tensor.file), other + done, bytes, slot, done))
                done += bytes
            }
        }
        guard !scattered.isEmpty, !contiguous.isEmpty else { return nil }
        return ReadBenchmark(
            scattered: run(scattered), contiguous: run(contiguous), contiguousSplit: run(split),
            experts: picks.count, expertBytes: perExpert
        )
    }
}

// MARK: - Test komprese

extension MLXExpertStore {
    struct CompressionResult: Sendable {
        let algorithm: String
        /// Komprimovaná / původní velikost (0,9 = ušetří 10 %).
        let ratio: Double
        /// Zvlášť váhy a škály s posuny – chovají se jinak.
        let weightRatio: Double
        let scaleRatio: Double
        /// Rozbalení na jednom jádře, GB/s původních dat.
        let decodeSingle: Double
        /// Rozbalení na všech jádrech souběžně, GB/s původních dat.
        let decodeParallel: Double
        /// Efektivní rychlost čtení expertů při 1,45 GB/s z flash: flash / ratio, pokud rozbalení stíhá.
        func effective(flash: Double) -> Double { min(flash / max(ratio, 0.01), decodeParallel) }
    }

    /// Vezme vzorek expertů z modelu (bez page cache), zkomprimuje je vestavěnými algoritmy
    /// a změří poměr a rychlost rozbalení. Rozhoduje, jestli by komprimované experty na flash
    /// zvedly efektivní propustnost (čte se míň, rozbalují volná jádra CPU).
    static func benchmarkCompression(plan: Plan, experts count: Int = 64) -> [CompressionResult] {
        var fds: [URL: Int32] = [:]
        defer { for fd in fds.values { close(fd) } }
        func descriptor(_ url: URL) -> Int32 {
            if let fd = fds[url] { return fd }
            let fd = open(url.path(percentEncoded: false), O_RDONLY)
            if fd >= 0 { _ = fcntl(fd, F_NOCACHE, 1) }
            fds[url] = fd
            return fd
        }
        // Vzorek: kousky expertů (váhy a škály/posuny zvlášť).
        var weights: [Data] = []
        var scales: [Data] = []
        var generator = SystemRandomNumberGenerator()
        let layers = Array(plan.tensors.keys)
        for _ in 0 ..< count {
            guard let layer = layers.randomElement(using: &generator), let tensors = plan.tensors[layer] else { continue }
            let expert = Int.random(in: 0 ..< plan.expertCount, using: &generator)
            for name in tensorNames {
                guard let tensor = tensors[name] else { continue }
                let slice = tensor.bytes / plan.expertCount
                var data = Data(count: slice)
                let fd = descriptor(tensor.file)
                let ok = data.withUnsafeMutableBytes { raw -> Bool in
                    var done = 0
                    while done < slice {
                        let n = pread(fd, raw.baseAddress! + done, slice - done, off_t(tensor.offset + expert * slice + done))
                        if n <= 0 { return false }
                        done += n
                    }
                    return true
                }
                guard ok else { continue }
                if name.hasSuffix(".weight") { weights.append(data) } else { scales.append(data) }
            }
        }
        guard !weights.isEmpty else { return [] }

        let algorithms: [(String, compression_algorithm)] = [
            ("LZ4", COMPRESSION_LZ4), ("LZFSE", COMPRESSION_LZFSE), ("ZLIB", COMPRESSION_ZLIB),
        ]
        var results: [CompressionResult] = []
        for (name, algorithm) in algorithms {
            func compress(_ chunks: [Data]) -> (compressed: [Data], original: Int, packed: Int) {
                var out: [Data] = []
                var original = 0
                var packed = 0
                for chunk in chunks {
                    var buffer = Data(count: chunk.count + chunk.count / 16 + 4096)
                    let size = buffer.withUnsafeMutableBytes { dst in
                        chunk.withUnsafeBytes { src in
                            compression_encode_buffer(
                                dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algorithm)
                        }
                    }
                    original += chunk.count
                    // 0 = nevešlo se (nekomprimovatelné) – počítá se jako uložené bez komprese.
                    packed += size == 0 ? chunk.count : size
                    buffer.count = size == 0 ? 0 : size
                    out.append(size == 0 ? chunk : buffer)
                }
                return (out, original, packed)
            }
            let w = compress(weights)
            let sc = compress(scales)
            // Rozbalení: jen komprimované kousky (nekomprimovatelné by se jen zkopírovaly).
            let pairs = zip(w.compressed + sc.compressed, weights + scales).filter { $0.0.count < $0.1.count }
            func decode(_ list: [(Data, Data)]) -> Int {
                var total = 0
                for (packed, original) in list {
                    var target = Data(count: original.count)
                    let n = target.withUnsafeMutableBytes { dst in
                        packed.withUnsafeBytes { src in
                            compression_decode_buffer(
                                dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algorithm)
                        }
                    }
                    total += n
                }
                return total
            }
            var single = 0.0
            var parallel = 0.0
            if !pairs.isEmpty {
                var start = Date.now
                let bytes = decode(pairs)
                var seconds = Date.now.timeIntervalSince(start)
                single = seconds > 0 ? Double(bytes) / seconds / 1_073_741_824 : 0
                let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
                let parts = (0 ..< cores).map { core in pairs.enumerated().filter { $0.offset % cores == core }.map(\.element) }
                let totals = OSAllocatedUnfairLock(initialState: 0)
                start = Date.now
                DispatchQueue.concurrentPerform(iterations: cores) { core in
                    let n = decode(parts[core])
                    totals.withLock { $0 += n }
                }
                seconds = Date.now.timeIntervalSince(start)
                parallel = seconds > 0 ? Double(totals.withLock { $0 }) / seconds / 1_073_741_824 : 0
            }
            let original = w.original + sc.original
            results.append(CompressionResult(
                algorithm: name,
                ratio: Double(w.packed + sc.packed) / Double(max(1, original)),
                weightRatio: Double(w.packed) / Double(max(1, w.original)),
                scaleRatio: Double(sc.packed) / Double(max(1, sc.original)),
                decodeSingle: single,
                decodeParallel: parallel
            ))
        }
        return results
    }
}

// MARK: - Zapnutí pro načítaný model

/// Předává plán z `MLXEngine` do tvůrce modelu v registru mlx-swift-lm (ten dostane jen config).
enum MLXExpertStreaming {
    typealias Request = (plan: MLXExpertStore.Plan, experts: Int)
    private static let pending = OSAllocatedUnfairLock<Request?>(initialState: nil)
    private static let active = OSAllocatedUnfairLock<MLXExpertStore?>(uncheckedState: nil)
    private static let registered = OSAllocatedUnfairLock(initialState: false)

    /// Architektury, pro které je streamovaná varianta.
    static let supportedTypes: Set<String> = ["qwen3_moe"]

    static func modelType(_ directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return config["model_type"] as? String
    }

    /// Nastaví (nebo zruší) streamování pro další načtení modelu z registru.
    static func prepare(plan: MLXExpertStore.Plan?, expertsPerToken: Int) async {
        let request: Request? = plan.map { (plan: $0, experts: expertsPerToken) }
        pending.withLock { $0 = request }
        active.withLock { $0 = nil }
        let first = MLXExpertStreaming.registered.withLock { (done: inout Bool) -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        await LLMTypeRegistry.shared.registerModelType("qwen3_moe") { data in
            if let request = MLXExpertStreaming.pending.withLock({ (current: inout Request?) -> Request? in
                defer { current = nil }
                return current
            }) {
                let configuration = try JSONDecoder().decode(StreamedQwen3MoEConfiguration.self, from: data)
                let store = try MLXExpertStore(plan: request.plan, expertsPerToken: configuration.numExpertsPerToken)
                MLXExpertStreaming.active.withLock { $0 = store }
                return StreamedQwen3MoEModel(configuration, store: store)
            }
            // Bez streamování: původní model z mlx-swift-lm.
            return Qwen3MoEModel(try JSONDecoder().decode(Qwen3MoEConfiguration.self, from: data))
        }
    }

    /// Store právě načteného streamovaného modelu (pro statistiky).
    static var current: MLXExpertStore? { active.withLock { $0 } }

    static func reset() {
        current?.waitForPrefetch()
        pending.withLock { $0 = nil }
        active.withLock { $0 = nil }
    }
}
#endif
