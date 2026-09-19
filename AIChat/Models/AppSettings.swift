import Foundation
import Observation

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case local
    case apple
    case claude
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Lokální model"
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var symbol: String {
        switch self {
        case .local: "cpu"
        case .apple: "apple.intelligence"
        case .claude: "asterisk"
        case .gemini: "sparkles"
        }
    }

    var keychainAccount: KeychainAccount? {
        switch self {
        case .claude: .claude
        case .gemini: .gemini
        default: nil
        }
    }
}

/// Přesnost KV cache. Kvantizace je největší páka na délku kontextu: KV cache roste
/// lineárně s počtem tokenů a u 4B modelu zabere ve f16 ~144 kB na token.
/// q8 ji půlí prakticky beze ztráty kvality, q4 dělí čtyřmi (znatelně u dlouhého kontextu).
enum KVCachePrecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case f16, q8, q4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .f16: "f16 (bez kvantizace)"
        case .q8: "q8 – doporučeno"
        case .q4: "q4 – nejdelší kontext"
        }
    }

    /// Bajty na jednu hodnotu KV cache. Kvantované formáty mají navíc měřítko a posun
    /// na každou skupinu 64 hodnot (2× f16), proto to není přesně 1, resp. 0,5.
    var bytesPerValue: Double {
        switch self {
        case .f16: 2
        case .q8: 1 + 4.0 / 64
        case .q4: 0.5 + 4.0 / 64
        }
    }

    /// Počet bitů pro MLX (`kvBits`). nil = nekvantovat.
    var mlxBits: Int? {
        switch self {
        case .f16: nil
        case .q8: 8
        case .q4: 4
        }
    }
}

extension LocalModelSettings {
    /// MLX kvantuje K i V společně jediným `kvBits`. Když se nastavení liší, použije se
    /// to opatrnější: stačí jedno f16 a MLX nekvantuje vůbec.
    var mlxKVBits: Int? {
        guard let k = kvCacheK.mlxBits, let v = kvCacheV.mlxBits else { return nil }
        return max(k, v)
    }

    /// Bajty na hodnotu KV cache, jak je nakonec uloží MLX.
    var mlxKVBytesPerValue: Double {
        switch mlxKVBits {
        case 4: KVCachePrecision.q4.bytesPerValue
        case 8: KVCachePrecision.q8.bytesPerValue
        default: KVCachePrecision.f16.bytesPerValue
        }
    }
}

/// Parametry lokálních modelů (GGUF přes llama.cpp i MLX). Systémový prompt, teplota
/// a délka odpovědi platí i pro Apple Intelligence.
struct LocalModelSettings: Codable, Equatable, Sendable {
    var systemPrompt = "Jsi užitečný asistent. Odpovídej česky, věcně a stručně."
    var temperature = 0.7
    var topP = 0.9
    var topK = 40
    var minP = 0.05
    var repeatPenalty = 1.1
    var repeatLastN = 64
    var maxTokens = 1024
    var contextLength = 4096
    /// Kolik tokenů promptu zpracuje MLX v jednom kroku. Větší krok líp vytíží GPU
    /// a zrychlí prefill, ale zvedne špičku paměti při zpracování dlouhé přílohy.
    /// GGUF přes llama.cpp má vlastní dávkování a tohle se ho netýká.
    var prefillStep = 1024
    /// Při málo volné paměti prefill krok dočasně zmenšit. Špička při zpracování promptu
    /// roste s velikostí kroku, takže tohle je poslední pojistka před ukončením appky –
    /// zaplatí se pomalejším prefillem u té jedné odpovědi.
    /// Platí pro MLX i pro GGUF (tam se zmenšuje `ggufPrefillBatch` u jednoho promptu,
    /// bez nového kontextu). U GGUF to chrání před růstem výpočetních bufferů, ne před
    /// kopiemi vah do bufferu GPU – ty na velikosti dávky nezávisí.
    var adaptivePrefill = true
    /// Strop na paměť lokálního modelu v MB. 0 = jen systémový limit.
    /// Platí pro MLX i pro GGUF – oba počítají délku kontextu i prefill krok
    /// z `MemoryBudget`, takže se strop propíše všude bez další změny.
    var memoryCapMB = 5_120

