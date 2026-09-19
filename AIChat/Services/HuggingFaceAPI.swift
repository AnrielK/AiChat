import Foundation

/// Hugging Face: výpis souborů repozitáře, odkazy ke stažení, velikost souboru.
enum HuggingFaceRepo {
    struct File: Sendable {
        let path: String
        let size: Int64
    }

    /// Stejné vzory, jaké stahuje mlx-swift-lm, plus tokenizéry mimo JSON.
    private static let suffixes = [".safetensors", ".json", ".jinja", ".model", ".tiktoken", ".txt"]

    /// Požadavek s User-Agentem a volitelným tokenem (jen pro huggingface.co).
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("AIChat/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if url.host()?.hasSuffix("huggingface.co") == true, let token = KeychainHelper.read(.huggingFace) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// „mlx-community/Qwen3-4B-4bit“ i „https://huggingface.co/mlx-community/Qwen3-4B-4bit“ → ID repozitáře.
    static func normalizedID(_ input: String) -> String? {
        var id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        let parts = id.split(separator: "/").prefix(2)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// Všechny soubory repozitáře (rekurzivně) se skutečnou velikostí.
    static func allFiles(repo: String) async throws -> [File] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            throw ProviderError.notConfigured("Neplatné ID repozitáře.")
        }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, message: message(forStatus: http.statusCode, repo: repo))
        }
        let items = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return items.compactMap { item -> File? in
            guard item["type"] as? String == "file", let path = item["path"] as? String else { return nil }
            // U LFS souborů je skutečná velikost v lfs.size, `size` je velikost ukazatele.
            let lfsSize = ((item["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value
            let size = lfsSize ?? (item["size"] as? NSNumber)?.int64Value ?? 0
            return File(path: path, size: size)
        }
    }

    /// Soubory potřebné pro MLX model.
    static func files(repo: String) async throws -> [File] {
        try await allFiles(repo: repo).filter { file in
            let lower = file.path.lowercased()
            return !lower.hasPrefix(".") && suffixes.contains(where: { lower.hasSuffix($0) })
        }
    }

    /// Samostatně použitelné soubory .gguf (bez vision projektorů a rozdělených částí), od nejmenšího.
    static func ggufFiles(repo: String) async throws -> [File] {
        try await allFiles(repo: repo)
            .filter { file in
                let name = (file.path as NSString).lastPathComponent.lowercased()
                return name.hasSuffix(".gguf")
                    && !name.contains("mmproj")
                    && name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) == nil
            }
            .sorted { $0.size < $1.size }
    }

    /// „Llama-3.2-3B-Instruct-Q4_K_M.gguf“ → „Q4_K_M“. Když kvantizaci nepozná, vrátí název souboru.
    static func quantLabel(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.components(separatedBy: CharacterSet(charactersIn: "-."))
        let quant = parts.last { part in
            part.range(of: #"^(i?q\d(_[a-z0-9]+)*|bf16|f16|f32)$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return quant?.uppercased() ?? base
    }

    static func fileURL(repo: String, path: String) -> URL? {
        let encoded = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")
    }

    /// Velikost souboru přes HEAD (kvůli průběhu stahování GGUF). nil = neznámá.
    static func remoteSize(of url: URL) async -> Int64? {
        var head = request(url)
        head.httpMethod = "HEAD"
        guard let result = try? await URLSession.shared.data(for: head),
              let http = result.1 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        if let linked = http.value(forHTTPHeaderField: "X-Linked-Size"), let size = Int64(linked) {
            return size
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    static func message(forStatus status: Int, repo: String? = nil) -> String {
        switch status {
        case 401, 403:
            "Model vyžaduje přihlášení. Vlož token Hugging Face ve Stahování a na webu přijmi licenci modelu."
        case 404:
            repo.map { "Repozitář \($0) neexistuje." } ?? "Soubor na Hugging Face neexistuje."
        default:
            "Server vrátil chybu \(status)."
        }
    }
}

// MARK: - Hledání

/// Model z výsledků hledání na Hugging Face.
struct HFModelSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let downloads: Int
    let likes: Int
    let pipelineTag: String?

    private enum CodingKeys: String, CodingKey {
        case id, downloads, likes
        case pipelineTag = "pipeline_tag"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
    }

    /// „mlx-community“
    var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
    /// „Qwen3-4B-4bit“
    var name: String { id.split(separator: "/").dropFirst().first.map(String.init) ?? id }

    var webURL: URL? { URL(string: "https://huggingface.co/\(id)") }
}

/// Jeden dataset ve výsledcích hledání.
struct HFDatasetSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let downloads: Int
    let likes: Int
    /// `gated` je v JSONu buď bool, nebo řetězec („auto“, „manual“) – proto vlastní dekódování.
    let isGated: Bool
    let isPrivate: Bool
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags, gated
        case isPrivate = "private"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .gated) {
            isGated = flag
        } else {
            // „auto“ i „manual“ znamenají, že se před stažením musí odsouhlasit podmínky.
            isGated = (try? container.decodeIfPresent(String.self, forKey: .gated)) != nil
        }
    }

    var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { id.split(separator: "/").dropFirst().first.map(String.init) ?? id }
    var webURL: URL? { URL(string: "https://huggingface.co/datasets/\(id)") }

    /// Licence z tagů (`license:cc-by-nc-4.0`) – u trénovacích dat se hodí vidět hned.
    var license: String? {
        tags.first { $0.hasPrefix("license:") }
            .map { String($0.dropFirst("license:".count)) }
    }

    /// Jazyky z tagů (`language:cs`).
    var languages: [String] {
        tags.filter { $0.hasPrefix("language:") }
            .map { String($0.dropFirst("language:".count)) }
    }
}

