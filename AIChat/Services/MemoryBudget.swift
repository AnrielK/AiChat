import Foundation
import Observation
import os
#if canImport(MLX)
import MLX
#endif

/// Kolik paměti smí lokální model zabrat, než iOS aplikaci ukončí (jetsam).
///
/// Limit je jen část RAM zařízení; entitlement increased-memory-limit ho zvedne
/// (na iPhonu s 8 GB z ~3,3 GB na ~6,5 GB). KV cache roste s délkou kontextu – u Gemma 3 4B
/// je to ~150 kB na token, 16k kontextu = 2,4 GB navíc k modelu. Dlouhý text pak appku shodil.
enum MemoryBudget {
    /// Vlastní strop na paměť lokálního modelu v bajtech. 0 = jen systémový limit.
    ///
    /// Systémový limit je na iPhonu s rozšířeným entitlementem kolem 6,5 GB. Jenže
    /// jetsam nesleduje jen tuhle appku: když si na hranici sáhneš, iOS zabíjí i to,
    /// co běží na pozadí, a zařízení se kousne. Vlastní strop drží model níž, takže
    /// zbyde pás, ve kterém se nic nemusí zabíjet.
    ///
    /// Strop nefunguje jako tvrdá zeď, na které by alokace selhala – kdyby ano, appka
    /// spadne místo aby zpomalila. Působí přes všechno, co se z něj počítá: délku
    /// kontextu (`maxContext`), velikost prefill kroku (`pressure`) a hlídku v generační
    /// smyčce. Model se tedy k pěti gigabajtům nepřiblíží, místo aby o ně narazil.
    ///
    /// Nastavuje se z poskytovatele před generováním, čte se z několika vláken.
    nonisolated(unsafe) static var cap = 0

    /// Limit, pod který se musí model vejít: systémový, vlastní strop, nebo to menší
    /// z obou. 0 = nedá se zjistit (simulátor) a zároveň není nastavený strop.
    static var limit: Int {
        let free = Int(os_proc_available_memory())
        let system = free > 0 ? free + footprint : 0
        guard cap > 0 else { return system }
        return system > 0 ? min(system, cap) : cap
    }

    /// Paměť, kterou aplikace ještě smí použít. 0 znamená „nic nezbývá“, ne „nevím“ –
    /// na to je `limit`.
    ///
    /// Dřív tady bylo obojí naráz a při překročení stropu se to rozbilo: `available`
    /// spadla na nulu, což všude znamenalo „limit se nedá zjistit“. `maxContext` pak
    /// přestal kontext zkracovat, ukazatel paměti zmizel a appka tvrdila, že běží
    /// na simulátoru. Strop se tím vypnul přesně ve chvíli, kdy měl začít platit.
    static var available: Int {
        let ceiling = limit
        guard ceiling > 0 else { return 0 }
        return max(0, ceiling - footprint)
    }

    /// Jak blízko je model ke stropu. Podle toho se za běhu ubírá plyn.
    enum Strain: Sendable {
        /// Místa dost, nic se neomezuje.
        case easy
        /// Zbývá míň než rezerva – uvolnit cache MLX a zmenšit prefill krok.
        case tight
        /// Zbývá míň než třetina rezervy – generování se ukončí, než přijde jetsam.
        case critical
    }

    static var strain: Strain {
        // Neznámý limit = simulátor; tam se neomezuje nic.
        guard limit > 0 else { return .easy }
        let free = available
        if free < reserve / 3 { return .critical }
        if free < reserve { return .tight }
        return .easy
    }

    /// Kolik paměti aplikace právě zabírá (phys_footprint – to, co počítá jetsam).
    static var footprint: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Celkový limit aplikace. 0 = neznámý (simulátor). Se zapnutým stropem je to
    /// strop, takže proti němu ukazuje i pruh v UI a počítá se z něj `pressure`.
    static var appLimit: Int { limit }

    /// Fyzická RAM, kterou aplikace opravdu drží – včetně stránek namapovaných ze souboru.
    /// U GGUF (llama.cpp mapuje váhy přes mmap) bývá výrazně vyšší než `footprint`:
    /// clean file-backed stránky se do footprintu nepočítají, protože je jádro může kdykoli
    /// zahodit a načíst znovu z disku. RAM ale zabírají.
    static var resident: Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    static var deviceMemory: Int { Int(ProcessInfo.processInfo.physicalMemory) }

    /// Čítače stránkování procesu: všechny výpadky stránek a z nich ty, kvůli kterým se četlo
    /// z úložiště (pageins). Výpadek bez čtení = stránka už byla v cache, jen se mapovala.
    struct PageCounters {
        var faults: Int
        var pageins: Int

        static var now: PageCounters {
            var info = task_events_info()
            var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return PageCounters(faults: 0, pageins: 0) }
            return PageCounters(faults: Int(UInt32(bitPattern: info.faults)), pageins: Int(UInt32(bitPattern: info.pageins)))
        }

