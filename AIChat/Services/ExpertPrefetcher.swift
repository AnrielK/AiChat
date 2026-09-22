#if canImport(llama)
import Foundation
import llama
import os

/// Předčítá experty MoE z flash dřív, než na ně sáhne výpočet.
///
/// Bez toho si llama.cpp experty dotahuje přes page faulty namapovaného souboru – stránku
/// po stránce (16 kB), sériově, v okamžiku, kdy je násobení zrovna potřebuje. Na jeden token
/// Qwen3-30B-A3B to jsou desítky tisíc faultů a flash se nevyužije.
///
/// Postup (princip z Colibrì, bez zásahu do llama.cpp):
/// 1. `cb_eval` callback si řekne o výsledek uzlu `ffn_moe_topk-N` – scheduler kvůli tomu
///    graf za výběrem expertů rozdělí a zavolá nás dřív, než se spočítá `MUL_MAT_ID`.
/// 2. Z výsledku vezmeme, které experty router pro vrstvu N vybral (pro všechny tokeny dávky).
/// 3. Jejich rozsahy v souboru pošleme jádru jako `F_RDADVISE` – souvislé bloky po MB,
///    paralelně. Mmap i čtení z deskriptoru sdílí na Darwinu stejnou cache, takže následné
///    faulty výpočtu už najdou stránky načtené (nebo počkají na rozjeté čtení).
///    Stránky, které už v cache jsou, jádro přeskočí – nic se zbytečně nekopíruje.
final class ExpertPrefetcher: @unchecked Sendable {
    private static let log = EngineLog(category: "gguf")
    /// Největší blok na jedno `pread` – buffer se na něj alokuje, tak ať není obří.
    /// `F_RDADVISE` se nedělí: jádro si čtení naplánuje samo a každý kus navíc je jen
    /// jeden syscall k dobru.
    private static let chunkBytes = 8 * 1_048_576
    /// Od kolika rozsahů se vyplatí rozdělit práci mezi vlákna. `F_RDADVISE` je
    /// asynchronní (jen zařadí čtení), takže pár desítek volání je levnější vydat
    /// sériově, než na ně budit thread pool – a to se děje 48× na každý token.
    private static let parallelThreshold = 64
    /// Od jaké velikosti dávky se vyplatí sahat na stránky přes vlastní mapování.
    /// Scheduler posílá operace na GPU od 32 tokenů; přesně tam přestane jít zjistit adresa
    /// mmapu llama.cpp a nastupuje `ownMap`. Měření (Qwen3-30B-A3B, k=6, prompt 1593 tokenů):
    /// prefill 104,6 → 75,0 s. Při generování (dávka 1) je to ale ztráta: každá stránka se
    /// mapuje dvakrát, výpadky „jen mapování“ vyskočily z 312 tisíc na 15,7 milionu,
    /// RAM appky ze 4,0 na 6,7 GB a rychlost z 2,87 na 2,51 tok/s. Čekání na flash je tam
    /// krátké, protože jde o jednotky expertů, takže se dvojí mapování nemá z čeho zaplatit.
    private static let ownMapMinBatch = 32
    private static let topkPrefix = Array("ffn_moe_topk-".utf8CString.dropLast())
    /// Reziduální vstup MoE vrstvy (`ffn_inp-N`) – z něj se odhadují experti vrstvy N+1.
    private static let hiddenPrefix = Array("ffn_inp-".utf8CString.dropLast())

    private let fd: Int32
    private let path: String
    private let layers: [Int: [GGUFLayout.ExpertTensor]]
    private let expertCount: Int
    private let routers: [Int: GGUFLayout.RouterTensor]
    /// Kolik expertů router opravdu vybírá (po případném snížení v Parametrech).
    /// Odhad se ukládá dvojnásobně dlouhý, ať jde změřit i „odhad o pár expertů víc“.
    var activeExperts = 0

