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
    /// Předčítat experty další vrstvy podle odhadu z routeru: nil = ne, jinak kolik expertů
    /// navíc k `activeExperts` (0 = k, 2 = k+2). Nastavuje se přes `configure`.
    private(set) var speculativeExtra: Int?
    /// Předčítat i o dvě vrstvy dopředu (router L+2 nad vstupem vrstvy L). Záznam z iPhonu
    /// (6 expertů): L+2 sám trefí 72 % výpadků za 41 % zbytečného čtení, sjednocení s L+1
    /// 84 % za 52 % (L+1 sám 78 % za 28 %). Delší náskok míří na vrstvy, u kterých výpočet
    /// předběhl dočtení – s jednou vrstvou náskoku ve 23 % případů.
    private(set) var twoLayersAhead = false
    /// Co už bylo pro vrstvu ohlášeno odhadem o dvě vrstvy dřív – odhad o vrstvu dřív pak
    /// ohlásí jen experty navíc. Klíč = vrstva, pro kterou odhad platí.
    private var announcedEarly: [Int: Set<Int>] = [:]
    /// Rezidence (`mincore`) se měří jen na každém n-tém generovaném tokenu. Měřit každý token
    /// stálo 36–82 ms na token (u odhadu z routeru se měří ~18 expertů na vrstvu místo 8),
    /// tedy 10–18 % doby generování – záznam tím zkresloval rychlost, kterou měl měřit.
    private static let residencySampleTokens = 8
    private var decodeEvents = 0
    /// Předčítání podle odhadu běží mimo vlákno výpočtu. `F_RDADVISE` přímo v callbacku stálo
    /// 34 ms na token (k) a 57 ms (k+2) – výpočet na něj čekal, i když samo čtení je asynchronní.
    private let aheadQueue = DispatchQueue(label: "cz.aichat.experts-ahead", qos: .userInitiated)
    /// Mapování stránek zvlášť: čeká na dočtení z flash a nesmí zdržet ohlášení další vrstvy.
    private let touchQueue = DispatchQueue(label: "cz.aichat.experts-touch", qos: .userInitiated)
    /// Počet zpracovaných výběrů routeru při generování. Úloha na pozadí podle něj pozná,
    /// že ji výpočet předběhl – dotýkat se stránek vrstvy, kterou už spočítal, nemá smysl.
    private let decodeProgress = OSAllocatedUnfairLock(initialState: 0)
    /// Odhady čekající na skutečný výběr, podle vrstvy, pro kterou platí. Slovník, ne jedna
    /// hodnota: odhad pro N+1 vzniká u `ffn_inp-N`, tedy ještě před `ffn_moe_topk-N`.
    private var pendingPredictions: [Int: [Int]] = [:]
    /// Odhady o dvě vrstvy dopředu (z `ffn_inp-N` pro vrstvu N+2) – jen do záznamu, zatím se
    /// podle nich nečte. Mají ukázat, jestli by delší náskok vyvážil nižší přesnost: s odhadem
    /// o vrstvu dopředu výpočet předběhl dočtení ve 23 % vrstev.
    private var pendingPredictions2: [Int: [Int]] = [:]
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
    /// Při prefillu přečíst celé tenzory expertů vrstvy sekvenčně, když dávka vybere aspoň
    /// tenhle podíl expertů vrstvy (0 = nikdy). Prefill dostává z úložiště jednu 16kB stránku
    /// na operaci (~1,1 GB/s), sekvenční čtení velkými bloky jde ~3,7 GB/s – od ~30 % pokrytí
    /// je rychlejší přečíst všechno, i když se tím přečte víc bajtů. Záznam z iPhonu
    /// (Qwen3-30B-A3B, dávky 20–52 tokenů): průměrné pokrytí 40 %, 74 % vrstev nad 30 %.
    var wholeLayerCoverage = 0.0

    /// Adresa začátku souboru v mmapu llama.cpp (tenzor = adresa + offset v souboru).
    /// Zjistí se z prvního `MUL_MAT_ID` uzlu, který scheduler nabídne callbacku.
    private var mappingBase: UnsafeRawPointer?
    private var baseLookupFailed = false
    private var gpuMappingLogged = false
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
        /// Vrstvy prefillu přečtené celé (`wholeLayerCoverage`) a kolik to bylo bajtů.
        /// Předčítání podle odhadu (`speculativeExtra`): ohlášení experti a bajty.
        var aheadExperts = 0
        var aheadBytes = 0
        var aheadSeconds = 0.0
        /// Kolikrát výpočet předběhl úlohu na pozadí dřív, než stihla namapovat stránky.
        var aheadLate = 0
        /// Kolik generovaných tokenů mělo změřenou rezidenci (vzorek, viz `residencySampleTokens`).
        var sampledTokens = 0
        var wholeLayers = 0
        var wholeLayerBytes = 0
        var wholeLayerSeconds = 0.0
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

    /// Nastaví záznam trace a předčítání podle odhadu. Volat mezi odpověďmi, ne během výpočtu.
    ///
    /// Záznam: jeden soubor na načtený model – navazující odpovědi se připisují do stejného,
    /// protože page cache mezi nimi přetrvává a simulace to má vidět.
    /// Routery (u Qwen3-30B-A3B ~25 MB) se načtou, jen když je potřebuje záznam nebo
    /// předčítání podle odhadu, a s posledním z nich se uvolní.
    func configure(tracing: Bool, speculativeExtra: Int?, twoLayersAhead: Bool = false) {
        self.speculativeExtra = speculativeExtra
        self.twoLayersAhead = speculativeExtra != nil && twoLayersAhead
        announcedEarly = [:]
        if tracing || speculativeExtra != nil {
            if predictor == nil, !predictorFailed, !routers.isEmpty {
                predictor = RouterPredictor(fd: fd, routers: routers)
                predictorFailed = predictor == nil
            }
        } else {
            predictor = nil
            pendingPredictions = [:]
            pendingPredictions2 = [:]
        }
        if !tracing {
            traceWriter?.flush()
            traceWriter = nil
            return
        }
        guard traceWriter == nil else { return }
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
        guard let offset = tensorOffsets[name] else {
            baseLookupFailed = true
            Self.log.warning("adresu mmapu expertů se nepodařilo zjistit – stránky se předem nemapují")
            return
        }
        // Uzel prefillu na GPU (op_offload) má experty zkopírované v bufferu GPU. Nevzdávat se
        // natrvalo: generování (dávka 1) běží na CPU nad mmapem a adresa se zjistí z jeho uzlu.
        // Dřív první GPU uzel zablokoval mapování stránek pro celou dobu načtení modelu.
        guard weights.pointee.buffer != nil, ggml_backend_buffer_is_host(weights.pointee.buffer) else {
            if !gpuMappingLogged {
                gpuMappingLogged = true
                Self.log.notice("experti prefillu jdou na GPU – stránky se tam předem mapují přes vlastní mmap")
            }
            return
        }
        mappingBase = UnsafeRawPointer(data) - offset
    }

    fileprivate func wants(_ tensor: UnsafeMutablePointer<ggml_tensor>) -> Bool {
        Self.hasPrefix(tensor, Self.topkPrefix) || wantsHidden(tensor)
    }

    /// Skrytý stav pro odhad jen při generování (dávka 1) a jen když ho něco použije (záznam
    /// nebo předčítání podle odhadu). Každý uzel, o který si callback řekne, dělí graf –
    /// u prefillu by odhad stál víc, než kolik by řekl.
    fileprivate func wantsHidden(_ tensor: UnsafeMutablePointer<ggml_tensor>) -> Bool {
        predictor != nil && (traceWriter != nil || speculativeExtra != nil) && tensor.pointee.ne.1 == 1
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
        let count = min(predictor.experts, 2 * max(1, activeExperts))
        // Odhad o dvě vrstvy dopředu jen se záznamem – router L+2 má složenou vlastní normu,
        // takže stačí stejný vstup.
        let secondLayer = (traceWriter != nil || twoLayersAhead) && predictor.canPredict(layer: layer + 2)
            ? layer + 2 : nil
        let predictBoth = { (hidden: UnsafePointer<Float>) -> ([Int], [Int]?) in
            let first = predictor.predict(layer: layer + 1, hidden: hidden, count: count)
            let second = secondLayer.map { predictor.predict(layer: $0, hidden: hidden, count: count) }
            return (first, second)
        }
        let result: ([Int], [Int]?)
        if ggml_backend_buffer_is_host(tensor.pointee.buffer), let data = tensor.pointee.data {
            result = predictBoth(UnsafePointer(data.assumingMemoryBound(to: Float.self)))
        } else {
            if hiddenBuffer.count < predictor.embedding {
                hiddenBuffer = [Float](repeating: 0, count: predictor.embedding)
            }
            result = hiddenBuffer.withUnsafeMutableBufferPointer { buffer in
                ggml_backend_tensor_get(tensor, buffer.baseAddress!, 0, bytes)
                return predictBoth(UnsafePointer(buffer.baseAddress!))
            }
        }
        let (ranked, ranked2) = result
        pendingPredictions[layer + 1] = ranked
        if let secondLayer, let ranked2, traceWriter != nil { pendingPredictions2[secondLayer] = ranked2 }
        if let speculativeExtra, readEnabled, !splitOnly, !useReadFallback {
            let k = max(1, activeExperts)
            // O vrstvu dopředu jen to, co odhad o dvě vrstvy dřív pro tuhle vrstvu neohlásil.
            let early = announcedEarly.removeValue(forKey: layer + 1) ?? []
            let next = ranked.prefix(k + speculativeExtra).filter { !early.contains($0) }
            if !next.isEmpty { scheduleAhead(layer: layer + 1, experts: next, lead: 1) }
            if twoLayersAhead, let secondLayer, let ranked2 {
                let far = Array(ranked2.prefix(k))
                announcedEarly[secondLayer] = Set(far)
                scheduleAhead(layer: secondLayer, experts: far, lead: 2)
            }
        }
    }

    /// Počká, až doběhne předčítání podle odhadu. Volat před uvolněním modelu – úloha
    /// na pozadí sahá na stránky mmapu llama.cpp.
    func waitForAhead() {
        aheadQueue.sync {}
        touchQueue.sync {}
    }

    /// Předčte experty další vrstvy podle odhadu – na pozadí, výpočet na to nečeká.
    ///
    /// 1. `F_RDADVISE` na rozsahy odhadnutých expertů – čtení z flash běží souběžně s MoE této
    ///    vrstvy a attention další. Stránky, které už v cache jsou, jádro přeskočí.
    /// 2. S „Mapovat stránky předem“ se na stránky i sáhne (přes mmap llama.cpp), takže je
    ///    výpočet najde namapované. Mapování v cestě výpočtu stálo ~60 ms na token
    ///    (~10 000 výpadků „jen mapování“ po ~6 µs). Přeskočí se, jakmile výpočet vrstvu předběhne.
    ///
    /// Když router vybere jiné experty, dočtou se běžnou cestou v `handle`.
    /// `lead` = o kolik vrstev dopředu (1 = další vrstva, 2 = ob jednu).
    private func scheduleAhead(layer: Int, experts: [Int], lead: Int) {
        guard let tensors = layers[layer], !experts.isEmpty else { return }
        let sorted = experts.sorted()
        var ranges: [(offset: Int, bytes: Int)] = []
        for expertTensor in tensors {
            let slice = expertTensor.bytes / expertCount
            guard slice > 0 else { continue }
            var index = 0
            while index < sorted.count {
                var end = index
                while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
                ranges.append((expertTensor.fileOffset + sorted[index] * slice, (end - index + 1) * slice))
                index = end + 1
            }
        }
        let all = ranges
        let count = experts.count
        // Mmap llama.cpp, ne vlastní: dvojí mapování se při generování nevyplácí (viz `ownMapMinBatch`).
        // Adresa jako číslo: ukazatel není Sendable a úloha jde do jiného vlákna.
        let baseAddress = prefaultPages ? mappingBase.map { Int(bitPattern: $0) } : nil
        // Tahle vrstva je teď `N`; výběr routeru pro ni přijde jako další, pro N+1 jako ten po něm.
        // Až výpočet výběr pro N+1 zpracuje, je na dotyk pozdě.
        let deadline = decodeProgress.withLock { $0 } + 1 + lead
        let fd = self.fd
        aheadQueue.async { [self] in
            let start = Date.now
            var bytes = 0
            for range in all {
                var advice = radvisory(ra_offset: off_t(range.offset), ra_count: Int32(clamping: range.bytes))
                _ = fcntl(fd, F_RDADVISE, &advice)
                bytes += range.bytes
            }
            let elapsed = Date.now.timeIntervalSince(start)
            let announced = bytes
            stats.withLock {
                $0.aheadExperts += count
                $0.aheadBytes += announced
                $0.aheadSeconds += elapsed
            }
            guard let baseAddress else { return }
            touchQueue.async { [self] in
                guard let base = UnsafeRawPointer(bitPattern: baseAddress) else { return }
                for range in all {
                    if decodeProgress.withLock({ $0 }) >= deadline {
                        stats.withLock { $0.aheadLate += 1 }
                        return
                    }
                    Self.touchPages(base + range.offset, bytes: range.bytes)
                }
            }
        }
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
        if batchTokens == 1 { decodeProgress.withLock { $0 += 1 } }

        // Záznam a zásah cache – musí se změřit před předčtením, jinak by vyšel vždy 100 %.
        // Odhad pro tuhle vrstvu (udělaný o vrstvu dřív) platí jen jednou – pak se zahodí.
        let prediction = pendingPredictions.removeValue(forKey: layer)
        let prediction2 = pendingPredictions2.removeValue(forKey: layer)
        if let traceWriter {
            let measureStart = Date.now
            let predicted = batchTokens == 1 ? prediction ?? [] : []
            let predicted2 = batchTokens == 1 ? prediction2 ?? [] : []
            // Vzorek: generování jen každý n-tý token (celý token, všechny vrstvy), prefill vždy.
            var sample = true
            if batchTokens == 1 {
                let perToken = max(1, layers.count)
                let firstOfToken = decodeEvents % perToken == 0
                sample = (decodeEvents / perToken) % Self.residencySampleTokens == 0
                decodeEvents += 1
                if sample, firstOfToken { stats.withLock { $0.sampledTokens += 1 } }
            }
            // Měří se i odhadnutí experti: simulátor pak ví, kolik by předčítání podle odhadu
            // opravdu četlo z flash (odhad, který už v cache leží, nic nestojí).
            let measured = sample
                ? residency(of: Array(Set(selected).union(predicted).union(predicted2)), in: tensors) : nil
            traceWriter.append(layer: layer, tokens: batchTokens, experts: selected,
                               predicted: predicted, predicted2: predicted2, resident: measured?.resident)
            if let measured {
                let elapsed = Date.now.timeIntervalSince(measureStart)
                let hits = selected.filter { measured.resident.contains($0) }
                let residentBytes = selected.reduce(0) { $0 + (measured.residentBytes[$1] ?? 0) }
                stats.withLock {
                    $0.measuredExperts += selected.count
                    $0.residentExperts += hits.count
                    $0.measuredBytes += selected.count * measured.expertBytes
                    $0.residentBytes += residentBytes
                    $0.measuredSeconds += elapsed
                }
            }
        }
        if splitOnly || !readEnabled {
            stats.withLock { $0.layers += 1 }
            return
        }

        // Prefill s velkým pokrytím: nejdřív celé tenzory vrstvy sekvenčně do page cache.
        // Předčítání vybraných expertů níž pak už jen najde stránky v cache a namapuje je.
        let coverage = Double(selected.count) / Double(max(1, expertCount))
        if batchTokens > 1, wholeLayerCoverage > 0, coverage >= wholeLayerCoverage {
            let wholeStart = Date.now
            let wholeBytes = readWholeLayer(tensors)
            let elapsed = Date.now.timeIntervalSince(wholeStart)
            stats.withLock {
                $0.wholeLayers += 1
                $0.wholeLayerBytes += wholeBytes
                $0.wholeLayerSeconds += elapsed
            }
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

    /// Přečte celé tenzory expertů vrstvy sekvenčně po `chunkBytes` blocích, paralelně.
    /// Čte se přes page cache (bez `F_NOCACHE`), takže výsledek zůstane v cache pro výpočet;
    /// stránky, které v ní už jsou, se jen zkopírují. Vrací počet přečtených bajtů.
    private func readWholeLayer(_ tensors: [GGUFLayout.ExpertTensor]) -> Int {
        var chunks: [(offset: Int, bytes: Int)] = []
        for expertTensor in tensors {
            var offset = expertTensor.fileOffset
            let end = expertTensor.fileOffset + expertTensor.bytes
            while offset < end {
                let bytes = min(Self.chunkBytes, end - offset)
                chunks.append((offset, bytes))
                offset += bytes
            }
        }
        let all = chunks
        DispatchQueue.concurrentPerform(iterations: all.count) { index in
            self.readRange(offset: all[index].offset, bytes: all[index].bytes)
        }
        return all.reduce(0) { $0 + $1.bytes }
    }

    /// Kteří z daných expertů leží v page cache, zjištěno přes `mincore` nad vlastním
    /// mapováním souboru. Na Darwinu mapování i čtení z deskriptoru sdílí jeden VM objekt
    /// souboru, takže `mincore` hlásí stránky, které jsou v cache, i když je tohle mapování
    /// ještě nikdy nedotklo. Nic se tím nečte ani nemapuje.
    ///
    /// Expert je zásah, jen když leží v cache celý (všechny tři tenzory, všechny stránky):
    /// jediná chybějící stránka znamená čekání na flash uprostřed násobení.
    private func residency(
        of experts: [Int],
        in tensors: [GGUFLayout.ExpertTensor]
    ) -> (resident: Set<Int>, residentBytes: [Int: Int], expertBytes: Int)? {
        guard let ownMap, ownMapBytes > 0, !residencyFailed else { return nil }
        let pageMask = Self.pageSize - 1
        var residentExperts = Set<Int>()
        var residentBytes: [Int: Int] = [:]
        let expertBytes = tensors.reduce(0) { $0 + $1.bytes / expertCount }
        for expert in experts {
            var whole = true
            var inCache = 0
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
                inCache += min(slice, incore * Self.pageSize)
            }
            if whole { residentExperts.insert(expert) }
            residentBytes[expert] = inCache
        }
        return (residentExperts, residentBytes, expertBytes)
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
