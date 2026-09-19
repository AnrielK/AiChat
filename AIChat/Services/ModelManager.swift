import Foundation
import Observation

enum LocalModelKind: String, Codable, Sendable, Identifiable {
    case gguf
    case mlx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gguf: "GGUF"
        case .mlx: "MLX"
        }
    }
}

/// Umístění modelů: GGUF soubory v Documents/Models, MLX složky v Documents/Models/MLX.
/// Díky UIFileSharingEnabled je obojí vidět v aplikaci Soubory i ve Finderu.
enum ModelPaths {
    static var root: URL {
        URL.documentsDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    static var mlx: URL {
        root.appending(path: "MLX", directoryHint: .isDirectory)
    }

    /// Rozpracovaná stahování (skrytá složka – seznam modelů ji přeskakuje).
    static var stagingRoot: URL {
        root.appending(path: ".downloads", directoryHint: .isDirectory)
    }

    static func staging(for jobID: UUID) -> URL {
        stagingRoot.appending(path: jobID.uuidString, directoryHint: .isDirectory)
    }

    /// Seznam běžících stahování (přežije ukončení appky).
    static var jobsFile: URL {
        URL.applicationSupportDirectory.appending(path: "downloads.json")
    }

    /// „mlx-community/Qwen3-4B-4bit“ → „mlx-community__Qwen3-4B-4bit“
    static func mlxFolderName(repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "__")
    }
}

/// Model v zařízení – soubor .gguf nebo složka MLX.
struct LocalModelFile: Identifiable, Hashable, Sendable {
    let kind: LocalModelKind
    let url: URL
    let size: Int64

    /// GGUF = název souboru (kompatibilní se starším nastavením), MLX = "mlx:<složka>".
    var id: String {
        kind == .gguf ? url.lastPathComponent : "mlx:" + url.lastPathComponent
    }

    var displayName: String { Self.displayName(forID: id) }

    /// Druh modelu se dá poznat z ID (MLX má prefix), bez sáhnutí na disk.
    static func kind(forID id: String) -> LocalModelKind {
        id.hasPrefix("mlx:") ? .mlx : .gguf
    }

    static func displayName(forID id: String) -> String {
        if id.hasPrefix("mlx:") {
            let folder = String(id.dropFirst(4))
            return folder.components(separatedBy: "__").last ?? folder
        }
        return (id as NSString).deletingPathExtension
    }
}

/// Doporučené modely ke stažení.
struct CatalogModel: Identifiable, Hashable, Sendable {
    let kind: LocalModelKind
    let name: String
    let summary: String
    let sizeLabel: String
    /// GGUF: přímý odkaz na soubor; MLX: ID repozitáře na Hugging Face.
    let source: String
    var thinks = false

    var id: String {
        switch kind {
        case .gguf: URL(string: source)?.lastPathComponent ?? source
        case .mlx: "mlx:" + ModelPaths.mlxFolderName(repo: source)
        }
    }

    /// Repozitář na Hugging Face, ze kterého se stahuje („mlx-community/Qwen3-4B-4bit“).
    var repo: String {
        switch kind {
        case .mlx: source
        case .gguf: HuggingFaceRepo.normalizedID(source) ?? source
        }
    }