    /// Přesnost klíčů v KV cache. Platí jen pro MLX – u GGUF na Metalu dává kvantovaná
    /// KV cache nesmyslné odpovědi, pro GGUF je proto zvlášť `ggufKVCache`.
    var kvCacheK: KVCachePrecision = .f16
    /// Přesnost hodnot v KV cache. Platí jen pro MLX, stejně jako `kvCacheK`.
    var kvCacheV: KVCachePrecision = .f16
    /// Přesnost KV cache u GGUF. Uplatní se jen při streamování expertů, kdy výpočet
    /// běží celý na CPU – tam je kvantovaná cache ověřená (na Metalu dává nesmysly,
    /// proto se jinde nepoužije). q8 uvolní polovinu paměti KV cache pro page cache
    /// expertů: u Qwen3-30B-A3B je to při 16k kontextu skoro 800 MB.
    /// Vyžaduje flash attention; bez něj se použije f16.
    /// Měření (Qwen3-30B-A3B, k=6, prefill na GPU, prompt 1593 tokenů): q8 stojí prefill
    /// 43,0 → 116,1 s a generování nezrychlí ani o setinu (2,80 vs 2,79 tok/s). Kvantovaná
    /// cache zjevně vyřadí flash-attention kernel na Metalu a attention spadne na CPU.
    /// Smysl může dávat až u kontextu v desítkách tisíc tokenů, kde KV cache začne ubírat
    /// fyzickou RAM page cache expertů – tam je ale potřeba to změřit znovu.
    var ggufKVCache: KVCachePrecision = .f16
    /// Kolik tokenů promptu zpracuje llama.cpp v jedné dávce (`n_batch` i `n_ubatch`).
    /// Uplatní se jen při streamování expertů, kde dávka řídí i počet průchodů souborem:
    /// experti se čtou jednou na dávku a vrstvu a jejich počet se zastaví na 128, takže
    /// větší dávka znamená míň čtení. Platí se špičkou paměti výpočetních bufferů,
    /// o kterou se zkrátí dostupný kontext.
    var ggufPrefillBatch = 2048
    /// Poslat výpočet prefillu na Metal, i když experti leží na CPU (`op_offload`).
    /// Scheduler to udělá jen pro dávky od 32 tokenů, takže generování (dávka 1) zůstane
    /// na CPU – a to je správně: prefill je omezený výpočtem, generování propustností flash.
    /// Měření (Qwen3-30B-A3B, k=6, 3 vlákna): prefill jede ~77 GFLOPS, GPU zvládá řádově víc.
    /// Cena je paměť navíc na kopie tenzorů expertů do bufferu GPU – když appku začne
    /// ukončovat jetsam, tohle je první věc k vypnutí.
    var ggufGPUPrefill = false
    /// Diagnostika: nechat ggml vypsat, jak rozdělil graf mezi CPU a GPU (`GGML_SCHED_DEBUG`).
    /// Každý split je synchronizace obou stran, takže jejich počet vysvětluje, proč prefill
    /// na GPU nedosahuje zdaleka výkonu GPU. Výpis je ukecaný a do logu jde jen omezený
    /// počet řádků – nenechávej zapnuté při běžném používání.
    var ggufSchedDebug = false
    /// Dlouhou přílohu ke shrnutí zpracovat po částech (`SummaryPipeline`). Vypnuto =
    /// příloha jde do jednoho promptu jako v běžném chatu; co se nevejde do kontextu,
    /// se ořízne. Na porovnání rychlosti obou cest.
    var summarizeLongAttachments = true
    /// Strop na velikost jednoho kusu při shrnování, v tokenech (0 = podle délky kontextu).
    /// Nejde jen o paměť: generování na dlouhém kontextu je citelně pomalejší (attention
    /// nad velkou KV cache a KV navíc ubírá RAM page cache expertů), takže víc menších
    /// průchodů může být rychlejší než málo velkých, i když se prefillem projde totéž.
    var summaryChunkTokens = 0
    /// Ukazovat pod odpovědí úryvky, ze kterých vznikla. Když je vypnuté, model se
    /// zároveň přestane odkazovat čísly v hranatých závorkách – bez seznamu podkladů
    /// by odkazovala na něco, co uživatel nevidí.
    var showSources = false
    /// Odpovídat nad přílohou stručně: první věta je odpověď, žádné komentáře o tom,
    /// že model dostal jen výběr z dokumentu.
    var conciseAnswers = true
    /// Před hledáním nechat model vybrat kapitolu podle osnovy dokumentu.
    /// Stojí jeden krátký průchod (vstup osnova, výstup číslo), zato u dokumentů
    /// s jasnou strukturou – výkazy, smlouvy – trefuje líp než hledání na slovech.
    var sectionRouting = true
    /// Nechat model volat nástroje samotného hledání (`AgentPipeline`) místo pevné
    /// pipeline. Přesnější u dotazů, na které heuristika nesedí, ale každý krok je
    /// nový prompt ke zpracování – na telefonu je pět kroků víc než minuta čekání.
    /// Proto je to vypnuté a hodí se hlavně pro cloudové modely a zapnuté přemýšlení.
    var agentTools = false
    var gpuLayers = 99
    var threads = LocalModelSettings.defaultThreads
    /// Vlákna pro zpracování promptu (0 = stejně jako `threads`). Prefill a generování
    /// mají u streamovaného MoE jiné optimum: prefill sahá na desítky expertů na vrstvu
    /// a je omezený počtem operací úložiště, generování na jednotky expertů a víc vláken
    /// si tam navzájem trhá readahead okna. Proto se dají nastavit zvlášť.
    var threadsBatch = 0
    /// MoE modely (Qwen3-30B-A3B, Gemma 4 26B-A4B …): routované experty nechat na CPU
    /// namapované ze souboru a na Metal dát jen hustou část. Model pak nemusí celý
    /// zabírat RAM – experti se čtou z úložiště podle potřeby. U ostatních modelů se nic nemění.
    var streamExperts = true
    /// Při streamování předčítat vybrané experty z flash paralelně, dřív než je výpočet potřebuje.
    /// Vypínatelné hlavně kvůli porovnání rychlosti.
    var prefetchExperts = true
    /// Diagnostika předčítání: jen dělit graf výpočtu, experty nečíst.
    var prefetchSplitOnly = false
    /// Při předčítání stránky expertů rovnou paralelně namapovat do procesu.
    /// Měření na iPhonu (Qwen3-30B-A3B, k=6, 3 vlákna): 4,59 → 4,78 tok/s a z jednoho
    /// I/O přijde 5,2 stránky místo 4,7. Dřív se to jevilo jako neutrální, ale to bylo
    /// ještě s dřívější režií předčítání, která rozdíl přebila.
    var prefaultPages = true
    /// Po kolika megabajtech se při předčítání čeká na dokončení čtení (0 = vrstva naráz).
    /// Týká se jen zapnutého mapování stránek – viz `ExpertPrefetcher.waveBytes`.
    ///
    /// Výchozí vypnuto: měření (Qwen3-30B-A3B, k=6, 3 vlákna) neukázalo žádný přínos.
    /// Prefill dostával z úložiště 16,1 kB na jedno I/O při 8, 16, 32 i 64MB vlnách
    /// i bez nich – tedy přesně jednu stránku, bez ohledu na velikost vlny. Domněnka,
    /// že se readahead ztrácí kvůli objemu ohlášenému naráz, tím padla. Volba zůstává
    /// jen pro pokusy na jiném hardwaru.
    var prefetchWaveMB = 0
    /// Hustou část streamovaného MoE počítat na GPU. Na iPhonu je jen CPU rychlejší
    /// (střídání CPU a GPU v každé vrstvě), proto výchozí vypnuto.
    var streamingGPU = false
    /// Hustou část streamovaného MoE přebalit pro rychlejší ARM jádra (stojí ~1 GB RAM).
    var repackDense = true
    /// Kolik expertů smí router na vrstvu vybrat (0 = kolik má model v metadatech).
    /// Objem čtení z úložiště na token je na tomhle čísle lineárně závislý: u Qwen3-30B-A3B
    /// je to 8 × 48 vrstev × 2,7 MB ≈ 1 GB na token, se čtyřmi experty polovina.
    /// Kvalita odpovědí tím klesá – 8→6 bývá skoro bez rozdílu, 8→4 už znát je.
    var expertsPerToken = 0
    var useRandomSeed = true
    var seed = 42