extension HuggingFaceRepo {
    /// Hledá datasety, seřazené podle počtu stažení.
    ///
    /// API hledá jen souvislý podřetězec, takže se pošle nejdelší slovo dotazu a zbytek
    /// se dofiltruje tady – stejně jako u modelů.
    ///
    /// Nefiltruje se na to, jestli dataset umí prohlížeč datasetů. API to neříká
    /// a zjistí se to až při načtení splitů; tam už je hláška srozumitelná.
    static func searchDatasets(_ query: String, language: String? = nil) async throws -> [HFDatasetSummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard var components = URLComponents(string: "https://huggingface.co/api/datasets") else { return [] }
        var items = [
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: words.count > 1 ? "100" : "50"),
            // Bez toho by chyběly tagy, a tedy licence i jazyk.
            URLQueryItem(name: "full", value: "true"),
        ]
        if let longest = words.max(by: { $0.count < $1.count }) {
            items.append(URLQueryItem(name: "search", value: longest))
        }
        if let language {
            items.append(URLQueryItem(name: "filter", value: "language:" + language))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, message: "Hledání datasetů selhalo.")
        }
        return try JSONDecoder().decode([HFDatasetSummary].self, from: data).filter { dataset in
            let id = dataset.id.lowercased()
            return words.allSatisfy { id.contains($0) }
        }
    }

    /// Úlohy, které s chatem nesouvisí (přepis řeči, obrázky, embeddingy…) – ve výsledcích je skryjeme.
    private static let nonChatPipelines: Set<String> = [
        "automatic-speech-recognition", "text-to-speech", "text-to-audio", "audio-to-audio", "audio-classification",
        "text-to-image", "image-to-image", "unconditional-image-generation", "text-to-video", "image-to-video",
        "feature-extraction", "sentence-similarity", "fill-mask", "token-classification", "text-classification",
        "zero-shot-classification", "image-classification", "object-detection", "image-segmentation",
        "depth-estimation", "text-ranking"
    ]

    /// Hledá modely MLX nebo GGUF, seřazené podle počtu stažení.
    /// API hledá jen souvislý podřetězec, takže „qwen 4b“ pošleme jako „qwen“ a zbytek slov dofiltrujeme tady.
    static func search(_ query: String, kind: LocalModelKind) async throws -> [HFModelSummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let longest = words.max(by: { $0.count < $1.count }),
              var components = URLComponents(string: "https://huggingface.co/api/models") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "search", value: longest),
            URLQueryItem(name: "filter", value: kind == .mlx ? "mlx" : "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: words.count > 1 ? "100" : "50")
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, message: "Hledání na Hugging Face selhalo.")
        }
        return try JSONDecoder().decode([HFModelSummary].self, from: data).filter { model in
            let id = model.id.lowercased()
            let isChat = model.pipelineTag.map { !nonChatPipelines.contains($0) } ?? true
            return isChat && words.allSatisfy { id.contains($0) }
        }
    }
}

