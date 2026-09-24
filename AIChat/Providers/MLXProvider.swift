import Foundation
import os
#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
#endif

/// Lokální model ve formátu MLX (složka s config.json, tokenizérem a *.safetensors).
/// Běží na GPU přes Apple MLX – na iPhonu bývá rychlejší než GGUF stejné velikosti.
struct MLXProvider: ChatProvider {
    let directory: URL
    let settings: LocalModelSettings
    var reasoning: Bool
    /// Jednorázové kolo: po odpovědi se sezení zahodí, protože na tenhle prompt
    /// už se navazovat nebude.
    var isOneShot = false
    /// Značky, na kterých se generování ukončí. Kontrolují se přímo v generační
    /// smyčce, takže se nečeká na zrušení streamu.
    var stopSequences: [String] = []

    func oneShot() -> any ChatProvider {
        var copy = self
        copy.isOneShot = true
        return copy
    }

    func stopping(at sequences: [String]) -> any ChatProvider {
        var copy = self
        copy.stopSequences += sequences
        return copy
    }

    func thinking(_ enabled: Bool) -> any ChatProvider {
        var copy = self
        copy.reasoning = enabled
        return copy
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // GGUF model uvolnit dřív, než se načte tenhle – jinak leží v paměti oba.
                    await LocalEngines.keepOnly(.mlx)
                    try await MLXEngine.shared.generate(
                        directory: directory,
                        history: history,
                        settings: settings,
                        reasoning: reasoning,
                        oneShot: isOneShot,
                        stop: stopSequences
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

/// Drží načtený MLX model mezi dotazy.
actor MLXEngine {
    static let shared = MLXEngine()

#if canImport(MLXLLM)
    private var container: MLXLMCommon.ModelContainer?
    private var loadedPath = ""
    /// Diagnostika v Konzoli: `subsystem:cz.aichat category:mlx`.
    private static let log = EngineLog(category: "mlx")

    /// Sezení drží KV cache mezi zprávami, takže se do modelu posílá jen nová zpráva
    /// a dosavadní konverzace se nezpracovává znovu. Historie tím nemizí – ta je
    /// v databázi appky; sezení je jen předpočítaný stav modelu pro ni.
    private var session: ChatSession?
    /// Zprávy, které v sezení opravdu jsou (včetně odpovědí modelu). Porovnáním
    /// s novou historií se pozná, jestli se dá navázat, nebo se musí stavět znovu.
    private var sessionTurns: [ChatTurn] = []
    /// Co všechno musí sedět, aby se dalo navázat: model, systémový prompt, přemýšlení
    /// a nastavení KV cache. Vzorkovací parametry ne – ty se uplatní až při výběru tokenu.
    private var sessionKey = ""
    /// Kolik tokenů sezení zabírá. Při přetečení kontextu se staví znovu z ořezané historie.
    private var sessionTokens = 0

    func unload() {
        dropSession()
        container = nil
        loadedPath = ""
        // Uvolněné buffery by jinak zůstaly v cache MLX.
        Memory.clearCache()
    }

    /// Zahodí KV cache. Konverzace zůstává, jen se příště musí zpracovat celá znovu.
    private func dropSession() {
        session = nil
        sessionTurns = []
        sessionKey = ""
        sessionTokens = 0
        Memory.clearCache()
    }

    func generate(
        directory: URL,
        history: [ChatTurn],
        settings: LocalModelSettings,
        reasoning: Bool,
        oneShot: Bool,
        stop: [String] = [],
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws {
        // Strop se nastaví dřív, než se spočítá kontext – `maxContext` z něj vychází.
        MemoryBudget.cap = max(0, settings.memoryCapMB) * 1_048_576
        // Znovu i tady: strop se dá v Parametrech změnit, aniž by se model přenačítal.
        Self.applyMemoryLimit()
        let container = try await load(directory, experts: settings.expertsPerToken)
        defer { Memory.clearCache() }

        // Kontext podle volné paměti (měřeno po načtení modelu) – dlouhý text by jinak appku shodil.
        let perToken = Self.bytesPerToken(directory, settings: settings)
        // Zpracování promptu má vlastní špičku, která s kontextem nesouvisí – musí se
        // do rozpočtu započítat, jinak se rozdá kontext, na který místo je, ale
        // na jeho zpracování ne. `LlamaProvider` to takhle dělá už dávno, MLX ne.
        let contextLength = MemoryBudget.maxContext(
            bytesPerToken: perToken,
            requested: settings.contextLength,
            // Jen ta část špičky, která přesahuje obecnou rezervu – ta je na výpočetní
            // buffery taky, takže sečíst obojí by znamenalo počítat je dvakrát.
            extraReserve: max(0, Self.prefillPeak(step: Self.prefillStep(settings: settings))
                              - MemoryBudget.reserve)
        )
        LocalRuntime.report(requested: settings.contextLength, effective: contextLength)
        guard contextLength >= 512 else {
            throw ProviderError.engine("""
                Na odpověď nezbývá paměť. Zpracování promptu si při kroku \
                \(Self.prefillStep(settings: settings)) tokenů vezme navíc zhruba \
                \(Self.prefillPeak(step: Self.prefillStep(settings: settings)) / 1_048_576) MB. \
                Zmenši „Prefill po krocích“, zvedni strop paměti, nebo vyber menší model.
                """)
        }
        let maxTokens = max(16, min(settings.maxTokens, contextLength / 2))

        let system = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTokens = contextLength - maxTokens

        var parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(settings.temperature),
            topP: Float(settings.topP),
            topK: settings.topK,
            minP: Float(settings.minP),
            repetitionPenalty: settings.repeatPenalty == 1 ? nil : Float(settings.repeatPenalty),
            repetitionContextSize: settings.repeatLastN,
            seed: settings.useRandomSeed ? nil : UInt64(truncatingIfNeeded: settings.seed)
        )
        // Prefill po větších krocích: GPU je líp vytížené, špička paměti vyšší.
        let prefill = Self.prefillStep(settings: settings)
        parameters.prefillStepSize = prefill
        // Když je těsno, buffery držené v cache MLX se hodí víc jako volná paměť
        // než jako ušetřené alokace.
        if prefill < max(256, settings.prefillStep) { Memory.clearCache() }

        // Kvantizace KV cache. `maxKVSize` zapne RotatingKVCache, který se v MLX nekvantuje,
        // takže obojí najednou nedává smysl; bez kvantizace zůstává rotující cache jako pojistka.
        if let bits = settings.mlxKVBits {
            parameters.kvBits = bits
            parameters.kvGroupSize = 64
            parameters.quantizedKVStart = 0
        } else {
            parameters.maxKVSize = contextLength
        }

        // Navázat na minulou zprávu se dá, jen když sedí model i nastavení, dosavadní
        // historie je předponou nové a v kontextu zbývá místo. Rozhoduje se to dřív,
        // než se skládá prompt – jinak by se zbytečně tokenizoval celý dokument.
        let key = [
            loadedPath, system, reasoning ? "1" : "0",
            settings.mlxKVBits.map(String.init) ?? "f16",
        ].joined(separator: "|")

        let canContinue = session != nil
            && sessionKey == key
            && history.count > sessionTurns.count
            && sessionTokens + maxTokens < contextLength
            && zip(sessionTurns, history).allSatisfy { $0.role == $1.role && $0.text == $1.text }

        let live: ChatSession
        var raw: [ChatTurn]          // syrové zprávy, které po tomto kole budou v sezení
        let fresh: [ChatTurn]        // co se teď posílá do modelu (s vloženými přílohami)
        var droppedHistory = false

        if canContinue, let existing = session {
            existing.generateParameters = parameters
            existing.additionalContext = ["enable_thinking": reasoning]
            live = existing
            let added = Array(history.suffix(history.count - sessionTurns.count))
            let room = max(1_500, (contextLength - sessionTokens - maxTokens) * 2)
            fresh = ChatTurn.inliningAttachments(added, characterBudget: room)
            raw = history
        } else {
            // Nové sezení: celá konverzace se složí, ořeže na rozpočet a projde tokenizérem.
            // Odhad „3 znaky na token“ je jen první nástřel – u češtiny je optimistický.
            func prepare(_ turns: [ChatTurn], characters: Int) async throws -> LMInput {
                var messages: [MLXLMCommon.Chat.Message] = []
                if !system.isEmpty { messages.append(.system(system)) }
                for turn in Self.messages(turns, characters: characters, contextLength: promptTokens) {
                    messages.append(Self.message(turn))
                }
                let input = UserInput(chat: messages, additionalContext: ["enable_thinking": reasoning])
                return try await container.prepare(input: input)
            }

            let hasFiles = history.contains { !$0.attachments.isEmpty }
            var kept = history
            var characters = max(1_500, promptTokens * 3 - system.count)
            var prepared = try await prepare(kept, characters: characters)
            var attempts = 0
            while prepared.text.tokens.size > promptTokens, attempts < 6 {
                attempts += 1
                let ratio = Double(promptTokens) / Double(prepared.text.tokens.size) * 0.9
                if hasFiles, characters > 1_500 {
                    characters = max(1_500, Int(Double(characters) * ratio))
                } else if kept.count > 1 {
                    kept.removeFirst(min(2, kept.count - 1))
                } else {
                    break
                }
                prepared = try await prepare(kept, characters: characters)
            }

            var ready = Self.messages(kept, characters: characters, contextLength: promptTokens)
            // `trimmed` může zahodit nejstarší zprávy – syrový seznam musí zůstat zarovnaný.
            if ready.count < kept.count { kept = Array(kept.suffix(ready.count)) }
            guard let last = ready.popLast() else {
                throw ProviderError.engine("Prázdný prompt.")
            }

            dropSession()
            live = ChatSession(
                container,
                instructions: system.isEmpty ? nil : system,
                history: ready.map(Self.message),
                generateParameters: parameters,
                additionalContext: ["enable_thinking": reasoning]
            )
            sessionKey = key
            fresh = [last]
            raw = kept
            droppedHistory = kept.count < history.count || attempts > 0
        }

        // Interpolace v Loggeru je autoclosure, takže vlastnosti actoru se do ní musí
        // předat hodnotou – jinak si vyžádá explicitní `self`. Hodí se to i níž: obsazení
        // se počítá z téhle kopie, ne z `sessionTokens`, o které může přijít `dropSession`.
        let cached = sessionTokens

        // Přesný počet tokenů promptu ohlásí MLX až po prefillu – u dlouhé přílohy
        // to jsou desítky sekund, po které by ukazatel stál na nule, i když zpráva
        // do kontextu dávno přibyla. Do té doby tam svítí odhad ze znaků.
        var usage = TokenUsage(
            promptTokens: cached + fresh.reduce(0) { $0 + $1.text.count } / 3,
            outputTokens: 0,
            contextWindow: contextLength,
            maxOutputTokens: maxTokens,
            isEstimate: true,
            droppedHistory: droppedHistory
        )
        onEvent(.usage(usage))

        Self.log.notice("""
            kontext \(contextLength) · \(perToken / 1024) kB/token\(perToken == 0 ? " (config.json nepřečten)" : "") \
            · KV \(settings.mlxKVBits.map { "q\($0)" } ?? "f16") · prefill \(prefill)\(prefill == max(256, settings.prefillStep) ? "" : " (zmenšeno kvůli paměti)") \
            · přemýšlení \(reasoning ? "zap" : "vyp") \
            · \(canContinue ? "navazuji na \(cached) tokenů" : "nové sezení")\(oneShot ? " · jednorázové" : "")
            """)

        var parser = ThinkTagParser()
        var answer = ""
        var promptCount = 0
        var outputCount = 0

        func handle(_ events: [StreamEvent]) {
            for event in events {
                switch event {
                case .text(let piece): answer += piece
                case .promoteTextToReasoning: answer = ""
                default: break
                }
                onEvent(event)
            }
        }

        // Text, na kterém se hlídají značky. Bere se syrový výstup, ne `answer` –
        // ten je bez think bloku a značka v přemýšlení se počítat nemá.
        var stopped = false
        let stops = stop.filter { !$0.isEmpty }

        do {
            for try await generation in live.streamDetails(to: fresh.map(Self.message)) {
                if Task.isCancelled { break }
                switch generation {
                case .chunk(let text):
                    handle(parser.feed(text))
                    usage.outputTokens += 1
                    // První token znamená, že prefill doběhl.
                    if usage.outputTokens == 1 {
                        Self.logMemory("prefill hotov", tokens: usage.promptTokens)
                    }
                    if usage.outputTokens % 16 == 0 { onEvent(.usage(usage)) }
                    // Konec generování na značce. Kontroluje se jen konec odpovědi:
                    // značka nikdy nepřijde celá v jednom tokenu, ale kus po kusu.
                    if !stops.isEmpty, stops.contains(where: { answer.hasSuffix($0) }) {
                        stopped = true
                    }
                    // Hlídka paměti. KV cache roste s každým tokenem, takže odpověď,
                    // která se na začátku vešla, se ke konci vejít nemusí. Kontroluje
                    // se po šestnácti tokenech – footprint je syscall, ne proměnná.
                    if !stopped, usage.outputTokens % 16 == 0 {
                        switch MemoryBudget.strain {
                        case .easy:
                            break
                        case .tight:
                            // Uvolněné buffery MLX si drží na později; tady se hodí víc
                            // vrátit je systému než ušetřit jednu alokaci.
                            Memory.clearCache()
                        case .critical:
                            // Radši useknutá odpověď než jetsam. Uživatel se to dozví,
                            // protože prázdný konec by vypadal jako chyba modelu.
                            onEvent(.status("Došla paměť, odpověď je useknutá. Zkrať kontext nebo zvedni strop v Parametrech.\n"))
                            stopped = true
                            Self.log.notice(
                                "generování ukončeno kvůli paměti · footprint \(MemoryBudget.footprint / 1_048_576) MB")
                        }
                    }
                    if stopped { break }
                case .info(let info):
                    promptCount = info.promptTokenCount
                    outputCount = info.generationTokenCount
                default:
                    break
                }
            }
        } catch {
            // Poškozené sezení se nesmí použít podruhé.
            dropSession()
            throw error
        }
        handle(parser.flush())

        // Odpověď je teď součástí KV cache, takže do seznamu patří taky. Ukládá se text
        // bez think bloku – přesně tak, jak ho má appka v historii, aby porovnání sedělo.
        session = live
        raw.append(ChatTurn(role: .assistant, text: answer))
        sessionTurns = raw
        sessionTokens = cached + promptCount + outputCount

        // Obsazení se bere z lokálních součtů, ne ze `sessionTokens`: `dropSession` níž
        // čítač vynuluje, takže se dřív u první zprávy v chatu (historie = jedna zpráva)
        // vracela nula a prompt se do kontextu vůbec nezapočítal. Když `.info` nedorazilo
        // (uživatel generování zastavil), zůstane na ukazateli odhad.
        if promptCount > 0 || outputCount > 0 {
            usage.promptTokens = cached + promptCount
            usage.outputTokens = outputCount
            usage.isEstimate = false
        }

        // Jednorázové kolo nemá na co navazovat – cache by jen držela paměť. Dřív se to
        // poznávalo podle toho, že historie je jediná zpráva; jenže to sedí i na první
        // zprávu normálního chatu, takže se u ní cache zahazovala a navazující dotaz
        // nad dokumentem zpracovával celou přílohu znovu.
        //
        // Přerušená generace se zahazuje taky: KV cache i `sessionTurns` by seděly na
        // odpověď, která nikdy nedoběhla, a další kolo by na ni navazovalo.
        if oneShot || stopped { dropSession() }
        Self.logMemory(stopped ? "generování přerušeno" : "odpověď hotová", tokens: usage.outputTokens)

        onEvent(.usage(usage))
    }

    /// Prefill krok pro tuhle generaci. MLX ho čte jednou při startu, takže se
    /// rozhoduje těsně před ní a na další odpověď se měří znovu.
    ///
    /// Zpracování promptu alokuje pracovní matice pro celý krok najednou – právě tahle
    /// špička bývá to, co appku u dlouhé přílohy přehoupne přes limit, i když ustálený
    /// stav (váhy + KV cache) by se ještě vešel. Menší krok špičku srazí za cenu
    /// pomalejšího prefillu; na velikost kontextu nemá vliv.
    /// Kolik paměti si navíc vezme zpracování promptu.
    ///
    /// Změřeno na Qwen3.8-4B-4bit, prompt 17 390 tokenů, dvě velikosti kroku:
    /// krok 4096 → špička +2 662 MB, krok 2048 → +1 854 MB. Z toho vychází pevná část
    /// 1 046 MB a 404 kB na každý token kroku. Je to špička, ne trvalá spotřeba –
    /// po dotečení odpovědi se uvolní, ale zemřít na jetsam se dá i na ní.
    private static func prefillPeak(step: Int) -> Int {
        1_046 * 1_048_576 + step * 404 * 1_024
    }

    private static func prefillStep(settings: LocalModelSettings) -> Int {
        let configured = max(256, settings.prefillStep)
        guard settings.adaptivePrefill else { return configured }
        switch MemoryBudget.pressure {
        case 0.90...: return min(configured, 512)
        case 0.80..<0.90: return max(512, configured / 2)
        // Sem spadne i nula, tedy „limit se nedá zjistit“ – pak se nic neomezuje.
        default: return configured
        }
    }

    /// Kolik drží MLX a kolik celá appka, na jedné řádce do logu.
    ///
    /// Tři body v čase stačí na to, aby se poznalo, kde paměť roste. Hned po načtení
    /// jsou to čisté váhy a pevné stavy vrstev. Po prefillu k tomu přibyla KV cache
    /// a pracovní paměť zpracování promptu. Na konci odpovědi zůstane to, co se
    /// neuvolnilo. Když je špička výrazně nad koncem, je to pracovní paměť prefillu
    /// a řeší se menším `prefillStep`; když se konec od načtení liší trvale, roste
    /// něco, s čím `bytesPerToken` nepočítá.
    /// Špička MLX ve chvíli, kdy byl model načtený. Slouží jako nula pro další body.
    nonisolated(unsafe) private static var peakAfterLoad = 0

    private static func logMemory(_ stage: String, tokens: Int? = nil) {
        let mlx = MemoryBudget.mlxMemory
        let megabytes: (Int) -> String = { "\($0 / 1_048_576) MB" }
        let peak = Memory.peakMemory
        let growth = max(0, peak - peakAfterLoad)
        // `EngineLog.notice` bere obyčejný `String` a privacy si řeší sám.
        let count = tokens.map { " · \($0) tokenů" } ?? ""
        log.notice("""
            \(stage)\(count) · MLX aktivní \(megabytes(mlx?.active ?? 0)) · \
            cache \(megabytes(mlx?.cache ?? 0)) · špička \(megabytes(peak)) \
            (+\(megabytes(growth)) od načtení) · appka \(megabytes(MemoryBudget.footprint))
            """)
    }

    /// Předá strop rovnou alokátoru MLX.
    ///
    /// `MemoryBudget.cap` je strop celé aplikace, kdežto `Memory.memoryLimit` platí jen
    /// pro buffery MLX – odečítá se proto, co drží zbytek appky (UI, tokenizér, obrázky).
    /// Rozdíl proti našemu počítání: tohle je tvrdá hranice uvnitř MLX. Když na ni
    /// alokace narazí, MLX nejdřív uvolní cache, a teprve pak to skončí chybou. Proto
    /// zůstávají i měkké pojistky – zkrácený kontext, menší prefill krok a hlídka
    /// v generační smyčce – aby se na tuhle hranici vůbec nedošlo.
    private static func applyMemoryLimit() {
        guard MemoryBudget.cap > 0 else { return }
        let mlx = MemoryBudget.mlxMemory.map { $0.active + $0.cache } ?? 0
        let overhead = max(0, MemoryBudget.footprint - mlx)
        let room = MemoryBudget.cap - overhead - MemoryBudget.reserve
        Memory.memoryLimit = max(256 * 1_048_576, room)
    }

    /// Velikost vah ve složce modelu (safetensors + gguf). 0 = nedá se zjistit.
    private static func directorySize(_ directory: URL) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(0) { total, url in
            let suffix = url.pathExtension.lowercased()
            guard suffix == "safetensors" || suffix == "gguf" || suffix == "npz" else { return total }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }

    /// Zprávy s vloženými přílohami, ořezané na rozpočet kontextu.
    private static func messages(
        _ turns: [ChatTurn], characters: Int, contextLength: Int
    ) -> [ChatTurn] {
        trimmed(
            ChatTurn.inliningAttachments(turns, characterBudget: characters, carriedShare: 0.35),
            contextLength: contextLength
        )
    }

    /// Převod zprávy chatu na formát MLX.
    private static func message(_ turn: ChatTurn) -> MLXLMCommon.Chat.Message {
        turn.role == .user ? .user(turn.text) : .assistant(turn.text)
    }

    /// `experts` = kolik expertů na token u MoE (0 = podle modelu), viz `MLXExperts`.
    private func load(_ directory: URL, experts: Int) async throws -> MLXLMCommon.ModelContainer {
        // Natrénovaný adaptér je součástí identity načteného modelu: po jeho zapnutí
        // nebo vypnutí se musí model načíst znovu, jinak by se dál generovalo
        // z toho, co je zrovna v paměti.
        let adapterDirectory = AdapterPaths.active(forModelAt: directory)
        let path = directory.path(percentEncoded: false)
            + (adapterDirectory.map { "|" + $0.path(percentEncoded: false) } ?? "")
            + (experts > 0 ? "|k\(experts)" : "")
        if let container, path == loadedPath { return container }
        unload()

        guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path(percentEncoded: false)) else {
            throw ProviderError.engine("Ve složce modelu chybí config.json.")
        }
        // Strop na váhy. Kontext se dá zkrátit, váhy ne – jakmile je model načtený,
        // nemá co uhnout. Když se pod strop nevejdou, je správná odpověď odmítnout
        // načtení, ne ho spustit a pak zjistit, že strop neplatí.
        if MemoryBudget.cap > 0 {
            let weights = Self.directorySize(directory)
            let needed = weights + MemoryBudget.footprint + MemoryBudget.reserve
            if weights > 0, needed > MemoryBudget.cap {
                let format: (Int) -> String = {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                }
                throw ProviderError.engine("""
                    Model má \(format(weights)) a se stropem \(format(MemoryBudget.cap)) se \
                    nevejde – potřeboval by \(format(needed)) i s rezervou. Zvedni strop \
                    v Parametrech, nebo vyber menší model.
                    """)
            }
        }
        // Výchozí cache MLX si nechává uvolněné buffery až do limitu paměti zařízení –
        // na iPhonu bez rozšířeného limitu to při delším textu vede k ukončení appky.
        Memory.cacheLimit = 32 * 1_048_576
        Self.applyMemoryLimit()
        let source: (url: URL, experts: Int?)
        do {
            source = try MLXExperts.loadDirectory(for: directory, requested: experts)
        } catch {
            throw ProviderError.engine("Počet expertů se nepodařilo změnit: \(error.localizedDescription) Vrať v Parametrech „Aktivních expertů“ na „podle modelu“.")
        }
        if let reduced = source.experts {
            Self.log.notice("MoE: \(reduced) z \(MLXExperts.used(in: directory) ?? 0) expertů na token (sníženo)")
        }
        let loaded: MLXLMCommon.ModelContainer
        do {
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: source.url,
                using: #huggingFaceTokenizerLoader()
            )
        } catch {
            throw ProviderError.engine("MLX model se nepodařilo načíst: \(error.localizedDescription)")
        }
        // Špička se v MLX nedá vynulovat, takže se jen zapamatuje, kde byla po načtení –
        // další body se pak hlásí i jako přírůstek proti ní. Nula v přírůstku znamená,
        // že tenhle běh nepřekonal nic z předchozích, ne že se nic nedělo.
        Self.peakAfterLoad = Memory.peakMemory
        Self.logMemory("model načten")

        if let adapterDirectory {
            // Adaptér nahradí lineární vrstvy za (Q)LoRA verze a vloží do nich váhy.
            // Základní model zůstává kvantovaný – v paměti přibudou jen jednotky MB.
            // Chyba se nepřechází mlčky: odpovídat bez adaptéru, který si uživatel
            // zapnul, vypadá jako by se trénink nepovedl.
            do {
                let adapter = try LoRAContainer.from(directory: adapterDirectory)
                try await loaded.perform { context in
                    try adapter.load(into: context.model)
                }
                Self.log.notice("adaptér \(adapterDirectory.lastPathComponent) načten")
            } catch {
                throw ProviderError.engine(
                    "LoRA adaptér se nepodařilo použít: \(error.localizedDescription) Vypni ho v Nastavení › Trénink, nebo ho natrénuj znovu."
                )
            }
        }

        container = loaded
        loadedPath = path
        return loaded
    }

    /// Paměť na jeden token kontextu z config.json: velikost KV cache v dané přesnosti.
    /// Pracovní matice pozornosti se tu nepočítá – MLX má fúzované SDPA jádro, které
    /// celou matici skóre nikdy nevytvoří, takže prefill nemá paměť závislou na kontextu.
    /// Na buffery a výkyvy je rezerva v `MemoryBudget.reserve`.
    private static func bytesPerToken(_ directory: URL, settings: LocalModelSettings) -> Int {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        // Multimodální modely (Gemma 3, Qwen 3.5…) mají parametry jazykové části v text_config.
        let config = root.merging(root["text_config"] as? [String: Any] ?? [:]) { _, text in text }
        func value(_ key: String) -> Int? { (config[key] as? NSNumber)?.intValue }

        guard var layers = value("num_hidden_layers"), let heads = value("num_attention_heads"), heads > 0 else { return 0 }
        // S kontextem rostou jen vrstvy s plnou pozorností: sliding-window vrstvy drží jen okno,
        // lineární (Qwen 3.5, GatedDeltaNet) mají pevný stav.
        if let types = config["layer_types"] as? [String], types.contains("full_attention") {
            layers = types.filter { $0 == "full_attention" }.count
        } else if let interval = value("full_attention_interval"), interval > 0 {
            layers = max(1, layers / interval)
        } else if let pattern = value("sliding_window_pattern"), pattern > 0 {
            layers = max(1, layers / pattern)
        }
        let kvHeads = value("num_key_value_heads") ?? heads
        let headDim = value("head_dim") ?? (value("hidden_size") ?? 0) / heads
        // MLX kvantuje K i V společně, takže obě půlky mají stejnou přesnost.
        //
        // Do rozpočtu se ale počítá nejmíň f16, i když je nastavená kvantovaná cache:
        // MLX kvantuje až po nějaké délce, takže na začátku promptu cache f16 opravdu
        // je. Změřeno – při nastaveném q8 vycházel odhad 17 kB na token, zatímco cache
        // po prefillu 17 tisíc tokenů zabírala 648 MB, tedy 38 kB na token. To přesně
        // odpovídá f16 (36 kB) plus stav lineárních vrstev. S původním odhadem rozdával
        // rozpočet dvakrát delší kontext, než na jaký byla paměť.
        let bytesPerValue = max(2, settings.mlxKVBytesPerValue)
        return Int((Double(layers * kvHeads * headDim * 2) * bytesPerValue).rounded(.up))
    }

    /// MLX nemá pevné okno kontextu – historii zkrátíme podle odhadu ~3 znaky na token.
    private static func trimmed(_ history: [ChatTurn], contextLength: Int) -> [ChatTurn] {
        var budget = contextLength * 3
        var result: [ChatTurn] = []
        for turn in history.reversed() {
            if !result.isEmpty && turn.text.count > budget { break }
            budget -= turn.text.count
            result.insert(turn, at: 0)
        }
        while result.first?.role == .assistant { result.removeFirst() }
        return result
    }

#else
    func unload() {}

    func generate(
        directory: URL,
        history: [ChatTurn],
        settings: LocalModelSettings,
        reasoning: Bool,
        oneShot: Bool,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws {
        throw ProviderError.engine("Knihovna MLX není v projektu. Přidej balíčky mlx-swift-lm a swift-transformers (viz README).")
    }
#endif
}
