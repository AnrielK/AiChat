#if canImport(llama) && canImport(MLX)
import Foundation
import MLX

/// Měření, jestli by mělo smysl přepsat MLX na streamování expertů z flash (jako u GGUF).
///
/// Streamované MoE na GPU musí v každé vrstvě počkat, až GPU spočítá router, přečíst vybrané
/// experty z flash, zkopírovat je do MLX polí a teprve pak pokračovat. Tady se ten průchod
/// napodobí s rozměry vybraného GGUF modelu, ale bez skutečných vah: husté matice jsou nulové
/// 4bitové matice správné velikosti (GPU je projde stejně rychle jako skutečné) a experti
/// se opravdu čtou ze souboru modelu – podle posledního záznamu expertů (.axtr), takže
/// i page cache se chová jako při generování. Obsah vah je nesmyslný, na čase to nezáleží.
///
/// Tři běhy, každý přes stejný počet tokenů:
/// 1. výpočet bez čekání – celý token v jednom grafu (strop GPU),
/// 2. výpočet s čekáním na výběr routeru v každé vrstvě (cena synchronizace),
/// 3. celý průchod: čekání + čtení expertů z flash + kopie do MLX (bez předčítání).
enum MLXMoEProbe {
    private static let log = EngineLog(category: "mlx")
    private static let group = 64
    private static let warmupTokens = 4

    struct Result: Sendable {
        let summary: String
        let source: String
        let layers: Int
        let experts: Int
        let tokens: Int
        /// Sekundy na token.
        let gpuBatched: Double
        let gpuSynced: Double
        let pipeline: Double
        let pipelineRead: Double
        let pipelineUpload: Double
        let bytesPerToken: Int

        /// Cena jednoho čekání na GPU (ms).
        var syncPerLayerMs: Double { max(0, gpuSynced - gpuBatched) / Double(max(1, layers)) * 1000 }
        /// Bez předčítání: všechno za sebou.
        var serialTokensPerSecond: Double { pipeline > 0 ? 1 / pipeline : 0 }
        /// S ideálním předčítáním: čtení z flash běží souběžně s výpočtem.
        var overlapTokensPerSecond: Double {
            let bound = max(gpuSynced + pipelineUpload, pipelineRead)
            return bound > 0 ? 1 / bound : 0
        }
        var readGigabytesPerSecond: Double {
            pipelineRead > 0 ? Double(bytesPerToken) / pipelineRead / 1_073_741_824 : 0
        }
    }