    static let gguf: [CatalogModel] = [
        CatalogModel(kind: .gguf, name: "Gemma 3 1B", summary: "Nejmenší a nejrychlejší, zvládne i starší iPhone.", sizeLabel: "0,8 GB",
                     source: "https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/main/google_gemma-3-1b-it-Q4_K_M.gguf"),
        CatalogModel(kind: .gguf, name: "Llama 3.2 1B", summary: "Rychlý malý model od Meta.", sizeLabel: "0,8 GB",
                     source: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
        CatalogModel(kind: .gguf, name: "Qwen 2.5 1.5B", summary: "Dobrý poměr velikosti a kvality, slušná čeština.", sizeLabel: "1,1 GB",
                     source: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"),
        CatalogModel(kind: .gguf, name: "Llama 3.2 3B", summary: "Vyvážený model pro běžné konverzace.", sizeLabel: "2,0 GB",
                     source: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
        CatalogModel(kind: .gguf, name: "Gemma 3 4B", summary: "Nejlepší čeština z nabídky, chce iPhone s 8 GB RAM.", sizeLabel: "2,5 GB",
                     source: "https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf"),
        CatalogModel(kind: .gguf, name: "Qwen 3 4B", summary: "Silný v logice a kódu.", sizeLabel: "2,5 GB",
                     source: "https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf", thinks: true),
        CatalogModel(kind: .gguf, name: "Qwen 3 30B-A3B 2507", summary: "MoE: 30B parametrů, na token jen 3B. Experty čte z úložiště – chytřejší, ale pomalejší. Chce ~20 GB volného místa.", sizeLabel: "18,6 GB",
                     source: "https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf")
    ]

    static let mlx: [CatalogModel] = [
        CatalogModel(kind: .mlx, name: "Gemma 3 1B QAT", summary: "Malý a svižný, dobrý první pokus.", sizeLabel: "≈ 0,7 GB",
                     source: "mlx-community/gemma-3-1b-it-qat-4bit"),
        CatalogModel(kind: .mlx, name: "Qwen 3 1.7B", summary: "Malý model, který umí přemýšlet.", sizeLabel: "≈ 1 GB",
                     source: "mlx-community/Qwen3-1.7B-4bit", thinks: true),
        CatalogModel(kind: .mlx, name: "Qwen 3.5 2B", summary: "Novější generace Qwen, přemýšlí.", sizeLabel: "≈ 1,5 GB",
                     source: "mlx-community/Qwen3.5-2B-4bit", thinks: true),
        CatalogModel(kind: .mlx, name: "Llama 3.2 3B", summary: "Vyvážený model pro běžné konverzace.", sizeLabel: "≈ 1,8 GB",
                     source: "mlx-community/Llama-3.2-3B-Instruct-4bit"),
        CatalogModel(kind: .mlx, name: "Qwen 3 4B", summary: "Silný v logice a kódu, chce 8 GB RAM.", sizeLabel: "≈ 2,3 GB",
                     source: "mlx-community/Qwen3-4B-4bit", thinks: true)
    ]
}

/// Správa lokálních modelů: seznam, import ze Souborů, mazání.
/// Stahování řeší `DownloadManager` (background URLSession).
@MainActor
@Observable
final class ModelManager {
    private(set) var installed: [LocalModelFile] = []
    private(set) var isImporting = false
    var lastError: String?

    init() {
        prepareDirectories()
        removeStalePartials()
        refresh()
        DownloadManager.shared.onInstalled = { [weak self] in self?.refresh() }
    }

    // MARK: - Seznam

    func refresh() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]

        let ggufs = ((try? fileManager.contentsOfDirectory(at: ModelPaths.root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { LocalModelFile(kind: .gguf, url: $0, size: Self.fileSize($0)) }

        let mlxFolders = ((try? fileManager.contentsOfDirectory(at: ModelPaths.mlx, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension != "partial" && Self.isMLXModel($0) }
            .map { LocalModelFile(kind: .mlx, url: $0, size: Self.directorySize($0)) }

        installed = (ggufs + mlxFolders).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func model(id: String) -> LocalModelFile? {
        installed.first { $0.id == id }
    }

    func isInstalled(_ item: CatalogModel) -> Bool {
        model(id: item.id) != nil
    }

    func delete(_ model: LocalModelFile) {
        Task {
            await LlamaEngine.shared.unload()
            await MLXEngine.shared.unload()
            try? FileManager.default.removeItem(at: model.url)
            refresh()
        }
    }

    // MARK: - Import z disku

    /// GGUF soubor se zkopíruje do Models, MLX složka do Models/MLX.
    func importModel(from source: URL, kind: LocalModelKind) async {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let destination: URL
        switch kind {
        case .gguf:
            guard source.pathExtension.lowercased() == "gguf" else {
                lastError = "Vyber soubor s příponou .gguf."
                return
            }
            destination = ModelPaths.root.appending(path: source.lastPathComponent)
        case .mlx:
            guard Self.isMLXModel(source) else {
                lastError = "Vybraná složka není MLX model – musí obsahovat config.json, tokenizér a soubory .safetensors."
                return
            }
            destination = ModelPaths.mlx.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        }
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            refresh()
            return
        }

        prepareDirectories()
        isImporting = true
        defer { isImporting = false }
        do {
            // Kopírování několika GB nesmí blokovat UI.
            try await Task.detached(priority: .userInitiated) {
                // Koordinované čtení: soubor v iCloudu, který je v telefonu jen jako odkaz,
                // se nejdřív stáhne (obyčejné copyItem by na něm selhalo).
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                    do {
                        let fileManager = FileManager.default
                        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                            try fileManager.removeItem(at: destination)
                        }
                        try fileManager.copyItem(at: readable, to: destination)
                    } catch {
                        copyError = error
                    }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
            }.value
            refresh()
        } catch {
            lastError = "Import selhal: \(error.localizedDescription)"
        }
    }

    // MARK: - Pomocné

    private func prepareDirectories() {
        for directory in [ModelPaths.root, ModelPaths.mlx] {
            var url = directory
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Gigabajtové modely nemají co dělat v zálohách iCloudu.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// Pozůstatky starého (popředního) stahování ve tvaru *.partial – smazat.
    /// Background stahování má vlastní skrytou složku `.downloads`, té se to netýká.
    private func removeStalePartials() {
        let fileManager = FileManager.default
        for directory in [ModelPaths.root, ModelPaths.mlx] {
            let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for item in items where item.pathExtension == "partial" {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    private static func isMLXModel(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appending(path: "config.json").path(percentEncoded: false)) else { return false }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += fileSize(file)
        }
        return total
    }
}