        /// Rozdíl oproti dřívějšímu stavu (čítače jsou 32bitové – přetečení se ošetří).
        func since(_ earlier: PageCounters) -> PageCounters {
            let wrap = 1 << 32
            return PageCounters(
                faults: (faults - earlier.faults + wrap) % wrap,
                pageins: (pageins - earlier.pageins + wrap) % wrap
            )
        }
    }

    /// Paměť MLX (váhy, KV cache a buffery na GPU) – je součástí `footprint`. nil = MLX nic nedrží.
    static var mlxMemory: (active: Int, cache: Int)? {
        #if canImport(MLX)
        let active = Memory.activeMemory
        let cache = Memory.cacheMemory
        return active + cache > 0 ? (active, cache) : nil
        #else
        return nil
        #endif
    }

    /// Jak blízko je aplikace k limitu: 0 = prázdno, 1 = na hraně jetsamu.
    /// Vrací 0, když se limit nedá zjistit (simulátor) – volající pak nic neomezuje.
    static var pressure: Double {
        let limit = appLimit
        guard limit > 0 else { return 0 }
        return min(1, Double(footprint) / Double(limit))
    }

    /// Rezerva pro výpočetní buffery, UI a výkyvy.
    static let reserve = 450 * 1_048_576

    /// Nejdelší kontext (násobek 256), který se při `bytesPerToken` ještě vejde.
    /// Když se nedá zjistit, vrátí `requested`.
    ///
    /// - Parameter extraReserve: paměť, kterou aplikace fakticky drží, ale `available` ji
    ///   nevidí – u GGUF velikost namapovaného souboru s vahami. Bez toho by rozpočet
    ///   rozdal kontext, na který sice stačí jetsam limit, ale ne fyzická RAM.
    static func maxContext(bytesPerToken: Int, requested: Int, extraReserve: Int = 0) -> Int {
        guard limit > 0 else { return requested }
        let free = available
        // Když se velikost KV cache nepodařilo z modelu zjistit, počítá se s 144 kB na token
        // (KV cache 4B modelu ve f16). Dřív se v takovém případě vracela nastavená hodnota,
        // což u nastavených 131 072 tokenů znamenalo, že se rozpočet vůbec neuplatnil
        // a do modelu šly prompty, na které v paměti není místo.
        let perToken = bytesPerToken > 0 ? bytesPerToken : 147_456
        let fits = max(0, free - reserve - extraReserve) / perToken
        return min(requested, fits / 256 * 256)
    }
}

/// V paměti smí být naráz jen jeden lokální engine. Bez toho zůstane při přepnutí
/// z GGUF na MLX (nebo naopak) předchozí model načtený a nový se načítá vedle něj –
/// každý engine uvolňuje jen svůj vlastní předchozí model, o tom druhém neví.
/// Na iPhonu to znamená 3 + 3 GB a okamžitý jetsam.
enum LocalEngines {
    /// Uvolní všechny lokální enginy kromě toho, který se bude používat.
    /// `nil` = uvolnit oba (přepnutí na cloud nebo Apple Intelligence).
    static func keepOnly(_ kind: LocalModelKind?) async {
        if kind != .gguf { await LlamaEngine.shared.unload() }
        if kind != .mlx { await MLXEngine.shared.unload() }
    }
}

/// Stav lokálního modelu pro UI – na jaký kontext naposled stačila paměť.
@MainActor
@Observable
final class LocalRuntime {
    static let shared = LocalRuntime()

    /// Kontext, na který se musel nastavený zkrátit kvůli paměti. nil = nastavený se vešel.
    var memoryLimitedContext: Int?

    /// Kontext, se kterým engine naposled opravdu běžel. Na rozdíl od `memoryLimitedContext`
    /// se plní vždy – potřebuje ho `SummaryPipeline`, aby dělila dokument na kusy, které
    /// se do paměti vejdou, a ne podle nastavené hodnoty.
    var effectiveContext: Int?

    /// Rozložení načteného GGUF modelu, když jsou jeho experti streamovaní z úložiště.
    /// nil = model běží celý z RAM (nebo žádný GGUF model není načtený).
    var streamedExperts: GGUFLayout?
    /// Kde běží výpočet streamovaného MoE modelu.
    var streamingPlacement: StreamingPlacement = .cpuOnly
    /// Kolik bajtů husté části se přebalilo pro rychlá ARM jádra (0 = nic).
    var repackedDenseBytes = 0
    /// Kolik expertů na vrstvu model opravdu používá – po případném snížení v Parametrech.
    /// 0 = nestreamuje se. Liší se od `streamedExperts?.expertUsed`, což je hodnota ze souboru.
    var activeExperts = 0

    nonisolated static func reportStreaming(
        _ layout: GGUFLayout?,
        placement: StreamingPlacement,
        repackedBytes: Int,
        expertUsed: Int = 0
    ) {
        Task { @MainActor in
            LocalRuntime.shared.streamedExperts = layout
            LocalRuntime.shared.streamingPlacement = placement
            LocalRuntime.shared.repackedDenseBytes = repackedBytes
            LocalRuntime.shared.activeExperts = expertUsed
        }
    }

    /// Volá se z enginů (mimo hlavní vlákno).
    nonisolated static func report(requested: Int, effective: Int) {
        Task { @MainActor in
            LocalRuntime.shared.memoryLimitedContext = effective < requested ? effective : nil
            LocalRuntime.shared.effectiveContext = effective
        }
    }
}

enum StreamingPlacement: Sendable {
    /// Všechno na CPU (výchozí – na iPhonu nejrychlejší).
    case cpuOnly
    /// GPU zapnuté v nastavení, ale soubor nemá hustou část pohromadě – běží na CPU.
    case cpuOnlyInterleaved
    /// Hustá část na GPU, experti na CPU.
    case hybrid
}
