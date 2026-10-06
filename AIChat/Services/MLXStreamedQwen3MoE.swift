#if canImport(MLXLLM)
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// Qwen3-MoE pro MLX s experty z úložiště (viz `MLXExpertStore`). Hustá část je kopie
// Qwen3MoE.swift z mlx-swift-lm 3.31.4 (tamní třídy nejsou veřejné), MoE blok je vlastní:
// v každé vrstvě počká na výběr routeru, doplní chybějící experty do slotů a počítá nad sloty.

struct StreamedQwen3MoEConfiguration: Decodable, Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var numExperts: Int
    var numExpertsPerToken: Int
    var decoderSparseStep: Int
    var mlpOnlyLayers: [Int]
    var moeIntermediateSize: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var kvHeads: Int
    var headDim: Int
    var ropeTheta: Float
    var tieWordEmbeddings: Bool
    var normTopkProb: Bool
    var ropeScaleFactor: Float?

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case numExperts = "num_experts"
        case numExpertsPerToken = "num_experts_per_tok"
        case decoderSparseStep = "decoder_sparse_step"
        case mlpOnlyLayers = "mlp_only_layers"
        case moeIntermediateSize = "moe_intermediate_size"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case ropeTheta = "rope_theta"
        case tieWordEmbeddings = "tie_word_embeddings"
        case normTopkProb = "norm_topk_prob"
        case ropeScaling = "rope_scaling"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        hiddenLayers = try c.decode(Int.self, forKey: .hiddenLayers)
        intermediateSize = try c.decode(Int.self, forKey: .intermediateSize)
        attentionHeads = try c.decode(Int.self, forKey: .attentionHeads)
        numExperts = try c.decode(Int.self, forKey: .numExperts)
        numExpertsPerToken = try c.decode(Int.self, forKey: .numExpertsPerToken)
        decoderSparseStep = try c.decodeIfPresent(Int.self, forKey: .decoderSparseStep) ?? 1
        mlpOnlyLayers = try c.decodeIfPresent([Int].self, forKey: .mlpOnlyLayers) ?? []
        moeIntermediateSize = try c.decode(Int.self, forKey: .moeIntermediateSize)
        rmsNormEps = try c.decode(Float.self, forKey: .rmsNormEps)
        vocabularySize = try c.decode(Int.self, forKey: .vocabularySize)
        kvHeads = try c.decode(Int.self, forKey: .kvHeads)
        headDim = try c.decode(Int.self, forKey: .headDim)
        ropeTheta = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 1_000_000
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        normTopkProb = try c.decodeIfPresent(Bool.self, forKey: .normTopkProb) ?? false
        // Jen lineární škálování RoPE, jako v originále; jiné typy se ignorují.
        if let scaling = try? c.decodeIfPresent([String: StringOrNumber].self, forKey: .ropeScaling),
           scaling["type"] == .string("linear"), let factor = scaling["factor"]?.asFloat() {
            ropeScaleFactor = factor
        } else {
            ropeScaleFactor = nil
        }
    }
}

final class StreamedQwen3MoEAttention: Module {
    let args: StreamedQwen3MoEConfiguration
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE

    init(_ args: StreamedQwen3MoEConfiguration) {
        self.args = args
        let dim = args.hiddenSize
        scale = pow(Float(args.headDim), -0.5)
        _wq.wrappedValue = Linear(dim, args.attentionHeads * args.headDim, bias: false)
        _wk.wrappedValue = Linear(dim, args.kvHeads * args.headDim, bias: false)
        _wv.wrappedValue = Linear(dim, args.kvHeads * args.headDim, bias: false)
        _wo.wrappedValue = Linear(args.attentionHeads * args.headDim, dim, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: args.headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: args.headDim, eps: args.rmsNormEps)
        rope = RoPE(dimensions: args.headDim, traditional: false, base: args.ropeTheta,
                    scale: args.ropeScaleFactor.map { 1 / $0 } ?? 1)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        var queries = qNorm(wq(x).reshaped(B, L, args.attentionHeads, -1)).transposed(0, 2, 1, 3)
        var keys = kNorm(wk(x).reshaped(B, L, args.kvHeads, -1)).transposed(0, 2, 1, 3)
        let values = wv(x).reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        let output = attentionWithCacheUpdate(
            queries: queries, keys: keys, values: values, cache: cache, scale: scale, mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)
        return wo(output)
    }
}

final class StreamedQwen3MoEMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

/// MoE blok s experty ve slotech `MLXExpertStore`. Váhy expertů nejsou parametry modulu –
/// načítání vah je tak nevidí a nenačte (viz `StreamedQwen3MoEModel.sanitize`).
/// Odkaz na další vrstvu pro odhad jejích expertů. Schválně ne `Module` – jinak by ji
/// načítání vah bralo jako další potomky. Moduly se čtou až za běhu, protože kvantizace
/// při načtení nahradí `Linear` za `QuantizedLinear`.
final class StreamedNextLayer {
    weak var layer: StreamedQwen3MoEDecoderLayer?
}

