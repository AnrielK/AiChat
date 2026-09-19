import Foundation
import Observation

/// Natrénované LoRA adaptéry. Jeden adaptér na model, ve složce
/// `Documents/Adapters/<složka modelu>/`: `adapter_config.json` a `adapters.safetensors` –
/// přesně ta dvojice, kterou čte `LoRAContainer.from(directory:)`. Vedle nich `training.json`
/// s údaji o běhu, jen pro zobrazení.
///
/// Složka je v Documents, takže je díky `UIFileSharingEnabled` vidět v Souborech –
/// adaptér jde z telefonu vytáhnout a stejně tak tam nahrát natrénovaný na Macu.
enum AdapterPaths {
    static var root: URL {
        URL.documentsDirectory.appending(path: "Adapters", directoryHint: .isDirectory)
    }

    /// „mlx:mlx-community__Qwen3-4B-4bit“ → složka „mlx-community__Qwen3-4B-4bit“.
    static func directory(forModelID id: String) -> URL {
        let name = id.hasPrefix("mlx:") ? String(id.dropFirst(4)) : id
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    /// Z cesty ke složce MLX modelu – engine jiné ID k dispozici nemá.
    static func directory(forModelAt modelDirectory: URL) -> URL {
        directory(forModelID: modelID(forModelAt: modelDirectory))
    }

    static func modelID(forModelAt modelDirectory: URL) -> String {
        "mlx:" + modelDirectory.lastPathComponent
    }

    static func weights(in directory: URL) -> URL {
        directory.appending(path: "adapters.safetensors")
    }

    static func configuration(in directory: URL) -> URL {
        directory.appending(path: "adapter_config.json")
    }

    static func info(in directory: URL) -> URL {
        directory.appending(path: "training.json")
    }

    /// Je ve složce kompletní adaptér? Samotné váhy bez konfigurace se načíst nedají –
    /// z ní se bere počet vrstev a klíče, bez kterých se neví, kam se váhy mají vložit.
    static func exists(in directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: weights(in: directory).path(percentEncoded: false))
            && manager.fileExists(atPath: configuration(in: directory).path(percentEncoded: false))
    }

    /// Adaptér, který se má použít při generování. nil = žádný (neexistuje, nebo je vypnutý).
    /// Čte se z enginu mimo hlavní vlákno, proto UserDefaults a ne `SettingsStore`.
    static func active(forModelAt modelDirectory: URL) -> URL? {
        let id = modelID(forModelAt: modelDirectory)
        guard AdapterStore.isEnabled(modelID: id) else { return nil }
        let directory = directory(forModelID: id)
        return exists(in: directory) ? directory : nil
    }
}

/// Údaje o posledním tréninku. Jen pro zobrazení – na načtení adaptéru nemají vliv.
struct AdapterInfo: Codable, Sendable {
    var finishedAt = Date.now
    var baseModelID = ""
    /// Kolik iterací opravdu proběhlo (při zastavení míň, než bylo nastaveno).
    var iterations = 0
    var samples = 0
    var trainLoss: Float?
    var validationLoss: Float?
    var rank = 0
    var numLayers = 0
}

/// Stav adaptérů pro UI. Samotný přepínač je v UserDefaults, aby si ho engine mohl
/// přečíst i mimo hlavní vlákno; tahle třída ho jen obaluje, ať se pohledy překreslí.
@MainActor
@Observable
final class AdapterStore {
    static let shared = AdapterStore()

    /// Zvedne se při každé změně (zapnutí, smazání, dokončený trénink) – pohledy
    /// se na ni dívají, protože samotný stav leží v UserDefaults a na disku.
    private(set) var version = 0

    nonisolated static func isEnabled(modelID: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(modelID))
    }

    nonisolated private static func key(_ modelID: String) -> String {
        "adapter.enabled." + modelID
    }

    func isEnabled(modelID: String) -> Bool {
        _ = version
        return Self.isEnabled(modelID: modelID)
    }

    func setEnabled(_ enabled: Bool, modelID: String) {
        UserDefaults.standard.set(enabled, forKey: Self.key(modelID))
        version += 1
    }

    func exists(modelID: String) -> Bool {
        _ = version
        return AdapterPaths.exists(in: AdapterPaths.directory(forModelID: modelID))
    }

    func info(modelID: String) -> AdapterInfo? {
        _ = version
        let url = AdapterPaths.info(in: AdapterPaths.directory(forModelID: modelID))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AdapterInfo.self, from: data)
    }

    func delete(modelID: String) {
        try? FileManager.default.removeItem(at: AdapterPaths.directory(forModelID: modelID))
        UserDefaults.standard.removeObject(forKey: Self.key(modelID))
        version += 1
    }

    /// Volá trenér po dokončení běhu.
    func reload() { version += 1 }
}