    /// Předčítat vybrané experty. Vypnuté jen tehdy, když callback běží kvůli záznamu trace
    /// a předčítání je v nastavení vypnuté – pak se jen měří a zapisuje, nic se nečte.
    var readEnabled = true
    /// Záznam výběru routeru (viz `ExpertTrace`). nil = nezaznamenává se.
    private var traceWriter: ExpertTraceWriter?
    /// Buffer pro `mincore` – callback běží v jednom vlákně, stačí jeden.
    private var residencyVector: [CChar] = []
    private var residencyFailed = false
    /// Odhad expertů další vrstvy z jejího routeru – jen při záznamu (zatím se jen měří).
    private var predictor: RouterPredictor?
    private var predictorFailed = false
    /// Odhady čekající na skutečný výběr, podle vrstvy, pro kterou platí. Slovník, ne jedna
    /// hodnota: odhad pro N+1 vzniká u `ffn_inp-N`, tedy ještě před `ffn_moe_topk-N`.
    private var pendingPredictions: [Int: [Int]] = [:]
    private var hiddenBuffer: [Float] = []

    // Statistiky jedné odpovědi (callback běží synchronně ve vlákně llama_decode).
    private let stats = OSAllocatedUnfairLock(initialState: Stats())
    private var useReadFallback = false
    /// Diagnostika: graf se dělí za výběrem expertů jako při předčítání, ale nic se nečte.
    /// Porovnáním s vypnutým předčítáním se změří cena samotného dělení grafu.
    var splitOnly = false
    /// Po přečtení stránky expertů rovnou namapovat do procesu (paralelně sáhnout na každou
    /// stránku). Jinak je výpočet mapuje sám, po jedné stránce ve vlákně výpočtu.
    var prefaultPages = false
    /// Kolik bajtů ohlásit najednou, než se na ně počká dotykem stránek. 0 = celá vrstva naráz.
    ///
    /// Proč po vlnách: při zpracování promptu vybere router přes padesát expertů na vrstvu,
    /// takže se naráz ohlásí ~146 MB. Měření ukazuje, že takový prefill dostane z úložiště
    /// jednu 16kB stránku na jedno I/O, zatímco generování (~16 MB na vrstvu) jich dostane
    /// přes pět – readahead se u velkého objemu evidentně neuplatní a prefill je pak
    /// omezený počtem operací (~75 000/s, tedy ~1,1 GB/s) místo propustností (~3,7 GB/s).
    /// Menší vlna drží objem nevyřízeného readaheadu v mezích, ve kterých funguje.
    var waveBytes = 0

    /// Adresa začátku souboru v mmapu llama.cpp (tenzor = adresa + offset v souboru).
    /// Zjistí se z prvního `MUL_MAT_ID` uzlu, který scheduler nabídne callbacku.
    private var mappingBase: UnsafeRawPointer?
    private var baseLookupFailed = false
    /// Vlastní mapování souboru. Použije se, když adresu mmapu llama.cpp zjistit nejde –
    /// s `op_offload` jsou tenzory expertů v grafu už kopie v bufferu GPU, takže test na
    /// host buffer selže a prefaulting by se jinak vypnul úplně.
    /// Dotyk vlastního mapování natáhne stránky do sdílené cache souboru, takže výpočtu
    /// zbydou jen levné výpadky bez čtení místo čekání na flash. Clean file-backed stránky
    /// se nepočítají do footprintu, mapování navíc tedy nic nestojí.
    private var ownMap: UnsafeRawPointer?
    private var ownMapBytes = 0
    private let tensorOffsets: [String: Int]
    private static let pageSize = Int(getpagesize())

    struct Stats {
        var layers = 0
        var experts = 0
        var bytes = 0
        var seconds = 0.0
        /// Zásah page cache změřený přes `mincore` ještě před předčtením – jen při záznamu trace.
        /// Obdoba „TRUE resident hit rate“ z kimi-k3-in-c: expert se počítá jako zásah, jen když
        /// v cache leží celý. Hity, které by obsloužilo až předčítání, se sem nepočítají.
        var measuredExperts = 0
        var residentExperts = 0
        var measuredBytes = 0
        var residentBytes = 0
        var measuredSeconds = 0.0
    }

