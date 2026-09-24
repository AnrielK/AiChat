#if canImport(MLXLLM)
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// Architektura `spark2_5` (Spark-X2.5 od XHToken) pro MLX. mlx-swift-lm ji zatím nezná,
// takže načtení skončí „Unsupported model type“. Port Python implementace z mlx-lm
// (PR #1891, mlx_lm/models/spark2_5.py): střídání sliding/full attention jako Gemma 3
// a Olmo 3, sloučená projekce Q/K/V, sigmoid brána výstupu attention po hlavách,
// částečné RoPE s vlastním základem pro každý typ vrstvy a GELU v MLP.
// Registruje se za běhu (`MLXSpark25.register()`) před načtením modelu.

enum MLXSpark25 {
    private static let registration = Registration()

    /// Přidá `spark2_5` do registru modelů mlx-swift-lm (stačí jednou).
    static func register() async {
        guard await registration.claim() else { return }
        await LLMTypeRegistry.shared.registerModelType("spark2_5") { data in
            let configuration = try JSONDecoder().decode(Spark25Configuration.self, from: data)
            return Spark25Model(configuration)
        }
    }

    private actor Registration {
        private var done = false
        func claim() -> Bool {
            defer { done = true }
            return !done
        }
    }
}

// MARK: - Konfigurace

struct Spark25Configuration: Codable, Sendable {
    struct Rope: Codable, Sendable {
        var partialRotaryFactor: Float = 1
        var ropeTheta: Float = 10_000

        enum CodingKeys: String, CodingKey {
            case partialRotaryFactor = "partial_rotary_factor"
            case ropeTheta = "rope_theta"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            partialRotaryFactor = try container.decodeIfPresent(Float.self, forKey: .partialRotaryFactor) ?? 1
            ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 10_000
        }
    }

    var hiddenSize: Int
    var intermediateSize: Int
    var hiddenLayers: Int
    var attentionHeads: Int
    var kvHeads: Int
    var headDim: Int
    var vocabularySize: Int
    var slidingWindow: Int
    var ropeParameters: [String: Rope]
    var layerTypes: [String]
    var rmsNormEps: Float
    var attentionBias: Bool
    var mlpBias: Bool
    var tieWordEmbeddings: Bool

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case hiddenLayers = "num_hidden_layers"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case vocabularySize = "vocab_size"
        case slidingWindow = "sliding_window"
        case ropeParameters = "rope_parameters"
        case layerTypes = "layer_types"
        case rmsNormEps = "rms_norm_eps"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        hiddenLayers = try container.decode(Int.self, forKey: .hiddenLayers)
        attentionHeads = try container.decode(Int.self, forKey: .attentionHeads)
        kvHeads = try container.decodeIfPresent(Int.self, forKey: .kvHeads) ?? attentionHeads
        headDim = try container.decodeIfPresent(Int.self, forKey: .headDim) ?? hiddenSize / attentionHeads
        vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
        slidingWindow = try container.decode(Int.self, forKey: .slidingWindow)
        ropeParameters = try container.decode([String: Rope].self, forKey: .ropeParameters)
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        attentionBias = try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        mlpBias = try container.decodeIfPresent(Bool.self, forKey: .mlpBias) ?? false
        tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        // Oficiální checkpointy typy vrstev vypisují; výchozí vzor jsou tři sliding a jedna full.
        if let types = try container.decodeIfPresent([String].self, forKey: .layerTypes) {
            layerTypes = types
        } else {
            layerTypes = (0 ..< hiddenLayers).map { ($0 + 1) % 4 == 0 ? "full_attention" : "sliding_attention" }
        }
    }
}

// MARK: - Vrstvy

final class Spark25Attention: Module {
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let scale: Float
    let qSize: Int
    let kvSize: Int
    let isSliding: Bool

    @ModuleInfo(key: "q_k_v_proj") var qkvProj: Linear
    @ModuleInfo(key: "g_proj") var gProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    let rope: RoPE