    /// Jak se vybírá režim podle úkolu (výchozí: automaticky podle zprávy).
    var profileMode: TaskProfileMode = .automatic
    /// Parametry jednotlivých režimů – uživatel si je může upravit.
    var profiles: [String: SamplingParameters] = [:]
    /// Instrukce navíc k systémovému promptu, podle režimu. Sem patří to, co se u daného
    /// typu úlohy opakuje – „čísla neopisuj do tabulky“, „piš v odrážkách“.
    var instructionProfiles: [String: String] = [:]
    /// Osnova shrnutí podle režimu; jeden nadpis na řádek. Prázdná = použije se výchozí
    /// z `TaskProfile.defaultOutline`.
    var outlineProfiles: [String: [String]] = [:]
    /// Přemýšlení zvlášť pro každý režim (uložené, jinak `TaskProfile.thinksByDefault`).
    /// Platí jen pro modely, které přemýšlet umí a mají to zapnuté hlavním přepínačem.
    var reasoningProfiles: [String: Bool] = [:]
    /// Vlákna CPU zvlášť pro každý režim (0 nebo chybí = hodnota z Výkonu).
    ///
    /// Proč to jde nastavit po režimech: u MoE z úložiště se s délkou kontextu mění, co
    /// je úzké hrdlo. Krátký chat je omezený čtením z flash a nad tři vlákna zpomaluje,
    /// protože si vlákna navzájem trhají readahead. Práce nad dokumentem má kontext
    /// v tisících tokenů, kde attention převáží nad čtením – při 9k tokenech padlo
    /// předčítání na 20 % času, zbytek byl výpočet, a tam víc vláken pomáhá.
    /// Skutečný činitel je délka kontextu, režim je jen její praktický odhad.
    var threadProfiles: [String: Int] = [:]