    init?(path: String, layout: GGUFLayout) {
        guard layout.expertCount > 0, !layout.expertTensors.isEmpty else { return nil }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.path = path
        self.layers = layout.expertTensors
        self.expertCount = layout.expertCount
        self.routers = layout.routerTensors
        self.activeExperts = layout.expertUsed
        var offsets: [String: Int] = [:]
        for tensor in layout.expertTensors.values.joined() { offsets[tensor.name] = tensor.fileOffset }
        self.tensorOffsets = offsets

        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0 {
            let bytes = Int(info.st_size)
            if let map = mmap(nil, bytes, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED {
                ownMap = UnsafeRawPointer(map)
                ownMapBytes = bytes
            }
        }
    }

    deinit {
        if let ownMap, ownMapBytes > 0 { munmap(UnsafeMutableRawPointer(mutating: ownMap), ownMapBytes) }
        close(fd)
    }

    /// Nastaví callback do parametrů kontextu. Prefetcher musí žít déle než kontext.
    func install(into params: inout llama_context_params) {
        params.cb_eval = expertPrefetchCallback
        params.cb_eval_user_data = Unmanaged.passUnretained(self).toOpaque()
    }

    /// Vrátí a vynuluje statistiky od posledního volání.
    func takeStats() -> Stats {
        stats.withLock { current in
            defer { current = Stats() }
            return current
        }
    }

    /// Zapne nebo vypne záznam trace. Jeden soubor na načtený model – navazující odpovědi
    /// se připisují do stejného, protože page cache mezi nimi přetrvává a simulace to má vidět.
    /// Volat mezi odpověďmi, ne během výpočtu.
    func setTracing(_ enabled: Bool) {
        if !enabled {
            traceWriter?.flush()
            traceWriter = nil
            predictor = nil
            pendingPredictions = [:]
            return
        }
        guard traceWriter == nil else { return }
        // Routery (u Qwen3-30B-A3B ~25 MB) se načtou jen se záznamem a s ním se i uvolní.
        if predictor == nil, !predictorFailed, !routers.isEmpty {
            predictor = RouterPredictor(fd: fd, routers: routers)
            predictorFailed = predictor == nil
        }
        let layerCount = (layers.keys.max() ?? -1) + 1
        var slices = [Int](repeating: 0, count: layerCount)
        for (layer, tensors) in layers {
            slices[layer] = tensors.reduce(0) { $0 + $1.bytes / expertCount }
        }
        traceWriter = ExpertTraceWriter(
            modelName: (path as NSString).lastPathComponent,
            expertCount: expertCount,
            sliceBytes: slices,
            residencyMeasured: ownMap != nil && !residencyFailed,
            predictions: predictor != nil
        )
    }

    /// Zapíše nasbíraný záznam na disk (po odpovědi, mimo výpočet).
    func flushTrace() {
        traceWriter?.flush()
    }

    var traceFile: URL? { traceWriter?.url }

    // MARK: - Callback

    /// Z uzlu násobení experty (src[0] = tenzor expertů v mmapu) dopočítá adresu mmapu souboru.
    fileprivate func learnMapping(_ tensor: UnsafeMutablePointer<ggml_tensor>) {
        guard mappingBase == nil, !baseLookupFailed, tensor.pointee.op == GGML_OP_MUL_MAT_ID,
              let weights = tensor.pointee.src.0, let data = weights.pointee.data else { return }
        let name = withUnsafeBytes(of: weights.pointee.name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard let offset = tensorOffsets[name], weights.pointee.buffer != nil,
              ggml_backend_buffer_is_host(weights.pointee.buffer) else {
            baseLookupFailed = true
            if ownMap == nil {
                Self.log.warning("adresu mmapu expertů se nepodařilo zjistit – stránky se předem nemapují")
            } else {
                Self.log.notice("experti jdou na GPU – stránky se předem mapují přes vlastní mmap")
            }
            return
        }
        mappingBase = UnsafeRawPointer(data) - offset
    }

    fileprivate func wants(_ tensor: UnsafeMutablePointer<ggml_tensor>) -> Bool {
        Self.hasPrefix(tensor, Self.topkPrefix) || wantsHidden(tensor)
    }

    /// Skrytý stav pro odhad jen při generování (dávka 1) a se zapnutým záznamem. Každý uzel,
    /// o který si callback řekne, dělí graf – u prefillu by odhad stál víc, než kolik by řekl.
    fileprivate func wantsHidden(_ tensor: UnsafeMutablePointer<ggml_tensor>) -> Bool {
        predictor != nil && traceWriter != nil && tensor.pointee.ne.1 == 1
            && tensor.pointee.type == GGML_TYPE_F32 && Self.hasPrefix(tensor, Self.hiddenPrefix)
    }

    private static func hasPrefix(_ tensor: UnsafeMutablePointer<ggml_tensor>, _ prefix: [CChar]) -> Bool {
        withUnsafeBytes(of: tensor.pointee.name) { raw in
            raw.count > prefix.count && zip(raw, prefix).allSatisfy { UInt8(bitPattern: $1) == $0 }
        }
    }

    /// Ze vstupu MoE vrstvy N odhadne experty vrstvy N+1 (seřazené podle skóre).
    fileprivate func predictNext(_ tensor: UnsafeMutablePointer<ggml_tensor>) {
        guard let predictor, let layer = Self.layerNumber(tensor, prefix: Self.hiddenPrefix),
              predictor.canPredict(layer: layer + 1),
              Int(tensor.pointee.ne.0) == predictor.embedding, tensor.pointee.buffer != nil else { return }
        let bytes = predictor.embedding * MemoryLayout<Float>.size
        let ranked: [Int]
        let count = min(predictor.experts, 2 * max(1, activeExperts))
        if ggml_backend_buffer_is_host(tensor.pointee.buffer), let data = tensor.pointee.data {
            ranked = predictor.predict(layer: layer + 1, hidden: data.assumingMemoryBound(to: Float.self), count: count)
        } else {
            if hiddenBuffer.count < predictor.embedding {
                hiddenBuffer = [Float](repeating: 0, count: predictor.embedding)
            }
            ranked = hiddenBuffer.withUnsafeMutableBufferPointer { buffer in
                ggml_backend_tensor_get(tensor, buffer.baseAddress!, 0, bytes)
                return predictor.predict(layer: layer + 1, hidden: buffer.baseAddress!, count: count)
            }
        }
        pendingPredictions[layer + 1] = ranked
    }

    fileprivate func handle(_ tensor: UnsafeMutablePointer<ggml_tensor>) {
        // Bez záznamu zůstává „jen dělit graf“ čistá diagnostika – nic dalšího se nedělá,
        // aby měření ceny samotného dělení nezkreslilo čtení výběru routeru.
        if splitOnly && traceWriter == nil {
            stats.withLock { $0.layers += 1 }
            return
        }
        guard let layer = layerIndex(tensor), let tensors = layers[layer],
              let selected = selectedExperts(tensor), !selected.isEmpty else { return }
        let batchTokens = Int(tensor.pointee.ne.1)

        // Záznam a zásah cache – musí se změřit před předčtením, jinak by vyšel vždy 100 %.
        // Odhad pro tuhle vrstvu (udělaný o vrstvu dřív) platí jen jednou – pak se zahodí.
        let prediction = pendingPredictions.removeValue(forKey: layer)
        if let traceWriter {
            let measureStart = Date.now
            let measured = residency(of: selected, in: tensors)
            let predicted = batchTokens == 1 ? prediction ?? [] : []
            traceWriter.append(layer: layer, tokens: batchTokens, experts: selected,
                               resident: measured?.experts, predicted: predicted)
            if let measured {
                let elapsed = Date.now.timeIntervalSince(measureStart)
                stats.withLock {
                    $0.measuredExperts += selected.count
                    $0.residentExperts += measured.experts
                    $0.measuredBytes += measured.totalBytes
                    $0.residentBytes += measured.residentBytes
                    $0.measuredSeconds += elapsed
                }
            }
        }
        if splitOnly || !readEnabled {
            stats.withLock { $0.layers += 1 }
            return
        }

        let start = Date.now
        let fallback = useReadFallback
        // Nejlepší je mapování llama.cpp – tam dotyk ušetří výpadek i výpočtu. Když ho zjistit
        // nejde (viz `ownMap`), sáhne se na vlastní mapování: výpočet si stránku ještě jednou
        // namapuje, ale už nečeká na flash. To se vyplatí jen u velkých dávek, viz
        // `ownMapMinBatch` – při generování se dvojí mapování nevrátí.
        let fallbackBase = batchTokens >= Self.ownMapMinBatch ? ownMap : nil
        let base = prefaultPages ? (mappingBase ?? fallbackBase) : nil
        // Vlny mají smysl jen s mapováním stránek: `F_RDADVISE` je asynchronní, takže bez
        // čekání mezi vlnami skončí „po částech“ i „všechno naráz“ ve stejné frontě jádra.
        let wave = base != nil ? waveBytes : 0
        // Dělit rozsahy na menší kusy má smysl jen tam, kde se na každý kus alokuje buffer
        // nebo sahá vlastním vláknem; čisté `F_RDADVISE` se vydá na celý souvislý blok.
        let split = fallback || base != nil
        // Ve vlně chceme dost kusů na to, aby se dotyk stránek rozložil mezi vlákna.
        let chunk = wave > 0 ? max(1_048_576, wave / 8) : Self.chunkBytes
        var ranges: [(offset: Int, bytes: Int)] = []
        for expertTensor in tensors {
            let slice = expertTensor.bytes / expertCount
            guard slice > 0 else { continue }
            // Sousední experty spojit do jednoho bloku.
            var index = 0
            while index < selected.count {
                var end = index
                while end + 1 < selected.count, selected[end + 1] == selected[end] + 1 { end += 1 }
                var offset = expertTensor.fileOffset + selected[index] * slice
                var remaining = (end - index + 1) * slice
                while remaining > 0 {
                    let bytes = split ? min(remaining, chunk) : remaining
                    ranges.append((offset, bytes))
                    offset += bytes
                    remaining -= bytes
                }
                index = end + 1
            }
        }

        let failures = OSAllocatedUnfairLock(initialState: 0)
        /// Ohlásí jádru, že blok bude potřeba. Nečeká – jen zařadí čtení.
        func advise(_ index: Int) {
            let range = ranges[index]
            if fallback {
                self.readRange(offset: range.offset, bytes: range.bytes)
                return
            }
            var advice = radvisory(ra_offset: off_t(range.offset), ra_count: Int32(range.bytes))
            if fcntl(self.fd, F_RDADVISE, &advice) == -1 {
                failures.withLock { $0 += 1 }
                self.readRange(offset: range.offset, bytes: range.bytes)
            }
        }
        /// Sáhne na každou stránku bloku – tady se na dokončení čtení čeká.
        func touch(_ index: Int) {
            guard let base else { return }
            let range = ranges[index]
            if base == ownMap, ownMapBytes > 0, range.offset + range.bytes > ownMapBytes { return }
            Self.touchPages(base + range.offset, bytes: range.bytes)
        }

        if wave > 0 {
            // Ohlásit vlnu, počkat na ni, teprve pak ohlásit další.
            var index = 0
            while index < ranges.count {
                var end = index
                var bytes = 0
                while end < ranges.count, bytes < wave {
                    bytes += ranges[end].bytes
                    end += 1
                }
                for position in index..<end { advise(position) }
                DispatchQueue.concurrentPerform(iterations: end - index) { touch(index + $0) }
                index = end
            }
        } else if split || ranges.count >= Self.parallelThreshold {
            DispatchQueue.concurrentPerform(iterations: ranges.count) { advise($0); touch($0) }
        } else {
            for index in ranges.indices { advise(index); touch(index) }
        }
        if !fallback, failures.withLock({ $0 }) > 0 {
            useReadFallback = true
            Self.log.warning("F_RDADVISE nefunguje, experty předčítám přes pread")
        }

        let seconds = Date.now.timeIntervalSince(start)
        let bytes = ranges.reduce(0) { $0 + $1.bytes }
        stats.withLock {
            $0.layers += 1
            $0.experts += selected.count
            $0.bytes += bytes
            $0.seconds += seconds
        }
    }

    /// Kolik z vybraných expertů leží v page cache, zjištěno přes `mincore` nad vlastním
    /// mapováním souboru. Na Darwinu mapování i čtení z deskriptoru sdílí jeden VM objekt
    /// souboru, takže `mincore` hlásí stránky, které jsou v cache, i když je tohle mapování
    /// ještě nikdy nedotklo. Nic se tím nečte ani nemapuje.
    ///
    /// Expert je zásah, jen když leží v cache celý (všechny tři tenzory, všechny stránky):
    /// jediná chybějící stránka znamená čekání na flash uprostřed násobení.
    private func residency(
        of selected: [Int],
        in tensors: [GGUFLayout.ExpertTensor]
    ) -> (experts: Int, residentBytes: Int, totalBytes: Int)? {
        guard let ownMap, ownMapBytes > 0, !residencyFailed else { return nil }
        let pageMask = Self.pageSize - 1
        var residentExperts = 0
        var residentBytes = 0
        var totalBytes = 0
        for expert in selected {
            var whole = true
            for expertTensor in tensors {
                let slice = expertTensor.bytes / expertCount
                guard slice > 0 else { continue }
                let start = expertTensor.fileOffset + expert * slice
                let end = start + slice
                guard end <= ownMapBytes else { return nil }
                let alignedStart = start & ~pageMask
                let pages = (end - alignedStart + pageMask) / Self.pageSize
                if residencyVector.count < pages {
                    residencyVector = [CChar](repeating: 0, count: pages)
                }
                let status = residencyVector.withUnsafeMutableBufferPointer { vector in
                    mincore(ownMap + alignedStart, end - alignedStart, vector.baseAddress)
                }
                guard status == 0 else {
                    residencyFailed = true
                    Self.log.warning("mincore nefunguje (errno \(errno)) – zásah cache expertů se neměří")
                    return nil
                }
                var incore = 0
                for page in 0..<pages where residencyVector[page] & 1 != 0 { incore += 1 }
                if incore < pages { whole = false }
                totalBytes += slice
                residentBytes += min(slice, incore * Self.pageSize)
            }
            if whole { residentExperts += 1 }
        }
        return (residentExperts, residentBytes, totalBytes)
    }

    /// Sáhne na každou stránku rozsahu – jádro ji namapuje do procesu (a když ještě není
    /// v cache, dočte ji). Výpočet pak na těchto stránkách žádný výpadek nečeká.
    private static func touchPages(_ start: UnsafeRawPointer, bytes: Int) {
        var checksum: UInt8 = 0
        var offset = 0
        while offset < bytes {
            checksum &+= start.load(fromByteOffset: offset, as: UInt8.self)
            offset += pageSize
        }
        checksum &+= start.load(fromByteOffset: bytes - 1, as: UInt8.self)
        keepAlive(checksum)
    }

    /// Zápis do globální proměnné je vedlejší efekt – překladač kvůli němu čtení stránek nevyhodí.
    /// Souběžné zápisy z více vláken nevadí, na hodnotě nezáleží.
    nonisolated(unsafe) private static var sink: UInt8 = 0

    private static func keepAlive(_ value: UInt8) {
        sink = value
    }

    /// Náhradní cesta: přečíst blok do bufferu (stránky tím skončí v cache).
    private func readRange(offset: Int, bytes: Int) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        defer { buffer.deallocate() }
        var done = 0
        while done < bytes {
            let count = pread(fd, buffer + done, bytes - done, off_t(offset + done))
            if count <= 0 { break }
            done += count
        }
    }

    /// „ffn_moe_topk-12“ → 12
    private func layerIndex(_ tensor: UnsafeMutablePointer<ggml_tensor>) -> Int? {
        Self.layerNumber(tensor, prefix: Self.topkPrefix)
    }

    /// Číslo vrstvy za prefixem názvu uzlu („ffn_inp-7“ → 7).
    private static func layerNumber(_ tensor: UnsafeMutablePointer<ggml_tensor>, prefix: [CChar]) -> Int? {
        withUnsafeBytes(of: tensor.pointee.name) { raw in
            var value = 0
            var digits = 0
            for byte in raw.dropFirst(prefix.count) {
                guard byte >= 48, byte <= 57 else { break }
                value = value * 10 + Int(byte - 48)
                digits += 1
            }
            return digits > 0 ? value : nil
        }
    }

    /// Seřazené unikátní indexy expertů z výsledku `ffn_moe_topk` ([n_expert_used, n_tokens], I32).
    /// Tenzor je view nad argsort, takže se čte podle kroků `nb`, ne souvisle.
    private func selectedExperts(_ tensor: UnsafeMutablePointer<ggml_tensor>) -> [Int]? {
        let t = tensor.pointee
        guard t.type == GGML_TYPE_I32, t.ne.2 == 1, t.ne.3 == 1, t.buffer != nil else { return nil }
        let used = Int(t.ne.0)
        let tokens = Int(t.ne.1)
        let stride0 = Int(t.nb.0)
        let stride1 = Int(t.nb.1)
        let total = ggml_nbytes(tensor)
        guard used > 0, tokens > 0, total > 0 else { return nil }

        var chosen = [Bool](repeating: false, count: expertCount)
        let collect = { (base: UnsafeRawPointer) in
            for row in 0..<tokens {
                for column in 0..<used {
                    let offset = row * stride1 + column * stride0
                    guard offset + 4 <= total else { continue }
                    let id = Int(base.loadUnaligned(fromByteOffset: offset, as: Int32.self))
                    if id >= 0, id < chosen.count { chosen[id] = true }
                }
            }
        }

        if ggml_backend_buffer_is_host(t.buffer), let data = t.data {
            collect(UnsafeRawPointer(data))
        } else {
            // Výběr expertů běží na Metal (přeuspořádaný soubor s GPU) – zkopírovat k sobě.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 16)
            defer { buffer.deallocate() }
            ggml_backend_tensor_get(tensor, buffer, 0, total)
            collect(UnsafeRawPointer(buffer))
        }
        return chosen.indices.filter { chosen[$0] }
    }
}

/// C callback scheduleru. ask = true: „chceš výsledek tohohle uzlu?“, ask = false: výsledek je hotový.
private let expertPrefetchCallback: ggml_backend_sched_eval_callback = { tensor, ask, userData in
    guard let tensor, let userData else { return !ask }
    let prefetcher = Unmanaged<ExpertPrefetcher>.fromOpaque(userData).takeUnretainedValue()
    if ask {
        prefetcher.learnMapping(tensor)
        return prefetcher.wants(tensor)
    }
    if prefetcher.wantsHidden(tensor) {
        prefetcher.predictNext(tensor)
    } else if prefetcher.wants(tensor) {
        prefetcher.handle(tensor)
    }
    return true
}
#endif