// MARK: - Formátování

extension Int {
    /// 4 300 000 → „4,3M“, 12 500 → „12,5k“ (desetinná čárka podle jazyka).
    var compactFormatted: String {
        let value = Double(self)
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        switch self {
        case 1_000_000...: return (value / 1_000_000).formatted(style) + "M"
        case 1_000...: return (value / 1_000).formatted(style) + "k"
        default: return "\(self)"
        }
    }

    /// Číslo se správným tvarem podstatného jména: „1 kapitolu“, „2 kapitoly“, „5 kapitol“.
    ///
    /// Čeština má tři tvary – jednotné číslo, množné pro 2–4 a genitiv množného pro 0
    /// a 5 a víc. Volající dodává tvary ve správném pádu, protože ten se podle věty liší
    /// („zpracuji 1 **kapitolu**“ vs. „z 23 **kapitol**“).
    func czech(_ one: String, _ few: String, _ many: String) -> String {
        switch abs(self) {
        case 1: return "\(self) \(one)"
        case 2...4: return "\(self) \(few)"
        default: return "\(self) \(many)"
        }
    }
}

/// Kolik paměti má iPhone a jak velký model se do něj rozumně vejde.
enum DeviceMemory {
    static var bytes: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Kolik paměti smí appka zabrat – se sideload entitlementem je to výrazně víc než
    /// základní limit, takže se doporučení řídí skutečným limitem, ne velikostí RAM.
    static var limitBytes: Int64 { Int64(MemoryBudget.appLimit) }

    /// Na model zbyde limit appky bez místa na kontext, buffery a UI (zhruba třetina,
    /// nejméně 700 MB). Když limit nejde zjistit (simulátor), odhad z RAM zařízení.
    static var recommendedModelBytes: Int64 {
        let limit = limitBytes
        guard limit > 0 else { return bytes <= 6_500_000_000 ? 2_000_000_000 : bytes / 2 }
        return max(500_000_000, limit - max(700_000_000, limit / 3))
    }

    /// Vejde se model do paměti? U MoE GGUF (poznáno podle názvu, třeba „30B-A3B“) se
    /// počítá jen hustá část – experty engine při zapnutém streamování čte z úložiště.
    static func fits(_ size: Int64, fileName: String? = nil) -> Bool {
        if let fileName, isStreamableMoE(fileName) {
            return Int64(Double(size) * GGUFLayout.assumedDenseShare) + 1_000_000_000 <= recommendedModelBytes
        }
        return size <= recommendedModelBytes
    }

    static func isStreamableMoE(_ fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".gguf") && GGUFLayout.looksLikeMoE(fileName: fileName)
    }

    /// Volné místo pro modely (bez souborů, které iOS umí sám uvolnit). nil = nejde zjistit.
    static var freeStorage: Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Stáhne se soubor dané velikosti? Nechává rezervu 1 GB pro systém a KV cache.
    static func hasStorage(for size: Int64) -> Bool {
        guard let free = freeStorage, size > 0 else { return true }
        return size + 1_000_000_000 <= free
    }

    /// „6,5 GB (limit appky)“, nebo RAM zařízení, když limit není znám.
    static var label: String {
        let limit = limitBytes
        return limit > 0
            ? ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory) + " (limit appky)"
            : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) + " RAM"
    }

    static var recommendedLabel: String { ByteCountFormatter.string(fromByteCount: recommendedModelBytes, countStyle: .file) }
}