final class StreamedQwen3MoESparseBlock: Module, UnaryLayer {
    let layer: Int
    let topK: Int
    let normTopkProb: Bool
    let store: MLXExpertStore
    let next = StreamedNextLayer()
    /// Předčítat experty další vrstvy podle jejího routeru (fáze 2).
    var prefetch = true

    @ModuleInfo(key: "gate") var gate: Linear

    init(_ args: StreamedQwen3MoEConfiguration, layer: Int, store: MLXExpertStore) {
        self.layer = layer
        topK = args.numExpertsPerToken
        normTopkProb = args.normTopkProb
        self.store = store
        _gate.wrappedValue = Linear(args.hiddenSize, args.numExperts, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        callAsFunction(x, residual: nil)
    }

    /// `residual` = vstup MoE před normou (reziduální proud po attention). Z něj a routeru
    /// další vrstvy se odhadnou její experti – stejně jako u GGUF (`RouterPredictor`), jen
    /// na GPU a v témže vyhodnocení jako výběr této vrstvy.
    func callAsFunction(_ x: MLXArray, residual: MLXArray?) -> MLXArray {
        let gates = gate(x)
        let softGates = softmax(gates, axis: -1, precise: true)
        let inds = argPartition(negative(gates), kth: topK - 1, axis: -1)[.ellipsis, ..<topK]
        var scores = takeAlong(softGates, inds, axis: -1)
        if normTopkProb {
            scores = scores / scores.sum(axis: -1, keepDims: true)
        }

        // Odhad expertů další vrstvy – jen při generování (jeden token), u prefillu nedává smysl.
        var predicted: (layer: Int, indices: MLXArray)?
        if prefetch, store.prefetchEnabled, let residual, x.dim(0) == 1, x.dim(1) == 1,
           let nextLayer = next.layer, let nextBlock = nextLayer.mlp as? StreamedQwen3MoESparseBlock {
            let logits = nextBlock.gate(nextLayer.postAttentionLayerNorm(residual))
            let order = argPartition(negative(logits), kth: nextBlock.topK - 1, axis: -1)[.ellipsis, ..<nextBlock.topK]
            predicted = (nextBlock.layer, order)
        }

        // Synchronizace: bez výběru routeru není co číst. Vyhodnotí se i celý graf před tím.
        if let predicted {
            eval(inds, scores, predicted.indices)
            // Čtení další vrstvy na pozadí – běží souběžně s výpočtem této vrstvy.
            store.prefetch(layer: predicted.layer, experts: Array(Set(predicted.indices.asArray(UInt32.self).map(Int.init))))
        } else {
            eval(inds, scores)
        }
        let chosen = inds.asArray(UInt32.self).map(Int.init)
        let unique = Array(Set(chosen)).sorted()

        if unique.count <= store.slots {
            let (map, pending) = store.lookup(layer: layer, experts: unique)
            let missing = Set(pending.map(\.expert))
            // Někteří experti chybějí: GPU mezitím spočítá ty, co ve slotech jsou, a chybějící
            // se čtou z flash. MoE je vážený součet přes experty, takže se obě části sečtou.
            // Chybějící se v první části mapují na slot přítomného experta s nulovou vahou –
            // slot, do kterého se právě čte, GPU číst nesmí (rozepsaná data mohou být NaN).
            if !missing.isEmpty, store.overlapReads,
               let presentSlot = unique.first(where: { !missing.contains($0) }).flatMap({ map[$0] }),
               let missingSlot = pending.first?.slot {
                let present = chosen.map { missing.contains($0) ? Float(0) : Float(1) }
                let firstSlots = MLXArray(chosen.map { UInt32(missing.contains($0) ? presentSlot : (map[$0] ?? presentSlot)) }, inds.shape)
                let firstMask = MLXArray(present, inds.shape).asType(scores.dtype)
                let first = weightedExpertSum(experts(x, slots: firstSlots), scores * firstMask)
                asyncEval([first])
                store.load(layer: layer, pending)
                let secondSlots = MLXArray(chosen.map { UInt32(missing.contains($0) ? (map[$0] ?? missingSlot) : missingSlot) }, inds.shape)
                let secondMask = MLXArray(present.map { 1 - $0 }, inds.shape).asType(scores.dtype)
                let second = weightedExpertSum(experts(x, slots: secondSlots), scores * secondMask)
                return first + second
            }
            store.load(layer: layer, pending)
            let slots = MLXArray(chosen.map { UInt32(map[$0] ?? 0) }, inds.shape)
            return weightedExpertSum(experts(x, slots: slots), scores)
        }

        // Prefill: dávka vybrala víc expertů, než je slotů – po skupinách. Každá skupina se
        // spočítá (s nulovou vahou pro experty mimo ni) a vyhodnotí dřív, než další skupina
        // sloty přepíše.
        var output = MLXArray.zeros(like: x)
        var start = 0
        while start < unique.count {
            let group = Array(unique[start ..< min(unique.count, start + store.slots)])
            start += group.count
            let map = store.ensure(layer: layer, experts: group)
            let slots = MLXArray(chosen.map { UInt32(map[$0] ?? 0) }, inds.shape)
            let mask = MLXArray(chosen.map { map[$0] == nil ? Float(0) : Float(1) }, inds.shape).asType(scores.dtype)
            output = output + weightedExpertSum(experts(x, slots: slots), scores * mask).asType(x.dtype)
            eval(output)
        }
        return output
    }

    /// SwitchGLU nad sloty: `x` [B, L, H], `slots` [B, L, k] → [B, L, k, H].
    private func experts(_ input: MLXArray, slots indices: MLXArray) -> MLXArray {
        let pool = store.arrays(layer: layer)
        let gateQ = store.quantization(layer: layer, projection: "gate_proj")
        let upQ = store.quantization(layer: layer, projection: "up_proj")
        let downQ = store.quantization(layer: layer, projection: "down_proj")

        var x = expandedDimensions(input, axes: [-2, -3])
        let sort = indices.size >= 64
        var idx = indices
        var inverse = MLXArray()
        if sort {
            (x, idx, inverse) = gatherSort(x: x, indices: indices)
        }
        let up = gatherQuantizedMM(
            x, pool[3], scales: pool[4], biases: pool[5], rhsIndices: idx,
            transpose: true, groupSize: upQ.groupSize, bits: upQ.bits, sortedIndices: sort)
        let gate = gatherQuantizedMM(
            x, pool[0], scales: pool[1], biases: pool[2], rhsIndices: idx,
            transpose: true, groupSize: gateQ.groupSize, bits: gateQ.bits, sortedIndices: sort)
        x = gatherQuantizedMM(
            compiledSiluProduct(gate, up), pool[6], scales: pool[7], biases: pool[8], rhsIndices: idx,
            transpose: true, groupSize: downQ.groupSize, bits: downQ.bits, sortedIndices: sort)
        if sort {
            x = scatterUnsort(x: x, invOrder: inverse, shape: indices.shape)
        }
        return squeezed(x, axis: -2)
    }
}

final class StreamedQwen3MoEDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: StreamedQwen3MoEAttention
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    let mlp: UnaryLayer