    init(_ args: Spark25Configuration, layer: Int) {
        heads = args.attentionHeads
        kvHeads = args.kvHeads
        headDim = args.headDim
        scale = pow(Float(headDim), -0.5)
        qSize = heads * headDim
        kvSize = kvHeads * headDim
        let type = args.layerTypes[layer]
        isSliding = type == "sliding_attention"

        _qkvProj.wrappedValue = Linear(args.hiddenSize, qSize + 2 * kvSize, bias: args.attentionBias)
        _gProj.wrappedValue = Linear(args.hiddenSize, heads, bias: args.attentionBias)
        _outProj.wrappedValue = Linear(qSize, args.hiddenSize, bias: args.attentionBias)

        let parameters = args.ropeParameters[type]
        let dimensions = Int(Float(headDim) * (parameters?.partialRotaryFactor ?? 1))
        rope = RoPE(dimensions: dimensions, traditional: false, base: parameters?.ropeTheta ?? 10_000)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))

        let parts = split(qkvProj(x), indices: [qSize, qSize + kvSize], axis: -1)
        var queries = contiguous(parts[0].reshaped(batch, length, heads, headDim).transposed(0, 2, 1, 3))
        var keys = contiguous(parts[1].reshaped(batch, length, kvHeads, headDim).transposed(0, 2, 1, 3))
        let values = contiguous(parts[2].reshaped(batch, length, kvHeads, headDim).transposed(0, 2, 1, 3))

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        let output = contiguous(
            attentionWithCacheUpdate(
                queries: queries, keys: keys, values: values,
                cache: cache, scale: scale, mask: mask
            )
            .transposed(0, 2, 1, 3)
        )

        // Brána po hlavách: sigmoid ve f32, pak zpět do typu výstupu.
        let gate = sigmoid(gProj(x).asType(.float32)).asType(output.dtype)
        let gated = output * expandedDimensions(gate, axis: -1)
        return outProj(gated.reshaped(batch, length, -1))
    }
}

final class Spark25MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(_ args: Spark25Configuration) {
        _gate.wrappedValue = Linear(args.hiddenSize, args.intermediateSize, bias: args.mlpBias)
        _up.wrappedValue = Linear(args.hiddenSize, args.intermediateSize, bias: args.mlpBias)
        _down.wrappedValue = Linear(args.intermediateSize, args.hiddenSize, bias: args.mlpBias)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(gelu(gate(x)) * up(x))
    }
}

final class Spark25Block: Module {
    @ModuleInfo(key: "self_attn") var attention: Spark25Attention
    @ModuleInfo(key: "mlp") var mlp: Spark25MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    var isSliding: Bool { attention.isSliding }

    init(_ args: Spark25Configuration, layer: Int) {
        _attention.wrappedValue = Spark25Attention(args, layer: layer)
        _mlp.wrappedValue = Spark25MLP(args)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let h = x + attention(inputLayerNorm(x), mask: mask, cache: cache)
        return h + mlp(postAttentionLayerNorm(h))
    }
}

final class Spark25Inner: Module {
    @ModuleInfo(key: "embedding") var embedding: Embedding

    let layers: [Spark25Block]
    let norm: RMSNorm
    let slidingWindow: Int
    let firstFull: Int?
    let firstSliding: Int?

    init(_ args: Spark25Configuration) {
        _embedding.wrappedValue = Embedding(embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        layers = (0 ..< args.hiddenLayers).map { Spark25Block(args, layer: $0) }
        norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        slidingWindow = args.slidingWindow
        firstFull = args.layerTypes.firstIndex(of: "full_attention")
        firstSliding = args.layerTypes.firstIndex(of: "sliding_attention")
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var h = embedding(inputs)
        let fullMask = createAttentionMask(h: h, cache: firstFull.flatMap { cache?[$0] })
        let slidingMask = createAttentionMask(
            h: h, cache: firstSliding.flatMap { cache?[$0] }, windowSize: slidingWindow)
        for (index, layer) in layers.enumerated() {
            h = layer(h, mask: layer.isSliding ? slidingMask : fullMask, cache: cache?[index])
        }
        return norm(h)
    }
}

final class Spark25Model: Module, LLMModel {
    let vocabularySize: Int
    let args: Spark25Configuration

    @ModuleInfo(key: "model") var model: Spark25Inner
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ args: Spark25Configuration) {
        self.args = args
        vocabularySize = args.vocabularySize
        _model.wrappedValue = Spark25Inner(args)
        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let out = model(inputs, cache: cache)
        if let lmHead { return lmHead(out) }
        return model.embedding.asLinear(out)
    }

    /// Sliding vrstvy drží jen posledních `sliding_window` tokenů, full vrstvy celý kontext.
    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        model.layers.map { layer -> KVCache in
            layer.isSliding ? RotatingKVCache(maxSize: args.slidingWindow, keep: 0) : KVCacheSimple()
        }
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var weights = weights
        // Některé převody přejmenují embedding na embed_tokens.
        if let embedTokens = weights.removeValue(forKey: "model.embed_tokens.weight"),
           weights["model.embedding.weight"] == nil {
            weights["model.embedding.weight"] = embedTokens
        }
        for suffix in ["scales", "biases"] {
            if let value = weights.removeValue(forKey: "model.embed_tokens.\(suffix)"),
               weights["model.embedding.\(suffix)"] == nil {
                weights["model.embedding.\(suffix)"] = value
            }
        }
        if args.tieWordEmbeddings {
            weights = weights.filter { !$0.key.hasPrefix("lm_head.") }
        }
        return weights.filter { !$0.key.contains("rotary_emb.inv_freq") }
    }

    var loraLayers: [Module] { model.layers }
}
#endif