    /// Parametry režimu (uložené, jinak výchozí).
    func parameters(for profile: TaskProfile) -> SamplingParameters {
        profiles[profile.rawValue] ?? profile.defaults
    }

    /// Systémový prompt pro daný režim: společný základ plus instrukce režimu.
    func instructions(for profile: TaskProfile) -> String {
        let extra = (instructionProfiles[profile.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return systemPrompt }
        return systemPrompt + "\n\n" + extra
    }

    /// Osnova shrnutí pro daný režim.
    func outline(for profile: TaskProfile) -> [String] {
        let custom = (outlineProfiles[profile.rawValue] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return custom.isEmpty ? profile.defaultOutline : custom
    }

    /// Vlákna CPU pro režim (uložená, jinak společná hodnota z Výkonu).
    func threads(for profile: TaskProfile) -> Int {
        let value = threadProfiles[profile.rawValue] ?? 0
        return value > 0 ? value : threads
    }

    /// Má se v tomto režimu přemýšlet?
    func reasoning(for profile: TaskProfile) -> Bool {
        reasoningProfiles[profile.rawValue] ?? profile.thinksByDefault
    }

    /// Kopie nastavení s parametry vzorkování daného režimu – tu dostane engine.
    func applying(_ profile: TaskProfile) -> LocalModelSettings {
        let values = parameters(for: profile)
        // Instrukce režimu se propíší do systémového promptu, protože právě ten oba
        // lokální enginy posílají modelu – žádná další cesta do promptu nevede.
        var copy = self
        copy.temperature = values.temperature
        copy.topP = values.topP
        copy.minP = values.minP
        copy.topK = values.topK
        copy.repeatPenalty = values.repeatPenalty
        copy.threads = threads(for: profile)
        copy.systemPrompt = instructions(for: profile)
        return copy
    }

    /// Vlákna, se kterými se opravdu zpracuje prompt.
    var effectiveThreadsBatch: Int { threadsBatch > 0 ? threadsBatch : threads }

    static var defaultThreads: Int {
        max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
}

/// Parametry společné pro Claude a Gemini.
struct CloudSettings: Codable, Equatable, Sendable {
    var claudeModel = "claude-sonnet-5"
    var geminiModel = "gemini-3.6-flash"
    var systemPrompt = "Jsi užitečný asistent. Odpovídej česky."
    var maxTokens = 8192
    /// Jen Gemini. Claude od verze 4.7 teplotu nepřijímá, Gemini 3 ji doporučuje neměnit.
    var overrideTemperature = false
    var temperature = 1.0
    /// Délku promptu přizpůsobit tarifu účtu (limit vstupních tokenů za minutu).
    var adaptToTier = true
    /// Tarif účtu – vybraný ručně, nebo zjištěný z API (automaticky).
    var claudeTier: ClaudeTier = .automatic
    var geminiTier: GeminiTier = .automatic
    /// Přesný limit vstupních tokenů za minutu z konzole / AI Studia (má přednost před tarifem).
    var claudeInputPerMinute: Int?
    var geminiInputPerMinute: Int?
}

extension LocalModelSettings {
    /// Chybějící klíče (nová nastavení) dostanou výchozí hodnotu, ať aktualizace appky
    /// nesmaže uložený systémový prompt ani parametry.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? systemPrompt
        instructionProfiles = try container.decodeIfPresent(
            [String: String].self, forKey: .instructionProfiles) ?? instructionProfiles
        outlineProfiles = try container.decodeIfPresent(
            [String: [String]].self, forKey: .outlineProfiles) ?? outlineProfiles
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? topP
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? topK
        minP = try container.decodeIfPresent(Double.self, forKey: .minP) ?? minP
        repeatPenalty = try container.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? repeatPenalty
        repeatLastN = try container.decodeIfPresent(Int.self, forKey: .repeatLastN) ?? repeatLastN
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? maxTokens
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? contextLength
        gpuLayers = try container.decodeIfPresent(Int.self, forKey: .gpuLayers) ?? gpuLayers
        threads = try container.decodeIfPresent(Int.self, forKey: .threads) ?? threads
        threadsBatch = try container.decodeIfPresent(Int.self, forKey: .threadsBatch) ?? threadsBatch
        streamExperts = try container.decodeIfPresent(Bool.self, forKey: .streamExperts) ?? streamExperts
        prefetchExperts = try container.decodeIfPresent(Bool.self, forKey: .prefetchExperts) ?? prefetchExperts
        prefetchSplitOnly = try container.decodeIfPresent(Bool.self, forKey: .prefetchSplitOnly) ?? prefetchSplitOnly
        prefaultPages = try container.decodeIfPresent(Bool.self, forKey: .prefaultPages) ?? prefaultPages
        prefetchWaveMB = try container.decodeIfPresent(Int.self, forKey: .prefetchWaveMB) ?? prefetchWaveMB
        streamingGPU = try container.decodeIfPresent(Bool.self, forKey: .streamingGPU) ?? streamingGPU
        repackDense = try container.decodeIfPresent(Bool.self, forKey: .repackDense) ?? repackDense
        expertsPerToken = try container.decodeIfPresent(Int.self, forKey: .expertsPerToken) ?? expertsPerToken
        useRandomSeed = try container.decodeIfPresent(Bool.self, forKey: .useRandomSeed) ?? useRandomSeed
        seed = try container.decodeIfPresent(Int.self, forKey: .seed) ?? seed
        profileMode = (try? container.decodeIfPresent(TaskProfileMode.self, forKey: .profileMode)) ?? profileMode
        profiles = (try? container.decodeIfPresent([String: SamplingParameters].self, forKey: .profiles)) ?? [:]
        reasoningProfiles = (try? container.decodeIfPresent([String: Bool].self, forKey: .reasoningProfiles)) ?? [:]
        threadProfiles = (try? container.decodeIfPresent([String: Int].self, forKey: .threadProfiles)) ?? [:]
        prefillStep = try container.decodeIfPresent(Int.self, forKey: .prefillStep) ?? prefillStep
        adaptivePrefill = try container.decodeIfPresent(Bool.self, forKey: .adaptivePrefill) ?? adaptivePrefill
        kvCacheK = (try? container.decodeIfPresent(KVCachePrecision.self, forKey: .kvCacheK)) ?? kvCacheK
        kvCacheV = (try? container.decodeIfPresent(KVCachePrecision.self, forKey: .kvCacheV)) ?? kvCacheV
        ggufKVCache = (try? container.decodeIfPresent(KVCachePrecision.self, forKey: .ggufKVCache)) ?? ggufKVCache
        ggufPrefillBatch = try container.decodeIfPresent(Int.self, forKey: .ggufPrefillBatch) ?? ggufPrefillBatch
        ggufGPUPrefill = try container.decodeIfPresent(Bool.self, forKey: .ggufGPUPrefill) ?? ggufGPUPrefill
        ggufSchedDebug = try container.decodeIfPresent(Bool.self, forKey: .ggufSchedDebug) ?? ggufSchedDebug
        summarizeLongAttachments = try container.decodeIfPresent(Bool.self, forKey: .summarizeLongAttachments) ?? summarizeLongAttachments
        summaryChunkTokens = try container.decodeIfPresent(Int.self, forKey: .summaryChunkTokens) ?? summaryChunkTokens
        showSources = try container.decodeIfPresent(Bool.self, forKey: .showSources) ?? showSources
        conciseAnswers = try container.decodeIfPresent(Bool.self, forKey: .conciseAnswers) ?? conciseAnswers
        sectionRouting = try container.decodeIfPresent(Bool.self, forKey: .sectionRouting) ?? sectionRouting
        agentTools = try container.decodeIfPresent(Bool.self, forKey: .agentTools) ?? agentTools
        memoryCapMB = try container.decodeIfPresent(Int.self, forKey: .memoryCapMB) ?? memoryCapMB
    }
}

extension CloudSettings {
    /// Chybějící klíče (nová nastavení) dostanou výchozí hodnotu – přidání pole
    /// tak nesmaže uložený model, prompt ani ostatní nastavení.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? claudeModel
        geminiModel = try container.decodeIfPresent(String.self, forKey: .geminiModel) ?? geminiModel
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? systemPrompt
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? maxTokens
        overrideTemperature = try container.decodeIfPresent(Bool.self, forKey: .overrideTemperature) ?? overrideTemperature
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        adaptToTier = try container.decodeIfPresent(Bool.self, forKey: .adaptToTier) ?? adaptToTier
        claudeTier = (try? container.decodeIfPresent(ClaudeTier.self, forKey: .claudeTier)) ?? claudeTier
        geminiTier = (try? container.decodeIfPresent(GeminiTier.self, forKey: .geminiTier)) ?? geminiTier
        claudeInputPerMinute = try container.decodeIfPresent(Int.self, forKey: .claudeInputPerMinute)
        geminiInputPerMinute = try container.decodeIfPresent(Int.self, forKey: .geminiInputPerMinute)
    }
}

@MainActor
@Observable
final class SettingsStore {
    var provider: AIProvider { didSet { persist() } }
    var local: LocalModelSettings { didSet { persist() } }
    var cloud: CloudSettings { didSet { persist() } }
    /// ID vybraného lokálního modelu – název souboru .gguf, nebo "mlx:<složka>".
    var selectedLocalModel: String? { didSet { persist() } }
    /// Přemýšlení (reasoning) zapnuto/vypnuto zvlášť pro každý model; klíč viz `reasoningKey`.
    private(set) var reasoningPrefs: [String: Bool] { didSet { persist() } }

