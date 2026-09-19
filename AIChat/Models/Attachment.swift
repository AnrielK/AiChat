import Foundation

/// Soubor přiložený ke zprávě. Metadata a vytažený text se ukládají se zprávou (SwiftData),
/// originál – kvůli náhledu a posílání obrázků do cloudu – v `AttachmentStore`.
struct Attachment: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Cokoli, co se dá převést na text: txt, md, csv, json, kód, rtf, docx, xlsx, pptx…
        case text
        case pdf
        case image
    }

    let id: UUID
    var name: String
    var kind: Kind
    var mimeType: String
    var byteCount: Int64
    var pageCount: Int?
    /// Text souboru – u PDF z textové vrstvy, u obrázků a skenů z rozpoznávání (OCR).
    var text: String
    var characterCount: Int
    /// Text pochází z OCR (obrázek nebo PDF bez textové vrstvy).
    var isOCR: Bool
    /// Název uloženého souboru ve složce přílohy.
    var storedFileName: String
    /// Tabulka otagovaných čísel, když je soubor inline XBRL (výroční zpráva ze SECu).
    /// U ostatních souborů nil. Formát popisuje `InlineXBRL`.
    var facts: String?

    /// Instrukce, když uživatel pošle jen přílohy bez textu.
    static let defaultPrompt = "Prohlédni si přiložené soubory a stručně shrň, co obsahují a co je v nich podstatné."

    /// Hrubý odhad – čeština vychází na 2,5–3,5 znaku na token.
    var estimatedTokens: Int { characterCount / 3 }

    /// Obrázky a naskenovaná PDF pošleme cloudovému modelu jako originál (model je „vidí“),
    /// ostatní jako text. Textová PDF jdou jako text – jsou tak několikanásobně levnější.
    var sendsNatively: Bool {
        switch kind {
        case .image: true
        case .pdf: isOCR && byteCount <= 10_000_000
        case .text: false
        }
    }

    /// Originál pro cloud (base64). nil = soubor chybí nebo se neposílá nativně.
    func nativePayload() -> (mimeType: String, base64: String)? {
        guard sendsNatively, let data = try? Data(contentsOf: AttachmentStore.fileURL(for: self)) else { return nil }
        return (mimeType, data.base64EncodedString())
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var symbol: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text:
            switch fileExtension {
            case "csv", "tsv", "xlsx": return "tablecells"
            case "pptx": return "rectangle.on.rectangle.angled"
            case "docx", "rtf", "md", "txt": return "doc.text"
            case "json", "xml", "html", "htm", "yml", "yaml", "swift", "py", "js", "ts", "c", "cpp", "h", "hpp", "m",
                 "java", "kt", "go", "rs", "sh", "sql", "css": return "chevron.left.forwardslash.chevron.right"
            default: return "doc.plaintext"
            }
        }
    }

    /// „PDF · 12 str. · ≈ 8k tok.“
    var detail: String {
        var parts: [String] = []
        switch kind {
        case .pdf:
            parts.append("PDF")
            if let pageCount { parts.append("\(pageCount) str.") }
        case .image:
            parts.append("Obrázek")
        case .text:
            parts.append(fileExtension.isEmpty ? "Text" : fileExtension.uppercased())
        }
        if isOCR { parts.append("OCR") }
        if let facts { parts.append("XBRL \(InlineXBRL.factCount(in: facts).compactFormatted)") }
        if kind == .image || characterCount == 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        } else {
            parts.append("≈ \(estimatedTokens.compactFormatted) tok.")
        }
        return parts.joined(separator: " · ")
    }

    /// Blok pro prompt: `<file name="…">obsah</file>`, obsah zkrácený na `limit` znaků.
    func promptBlock(limit: Int) -> String {
        var header = "<file name=\"\(name)\""
        if let pageCount { header += " pages=\"\(pageCount)\"" }
        if kind == .image { header += " type=\"image\"" }
        header += ">"

        let body: String
        if text.isEmpty {
            body = kind == .image
                ? "(Obrázek – model ho nevidí a nebyl v něm rozpoznán žádný text.)"
                : "(Ze souboru se nepodařilo získat žádný text.)"
        } else if limit <= 0 {
            body = "(Obsah se už nevešel do kontextu modelu.)"
        } else if characterCount > limit {
            body = String(text.prefix(limit))
                + "\n[… zkráceno – model vidí prvních \(limit) z \(characterCount) znaků …]"
        } else {
            body = text
        }
        let note = isOCR && !text.isEmpty ? "(Text rozpoznaný z obrázku, může obsahovat chyby.)\n" : ""
        return header + "\n" + note + body + "\n</file>"
    }
}

