import Foundation
import os
#if canImport(llama)
import llama
#endif

/// Lokální GGUF model přes llama.cpp.
struct LlamaProvider: ChatProvider {
    let modelPath: String
    let settings: LocalModelSettings
    var reasoning: Bool

    func thinking(_ enabled: Bool) -> any ChatProvider {
        var copy = self
        copy.reasoning = enabled
        return copy
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // MLX model uvolnit dřív, než se načte tenhle – jinak leží v paměti oba.
                    await LocalEngines.keepOnly(.gguf)
                    try await LlamaEngine.shared.generate(
                        modelPath: modelPath,
                        history: history,
                        settings: settings,
                        reasoning: reasoning
                    ) { event in
                        _ = continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Drží načtený model mezi dotazy (načtení trvá sekundy) a běží mimo hlavní vlákno.
/// Kontext (KV cache) se vytváří pro každou odpověď znovu – jednodušší a robustní,
/// za cenu opětovného zpracování historie.
actor LlamaEngine {
    static let shared = LlamaEngine()

#if canImport(llama)
    private var model: OpaquePointer?
    private var loadedKey = ""
    /// Výsledek testu flash attention pro právě načtený model (viz `supportsFlashAttention`).
    private var flashAttention: Bool?
    /// Rozložení načteného modelu, když jsou jeho experti streamovaní z úložiště. nil = načtený normálně.
    private var streamedLayout: GGUFLayout?
    /// Předčítání expertů pro načtený model (jen při streamování). Musí žít déle než kontext.
    private var prefetcher: ExpertPrefetcher?
    /// Kontext (KV cache) se mezi odpověďmi drží naživu. Dřív se pro každou odpověď vytvářel
    /// znovu, takže se celá historie chatu pokaždé prefillovala od nuly – u streamovaného MoE
    /// to znamená přečíst z flash několik GB, než padne první slovo. Teď se dekódují jen
    /// tokeny za společným prefixem.
    private var context: OpaquePointer?
    /// Parametry, se kterými byl kontext vytvořen. Při změně se zahodí a udělá nový.
    private var contextSignature = ""
    /// Tokeny, které v KV cache leží – prompt i vygenerovaná odpověď, ve stejném pořadí.
    /// Musí přesně odpovídat tomu, co prošlo `llama_decode`, jinak se prefix spočítá špatně.
    private var cachedTokens: [llama_token] = []
    /// Bajty husté části přebalené do vlastní paměti – už se počítají do limitu appky.
    private var repackedBytes = 0
    /// Diagnostika v Konzoli: `subsystem:cz.aichat category:gguf`.
    private static let log = EngineLog(category: "gguf")

    init() {
        LlamaEngine.installLogBridge()
        llama_backend_init()
    }

    /// Přesměruje log llama.cpp/ggml do logu appky. Potřeba kvůli `GGML_SCHED_DEBUG`, jehož
    /// výpis jinak skončí na stderr, kam se u sideloadované appky nedostaneš.
    private static var logBridgeInstalled = false
    private static let logBridgeLock = NSLock()
    private static var logTail = ""
    /// Strop na počet přeposlaných řádků, aby diagnostika nezahltila log.
    private static var logBudget = 0

    private static func installLogBridge() {
        logBridgeLock.lock()
        defer { logBridgeLock.unlock() }
        guard !logBridgeInstalled else { return }
        logBridgeInstalled = true
        llama_log_set({ _, text, _ in
            guard let text else { return }
            LlamaEngine.forwardEngineLog(String(cString: text))
        }, nil)
    }

    /// llama.cpp posílá log po kouscích, ne po řádcích – text se skládá a posílá dál až celý.
    private static func forwardEngineLog(_ chunk: String) {
        logBridgeLock.lock()
        defer { logBridgeLock.unlock() }
        guard logBudget > 0 else { return }
        logTail += chunk
        while let newline = logTail.firstIndex(of: "\n") {
            let line = String(logTail[logTail.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
            logTail = String(logTail[logTail.index(after: newline)...])
            guard !line.isEmpty, logBudget > 0 else { continue }
            logBudget -= 1
            log.notice("ggml: \(line)")
        }
        if logTail.count > 4096 { logTail = "" }
    }

    private static func openLogBudget(_ lines: Int) {
        logBridgeLock.lock()
        logBudget = lines
        logTail = ""
        logBridgeLock.unlock()
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    /// Zahodí kontext i s KV cache. Kontext musí zmizet dřív než model, na kterém stojí.
    private func releaseContext() {
        if let context { llama_free(context) }
        context = nil
        contextSignature = ""
        cachedTokens = []
    }

    func unload() {
        releaseContext()
        if let model { llama_model_free(model) }
        model = nil
        loadedKey = ""
        flashAttention = nil
        streamedLayout = nil
        prefetcher = nil
        repackedBytes = 0
        LocalRuntime.reportStreaming(nil, placement: .cpuOnly, repackedBytes: 0)
    }

    func generate(
        modelPath: String,
        history: [ChatTurn],
        settings: LocalModelSettings,
        reasoning: Bool,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) throws {
        // Kolik z vah se po načtení objeví ve footprintu appky. S mmapem a bez offloadu
        // na Metal zůstanou váhy jako čisté stránky souboru a footprint nezvednou; při
        // offloadu je llama.cpp zkopíruje do Metal bufferů a ve footprintu jsou celé.
        // Rozpočet musí počítat jen tu část, která ve footprintu ještě není – jinak se
        // váhy odečtou dvakrát a nezbyde na kontext.
        let footprintBeforeLoad = MemoryBudget.footprint
        let model = try loadModel(path: modelPath, settings: settings)
        let residentWeights = max(0, MemoryBudget.footprint - footprintBeforeLoad)
        guard let vocab = llama_model_get_vocab(model) else {
            throw ProviderError.engine("Model neobsahuje slovník tokenů.")
        }

        let trainContext = Int(llama_model_n_ctx_train(model))
        let requested = max(512, trainContext > 0 ? min(settings.contextLength, trainContext) : settings.contextLength)
        // Kontext podle volné paměti – KV cache dlouhého kontextu by jinak appku shodila.
        // Měří se až po načtení modelu a po uvolnění kontextu z minulé odpovědi.
        // Váhy jsou namapované ze souboru (llama.cpp má use_mmap zapnuté), takže je
        // phys_footprint nevidí a `available` je hlásí jako volnou paměť. Fyzickou RAM
        // ale zabírají – bez tohoto odečtu by KV cache dlouhého kontextu váhy z RAM
        // vytlačila a každý token by se dočítal z flash (appka nespadne, jen se zadrhne).
        // Flash attention se musí zjistit dřív, než se počítá rozpočet: bez něj se při
        // prefillu materializuje matice skóre a ta zabere (dávka × hlavy × kontext × 4 B).
        let flash: Bool
        if let cached = flashAttention {
            flash = cached
        } else {
            flash = supportsFlashAttention(model, threads: settings.threads)
            flashAttention = flash
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath)
        let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        // Při streamování expertů v RAM pořád leží jen hustá část. Experti se do page cache
        // načítají a zase z ní vypadávají – kolik jich tam zůstane, rozhoduje rychlost, ne
        // stabilita. Rezerva pro ně je proto jen pevná pracovní sada, ne celý soubor, jinak
        // by 18GB model na kontext nedostal nic.
        // Přebalená část husté vrstvy už je v limitu appky (os_proc_available_memory ji odečetl),
        // do rezervy fyzické RAM se tedy nepočítá podruhé.
        let weights = streamedLayout.map {
            max(0, $0.denseBytes - repackedBytes) + min($0.expertBytes, Self.expertWorkingSet)
        } ?? fileSize
        // Kvantovaná KV cache se nabízí jen při streamování expertů: tam běží výpočet celý
        // na CPU, kde je ověřená. Na Metalu (běžné načtení modelu) dává nesmyslné odpovědi.
        // Bez flash attention ji llama.cpp neumí použít vůbec.
        let kvPrecision: KVCachePrecision = streamedLayout != nil && flash ? settings.ggufKVCache : .f16

        // Velikost dávky promptu. U streamovaného MoE nejde jen o výpočet: experti se čtou
        // jednou na dávku a na vrstvu, a počet vybraných expertů s velikostí dávky roste jen
        // do 128. Větší dávka proto znamená míň průchodů souborem, ne víc.
        // Měření (9232tokenový prompt, Qwen3-30B-A3B, k=6): při dávce 512 se prefill přečetl
        // 19× po 76 expertech na vrstvu = 188 GB. Při 2048 vyjdou zhruba 4 průchody a 83 GB.
        // Navíc se při skoro úplném výběru sousední experti slijí do jednoho souvislého čtení
        // celého tenzoru vrstvy, kde flash dává plnou propustnost místo rozházených řezů.
        // Platí se špičkou paměti výpočetních bufferů – ta se odečítá z rozpočtu níž.
        let promptBatch = streamedLayout != nil
            ? min(4096, max(512, settings.ggufPrefillBatch))
            : Self.prefillBatch

        // Prefill na GPU: scheduler zkopíruje tenzory expertů vrstvy do bufferu Metalu.
        // Velikost kopie nezávisí na dávce ani na `k` – kopíruje se celý tenzor, tedy všech
        // 128 expertů vrstvy. Rezerva je na dvě vrstvy: jedna se počítá, druhá se kopíruje.
        let gpuPrefill = streamedLayout != nil && settings.ggufGPUPrefill
        let gpuPrefillReserve = gpuPrefill
            ? 2 * (streamedLayout?.expertTensors.values
                .map { $0.reduce(0) { $0 + $1.bytes } }
                .max() ?? 0)
            : 0
        // Špička paměti jedné dávky promptu. Slouží dvakrát: jako rezerva při výpočtu délky
        // kontextu a jako práh pro zmenšování dávky za běhu (viz smyčka prefillu).
        let prefillPeak = computeReserve(model, batch: promptBatch) + gpuPrefillReserve

        // Všechno, co se musí shodovat, aby šel kontext z minulé odpovědi použít znovu.
        let signature = [
            "\(requested)", "\(flash)", kvPrecision.rawValue, "\(promptBatch)", "\(gpuPrefill)",
            "\(settings.ggufSchedDebug)",
            // Callback se instaluje jen při vytvoření kontextu – rozhoduje, jestli vůbec běží,
            // ne co dělá. Přepnutí záznamu při zapnutém předčítání kontext (a KV cache) nezahodí.
            "\(streamedLayout != nil)", "\(settings.prefetchExperts || settings.recordExpertTrace)"
        ].joined(separator: "|")
        if signature != contextSignature { releaseContext() }

        // Strop platí pro oba enginy: kdyby ho nastavoval jen MLX, zůstal by po přepnutí
        // na GGUF viset nastavený z minule.
        MemoryBudget.cap = max(0, settings.memoryCapMB) * 1_048_576
        // Rozpočet paměti se počítá jen při vytváření kontextu. U živého kontextu je
        // jeho KV cache už alokovaná, takže by `available` vyšla menší a délka by se
        // s každou odpovědí zkracovala – a kontext by se kvůli tomu pořád zahazoval.
        let contextLength: Int
        if let existing = context {
            contextLength = Int(llama_n_ctx(existing))
        } else {
            contextLength = MemoryBudget.maxContext(
                bytesPerToken: bytesPerToken(model, flashAttention: flash, kvPrecision: kvPrecision, batch: promptBatch),
                requested: requested,
                extraReserve: max(0, weights - residentWeights) + prefillPeak
            )
        }
        LocalRuntime.report(requested: requested, effective: contextLength)
        guard contextLength >= 512 else {
            let megabytes: (Int) -> String = { "\($0 / 1_048_576) MB" }
            throw ProviderError.engine("""
                Na odpověď nezbývá paměť. Váhy zabírají \(megabytes(residentWeights)), \
                zpracování promptu si vezme dalších \(megabytes(prefillPeak)) a do limitu \
                \(megabytes(MemoryBudget.appLimit)) zbývá \(megabytes(MemoryBudget.available)). \
                Zvedni strop paměti v Parametrech, zmenši dávku promptu, nebo vyber menší model.
                """)
        }
        let maxNewTokens = max(16, min(settings.maxTokens, contextLength / 2))

        // Přílohy se vloží do textu s odhadem ~3 znaky na token. Když se prompt i tak nevejde,
        // rozpočet příloh se zmenší podle skutečného počtu tokenů; pak se zahazují nejstarší výměny.
        let available = contextLength - maxNewTokens
        let hasFiles = history.contains { !$0.attachments.isEmpty }
        var budget = max(1_000, available * 3 - settings.systemPrompt.count)
        var turns = ChatTurn.inliningAttachments(history, characterBudget: budget, carriedShare: 0.35)
        var tokens: [llama_token] = []
        var renderedPrompt = ""
        while true {
            var prompt = formatPrompt(model: model, system: settings.systemPrompt, turns: turns)
            if !reasoning { prompt = suppressThinking(in: prompt, model: model) }
            renderedPrompt = prompt
            tokens = tokenize(vocab: vocab, text: prompt)
            if tokens.count <= available { break }
            if hasFiles, budget > 1_000 {
                budget = max(1_000, Int(Double(budget) * Double(available) / Double(tokens.count) * 0.9))
                turns = ChatTurn.inliningAttachments(history, characterBudget: budget, carriedShare: 0.35)
                continue
            }
            if turns.count <= 1 { break }
            turns.removeFirst(min(2, turns.count - 1))
        }
        // Když se prompt pořád nevejde, zkrátí se text poslední výměny a šablona se vykreslí
        // znovu. Dřív se tu ořezávalo `tokens.suffix(...)`, jenže tím z promptu zmizela
        // hlavička šablony (`<|im_start|>system…`) a model dostal text začínající uprostřed
        // věty – odpovídal pak nesmysly. Šablona teď zůstane vždy celá.
        var truncated = false
        var shrinks = 0
        while tokens.count > available, shrinks < 4, let last = turns.last, last.text.count > 200 {
            shrinks += 1
            truncated = true
            let ratio = Double(available) / Double(tokens.count) * 0.9
            let keep = max(200, Int(Double(last.text.count) * ratio))
            turns[turns.count - 1] = last.prefixed(characters: keep)
            var prompt = formatPrompt(model: model, system: settings.systemPrompt, turns: turns)
            if !reasoning { prompt = suppressThinking(in: prompt, model: model) }
            renderedPrompt = prompt
            tokens = tokenize(vocab: vocab, text: prompt)
        }
        guard !tokens.isEmpty else { throw ProviderError.engine("Prázdný prompt.") }

        // Když model odpovídá nesmysly, tohle ukáže proč: konec promptu musí být hlavička
        // asistenta podle šablony (u Qwen 3 bez přemýšlení `<|im_start|>assistant\n<think>\n\n</think>`).
        let expertPlacement = streamedLayout == nil ? "v RAM" : "z úložiště"
        Self.log.notice("""
            kontext \(contextLength) · KV \(kvPrecision.rawValue) · FA \(flash ? "ano" : "ne") · přemýšlení \(reasoning ? "zap" : "vyp") \
            · experti \(expertPlacement) · dávka \(promptBatch)\(gpuPrefill ? " (prefill na GPU)" : "") · vlákna \(settings.threads)\
            \(settings.effectiveThreadsBatch != settings.threads ? " (prompt \(settings.effectiveThreadsBatch))" : "") \
            · prompt \(tokens.count) tokenů\(truncated ? " (zkrácen)" : "")
            """)
        Self.log.debug("konec promptu: \(String(renderedPrompt.suffix(200)))")

        // Přesný počet tokenů z tokenizéru modelu.
        var usage = TokenUsage(
            promptTokens: tokens.count,
            outputTokens: 0,
            contextWindow: contextLength,
            maxOutputTokens: maxNewTokens,
            droppedHistory: truncated || turns.count < history.count
        )
        onEvent(.usage(usage))

        // Callback běží i s vypnutým předčítáním, když se zaznamenává trace – pak jen měří
        // a zapisuje výběr routeru, nic nečte.
        let activePrefetcher = settings.prefetchExperts || settings.recordExpertTrace ? prefetcher : nil
        prefetcher?.setTracing(activePrefetcher != nil && settings.recordExpertTrace)
        activePrefetcher?.readEnabled = settings.prefetchExperts
        // Záznam na disk i při zrušení nebo chybě – useknutá odpověď je pořád platná trace.
        defer { activePrefetcher?.flushTrace() }
        activePrefetcher?.splitOnly = settings.prefetchSplitOnly
        activePrefetcher?.prefaultPages = settings.prefaultPages
        activePrefetcher?.waveBytes = settings.prefetchWaveMB * 1_048_576
        let waveNote = settings.prefaultPages && settings.prefetchWaveMB > 0
            ? " po \(settings.prefetchWaveMB) MB" : ""
        let traceNote = settings.recordExpertTrace && activePrefetcher != nil ? " · záznam expertů" : ""
        let prefetchMode = (activePrefetcher == nil || !settings.prefetchExperts ? "vyp"
            : settings.prefetchSplitOnly ? "jen dělení grafu"
            : settings.prefaultPages ? "zap + mapování stránek" + waveNote : "zap") + traceNote
        _ = activePrefetcher?.takeStats()

        // Diagnostika dělení grafu mezi CPU a GPU. `ggml_backend_sched` si proměnnou čte při
        // vytvoření, tedy při vytvoření kontextu – proto se nastavuje tady a je v signatuře.
        // Počet splitů je hlavní podezřelý u prefillu na GPU: každý split je synchronizace,
        // a při 48 vrstvách jich může být na jednu dávku hodně.
        setenv("GGML_SCHED_DEBUG", settings.ggufSchedDebug ? "1" : "0", 1)
        if settings.ggufSchedDebug { Self.openLogBudget(400) }

        if context == nil {
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = UInt32(contextLength)
            // Prompt se zpracovává po dávkách `promptBatch`, ne celý najednou. Dávka musí být
            // i `n_ubatch`: samotné `n_batch` by práci stejně rozdělilo po `n_ubatch` a počet
            // průchodů experty by se nezměnil. Zdůvodnění velikosti viz `promptBatch` výš.
            contextParams.n_batch = UInt32(promptBatch)
            contextParams.n_ubatch = UInt32(promptBatch)
            contextParams.n_threads = Int32(settings.threads)
            contextParams.n_threads_batch = Int32(settings.effectiveThreadsBatch)
            // Flash attention: bez něj se materializuje matice skóre (dávka × hlavy × kontext × 4 B)
            // a kvantovaná KV cache navíc vůbec nejde použít.
            // Přesnost KV cache řídí `kvPrecision` výše: f16 všude kromě streamovaného MoE,
            // kde se dá zapnout q8 a uvolnit tím fyzickou RAM pro page cache expertů.
            // Flash attention se nastaví natvrdo podle testu, ne přes AUTO: rozpočet paměti
            // se od toho odvíjí a musí odpovídat tomu, co se doopravdy spustí.
            contextParams.flash_attn_type = flash ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED
            contextParams.type_k = Self.cacheType(kvPrecision)
            contextParams.type_v = Self.cacheType(kvPrecision)
            // Odesílání operací na Metal, i když váhy leží na CPU. Scheduler to dělá jen pro
            // dávky od 32 tokenů, takže se to týká prefillu, ne generování (dávka 1) – přesně
            // to dělení, které chceme: prefill je compute-bound (~77 GFLOPS na třech jádrech),
            // generování bandwidth-bound, kde by kopie na GPU jen ubíraly.
            // Cena je paměť: tenzory expertů vrstvy se kopírují do bufferu GPU a ta paměť se
            // počítá do limitu appky. Proto je to volitelné a rozpočet se o ni krátí níž.
            contextParams.op_offload = streamedLayout == nil || settings.ggufGPUPrefill
            activePrefetcher?.install(into: &contextParams)
            guard let created = llama_init_from_model(model, contextParams) else {
                throw ProviderError.engine("Nepodařilo se vytvořit kontext. Zkus menší délku kontextu.")
            }
            context = created
            contextSignature = signature
            cachedTokens = []
        }
        guard let context else {
            throw ProviderError.engine("Kontext není k dispozici.")
        }
        // Vlákna se mění za běhu, ne přes nový kontext – ten by zahodil KV cache
        // s celou historií chatu. Každý režim tak může mít vlastní počet vláken.
        llama_set_n_threads(context, Int32(settings.threads), Int32(settings.effectiveThreadsBatch))

        let sampler = makeSampler(vocab: vocab, settings: settings)
        defer { llama_sampler_free(sampler) }

        // 1) Zpracování promptu po dávkách. Pozice si llama.cpp doplní sama podle stavu
        // sekvence, takže stačí posílat souvislé kusy za sebou.
        //
        // Dekóduje se jen to, co v KV cache ještě neleží. U navazující zprávy je společný
        // prefix celá dosavadní historie včetně minulé odpovědi, takže zbyde posledních
        // pár desítek tokenů. Poslední token promptu se ale dekóduje vždy znovu – z jeho
        // logitů se vzorkuje první token odpovědi.
        let reused = min(Self.commonPrefix(cachedTokens, tokens), tokens.count - 1)
        if reused < cachedTokens.count {
            // Co je za společným prefixem, už neplatí (jiná větev konverzace, zkrácená
            // historie, přepsaná zpráva) – KV cache se od té pozice zahodí.
            llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(reused), -1)
            cachedTokens.removeLast(cachedTokens.count - reused)
        }

        var cancelledDuringPrefill = false
        var promptStatus: Int32 = 0
        let prefillStart = Date.now
        let prefillPages = MemoryBudget.PageCounters.now
        // Pojistka proti jetsamu. Dávka se do parametrů kontextu zapsala při jeho vytvoření,
        // ale jednotlivé `llama_decode` smí dostat míň tokenů, než je `n_ubatch` – zmenšení
        // za běhu tedy nevyžaduje nový kontext. Volná paměť se mezi odpověďmi mění (jiné
        // appky, delší KV cache), takže se kontroluje před každou dávkou.
        //
        // Pozor na hranici toho, co to umí: zmenšení dávky srazí výpočetní buffery, které
        // rostou lineárně s počtem tokenů. Kopie tenzorů expertů do bufferu GPU při zapnutém
        // prefillu na GPU jsou na velikosti dávky nezávislé – na ty tahle pojistka nestačí
        // a jediná obrana je GPU prefill vypnout.
        var batchLimit = promptBatch
        var shrunk = false
        tokens.withUnsafeMutableBufferPointer { buffer in
            var offset = reused
            while offset < buffer.count {
                if Task.isCancelled {
                    cancelledDuringPrefill = true
                    return
                }
                if settings.adaptivePrefill, batchLimit > Self.minPrefillBatch {
                    let free = MemoryBudget.available
                    // 0 = simulátor, tam se limit nedá zjistit a nemá se podle čeho řídit.
                    while free > 0, free < prefillPeak + Self.prefillHeadroom, batchLimit > Self.minPrefillBatch {
                        batchLimit = max(Self.minPrefillBatch, batchLimit / 2)
                        shrunk = true
                    }
                }
                let size = min(batchLimit, buffer.count - offset)
                let batch = llama_batch_get_one(buffer.baseAddress! + offset, Int32(size))
                let status = llama_decode(context, batch)
                if status != 0 {
                    promptStatus = status
                    return
                }
                cachedTokens.append(contentsOf: buffer[offset..<(offset + size)])
                offset += size
            }
        }
        if shrunk {
            Self.log.notice("málo volné paměti – dávka promptu zmenšena na \(batchLimit) tokenů")
        }
        guard promptStatus == 0 else {
            // Po chybě dekódování nevíme, co v KV cache zůstalo – kontext se zahodí celý.
            releaseContext()
            throw ProviderError.engine("Zpracování promptu selhalo (kód \(promptStatus)).")
        }
        if cancelledDuringPrefill {
            Self.log.notice("prefill zrušen po \(Self.decimal(Date.now.timeIntervalSince(prefillStart))) s")
            onEvent(.usage(usage))
            return
        }
        let prefillSeconds = Date.now.timeIntervalSince(prefillStart)
        let decoded = tokens.count - reused
        let reusedNote = reused > 0 ? " · \(reused) tokenů z KV cache" : ""
        Self.log.notice("prefill \(decoded) z \(tokens.count) tokenů za \(Self.decimal(prefillSeconds)) s" + reusedNote)
        Self.logPages("prefill", MemoryBudget.PageCounters.now.since(prefillPages), tokens: max(1, decoded))
        if let stats = activePrefetcher?.takeStats() {
            if settings.prefetchExperts, !settings.prefetchSplitOnly {
                Self.logPrefetch("prefill", stats, total: prefillSeconds)
            }
            Self.logResidency("prefill", stats)
        }
        let decodeStart = Date.now
        let decodePages = MemoryBudget.PageCounters.now

        // 2) Generování po jednom tokenu.
        var pendingBytes: [UInt8] = []
        var parser = ThinkTagParser()
        let onToken: (String) -> Void = { text in parser.feed(text).forEach(onEvent) }
        var position = tokens.count
        for _ in 0..<maxNewTokens {
            if Task.isCancelled { break }

            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                if usage.outputTokens == 0 {
                    // Bez tohohle appka prázdnou odpověď potichu smaže a nic nevysvětlí.
                    let first = token
                    let name = String(decoding: piece(vocab: vocab, token: first), as: UTF8.self)
                    Self.log.error("model ukončil odpověď hned prvním tokenem \(first) (\(name))")
                    throw ProviderError.engine("""
                        Model odpověď ukončil hned prvním tokenem („\(name)“). \
                        Prompt měl \(tokens.count) tokenů, zpracování trvalo \(String(format: "%.1f", prefillSeconds)) s. \
                        Nejčastěji to znamená nesedící šablonu promptu nebo poškozený výpočet.
                        """)
                }
                break
            }
            usage.outputTokens += 1
            if usage.outputTokens % 16 == 0 { onEvent(.usage(usage)) }

            // Token může obsahovat jen část vícebajtového znaku (č, ř, emoji…).
            pendingBytes.append(contentsOf: piece(vocab: vocab, token: token))
            if let text = String(bytes: pendingBytes, encoding: .utf8) {
                if !text.isEmpty { onToken(text) }
                pendingBytes.removeAll(keepingCapacity: true)
            } else if pendingBytes.count > 8 {
                onToken(String(decoding: pendingBytes, as: UTF8.self))
                pendingBytes.removeAll(keepingCapacity: true)
            }

            if position >= contextLength { break }
            let status = withUnsafeMutablePointer(to: &token) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard status == 0 else {
                releaseContext()
                throw ProviderError.engine("Generování selhalo (kód \(status)).")
            }
            cachedTokens.append(token)
            position += 1
        }
        if !pendingBytes.isEmpty {
            onToken(String(decoding: pendingBytes, as: UTF8.self))
        }
        parser.flush().forEach(onEvent)
        onEvent(.usage(usage))
        if usage.outputTokens > 0 {
            let seconds = Date.now.timeIntervalSince(decodeStart)
            let rate = seconds > 0 ? Double(usage.outputTokens) / seconds : 0
            Self.log.notice("""
                generování \(usage.outputTokens) tokenů za \(Self.decimal(seconds)) s \
                (\(Self.decimal(rate, digits: 2)) tok/s) · předčítání \(prefetchMode)
                """)
            Self.logPages("generování", MemoryBudget.PageCounters.now.since(decodePages), tokens: usage.outputTokens)
            if let stats = activePrefetcher?.takeStats() {
                Self.logResidency("generování", stats)
                if !settings.prefetchExperts {
                    // Callback běží jen kvůli záznamu – předčítání není co hlásit.
                } else if settings.prefetchSplitOnly {
                    Self.log.notice("graf rozdělen \(stats.layers)× (\(usage.outputTokens > 0 ? stats.layers / usage.outputTokens : 0)× na token), experti se nečetli")
                } else {
                    Self.logPrefetch("generování", stats, total: seconds)
                }
            }
        }
    }

    private static func logPrefetch(_ phase: String, _ stats: ExpertPrefetcher.Stats, total: Double) {
        let megabytes = stats.bytes / 1_048_576
        let share = total > 0 ? stats.seconds / total * 100 : 0
        log.notice("""
            \(phase): předčteno \(stats.experts) expertů ve \(stats.layers) vrstvách, \
            \(megabytes) MB za \(decimal(stats.seconds)) s \
            (\(decimal(share, digits: 0)) % z \(decimal(total)) s)
            """)
    }

    /// Zásah page cache expertů změřený před předčtením (jen se zapnutým záznamem trace).
    /// „Rezidentní“ znamená, že expert ležel v cache celý – co dotáhlo až předčítání, se
    /// nepočítá, stejně jako „TRUE resident hit rate“ v kimi-k3-in-c.
    private static func logResidency(_ phase: String, _ stats: ExpertPrefetcher.Stats) {
        guard stats.measuredExperts > 0 else { return }
        let hitRate = Double(stats.residentExperts) / Double(stats.measuredExperts) * 100
        let byteRate = stats.measuredBytes > 0 ? Double(stats.residentBytes) / Double(stats.measuredBytes) * 100 : 0
        log.notice("""
            \(phase): zásah cache expertů \(decimal(hitRate, digits: 1)) % \
            (\(stats.residentExperts) z \(stats.measuredExperts) celých v RAM, \
            \(decimal(byteRate, digits: 0)) % bajtů) · měření \(decimal(stats.measuredSeconds * 1_000, digits: 0)) ms
            """)
    }

    /// Výpadky stránek za fázi: celkem, z nich s čtením z úložiště, a přepočet na token.
    /// 16kB stránka – 1 GB expertů = ~65 000 stránek.
    private static func logPages(_ phase: String, _ pages: MemoryBudget.PageCounters, tokens: Int) {
        let mappedOnly = max(0, pages.faults - pages.pageins)
        let perToken = tokens > 0 ? " · na token \(pages.faults / tokens) výpadků, \(pages.pageins / tokens) načtení" : ""
        log.notice("\(phase): výpadky stránek \(pages.faults) (z úložiště \(pages.pageins), jen mapování \(mappedOnly))\(perToken) · RAM appky \(MemoryBudget.resident / 1_048_576) MB")
    }

    private static func decimal(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// Vypnutí přemýšlení u modelů, jejichž šablona zná `<think>` (Qwen 3, DeepSeek R1 …):
    /// za začátek odpovědi se vloží prázdný blok přemýšlení – stejně to dělá šablona Qwen 3
    /// s `enable_thinking=false`. U ostatních modelů se prompt nemění.
    private func suppressThinking(in prompt: String, model: OpaquePointer) -> String {
        guard let template = llama_model_chat_template(model, nil).map({ String(cString: $0) }),
              template.contains("<think>") else { return prompt }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Samotná zmínka `<think>` v šabloně nestačí. Qwen3-Instruct-2507 převzal šablonu
        // z přemýšlejících Qwen 3 (kvůli historii), ale přemýšlet neumí a `enable_thinking`
        // nezná – vložený prázdný blok je pro něj cizí a model může odpověď hned ukončit.
        // Potlačuje se tedy jen tam, kde šablona přepínač zná (Qwen 3, Qwen 3.5), nebo
        // přemýšlení sama otevírá na konci promptu (DeepSeek R1).
        guard template.contains("enable_thinking") || trimmed.hasSuffix("<think>") else { return prompt }
        return trimmed.hasSuffix("<think>")
            ? prompt + "\n\n</think>\n\n"
            : prompt + "<think>\n\n</think>\n\n"
    }

    // MARK: - Paměť

    /// Velikost dávky při zpracování promptu (tokeny).
    static let prefillBatch = 512
    /// Pod tuhle dávku se prefill nezmenšuje – menší už nic neušetří a jen přidá průchody
    /// experty (experti se čtou jednou na dávku a vrstvu).
    static let minPrefillBatch = 512
    /// Rezerva nad špičku jedné dávky, při které se dávka začne zmenšovat.
    static let prefillHeadroom = 384 * 1_048_576

    /// Délka společného prefixu uložených a nových tokenů.
    private static func commonPrefix(_ cached: [llama_token], _ prompt: [llama_token]) -> Int {
        var index = 0
        let limit = min(cached.count, prompt.count)
        while index < limit, cached[index] == prompt[index] { index += 1 }
        return index
    }

    /// Typ tenzoru KV cache podle nastavené přesnosti.
    private static func cacheType(_ precision: KVCachePrecision) -> ggml_type {
        switch precision {
        case .f16: GGML_TYPE_F16
        case .q8: GGML_TYPE_Q8_0
        case .q4: GGML_TYPE_Q4_0
        }
    }

    /// Kolik fyzické RAM se při streamování nechá expertům v page cache, než se začne
    /// ubírat z kontextu. Víc = méně čtení z flash u opakujících se témat, míň = delší kontext.
    static let expertWorkingSet = 1_536 * 1_048_576

    /// Vzor tenzorů expertů jako C řetězec – llama.cpp si ukazatel drží během načítání.
    nonisolated(unsafe) private static let expertPatternC: UnsafePointer<CChar> = UnsafePointer(strdup(GGUFLayout.expertPattern)!)

    /// Paměť na jeden token kontextu: KV cache ve f16 (klíče + hodnoty) a pracovní matice
    /// pozornosti (dávka × hlavy × 4 B) jako rezerva pro případ, že flash attention
    /// nenaskočí. S délkou kontextu rostou jen vrstvy s plnou pozorností – sliding-window
    /// vrstvy (Gemma) drží jen okno, rekurentní (Mamba, Qwen 3.5) žádnou KV cache.
    /// Jejich poměr GGUF neuvádí, proto opatrný odhad.
    private func bytesPerToken(_ model: OpaquePointer, flashAttention: Bool, kvPrecision: KVCachePrecision, batch: Int) -> Int {
        var layers = Int(llama_model_n_layer(model))
        if llama_model_is_recurrent(model) {
            layers = 0
        } else if llama_model_is_hybrid(model) {
            layers = max(1, layers / 4)
        } else if llama_model_n_swa(model) > 0 {
            layers = max(1, layers / 2)
        }
        let heads = max(1, Int(llama_model_n_head(model)))
        let kvHeads = max(1, Int(llama_model_n_head_kv(model)))
        let embedding = Int(llama_model_n_embd(model))
        let architecture = metadata(model, key: "general.architecture") ?? ""
        let keyLength = metadata(model, key: "\(architecture).attention.key_length").flatMap { Int($0) } ?? embedding / heads
        let valueLength = metadata(model, key: "\(architecture).attention.value_length").flatMap { Int($0) } ?? keyLength
        let cache = Int((Double(layers * kvHeads * (keyLength + valueLength)) * kvPrecision.bytesPerValue).rounded(.up))
        // Fúzované jádro matici skóre nikdy nevytvoří, takže s flash attention je paměť
        // prefillu nezávislá na délce kontextu. Bez něj se počítá s plnou maticí.
        let attention = flashAttention ? 0 : batch * heads * 4
        return cache + attention
    }

    /// Odhad špičky výpočetních bufferů pro jednu dávku promptu. Rostou lineárně s dávkou:
    /// mezivýsledky vrstvy (několik tenzorů `dávka × n_embd` ve f32) a u MoE navíc
    /// `dávka × aktivních expertů × velikost FFN`. Bez tohoto odečtu by se u velkých dávek
    /// délka kontextu nadhodnotila a appku by při dlouhém promptu ukončil jetsam.
    private func computeReserve(_ model: OpaquePointer, batch: Int) -> Int {
        let embedding = Int(llama_model_n_embd(model))
        let architecture = metadata(model, key: "general.architecture") ?? ""
        let expertUsed = metadata(model, key: "\(architecture).expert_used_count").flatMap { Int($0) } ?? 0
        let expertFFN = metadata(model, key: "\(architecture).expert_feed_forward_length").flatMap { Int($0) }
            ?? metadata(model, key: "\(architecture).feed_forward_length").flatMap { Int($0) } ?? 0
        // Zhruba deset mezivýsledků vrstvy ve f32 plus MoE mezivrstva.
        let dense = batch * embedding * 4 * 10
        let moe = batch * max(expertUsed, 1) * expertFFN * 4
        return dense + moe + 64 * 1_048_576
    }

    private func metadata(_ model: OpaquePointer, key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(min(Int(length), buffer.count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Model

    /// Umí backend pro tenhle model flash attention? `AUTO` si rozhodne sám, ale výsledek
    /// nijak nevrací – a bez té informace se nedá spočítat paměť na token. Zjistí se proto
    /// krátkým testovacím kontextem (512 tokenů), který se hned zahodí; stojí pár
    /// milisekund a výsledek se drží po celou dobu, co je model načtený.
    private func supportsFlashAttention(_ model: OpaquePointer, threads: Int) -> Bool {
        var probe = llama_context_default_params()
        probe.n_ctx = 512
        probe.n_batch = 512
        probe.n_ubatch = 512
        probe.n_threads = Int32(threads)
        probe.n_threads_batch = Int32(threads)
        probe.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        probe.type_k = GGML_TYPE_F16
        probe.type_v = GGML_TYPE_F16
        guard let context = llama_init_from_model(model, probe) else { return false }
        llama_free(context)
        return true
    }

    private func loadModel(path: String, settings: LocalModelSettings) throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProviderError.engine("Soubor modelu nebyl nalezen.")
        }
        let layout = settings.streamExperts ? GGUFLayout.read(path: path) : nil
        let stream = layout?.isMoE == true

        // Kde běží výpočet u streamovaného MoE. Měření na iPhonu (Qwen3-30B-A3B, 8 GB RAM):
        // jen CPU 3,3 tok/s, CPU + GPU 1,6–1,9 tok/s – střídání CPU a GPU ve 48 vrstvách
        // na token stojí víc, než GPU ušetří. GPU je proto jen volba pro pokusy, a i pak
        // jen u souboru s hustou částí pohromadě (jinak by Metal držel v RAM celý soubor,
        // viz `GGUFLayout.gpuTensorsContiguous`).
        let placement: StreamingPlacement
        if !stream {
            placement = .cpuOnly
        } else if !settings.streamingGPU || settings.gpuLayers == 0 {
            placement = .cpuOnly
        } else if layout?.gpuTensorsContiguous == false {
            placement = .cpuOnlyInterleaved
        } else {
            placement = .hybrid
        }
        let effectiveGPULayers = stream && placement != .hybrid ? 0 : settings.gpuLayers

        // Hustou část na CPU přebalit pro rychlejší ARM jádra (i8mm/dotprod). Experti zůstanou
        // v mmapu – přebalení by je zkopírovalo do paměti.
        let repack = stream && effectiveGPULayers == 0 && settings.repackDense
            ? Self.repackPlan(layout)
            : nil

        // Kolik expertů smí router vybrat. Objem čtení z úložiště je na tom lineárně závislý,
        // takže je to největší páka na rychlost, kterou lze otočit bez překvantování modelu.
        // Přepisuje se jen dolů a jen u streamovaného MoE – zvyšovat nad hodnotu z metadat
        // nemá smysl (model je trénovaný na své top-k) a u modelu v RAM to nic neušetří.
        let expertUsed = Self.expertUsedOverride(settings: settings, layout: layout, streaming: stream)

        let key = "\(path)|\(effectiveGPULayers)|\(stream)|\(repack?.matrices.count ?? 0)|\(expertUsed ?? 0)"
        if let model, key == loadedKey { return model }
        unload()

        var params = llama_model_default_params()
        params.n_gpu_layers = Int32(clamping: effectiveGPULayers)
        // Váhy vždy přes mmap – na tom streamování stojí: experti zůstanou clean stránky
        // souboru, které jádro načítá z flash a při nedostatku paměti zase zahodí.
        // (llama.cpp při CPU override doporučuje --load-mode none; to platí pro servery
        // s dostatkem RAM, tady by to znamenalo zkopírovat 17 GB do paměti.)
        params.load_mode = LLAMA_LOAD_MODE_MMAP

        // Pole končí prázdným klíčem; ukazatel musí žít po celou dobu načítání.
        var kvOverrides: [llama_model_kv_override] = []
        if let expertUsed, let layout, !layout.architecture.isEmpty {
            kvOverrides.append(Self.intOverride(key: "\(layout.architecture).expert_used_count", value: Int64(expertUsed)))
            kvOverrides.append(llama_model_kv_override())
        }

        let hasKVOverrides = !kvOverrides.isEmpty
        let loaded: OpaquePointer? = kvOverrides.withUnsafeBufferPointer { kvBuffer -> OpaquePointer? in
            params.kv_overrides = hasKVOverrides ? kvBuffer.baseAddress : nil
            if stream {
                // Automatický výběr extra buffer typů by přebalil i experty (17 GB do paměti).
                // Vypnout ho a přebalení husté části zadat ručně po jednotlivých tenzorech.
                params.use_extra_bufts = false

                // Pozor: override na `ggml_backend_cpu_buffer_type()` si llama.cpp převede zpátky na
                // automatický výběr CPU bufferu – proto musí být extra buffery vypnuté (výše), jinak
                // by se experti přebalili i přes override.
                var patterns: [UnsafeMutablePointer<CChar>] = []
                defer { patterns.forEach { free($0) } }
                var overrides = [llama_model_tensor_buft_override(pattern: Self.expertPatternC, buft: ggml_backend_cpu_buffer_type())]
                if let repack {
                    for matrix in repack.matrices {
                        let escaped = "^" + NSRegularExpression.escapedPattern(for: matrix.name) + "$"
                        guard let pattern = strdup(escaped) else { continue }
                        patterns.append(pattern)
                        overrides.append(llama_model_tensor_buft_override(pattern: UnsafePointer(pattern), buft: repack.bufferType))
                    }
                }
                overrides.append(llama_model_tensor_buft_override(pattern: nil, buft: nil))
                return overrides.withUnsafeBufferPointer { buffer in
                    params.tensor_buft_overrides = buffer.baseAddress
                    return llama_model_load_from_file(path, params)
                }
            } else {
                return llama_model_load_from_file(path, params)
            }
        }
        guard let loaded else {
            throw ProviderError.engine("Model se nepodařilo načíst. Je to platný GGUF a vejde se do paměti telefonu?")
        }
        model = loaded
        loadedKey = key
        // Rozhoduje se při překladu llama.cpp – oficiální XCFramework pro iOS tyhle instrukce nemá.
        Self.log.notice("""
            llama.cpp CPU: dotprod \(ggml_cpu_has_dotprod() != 0 ? "ano" : "ne") · \
            i8mm \(ggml_cpu_has_matmul_int8() != 0 ? "ano" : "ne")
            """)
        streamedLayout = stream ? layout : nil
        prefetcher = stream ? layout.flatMap { ExpertPrefetcher(path: path, layout: $0) } : nil
        if let expertUsed { prefetcher?.activeExperts = expertUsed }
        repackedBytes = repack?.matrices.reduce(0) { $0 + $1.bytes } ?? 0
        LocalRuntime.reportStreaming(
            streamedLayout,
            placement: placement,
            repackedBytes: repackedBytes,
            expertUsed: expertUsed ?? layout?.expertUsed ?? 0
        )
        if let layout, stream {
            let placementNote = switch placement {
            case .cpuOnly: "jen CPU"
            case .cpuOnlyInterleaved: "jen CPU (GPU zapnuté v nastavení, ale tenzory nejsou pohromadě)"
            case .hybrid: "CPU + GPU"
            }
            let repackNote = repack.map { "přebaleno \($0.matrices.count) matic husté části (\(repackedBytes / 1_048_576) MB)" }
                ?? (settings.repackDense && effectiveGPULayers == 0 ? "přebalení nedostupné (llama.cpp bez dotprod/i8mm nebo nevhodné kvantizace)" : "bez přebalení")
            Self.log.notice("""
                streamování expertů: v RAM \(layout.denseBytes / 1_048_576) MB, \
                z úložiště \(layout.expertBytes / 1_048_576) MB \
                (\(expertUsed ?? layout.expertUsed) z \(layout.expertCount) expertů na vrstvu\(expertUsed != nil ? ", sníženo z \(layout.expertUsed)" : "")) · \
                \(placementNote) · \(repackNote)
                """)
        }
        return loaded
    }

    /// Na kolik expertů na vrstvu se má model omezit. nil = nechat hodnotu z metadat.
    private static func expertUsedOverride(settings: LocalModelSettings, layout: GGUFLayout?, streaming: Bool) -> Int? {
        guard streaming, let layout, layout.expertUsed > 1, !layout.architecture.isEmpty else { return nil }
        let requested = settings.expertsPerToken
        guard requested > 0, requested < layout.expertUsed else { return nil }
        return requested
    }

    /// Celočíselný přepis metadat GGUF pro `llama_model_params.kv_overrides`.
    ///
    /// Hodnota leží v anonymní unii na konci struktury (`val_i64` / `val_f64` / `val_bool`
    /// / `val_str[128]`). Anonymní unie nemá ve Swiftu stabilní jméno – podle pořadí pole
    /// by z ní bylo `__Unnamed_union___Anonymous_fieldN` a při aktualizaci llama.cpp by se
    /// to tiše rozbilo. Zapisuje se proto podle rozložení v paměti: unie je posledních
    /// 128 bajtů struktury (velikost `val_str`) a `val_i64` leží na jejím začátku.
    private static func intOverride(key: String, value: Int64) -> llama_model_kv_override {
        var override = llama_model_kv_override()
        override.tag = LLAMA_KV_OVERRIDE_TYPE_INT
        withUnsafeMutableBytes(of: &override.key) { raw in
            raw.copyBytes(from: key.utf8.prefix(raw.count - 1))
        }
        withUnsafeMutableBytes(of: &override) { raw in
            raw.storeBytes(of: value, toByteOffset: raw.count - 128, as: Int64.self)
        }
        return override
    }

    /// Které matice husté části přebalit a do jakého bufferu. nil = nic k přebalení
    /// (build bez CPU_REPACK, CPU bez potřebných instrukcí, nevhodné kvantizace).
    private static func repackPlan(_ layout: GGUFLayout?) -> (bufferType: ggml_backend_buffer_type_t, matrices: [GGUFLayout.DenseMatrix])? {
        guard let layout, let bufferType = repackBufferType() else { return nil }
        let matrices = layout.denseMatrices.filter(canRepack)
        return matrices.isEmpty ? nil : (bufferType, matrices)
    }

    /// Buffer typ „CPU_REPACK“ z extra bufferů CPU zařízení (veřejné API přes proc address).
    private static func repackBufferType() -> ggml_backend_buffer_type_t? {
        guard let device = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU),
              let registry = ggml_backend_dev_backend_reg(device),
              let address = ggml_backend_reg_get_proc_address(registry, "ggml_backend_dev_get_extra_bufts") else {
            return nil
        }
        typealias GetExtraBuffers = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<OpaquePointer?>?
        let getExtraBuffers = unsafeBitCast(address, to: GetExtraBuffers.self)
        guard var cursor = getExtraBuffers(device) else { return nil }
        while let bufferType = cursor.pointee {
            if let name = ggml_backend_buft_name(bufferType), String(cString: name) == "CPU_REPACK" {
                return bufferType
            }
            cursor += 1
        }
        return nil
    }

    /// Zrcadlí `ggml_repack_get_optimal_repack_type` (ggml-cpu/repack.cpp, b10894) pro ARM.
    /// Musí sedět přesně: tenzor v repack bufferu, pro který repack nemá jádro, by při
    /// načítání spadl na nulovém ukazateli.
    private static func canRepack(_ matrix: GGUFLayout.DenseMatrix) -> Bool {
        guard ggml_cpu_has_neon() != 0 else { return false }
        let int8 = ggml_cpu_has_matmul_int8() != 0
        let dotprod = ggml_cpu_has_dotprod() != 0
        switch matrix.type {
        case GGML_TYPE_Q4_K.rawValue, GGML_TYPE_Q5_K.rawValue, GGML_TYPE_Q6_K.rawValue:
            return (int8 || dotprod) && matrix.rows % 8 == 0
        case GGML_TYPE_Q8_0.rawValue:
            return (int8 || dotprod) && matrix.rows % 4 == 0
        case GGML_TYPE_IQ4_NL.rawValue:
            return dotprod && matrix.rows % 4 == 0
        default:
            return false
        }
    }

    private func makeSampler(vocab: OpaquePointer, settings: LocalModelSettings) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!

        if settings.repeatPenalty != 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab),
                Int32(settings.repeatLastN),
                Float(settings.repeatPenalty),
                0,
                0
            ))
        }

        if settings.temperature <= 0.001 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if settings.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(settings.topK))) }
            if settings.topP < 1 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(settings.topP), 1)) }
            if settings.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(settings.minP), 1)) }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(settings.temperature)))
            let seed = settings.useRandomSeed
                ? UInt32.random(in: 0..<UInt32.max)
                : UInt32(truncatingIfNeeded: settings.seed)
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        }
        return chain
    }

    // MARK: - Text ↔ tokeny

    /// Použije chat šablonu uloženou v GGUF souboru; když ji llama.cpp nezná, spadne na ChatML.
    private func formatPrompt(model: OpaquePointer, system: String, turns: [ChatTurn]) -> String {
        var entries: [(role: String, content: String)] = []
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(("system", system))
        }
        entries += turns.map { (role: $0.role == .user ? "user" : "assistant", content: $0.text) }

        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        var messages: [llama_chat_message] = entries.map { entry in
            let role = strdup(entry.role)!
            let content = strdup(entry.content)!
            cStrings.append(role)
            cStrings.append(content)
            return llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content))
        }
        let messageCount = messages.count
        let totalBytes = entries.reduce(0) { $0 + $1.role.utf8.count + $1.content.utf8.count }
        var buffer = [CChar](repeating: 0, count: totalBytes * 2 + 512)

        func render(_ template: UnsafePointer<CChar>) -> String? {
            var capacity = Int32(buffer.count)
            var length = llama_chat_apply_template(template, &messages, messageCount, true, &buffer, capacity)
            if length > capacity {
                buffer = [CChar](repeating: 0, count: Int(length) + 1)
                capacity = Int32(buffer.count)
                length = llama_chat_apply_template(template, &messages, messageCount, true, &buffer, capacity)
            }
            guard length > 0 else { return nil }
            return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        if let modelTemplate = llama_model_chat_template(model, nil), let prompt = render(modelTemplate) {
            return prompt
        }
        if let prompt = "chatml".withCString({ render($0) }) {
            return prompt
        }
        return entries.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
    }

    private func tokenize(vocab: OpaquePointer, text: String) -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        let probe = llama_tokenize(vocab, text, byteCount, nil, 0, true, true)
        guard probe < 0, probe != Int32.min else { return [] }
        let needed = -probe
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        let written = llama_tokenize(vocab, text, byteCount, &tokens, needed, true, true)
        return written > 0 ? Array(tokens.prefix(Int(written))) : []
    }

    private func piece(vocab: OpaquePointer, token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var capacity = Int32(buffer.count)
        // special = true, aby prošly značky <think> (u některých modelů jsou to speciální tokeny).
        var length = llama_token_to_piece(vocab, token, &buffer, capacity, 0, true)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            capacity = Int32(buffer.count)
            length = llama_token_to_piece(vocab, token, &buffer, capacity, 0, true)
        }
        guard length > 0 else { return [] }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }

#else
    // Bez balíčku LlamaCpp (např. při buildu pro simulátor) se appka přeloží,
    // jen lokální GGUF modely nepůjdou spustit.
    func unload() {}

    func generate(
        modelPath: String,
        history: [ChatTurn],
        settings: LocalModelSettings,
        reasoning: Bool,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) throws {
        throw ProviderError.engine("Knihovna llama.cpp není v projektu. Přidej balíček LlamaCpp (viz README).")
    }
#endif
}