    /// Které cloudové služby mají uložený klíč (samotné klíče jsou jen v Klíčence).
    private(set) var connected: Set<AIProvider> = []

    private enum Key {
        static let provider = "settings.provider"
        static let local = "settings.local"
        static let cloud = "settings.cloud"
        static let selectedModel = "settings.selectedLocalModel"
        static let reasoning = "settings.reasoning"
        static let kvCacheReset = "settings.migration.kvCacheF16"
    }

    init() {
        let defaults = UserDefaults.standard
        provider = AIProvider(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .local
        local = Self.decode(LocalModelSettings.self, key: Key.local) ?? LocalModelSettings()
        cloud = Self.decode(CloudSettings.self, key: Key.cloud) ?? CloudSettings()
        selectedLocalModel = defaults.string(forKey: Key.selectedModel)
        reasoningPrefs = Self.decode([String: Bool].self, key: Key.reasoning) ?? [:]
        // Jednorázový návrat na f16: kvantovaná KV cache se krátce posílala jako výchozí
        // a uložila se do nastavení. Změna výchozí hodnoty v kódu na uložená data nesáhne.
        if !defaults.bool(forKey: Key.kvCacheReset) {
            local.kvCacheK = .f16
            local.kvCacheV = .f16
            defaults.set(true, forKey: Key.kvCacheReset)
        }
        refreshConnections()
    }

    // MARK: - API klíče

    func apiKey(for provider: AIProvider) -> String? {
        provider.keychainAccount.flatMap { KeychainHelper.read($0) }
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        guard let account = provider.keychainAccount else { return }
        KeychainHelper.save(key, for: account)
        refreshConnections()
    }

    func isConnected(_ provider: AIProvider) -> Bool { connected.contains(provider) }

    private func refreshConnections() {
        connected = Set(AIProvider.allCases.filter { apiKey(for: $0) != nil })
    }

    // MARK: - Přemýšlení (reasoning)

    /// Klíč modelu pro nastavení přemýšlení. nil = poskytovatel přemýšlení nepodporuje.
    func reasoningKey(for provider: AIProvider) -> String? {
        switch provider {
        case .local: selectedLocalModel.map { "local:" + $0 }
        case .apple: nil
        case .claude: "claude:" + cloud.claudeModel
        case .gemini: "gemini:" + cloud.geminiModel
        }
    }

    func isReasoningEnabled(key: String) -> Bool {
        if let stored = reasoningPrefs[key] { return stored }
        // Výchozí stav = výchozí chování modelu. Claude před verzí 5 bez přemýšlení.
        if key.hasPrefix("claude:") {
            return ClaudeProvider.Capabilities(model: String(key.dropFirst(7))).thinksByDefault
        }
        return true
    }

    func setReasoning(_ enabled: Bool, key: String) {
        reasoningPrefs[key] = enabled
    }

    /// Přepínač pro právě aktivní model (titulek, pole zprávy).
    var activeReasoningKey: String? { reasoningKey(for: provider) }

    var activeReasoningEnabled: Bool {
        get { activeReasoningKey.map(isReasoningEnabled(key:)) ?? false }
        set { if let key = activeReasoningKey { setReasoning(newValue, key: key) } }
    }

    /// Upozornění, když model přemýšlení vypnout neumí.
    func reasoningNote(for provider: AIProvider) -> String? {
        if provider == .claude, ClaudeProvider.Capabilities(model: cloud.claudeModel).alwaysThinks {
            return "Tento model přemýšlení vypnout neumí – vypnutím se jen skryje."
        }
        if provider == .claude, !ClaudeProvider.Capabilities(model: cloud.claudeModel).supportsThinking {
            return "Tento model přemýšlení nepodporuje."
        }
        if provider == .gemini, cloud.geminiModel.lowercased().contains("pro") {
            return "Modely Gemini Pro přemýšlení úplně vypnout neumí, jen ho omezí na minimum."
        }
        return nil
    }

    // MARK: - Popisky

    var activeModelLabel: String {
        switch provider {
        case .local:
            selectedLocalModel.map(LocalModelFile.displayName(forID:)) ?? "Model nevybrán"
        case .apple: "Model v zařízení"
        case .claude: cloud.claudeModel
        case .gemini: cloud.geminiModel
        }
    }

    // MARK: - Kontext

    /// Kontextové okno aktivního modelu, dokud ho nezpřesní první odpověď.
    /// Lokální: nastavená délka (případně zkrácená pamětí). Cloud: okno modelu, nebo limit tarifu.
    var expectedContextWindow: Int? {
        switch provider {
        case .local: min(local.contextLength, LocalRuntime.shared.memoryLimitedContext ?? .max)
        case .apple: 4096
        case .claude, .gemini: cloudPlan(for: provider).effectiveWindow
        }
    }

    /// Parametry dalšího požadavku podle limitů modelu a tarifu.
    func cloudPlan(for provider: AIProvider) -> CloudRequestPlan {
        CloudLimitsStore.shared.plan(
            provider: provider,
            model: cloudModel(for: provider),
            requestedMaxTokens: cloud.maxTokens,
            adaptToTier: cloud.adaptToTier,
            tierInputPerMinute: tierInputPerMinute(for: provider)
        )
    }

    /// Limity vybraného tarifu pro aktuální model (nil = automaticky / nezveřejněné).
    func tierLimits(for provider: AIProvider) -> TierLimits? {
        switch provider {
        case .claude: cloud.claudeTier.limits(model: cloud.claudeModel)
        case .gemini: cloud.geminiTier.limits
        case .local, .apple: nil
        }
    }

    /// Limit vstupu za minutu, se kterým se plánuje: ruční hodnota > vybraný tarif.
    /// nil = automaticky (zjištěno z API).
    func tierInputPerMinute(for provider: AIProvider) -> Int? {
        let manual = provider == .claude ? cloud.claudeInputPerMinute : cloud.geminiInputPerMinute
        if let manual, manual > 0 { return manual }
        return tierLimits(for: provider)?.inputPerMinute
    }

    func cloudModel(for provider: AIProvider) -> String {
        provider == .gemini ? cloud.geminiModel : cloud.claudeModel
    }

    /// Mění se s modelem – podle toho se znovu načtou jeho limity.
    var contextWindowKey: String { provider.rawValue + ":" + activeModelLabel }

    /// Okno a max. odpověď cloudového modelu z Models API (jednou za týden, `force` = hned).
    func refreshCloudModelInfo(for provider: AIProvider? = nil, force: Bool = false) async {
        let provider = provider ?? self.provider
        guard provider == .claude || provider == .gemini, let key = apiKey(for: provider) else { return }
        await CloudLimitsStore.shared.refreshModelInfo(
            provider: provider,
            model: cloudModel(for: provider),
            apiKey: key,
            force: force
        )
    }

    // MARK: - Sestavení poskytovatele

    /// `profile` řídí parametry vzorkování lokálního modelu (cloud je nepoužívá).
    /// - Parameter reasoningOverride: vynutí stav přemýšlení bez ohledu na nastavení.
    ///   Používá `SummaryPipeline` – při shrnování po částech by se think blok
    ///   opakoval v každém průchodu.
    /// - Parameter maxTokensOverride: strop délky odpovědi místo nastaveného.
    ///   `SummaryPipeline` ho snižuje u dílčích průchodů – tam stačí krátké odrážky
    ///   a nastavených několik tisíc tokenů by se generovalo u každé části zvlášť.
    func makeProvider(
        models: ModelManager,
        profile: TaskProfile = .chat,
        reasoningOverride: Bool? = nil,
        maxTokensOverride: Int? = nil
    ) throws -> any ChatProvider {
        // Přepnutí na cloud nebo Apple Intelligence uvolní lokální model z paměti.
        // Mezi lokálními enginy se o to postará samotný provider těsně před generováním.
        if provider != .local {
            Task { await LocalEngines.keepOnly(nil) }
        }
        switch provider {
        case .local:
            guard let id = selectedLocalModel, let model = models.model(id: id) else {
                throw ProviderError.notConfigured("Vyber nebo stáhni lokální model v Nastavení.")
            }
            // Hlavní přepínač u modelu má přednost: když je vypnutý, nepřemýšlí se nikdy.
            // Jinak rozhoduje režim – v běžném chatu se přemýšlení vyplatí vypnout.
            let reasoning = reasoningOverride
                ?? (isReasoningEnabled(key: "local:" + id) && local.reasoning(for: profile))
            var tuned = local.applying(profile)
            if let limit = maxTokensOverride { tuned.maxTokens = limit }
            switch model.kind {
            case .gguf:
                return LlamaProvider(modelPath: model.url.path(percentEncoded: false), settings: tuned, reasoning: reasoning)
            case .mlx:
                return MLXProvider(directory: model.url, settings: tuned, reasoning: reasoning)
            }
        case .apple:
            return AppleIntelligenceProvider(
                instructions: local.instructions(for: profile),
                temperature: local.applying(profile).temperature,
                maxTokens: local.maxTokens
            )
        case .claude, .gemini:
            return try cloudProvider(for: provider)
        }
    }

    func cloudProvider(for provider: AIProvider, maxTokens: Int? = nil) throws -> any ChatProvider {
        guard let key = apiKey(for: provider) else {
            throw ProviderError.notConfigured("Doplň API klíč pro \(provider.title) v Nastavení.")
        }
        let reasoning = reasoningKey(for: provider).map(isReasoningEnabled(key:)) ?? false
        switch provider {
        case .claude:
            return ClaudeProvider(
                apiKey: key,
                model: cloud.claudeModel,
                systemPrompt: cloud.systemPrompt,
                maxTokens: maxTokens ?? cloud.maxTokens,
                reasoning: reasoning,
                adaptToTier: cloud.adaptToTier,
                tierInputPerMinute: tierInputPerMinute(for: .claude)
            )
        case .gemini:
            return GeminiProvider(
                apiKey: key,
                model: cloud.geminiModel,
                systemPrompt: cloud.systemPrompt,
                maxTokens: maxTokens ?? cloud.maxTokens,
                temperature: cloud.overrideTemperature ? cloud.temperature : nil,
                reasoning: reasoning,
                adaptToTier: cloud.adaptToTier,
                tierInputPerMinute: tierInputPerMinute(for: .gemini)
            )
        default:
            throw ProviderError.notConfigured("\(provider.title) není cloudová služba.")
        }
    }

    // MARK: - Ukládání

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: Key.provider)
        defaults.set(try? JSONEncoder().encode(local), forKey: Key.local)
        defaults.set(try? JSONEncoder().encode(cloud), forKey: Key.cloud)
        defaults.set(selectedLocalModel, forKey: Key.selectedModel)
        defaults.set(try? JSONEncoder().encode(reasoningPrefs), forKey: Key.reasoning)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
