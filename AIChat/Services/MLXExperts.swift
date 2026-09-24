import Foundation

/// Počet aktivních expertů u MLX MoE modelů (Qwen3-30B-A3B, Qwen3.5/3.6 MoE, Gemma 4 …).
///
/// mlx-swift-lm bere počet expertů na token z config.json a jiný způsob, jak ho přepsat,
/// nenabízí. Model se proto načte ze „stínové“ složky: config.json je kopie se sníženou
/// hodnotou, ostatní soubory (váhy, tokenizér) jsou odkazy na originál –
/// nic se nekopíruje a místo na disku to nezabírá.
///
/// Na rozdíl od GGUF z úložiště se u MLX neušetří RAM: všichni experti leží v paměti.
/// Zrychlí se jen výpočet MoE vrstev, který roste s počtem expertů zhruba lineárně.
enum MLXExperts {
    /// Klíče počtu expertů na token v config.json (Qwen, Mixtral, DeepSeek … / Gemma 4).
    private static let keys = ["num_experts_per_tok", "top_k_experts"]

    /// Složka MLX modelu podle ID („mlx:<složka>“).
    static func directory(forID id: String) -> URL? {
        guard id.hasPrefix("mlx:") else { return nil }
        return ModelPaths.mlx.appending(path: String(id.dropFirst(4)), directoryHint: .isDirectory)
    }

    /// Kolik expertů model vybírá podle config.json (kořen nebo `text_config`). nil = není MoE.
    static func used(in directory: URL) -> Int? {
        guard let root = config(in: directory) else { return nil }
        for section in [root["text_config"] as? [String: Any], root].compactMap({ $0 }) {
            for key in keys {
                if let value = (section[key] as? NSNumber)?.intValue, value > 1 { return value }
            }
        }
        return nil
    }

    /// Složka, ze které se má model načíst, a použitý počet expertů (nil = podle modelu).
    /// Když snížení nedává smysl (není MoE, 0, nebo víc než model má), vrátí originál.
    static func loadDirectory(for original: URL, requested: Int) throws -> (url: URL, experts: Int?) {
        guard requested > 0, let used = used(in: original), requested < used,
              var root = config(in: original) else { return (original, nil) }
        patch(&root, experts: requested)
        if var text = root["text_config"] as? [String: Any] {
            patch(&text, experts: requested)
            root["text_config"] = text
        }

        let manager = FileManager.default
        let shadow = URL.cachesDirectory
            .appending(path: "MLXExperts", directoryHint: .isDirectory)
            .appending(path: original.lastPathComponent, directoryHint: .isDirectory)
        // Pokaždé znovu: originál se mohl mezitím změnit (nové stažení, jiné soubory).
        try? manager.removeItem(at: shadow)
        try manager.createDirectory(at: shadow, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: original, includingPropertiesForKeys: [.isDirectoryKey])
        where item.lastPathComponent != "config.json" {
            let target = shadow.appending(path: item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            // Soubory pevným odkazem (stejný svazek, pro čtenáře k nerozeznání od originálu),
            // podsložky symbolickým – na složky pevný odkaz nejde. Když pevný odkaz selže,
            // záloha je symbolický.
            if isDirectory {
                try manager.createSymbolicLink(at: target, withDestinationURL: item)
            } else if (try? manager.linkItem(at: item, to: target)) == nil {
                try manager.createSymbolicLink(at: target, withDestinationURL: item)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: shadow.appending(path: "config.json"), options: .atomic)
        return (shadow, requested)
    }

    private static func patch(_ section: inout [String: Any], experts: Int) {
        for key in keys where section[key] != nil {
            section[key] = experts
        }
    }

    private static func config(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