/// Originály příloh: Application Support/Attachments/<id>/<soubor>.
enum AttachmentStore {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    static func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func fileURL(for attachment: Attachment) -> URL {
        directory(for: attachment.id).appending(path: attachment.storedFileName)
    }

    /// Vytvoří složku přílohy; kořen se vyloučí ze zálohy (text je stejně uložený ve zprávě).
    static func makeDirectory(for id: UUID) throws -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path(percentEncoded: false)) {
            var url = root
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        let folder = Self.directory(for: id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func remove(_ attachments: [Attachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: directory(for: attachment.id))
        }
    }
}

extension ChatTurn {
    /// Vloží obsah příloh do textu zpráv – pro modely, které umí jen text, a pro textové přílohy u cloudu.
    ///
    /// `characterBudget` je rozpočet pro celou konverzaci. Počítá se od nejnovější zprávy:
    /// texty zpráv mají přednost, přílohy dostanou, co zbude, a novější přílohy dřív než starší.
    /// Přílohy, pro které `keepSeparate` vrátí true, v `attachments` zůstanou (cloud je pošle jako originál).
    /// - Parameter carriedShare: jakou část rozpočtu smí zabrat přílohy ze starších zpráv,
    ///   když poslední zpráva žádnou nemá. Bez omezení se celý dokument vkládá do promptu
    ///   znovu u každé navazující zprávy – i u „super“ nebo „díky“ – a na lokálním modelu
    ///   to znamená minutu zpracování. Snížený podíl kontext nezruší, jen zlevní.
    static func inliningAttachments(
        _ history: [ChatTurn],
        characterBudget: Int,
        carriedShare: Double = 1,
        keepSeparate: (Attachment) -> Bool = { _ in false }
    ) -> [ChatTurn] {
        // Platí jen pro přílohy nesené z dřívějška: když se ptáš rovnou k souboru,
        // dostane plný rozpočet.
        let carried = history.last?.attachments.isEmpty ?? true
        var remaining = carried ? Int(Double(characterBudget) * carriedShare) : characterBudget
        var result: [ChatTurn] = []

        for turn in history.reversed() {
            remaining -= turn.text.count
            let inline = turn.attachments.filter { !keepSeparate($0) }
            let separate = turn.attachments.filter(keepSeparate)
            guard !inline.isEmpty else {
                result.insert(ChatTurn(role: turn.role, text: turn.text, attachments: separate), at: 0)
                continue
            }

            // Rozdělit zbytek rozpočtu: krátké soubory celé, dlouhé se podělí o zbytek.
            var pool = max(0, remaining)
            var limits: [UUID: Int] = [:]
            var left = inline.count
            for file in inline.sorted(by: { $0.characterCount < $1.characterCount }) {
                let take = min(file.characterCount, pool / left)
                limits[file.id] = take
                pool -= take
                left -= 1
            }
            remaining -= max(0, remaining) - pool

            let blocks = inline.map { $0.promptBlock(limit: limits[$0.id] ?? 0) }
            let text = (blocks + [turn.text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
            result.insert(ChatTurn(role: turn.role, text: text, attachments: separate), at: 0)
        }
        return result
    }
}

extension ChatMessage {
    var profile: TaskProfile? {
        get { profileRaw.flatMap(TaskProfile.init(rawValue:)) }
        set { profileRaw = newValue?.rawValue }
    }

    var usage: TokenUsage? {
        get { usageData.flatMap { try? JSONDecoder().decode(TokenUsage.self, from: $0) } }
        set { usageData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var sources: [MessageSource] {
        get {
            guard let sourcesData else { return [] }
            return (try? JSONDecoder().decode([MessageSource].self, from: sourcesData)) ?? []
        }
        set {
            sourcesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    var attachments: [Attachment] {
        get {
            guard let attachmentsData else { return [] }
            return (try? JSONDecoder().decode([Attachment].self, from: attachmentsData)) ?? []
        }
        set {
            attachmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    /// Kopie pro poskytovatele. Zpráva jen s přílohami dostane výchozí instrukci.
    var turn: ChatTurn {
        let files = attachments
        let prompt = role == .user && files.count > 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Attachment.defaultPrompt
            : text
        return ChatTurn(role: role, text: prompt, attachments: files)
    }
}