    init(_ args: StreamedQwen3MoEConfiguration, layer: Int, store: MLXExpertStore) {
        _selfAttn.wrappedValue = StreamedQwen3MoEAttention(args)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        if !args.mlpOnlyLayers.contains(layer), args.numExperts > 0, (layer + 1) % args.decoderSparseStep == 0 {
            mlp = StreamedQwen3MoESparseBlock(args, layer: layer, store: store)
        } else {
            mlp = StreamedQwen3MoEMLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        }
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let h = x + selfAttn(inputLayerNorm(x), mask: mask, cache: cache)
        if let block = mlp as? StreamedQwen3MoESparseBlock {
            return h + block(postAttentionLayerNorm(h), residual: h)
        }
        return h + mlp(postAttentionLayerNorm(h))
    }
}

final class StreamedQwen3MoEInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    let layers: [StreamedQwen3MoEDecoderLayer]
    let norm: RMSNorm

    init(_ args: StreamedQwen3MoEConfiguration, store: MLXExpertStore) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        layers = (0 ..< args.hiddenLayers).map { StreamedQwen3MoEDecoderLayer(args, layer: $0, store: store) }
        norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        for index in 0 ..< max(0, layers.count - 1) {
            (layers[index].mlp as? StreamedQwen3MoESparseBlock)?.next.layer = layers[index + 1]
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var h = embedTokens(inputs)
        let mask = createAttentionMask(h: h, cache: cache?.first)
        for (index, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[index])
        }
        return norm(h)
    }
}

final class StreamedQwen3MoEModel: Module, LLMModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let kvHeads: [Int]
    let configuration: StreamedQwen3MoEConfiguration
    let store: MLXExpertStore

    @ModuleInfo(key: "model") var model: StreamedQwen3MoEInner
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ args: StreamedQwen3MoEConfiguration, store: MLXExpertStore) {
        configuration = args
        vocabularySize = args.vocabularySize
        kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.store = store
        _model.wrappedValue = StreamedQwen3MoEInner(args, store: store)
        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let out = model(inputs, cache: cache)
        if let lmHead { return lmHead(out) }
        return model.embedTokens.asLinear(out)
    }

    /// Experti se z vah vynechají – MLX safetensors načítá líně, takže se vůbec nepřečtou.
    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        weights.filter { key, _ in
            if configuration.tieWordEmbeddings, key.hasPrefix("lm_head.") { return false }
            return !key.contains(".mlp.switch_mlp.") && !key.contains(".mlp.experts.")
        }
    }

    var loraLayers: [Module] { model.layers }

    /// Zapne nebo vypne předčítání expertů další vrstvy.
    func setPrefetch(_ enabled: Bool) {
        for layer in model.layers {
            (layer.mlp as? StreamedQwen3MoESparseBlock)?.prefetch = enabled
        }
    }
}
#endif