    enum ProbeError: LocalizedError {
        case notMoE
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notMoE: "Vybraný GGUF není MoE model."
            case .unreadable: "Soubor modelu nejde otevřít."
            }
        }
    }

    // MARK: - Model

    private struct Quant {
        let w: MLXArray
        let scales: MLXArray
        let biases: MLXArray
    }

    private struct Layer {
        let q: Quant
        let k: Quant
        let v: Quant
        let o: Quant
        let router: MLXArray
    }

    private struct Expert {
        let gate: Quant
        let up: Quant
        let down: Quant
    }

    private struct Dims {
        var hidden = 2048
        var layers = 48
        var heads = 32
        var kvHeads = 4
        var headDim = 128
        var ffn = 768
        var experts = 128
        var used = 8
        var vocabulary = 151_936
    }

    /// 4bitová matice [out, in] (transpose = true, jako Linear v MLX) z nul.
    private static func zeroQuant(out: Int, in inDim: Int) -> Quant {
        Quant(
            w: MLXArray.zeros([out, inDim / 8], type: UInt32.self),
            scales: MLXArray.ones([out, inDim / group], type: Float16.self),
            biases: MLXArray.zeros([out, inDim / group], type: Float16.self)
        )
    }

    private static func qmm(_ x: MLXArray, _ q: Quant) -> MLXArray {
        quantizedMatmul(x, q.w, scales: q.scales, biases: q.biases, transpose: true, groupSize: group, bits: 4)
    }

    /// Projekce attention (samotná attention je u krátkého kontextu zanedbatelná).
    private static func attention(_ x: MLXArray, _ layer: Layer) -> MLXArray {
        let q = qmm(x, layer.q)
        let k = qmm(x, layer.k)
        let v = qmm(x, layer.v)
        // k a v se musí spočítat, jinak by je líný graf MLX vynechal.
        return x + qmm(q, layer.o) + (k.sum() + v.sum()) * 0
    }

    private static func routerLogits(_ x: MLXArray, _ layer: Layer) -> MLXArray {
        matmul(x, layer.router.T)
    }

    private static func moe(_ x: MLXArray, _ experts: [Expert]) -> MLXArray {
        var y = x * 0
        for expert in experts {
            let g = qmm(x, expert.gate)
            let u = qmm(x, expert.up)
            y = y + qmm(g * sigmoid(g) * u, expert.down)
        }
        return x + y / Float(max(1, experts.count))
    }

    // MARK: - Běh

    /// Spustí měření. Trvá desítky sekund a je synchronní – volat mimo hlavní vlákno,
    /// s uvolněnými modely (jinak si s nimi měření bere paměť i page cache).
    static func run(ggufPath path: String, expertsPerToken requested: Int, tokens: Int = 24) throws -> Result {
        guard let layout = GGUFLayout.read(path: path), layout.isMoE, layout.expertCount > 0 else {
            throw ProbeError.notMoE
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ProbeError.unreadable }
        defer { close(fd) }

        var dims = Dims()
        let keys = ["embedding_length", "block_count", "attention.head_count", "attention.head_count_kv",
                    "attention.key_length", "expert_feed_forward_length", "expert_count", "expert_used_count"]
        if let meta = GGUFLayout.dimensions(path: path, keys: keys) {
            func value(_ key: String, _ fallback: Int) -> Int { (meta.values[key] ?? 0) > 0 ? meta.values[key]! : fallback }
            dims.hidden = value("embedding_length", dims.hidden)
            dims.layers = value("block_count", dims.layers)
            dims.heads = value("attention.head_count", dims.heads)
            dims.kvHeads = value("attention.head_count_kv", dims.kvHeads)
            dims.headDim = value("attention.key_length", dims.hidden / max(1, dims.heads))
            dims.ffn = value("expert_feed_forward_length", dims.ffn)
            dims.experts = value("expert_count", layout.expertCount)
            dims.used = value("expert_used_count", dims.used)
            if meta.vocabulary > 0 { dims.vocabulary = meta.vocabulary }
        }
        if requested > 0, requested < dims.used { dims.used = requested }
        // Kvantizace po 64 – rozměry musí jít dělit.
        dims.ffn = max(group, dims.ffn / group * group)

        Memory.cacheLimit = 64 * 1_048_576
        defer { Memory.clearCache() }

        // Husté váhy a experti v paměti pro běhy bez čtení. Každá vrstva má vlastní matice –
        // sdílené by se vešly do cache GPU a výpočet by vyšel nereálně rychlý.
        let attentionWidth = dims.heads * dims.headDim
        let kvWidth = dims.kvHeads * dims.headDim
        var layers: [Layer] = []
        var resident: [[Expert]] = []
        for _ in 0 ..< dims.layers {
            let layer = Layer(
                q: zeroQuant(out: attentionWidth, in: dims.hidden),
                k: zeroQuant(out: kvWidth, in: dims.hidden),
                v: zeroQuant(out: kvWidth, in: dims.hidden),
                o: zeroQuant(out: dims.hidden, in: attentionWidth),
                router: MLXArray.zeros([dims.experts, dims.hidden], type: Float16.self)
            )
            let experts = (0 ..< dims.used).map { _ in
                Expert(
                    gate: zeroQuant(out: dims.ffn, in: dims.hidden),
                    up: zeroQuant(out: dims.ffn, in: dims.hidden),
                    down: zeroQuant(out: dims.hidden, in: dims.ffn)
                )
            }
            eval([layer.q.w, layer.k.w, layer.v.w, layer.o.w, layer.router]
                 + experts.flatMap { [$0.gate.w, $0.up.w, $0.down.w] })
            layers.append(layer)
            resident.append(experts)
        }
        let head = zeroQuant(out: dims.vocabulary, in: dims.hidden)
        // Škály a posuny pro experty čtené ze souboru – stačí jedny sdílené (jsou malé).
        let upScales = MLXArray.ones([dims.ffn, dims.hidden / group], type: Float16.self)
        let upBiases = MLXArray.zeros([dims.ffn, dims.hidden / group], type: Float16.self)
        let downScales = MLXArray.ones([dims.hidden, dims.ffn / group], type: Float16.self)
        let downBiases = MLXArray.zeros([dims.hidden, dims.ffn / group], type: Float16.self)
        eval(head.w, head.scales, upScales, upBiases, downScales, downBiases)

        let input = MLXArray.zeros([1, dims.hidden], type: Float16.self)
        func finish(_ x: MLXArray) -> MLXArray { qmm(x, head).argMax(axis: -1) }
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        // 1. Bez čekání: celý token jako jeden graf.
        var batched = 0.0
        for token in 0 ..< warmupTokens + tokens {
            let start = now()
            var x = input
            for index in 0 ..< dims.layers {
                x = attention(x, layers[index])
                x = x + routerLogits(x, layers[index]).sum() * 0
                x = moe(x, resident[index])
            }
            eval(finish(x))
            if token >= warmupTokens { batched += now() - start }
        }

        // 2. S čekáním na výběr routeru v každé vrstvě, experti v paměti.
        var synced = 0.0
        for token in 0 ..< warmupTokens + tokens {
            let start = now()
            var x = input
            for index in 0 ..< dims.layers {
                x = attention(x, layers[index])
                let order = argPartition(negative(routerLogits(x, layers[index])), kth: dims.used - 1, axis: -1)
                eval(order)
                _ = order.asArray(UInt32.self).prefix(dims.used)
                x = moe(x, resident[index])
            }
            eval(finish(x))
            if token >= warmupTokens { synced += now() - start }
        }

        // 3. Celý průchod se čtením expertů ze souboru.
        let plan = ExpertPlan(path: path, layout: layout, layers: dims.layers, used: dims.used,
                              tokens: warmupTokens + tokens)
        let upBytes = dims.ffn * dims.hidden / 2
        let downBytes = dims.hidden * dims.ffn / 2
        let tensorsPerLayer = layout.expertTensors.values.map(\.count).max() ?? 3
        let sliceMax = layout.expertTensors.values.joined().map { $0.bytes / layout.expertCount }.max() ?? upBytes
        let staging = UnsafeMutableRawPointer.allocate(byteCount: max(1, dims.used * tensorsPerLayer * sliceMax),
                                                       alignment: Int(getpagesize()))
        defer { staging.deallocate() }
        let stagingAddress = Int(bitPattern: staging)

        var pipeline = 0.0
        var readTime = 0.0
        var uploadTime = 0.0
        var readBytes = 0
        for token in 0 ..< warmupTokens + tokens {
            let measured = token >= warmupTokens
            let start = now()
            var x = input
            for index in 0 ..< dims.layers {
                x = attention(x, layers[index])
                let order = argPartition(negative(routerLogits(x, layers[index])), kth: dims.used - 1, axis: -1)
                eval(order)
                _ = order.asArray(UInt32.self).prefix(dims.used)

                // Čtení vybraných expertů (podle záznamu) paralelně do jednoho bufferu.
                let chosen = plan.experts(token: token, layer: index)
                let tensors = layout.expertTensors[index] ?? []
                var reads: [(offset: Int, bytes: Int, into: Int, down: Bool)] = []
                var cursor = 0
                for expert in chosen {
                    for tensor in tensors {
                        let slice = tensor.bytes / layout.expertCount
                        reads.append((tensor.fileOffset + expert * slice, slice, cursor, tensor.name.contains("down")))
                        cursor += slice
                    }
                }
                let readStart = now()
                let list = reads
                DispatchQueue.concurrentPerform(iterations: list.count) { item in
                    let read = list[item]
                    guard let target = UnsafeMutableRawPointer(bitPattern: stagingAddress + read.into) else { return }
                    var done = 0
                    while done < read.bytes {
                        let count = pread(fd, target + done, read.bytes - done, off_t(read.offset + done))
                        if count <= 0 { break }
                        done += count
                    }
                }
                let uploadStart = now()

                // Kopie do MLX polí. Ze slice se vezme tolik bajtů, kolik má 4bitová matice MLX
                // (Q4_K v GGUF má o škály víc, Q6_K ještě víc) – obsah nevadí, jde o čas.
                var experts: [Expert] = []
                var position = 0
                for _ in chosen {
                    var projections: [Quant] = []
                    var down: Quant?
                    for _ in tensors {
                        let read = list[position]
                        position += 1
                        let needed = read.down ? downBytes : upBytes
                        guard read.bytes >= needed else { continue }
                        let pointer = UnsafeRawBufferPointer(start: staging + read.into, count: needed)
                        if read.down {
                            let w = MLXArray(pointer, [dims.hidden, dims.ffn / 8], type: UInt32.self)
                            down = Quant(w: w, scales: downScales, biases: downBiases)
                        } else {
                            let w = MLXArray(pointer, [dims.ffn, dims.hidden / 8], type: UInt32.self)
                            projections.append(Quant(w: w, scales: upScales, biases: upBiases))
                        }
                    }
                    // Sloučený gate_up tenzor nebo příliš malý slice: chybějící matice z paměti.
                    let fallback = resident[index][experts.count % dims.used]
                    experts.append(Expert(
                        gate: projections.first ?? fallback.gate,
                        up: projections.count > 1 ? projections[1] : fallback.up,
                        down: down ?? fallback.down
                    ))
                }
                let uploadEnd = now()
                if measured {
                    readTime += uploadStart - readStart
                    uploadTime += uploadEnd - uploadStart
                    readBytes += list.reduce(0) { $0 + $1.bytes }
                }
                x = moe(x, experts)
            }
            eval(finish(x))
            if measured { pipeline += now() - start }
        }

        let count = Double(tokens)
        let result = Result(
            summary: "\(dims.layers) vrstev · skrytý stav \(dims.hidden) · \(dims.used) z \(dims.experts) expertů · FFN \(dims.ffn)",
            source: plan.source,
            layers: dims.layers,
            experts: dims.used,
            tokens: tokens,
            gpuBatched: batched / count,
            gpuSynced: synced / count,
            pipeline: pipeline / count,
            pipelineRead: readTime / count,
            pipelineUpload: uploadTime / count,
            bytesPerToken: readBytes / max(1, tokens)
        )
        log.notice("""
            test MLX MoE (\(result.summary), experti: \(result.source)): \
            GPU bez čekání \(ms(result.gpuBatched)) ms/token, s čekáním \(ms(result.gpuSynced)) ms \
            (\(String(format: "%.2f", result.syncPerLayerMs)) ms na vrstvu) · \
            celý průchod \(ms(result.pipeline)) ms: čtení \(ms(result.pipelineRead)) ms \
            (\(result.bytesPerToken / 1_048_576) MB, \(String(format: "%.2f", result.readGigabytesPerSecond)) GB/s), \
            kopie do MLX \(ms(result.pipelineUpload)) ms · \
            strop \(String(format: "%.1f", result.serialTokensPerSecond)) tok/s bez předčítání, \
            \(String(format: "%.1f", result.overlapTokensPerSecond)) tok/s s ideálním předčítáním
            """)
        return result
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.0f", seconds * 1000) }

    /// Které experty číst v kterém tokenu a vrstvě: z posledního záznamu tohoto modelu,
    /// jinak náhodně (pak je čtení pesimistické – bez opakování, které page cache využije).
    private struct ExpertPlan {
        let source: String
        private let tokens: [[Int: [Int]]]
        private let used: Int
        private let expertCount: Int

        init(path: String, layout: GGUFLayout, layers: Int, used: Int, tokens count: Int) {
            self.used = used
            self.expertCount = layout.expertCount
            let name = (path as NSString).lastPathComponent
            let files = (try? FileManager.default.contentsOfDirectory(
                at: ExpertTrace.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = files
                .filter { $0.pathExtension == ExpertTrace.fileExtension }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return a > b
                }
            var collected: [[Int: [Int]]] = []
            var label = "náhodně (záznam expertů chybí – čtení vyjde pesimisticky)"
            for url in newest {
                guard let trace = try? ExpertTrace(contentsOf: url),
                      trace.expertCount == layout.expertCount,
                      trace.modelName == name || trace.sliceBytes.count == layers else { continue }
                var current: [Int: [Int]] = [:]
                var previous = -1
                for event in trace.events where event.isDecode {
                    if event.layer <= previous, !current.isEmpty {
                        collected.append(current)
                        current = [:]
                        if collected.count >= count { break }
                    }
                    current[event.layer] = event.experts.map { Int($0 & 0x7FFF) }
                    previous = event.layer
                }
                if collected.count >= count {
                    label = "záznam \(url.deletingPathExtension().lastPathComponent)"
                    break
                }
                collected = []
            }
            self.tokens = collected
            self.source = label
        }

        func experts(token: Int, layer: Int) -> [Int] {
            if token < tokens.count, let recorded = tokens[token][layer], !recorded.isEmpty {
                return Array(recorded.prefix(used))
            }
            var generator = SystemRandomNumberGenerator()
            var chosen = Set<Int>()
            while chosen.count < min(used, expertCount) { chosen.insert(Int.random(in: 0 ..< expertCount, using: &generator)) }
            return Array(chosen)
        }
    }
}
#endif
