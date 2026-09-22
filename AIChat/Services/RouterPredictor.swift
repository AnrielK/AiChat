#if canImport(llama)
import Accelerate
import Foundation

/// Odhad expertů další vrstvy z routeru té vrstvy („pre-gating“).
///
/// Skrytý stav se mezi sousedními vrstvami mění jen málo (reziduální proud), takže router
/// vrstvy L+1 vynásobený vstupem MoE vrstvy L trefí většinu expertů, které vrstva L+1 opravdu
/// vybere – o celou vrstvu dřív. Literatura o MoE offloadingu (pre-gated MoE, HOBBIT,
/// MoE-Infinity) uvádí přesnost kolem 80–90 %. Tady se zatím jen měří: odhad jde do záznamu
/// (`ExpertTrace`) a simulátor spočítá, kolik by trefil a kolik by přečetl zbytečně.
///
/// Vstupem je reziduální proud před MoE vrstvy L (`ffn_inp-L`), ne jeho normovaná podoba:
/// router vrstvy L+1 vidí `x / rms(x) ⊙ w_norm(L+1)`. Kladné měřítko `1/rms` pořadí expertů
/// nezmění, takže stačí při načtení vynásobit sloupce routeru vahou normy vrstvy L+1
/// a za běhu násobit surovým `x`. Od skutečného vstupu routeru se odhad liší jen o
/// příspěvek attention vrstvy L+1.
///
/// Routery llama-quantize nekvantuje (F32, někdy F16/BF16). Drží se v F16 – u Qwen3-30B-A3B
/// 48 × 128 × 2048 × 2 B ≈ 25 MB – a před násobením se vrstva převede do F32 bufferu (1 MB).
final class RouterPredictor {
    private static let log = EngineLog(category: "gguf")
    private static let typeF32: UInt32 = 0
    private static let typeF16: UInt32 = 1
    private static let typeBF16: UInt32 = 30

    let embedding: Int
    let experts: Int
    /// Váhy v F16 podle vrstvy, řádek = expert (ne[1]), sloupec = složka skrytého stavu (ne[0]).
    private var weights: [Int: [UInt16]] = [:]
    private var scratch: [Float]
    private var scores: [Float]

    init?(fd: Int32, routers: [Int: GGUFLayout.RouterTensor]) {
        guard let first = routers.values.first, first.embedding > 0, first.experts > 0 else { return nil }
        embedding = first.embedding
        experts = first.experts
        let count = embedding * experts
        scratch = [Float](repeating: 0, count: count)
        scores = [Float](repeating: 0, count: experts)

        for (layer, router) in routers {
            guard router.embedding == embedding, router.experts == experts,
                  let half = Self.load(fd: fd, router: router, count: count) else {
                Self.log.warning("router vrstvy \(layer) nejde načíst (typ \(router.type)) – odhad expertů vypnut")
                return nil
            }
            weights[layer] = half
        }
        Self.log.notice("odhad expertů: routery \(weights.count) vrstev načteny (\(weights.count * count * 2 / 1_048_576) MB)")
    }

    func canPredict(layer: Int) -> Bool { weights[layer] != nil }

    /// Experti vrstvy `layer` seřazení podle skóre routeru, prvních `count`.
    /// `hidden` = reziduální vstup MoE předchozí vrstvy (`ffn_inp`), `embedding` floatů.
    func predict(layer: Int, hidden: UnsafePointer<Float>, count: Int) -> [Int] {
        guard let half = weights[layer], count > 0 else { return [] }
        half.withUnsafeBufferPointer { source in
            scratch.withUnsafeMutableBufferPointer { target in
                var input = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: UnsafeRawPointer(source.baseAddress!)),
                    height: vImagePixelCount(experts),
                    width: vImagePixelCount(embedding),
                    rowBytes: embedding * 2
                )
                var output = vImage_Buffer(
                    data: target.baseAddress!,
                    height: vImagePixelCount(experts),
                    width: vImagePixelCount(embedding),
                    rowBytes: embedding * 4
                )
                _ = vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        scratch.withUnsafeBufferPointer { matrix in
            scores.withUnsafeMutableBufferPointer { result in
                // scores[experts × 1] = W[experts × embedding] · hidden[embedding × 1]
                vDSP_mmul(matrix.baseAddress!, 1, hidden, 1, result.baseAddress!, 1,
                          vDSP_Length(experts), 1, vDSP_Length(embedding))
            }
        }
        // Softmax i sigmoid pořadí nemění – top-k stačí vzít ze surových skóre.
        let ranked = scores.indices.sorted { scores[$0] > scores[$1] }
        return Array(ranked.prefix(count))
    }

    /// Načte router ze souboru a převede do F16.
    private static func load(fd: Int32, router: GGUFLayout.RouterTensor, count: Int) -> [UInt16]? {
        let elementSize: Int
        switch router.type {
        case typeF32: elementSize = 4
        case typeF16, typeBF16: elementSize = 2
        default: return nil
        }
        guard router.bytes == count * elementSize,
              let norm = router.norm,
              var single = readFloats(fd: fd, offset: router.fileOffset, bytes: router.bytes, type: router.type, count: count),
              let scale = readFloats(fd: fd, offset: norm.fileOffset, bytes: norm.bytes, type: norm.type, count: router.embedding)
        else { return nil }

        // Norma vrstvy složená do routeru: sloupec j × w_norm[j].
        for expert in 0..<router.experts {
            let row = expert * router.embedding
            for column in 0..<router.embedding { single[row + column] *= scale[column] }
        }
        var half = [UInt16](repeating: 0, count: count)
        single.withUnsafeMutableBufferPointer { source in
            half.withUnsafeMutableBufferPointer { target in
                // Po řádcích (expert × šířka), ne jeden řádek o čtvrt milionu prvků.
                let rows = vImagePixelCount(router.experts)
                let width = vImagePixelCount(router.embedding)
                var input = vImage_Buffer(data: source.baseAddress!, height: rows, width: width, rowBytes: router.embedding * 4)
                var output = vImage_Buffer(data: target.baseAddress!, height: rows, width: width, rowBytes: router.embedding * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        return half
    }

    /// Přečte tenzor ze souboru jako F32 (zdroj F32, F16 nebo BF16).
    private static func readFloats(fd: Int32, offset: Int, bytes: Int, type: UInt32, count: Int) -> [Float]? {
        let elementSize: Int
        switch type {
        case typeF32: elementSize = 4
        case typeF16, typeBF16: elementSize = 2
        default: return nil
        }
        guard bytes == count * elementSize else { return nil }
        var raw = [UInt8](repeating: 0, count: bytes)
        let complete = raw.withUnsafeMutableBytes { buffer -> Bool in
            var done = 0
            while done < bytes {
                let read = pread(fd, buffer.baseAddress! + done, bytes - done, off_t(offset + done))
                if read <= 0 { return false }
                done += read
            }
            return true
        }
        guard complete else { return nil }

        var result = [Float](repeating: 0, count: count)
        raw.withUnsafeMutableBytes { source in
            switch type {
            case typeF32:
                result.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(source)) }
            case typeBF16:
                // BF16 = horních 16 bitů F32.
                let halves = source.bindMemory(to: UInt16.self)
                for index in 0..<count { result[index] = Float(bitPattern: UInt32(halves[index]) << 16) }
            default:
                result.withUnsafeMutableBufferPointer { target in
                    var input = vImage_Buffer(data: source.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                    var output = vImage_Buffer(data: target.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        return result
    }
}
#endif
