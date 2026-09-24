import Foundation
import os
#if canImport(llama)
import llama
#endif

/// Rozložení vah v GGUF souboru: kolik bajtů jsou routovaní experti MoE a kolik zbytek
/// (attention, embeddingy, normy, router, sdílení experti).
///
/// Na tom stojí streamování expertů: hustá část jde na Metal a zůstává v RAM, experti
/// zůstanou namapovaní ze souboru na CPU a jádro si je načítá z flash podle toho,
/// na které router zrovna sáhne. Page cache pak funguje jako LRU cache expertů.
struct GGUFLayout: Sendable, Equatable {
    /// Velikost dat všech tenzorů.
    let totalBytes: Int
    /// Tenzory routovaných expertů (`blk.N.ffn_{up,down,gate,gate_up}_exps` a `_chexps`).
    let expertBytes: Int
    /// Počet expertů na vrstvu a kolik jich router vybírá (0 = neuvedeno / není MoE).
    let expertCount: Int
    let expertUsed: Int
    /// `general.architecture` ze souboru („qwen3moe“). Potřebné pro klíč přepisu
    /// `<architektura>.expert_used_count` při snižování počtu aktivních expertů.
    let architecture: String
    /// Rozpětí v souboru od prvního po poslední konec tenzorů, které jdou na GPU
    /// (všechno kromě expertů a `token_embd`, který llama.cpp nechává na CPU).
    let gpuSpanBytes: Int
    /// Součet velikostí těch tenzorů.
    let gpuBytes: Int
    /// Tenzory expertů podle vrstvy: kde v souboru leží (absolutní offset) a kolik mají bajtů.
    /// Experti jsou v tenzoru za sebou, jeden expert = `bytes / expertCount`.
    let expertTensors: [Int: [ExpertTensor]]

    /// 2D matice husté části, které se násobí na CPU (attention, výstupní vrstva) –
    /// kandidáti na přebalení vah pro rychlejší ARM jádra (viz `LlamaEngine.repackOverrides`).
    let denseMatrices: [DenseMatrix]

    /// Routery MoE (`blk.N.ffn_gate_inp.weight`) podle vrstvy. Slouží k odhadu expertů další
    /// vrstvy dřív, než se k ní výpočet dostane (`ExpertPrefetcher`, záznam trace).
    let routerTensors: [Int: RouterTensor]
    /// Uzel grafu llama.cpp se vstupem MoE, ze kterého se odhadují experti další vrstvy:
    /// `ffn_inp` (reziduální proud, Qwen3 MoE) nebo `attn_post_norm` (už normovaný vstup –
    /// Qwen3.5/3.6 MoE a Qwen3-Next, které `ffn_norm` nemají a normu před MoE počítají
    /// jako `post_attention_norm`).
    let moeInputNode: String
    /// Vstup z `moeInputNode` je už vynásobený normou své vrstvy – odhad ji musí nejdřív vydělit.
    let moeInputNormalized: Bool
    /// Architektury, kde je norma před MoE uložená jako `post_attention_norm`.
    static let postNormArchitectures: Set<String> = ["qwen35moe", "qwen3next"]

    struct RouterTensor: Sendable, Equatable {
        /// Absolutní offset v souboru.
        let fileOffset: Int
        let bytes: Int
        /// `ggml_type` jako číslo (rawValue). llama-quantize routery nekvantuje – bývají F32.
        let type: UInt32
        /// `ne[0]` – šířka skrytého stavu, `ne[1]` – počet expertů.
        let embedding: Int
        let experts: Int
        /// RMSNorm před MoE téže vrstvy (`blk.N.ffn_norm.weight`) – router vidí vstup vynásobený
        /// touhle vahou. nil = v souboru není (odhad pak nejde).
        let norm: NormTensor?
    }

    struct NormTensor: Sendable, Equatable {
        let fileOffset: Int
        let bytes: Int
        let type: UInt32
    }

    struct DenseMatrix: Sendable, Equatable {
        let name: String
        /// `ggml_type` jako číslo (rawValue).
        let type: UInt32
        /// `ne[1]` – počet řádků matice; repacking vyžaduje násobek 4 nebo 8.
        let rows: Int
        let bytes: Int
    }

    struct ExpertTensor: Sendable, Equatable {
        let name: String
        let fileOffset: Int
        let bytes: Int
    }

    /// Leží tenzory pro GPU v souboru pohromadě?
    ///
    /// Metal umí sdílet namapovaný soubor jen jako souvislý `MTLBuffer` od prvního po poslední
    /// tenzor. V běžném GGUF se attention a experti střídají vrstvu po vrstvě, takže by buffer
    /// pokryl skoro celý soubor – a Metal si stránky bufferu drží v paměti (residency set,
    /// wiring při výpočtu). U 18GB modelu to znamená načíst celý soubor do RAM a pád.
    /// Pohromadě jsou jen v přeuspořádaném souboru (`tools/gguf_moe_reorder.py`).
    var gpuTensorsContiguous: Bool {
        gpuSpanBytes <= gpuBytes + gpuBytes / 4 + 64 * 1_048_576
    }

    /// Všechno kromě routovaných expertů – to musí být v RAM pořád.
    var denseBytes: Int { max(0, totalBytes - expertBytes) }

    /// MoE se streamováním má smysl jen tam, kde experti tvoří podstatnou část souboru.
    var isMoE: Bool { expertBytes > 0 && expertBytes * 2 > totalBytes }

    /// Stejný vzor, jaký používá llama.cpp pro `--cpu-moe` (`LLM_FFN_EXPS_REGEX` v common.h).
    /// Předává se do `tensor_buft_overrides`, proto C řetězec, který žije po celou dobu běhu.
    static let expertPattern = #"\.ffn_(up|down|gate|gate_up)_(ch|)exps"#

    static func isExpertTensor(_ name: String) -> Bool {
        name.range(of: expertPattern, options: .regularExpression) != nil
    }

    /// Hrubý odhad z názvu souboru ještě před stažením: „…-30B-A3B-…“, „…_A22B…“ = MoE.
    /// Slouží jen pro doporučení ve stahování, engine se řídí skutečným obsahem souboru.
    static func looksLikeMoE(fileName: String) -> Bool {
        fileName.range(of: #"(^|[-_.])A\d+(\.\d+)?B([-_.]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Podíl husté části u MoE, když ho ještě neznáme (před stažením). Qwen3-30B-A3B má
    /// v Q4_K_M zhruba 6 %, Gemma a novější modely se sdílenými experty víc – bereme opatrně.
    static let assumedDenseShare = 0.15

#if canImport(llama)
    private static let cache = LayoutCache()

    /// Přečte jen hlavičku GGUF (tenzory se nenačítají), výsledek si pamatuje podle cesty,
    /// velikosti a data změny souboru.
    static func read(path: String) -> GGUFLayout? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(modified)"
        if let cached = cache.value(for: key) { return cached }

        // ctx: metadata tenzorů (rozměry) bez dat – no_alloc nic nenačítá.
        var tensorContext: OpaquePointer?
        let opened = withUnsafeMutablePointer(to: &tensorContext) { pointer in
            gguf_init_from_file(path, gguf_init_params(no_alloc: true, ctx: pointer))
        }
        guard let context = opened else {
            if let tensorContext { ggml_free(tensorContext) }
            return nil
        }
        defer {
            gguf_free(context)
            if let tensorContext { ggml_free(tensorContext) }
        }

        var total = 0
        var experts = 0
        var gpuBytes = 0
        var gpuStart = Int.max
        var gpuEnd = 0
        var expertTensors: [Int: [ExpertTensor]] = [:]
        var denseMatrices: [DenseMatrix] = []
        var routerTensors: [Int: RouterTensor] = [:]
        var normTensors: [Int: NormTensor] = [:]
        var postNormTensors: [Int: NormTensor] = [:]
        let architecture = string(context, "general.architecture") ?? ""
        let dataOffset = Int(gguf_get_data_offset(context))
        for index in 0..<gguf_get_n_tensors(context) {
            let bytes = Int(gguf_get_tensor_size(context, index))
            total += bytes
            let name = gguf_get_tensor_name(context, index).map { String(cString: $0) } ?? ""
            if isExpertTensor(name) {
                experts += bytes
                if let layer = layerIndex(name) {
                    let offset = dataOffset + Int(gguf_get_tensor_offset(context, index))
                    expertTensors[layer, default: []].append(ExpertTensor(name: name, fileOffset: offset, bytes: bytes))
                }
            } else if !name.hasPrefix("token_embd.") {
                if name.hasSuffix(".ffn_norm.weight") || name.hasSuffix(".post_attention_norm.weight"),
                   let layer = layerIndex(name) {
                    let norm = NormTensor(
                        fileOffset: dataOffset + Int(gguf_get_tensor_offset(context, index)),
                        bytes: bytes,
                        type: gguf_get_tensor_type(context, index).rawValue
                    )
                    if name.hasSuffix(".ffn_norm.weight") { normTensors[layer] = norm } else { postNormTensors[layer] = norm }
                }
                if name.hasSuffix(".ffn_gate_inp.weight"), let layer = layerIndex(name), let tensorContext,
                   let meta = ggml_get_tensor(tensorContext, name), meta.pointee.ne.2 == 1, meta.pointee.ne.3 == 1 {
                    routerTensors[layer] = RouterTensor(
                        fileOffset: dataOffset + Int(gguf_get_tensor_offset(context, index)),
                        bytes: bytes,
                        type: meta.pointee.type.rawValue,
                        embedding: Int(meta.pointee.ne.0),
                        experts: Int(meta.pointee.ne.1),
                        norm: nil
                    )
                }
                if isDenseMatrixName(name), let tensorContext, let meta = ggml_get_tensor(tensorContext, name),
                   meta.pointee.ne.2 == 1, meta.pointee.ne.3 == 1, meta.pointee.ne.1 > 1 {
                    denseMatrices.append(DenseMatrix(
                        name: name,
                        type: meta.pointee.type.rawValue,
                        rows: Int(meta.pointee.ne.1),
                        bytes: bytes
                    ))
                }
                let offset = Int(gguf_get_tensor_offset(context, index))
                gpuBytes += bytes
                gpuStart = min(gpuStart, offset)
                gpuEnd = max(gpuEnd, offset + bytes)
            }
        }

        // Qwen3.5/3.6 MoE nemá `ffn_norm`: norma před MoE je `post_attention_norm` a v grafu
        // je její výstup jako `attn_post_norm-N` (reziduální vstup tam pojmenovaný není).
        // U jiných architektur `post_attention_norm` znamená normu výstupu attention – proto
        // jen pro vyjmenované architektury.
        let postNorm = normTensors.isEmpty && !postNormTensors.isEmpty
            && postNormArchitectures.contains(architecture)
        let moeNorms = postNorm ? postNormTensors : normTensors
        for (layer, router) in routerTensors {
            routerTensors[layer] = RouterTensor(
                fileOffset: router.fileOffset, bytes: router.bytes, type: router.type,
                embedding: router.embedding, experts: router.experts, norm: moeNorms[layer]
            )
        }

        let layout = GGUFLayout(
            totalBytes: total,
            expertBytes: experts,
            expertCount: integer(context, "\(architecture).expert_count"),
            expertUsed: integer(context, "\(architecture).expert_used_count"),
            architecture: architecture,
            gpuSpanBytes: gpuEnd > gpuStart ? gpuEnd - gpuStart : 0,
            gpuBytes: gpuBytes,
            expertTensors: expertTensors,
            denseMatrices: denseMatrices,
            routerTensors: routerTensors,
            moeInputNode: postNorm ? "attn_post_norm" : "ffn_inp",
            moeInputNormalized: postNorm
        )
        cache.set(layout, for: key)
        return layout
    }

    /// Matice násobené v každém tokenu mimo experty: projekce attention a výstupní vrstva.
    /// (token_embd se jen indexuje, normy a router jsou malé nebo F32.)
    private static func isDenseMatrixName(_ name: String) -> Bool {
        if name == "output.weight" { return true }
        guard name.hasPrefix("blk."), name.hasSuffix(".weight") else { return false }
        return [".attn_q.", ".attn_k.", ".attn_v.", ".attn_output.", ".attn_qkv."].contains { name.contains($0) }
    }

    /// „blk.12.ffn_up_exps.weight“ → 12
    private static func layerIndex(_ name: String) -> Int? {
        guard name.hasPrefix("blk.") else { return nil }
        return Int(name.dropFirst(4).prefix { $0.isNumber })
    }

    /// Rozměry modelu z metadat: `<arch>.<klíč>` pro zadané klíče a velikost slovníku.
    /// Chybějící klíč = 0. Pro modelování výpočtu v `MLXMoEProbe`.
    static func dimensions(path: String, keys: [String]) -> (architecture: String, values: [String: Int], vocabulary: Int)? {
        guard let context = gguf_init_from_file(path, gguf_init_params(no_alloc: true, ctx: nil)) else { return nil }
        defer { gguf_free(context) }
        let architecture = string(context, "general.architecture") ?? ""
        var values: [String: Int] = [:]
        for key in keys { values[key] = integer(context, "\(architecture).\(key)") }
        let tokens = gguf_find_key(context, "tokenizer.ggml.tokens")
        let vocabulary = tokens >= 0 ? Int(gguf_get_arr_n(context, tokens)) : 0
        return (architecture, values, vocabulary)
    }

    private static func string(_ context: OpaquePointer, _ key: String) -> String? {
        let id = gguf_find_key(context, key)
        guard id >= 0, gguf_get_kv_type(context, id) == GGUF_TYPE_STRING,
              let value = gguf_get_val_str(context, id) else { return nil }
        return String(cString: value)
    }

    private static func integer(_ context: OpaquePointer, _ key: String) -> Int {
        let id = gguf_find_key(context, key)
        guard id >= 0 else { return 0 }
        switch gguf_get_kv_type(context, id) {
        case GGUF_TYPE_UINT32: return Int(gguf_get_val_u32(context, id))
        case GGUF_TYPE_INT32: return Int(gguf_get_val_i32(context, id))
        case GGUF_TYPE_UINT64: return Int(gguf_get_val_u64(context, id))
        case GGUF_TYPE_INT64: return Int(gguf_get_val_i64(context, id))
        default: return 0
        }
    }
#endif
}

#if canImport(llama)
/// Malá vláknově bezpečná cache – `read` se volá z actoru enginu i z UI.
private final class LayoutCache: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String: GGUFLayout]())

    func value(for key: String) -> GGUFLayout? {
        storage.withLock { $0[key] }
    }

    func set(_ value: GGUFLayout, for key: String) {
        storage.withLock { $0[key] = value }
    }
}
#endif
