import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

/// Převede vybraný soubor nebo fotku na `Attachment`: zkopíruje originál a vytáhne z něj text.
/// Všechno běží mimo hlavní vlákno (PDF i OCR umí trvat i sekundy).
enum AttachmentLoader {
    static let maxFileBytes: Int64 = 50_000_000
    /// ≈ 300 000 tokenů – víc nepojme ani cloudový model.
    static let maxCharacters = 1_000_000
    static let maxOCRPages = 20
    /// Claude doporučuje nejdelší stranu do 1568 px – větší obrázek jen zdraží a zpomalí odpověď.
    static let maxImageSide: CGFloat = 1568

    enum LoadError: LocalizedError {
        case folder
        case tooLarge
        case unsupported(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .folder:
                "Složku přiložit nejde, vyber jednotlivé soubory."
            case .tooLarge:
                "Soubor je větší než 50 MB."
            case .unsupported(let name):
                "Soubor \(name) neumím přečíst. Podporované jsou texty a kód, CSV, JSON, PDF, obrázky, RTF a Word/Excel/PowerPoint (docx, xlsx, pptx). Starší .doc a .xls ulož jako PDF."
            case .unreadable(let message):
                message
            }
        }
    }

    // MARK: - Veřejné API

    /// Soubor z aplikace Soubory (security-scoped URL).
    static func load(fileAt url: URL) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) {
            try Self.loadFile(at: url)
        }.value
    }

    /// Fotka z knihovny (originální data, třeba HEIC).
    static func load(imageData data: Data, name: String) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) {
            let id = UUID()
            let directory = try AttachmentStore.makeDirectory(for: id)
            do {
                return try Self.makeImage(data: data, name: name, id: id, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    // MARK: - Soubory

    private static func loadFile(at source: URL) throws -> Attachment {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true { throw LoadError.folder }
        let size = Int64(values?.fileSize ?? 0)
        guard size <= maxFileBytes else { throw LoadError.tooLarge }

        let name = source.lastPathComponent
        let type = values?.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let id = UUID()
        let directory = try AttachmentStore.makeDirectory(for: id)

        do {
            if type.conforms(to: .image) {
                return try makeImage(data: Data(contentsOf: source), name: name, id: id, directory: directory)
            }

            let stored = directory.appending(path: name)
            try FileManager.default.copyItem(at: source, to: stored)

            var text = ""
            var pages: Int?
            var isOCR = false
            var facts: String?
            let ext = source.pathExtension.lowercased()

            if type.conforms(to: .pdf) {
                let result = try pdfText(stored)
                text = result.text
                pages = result.pages
                isOCR = result.isOCR
            } else if let office = OfficeText.Format(rawValue: ext) {
                text = try OfficeText.extract(from: stored, format: office)
            } else if ext == "html" || ext == "htm" || type.conforms(to: .html) {
                let source = try decodeText(Data(contentsOf: stored)) ?? ""
                // Výroční zpráva ze SECu je inline XBRL: každé číslo ve výkazech nese
                // značku s tím, co je zač a za jaké období. Vytáhne se dřív, než se
                // značky zahodí – v čistém textu už se to nedá poznat.
                facts = InlineXBRL.factTable(from: source, fileName: name)
                // Než se značky zahodí, vyznačí se podle nich hranice kapitol – jinak
                // celé přílohy účetní závěrky splynou do jedné kapitoly bez názvu.
                // Když soubor otagovaný není, vrátí `marking` původní HTML.
                let marked = InlineXBRL.marking(source)
                // Bez odstranění značek by šel do promptu celý zdroj – u výročních zpráv
                // je to pětinásobek textu a delší soubory by narazily na limit znaků.
                text = HTMLText.extract(from: marked)
            } else if type.conforms(to: .rtf) || type.conforms(to: .rtfd) {
                text = try NSAttributedString(url: stored, options: [:], documentAttributes: nil).string
            } else if let decoded = try decodeText(Data(contentsOf: stored)) {
                // Nejen public.text – i neznámé přípony (.log, .ini, .h, .env…), pokud je obsah text.
                text = decoded
            } else {
                throw LoadError.unsupported(name)
            }

            let content = capped(text)
            return Attachment(
                id: id,
                name: name,
                kind: type.conforms(to: .pdf) ? .pdf : .text,
                mimeType: type.preferredMIMEType ?? "text/plain",
                byteCount: size,
                pageCount: pages,
                text: content,
                characterCount: content.count,
                isOCR: isOCR,
                storedFileName: name,
                facts: facts
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func capped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "\n[… soubor je delší, dál už se nenačítal …]"
    }

    /// UTF-8, UTF-16 s BOM, nebo česká 8bitová kódování (Windows-1250, ISO 8859-2). nil = binární soubor.
    static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // Nulové bajty = binární soubor (docx, zip, obrázek bez přípony…).
        if data.prefix(8192).contains(0) { return nil }

        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.windowsCP1250.rawValue,
                    String.Encoding.isoLatin2.rawValue,
                    String.Encoding.windowsCP1252.rawValue
                ],
                .useOnlySuggestedEncodingsKey: true
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        guard encoding != 0, let converted else { return nil }
        return converted as String
    }

    // MARK: - PDF

    /// Text po stranách. PDF bez textové vrstvy (sken) se přečte přes OCR – nejvýš `maxOCRPages` stran.
    private static func pdfText(_ url: URL) throws -> (text: String, pages: Int, isOCR: Bool) {
        guard let document = PDFDocument(url: url) else {
            throw LoadError.unreadable("PDF nejde otevřít – je poškozené?")
        }
        if document.isLocked {
            throw LoadError.unreadable("PDF je chráněné heslem. Odemkni ho (třeba tiskem do PDF) a přilož znovu.")
        }

        let pageCount = document.pageCount
        var parts: [String] = []
        var total = 0
        for index in 0..<pageCount {
            guard total < maxCharacters else { break }
            let pageText = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pageText.isEmpty else { continue }
            parts.append("[strana \(index + 1)]\n" + pageText)
            total += pageText.count
        }

        // Pár znaků na stranu = jen čísla stránek nebo hlavičky, zbytek je obrázek.
        if pageCount > 0, total / pageCount < 40 {
            var recognized: [String] = []
            for index in 0..<min(pageCount, maxOCRPages) {
                guard let page = document.page(at: index), let image = render(page) else { continue }
                let pageText = (try? recognizeText(in: image)) ?? ""
                if !pageText.isEmpty {
                    recognized.append("[strana \(index + 1)]\n" + pageText)
                }
            }
            if pageCount > maxOCRPages {
                recognized.append("[… rozpoznáno prvních \(maxOCRPages) z \(pageCount) stran …]")
            }
            if !recognized.isEmpty {
                return (recognized.joined(separator: "\n\n"), pageCount, true)
            }
        }
        return (parts.joined(separator: "\n\n"), pageCount, false)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2200 / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }

    // MARK: - Obrázky

    /// Uloží zmenšené JPEG (bílé pozadí místo průhlednosti, správná orientace) a rozpozná text.
    private static func makeImage(data: Data, name: String, id: UUID, directory: URL) throws -> Attachment {
        guard let image = UIImage(data: data) else {
            throw LoadError.unreadable("Obrázek \(name) nejde načíst.")
        }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { throw LoadError.unreadable("Obrázek \(name) je prázdný.") }
        let scale = min(1, maxImageSide / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else {
            throw LoadError.unreadable("Obrázek \(name) nejde uložit.")
        }

        let fileName = (name as NSString).deletingPathExtension + ".jpg"
        try jpeg.write(to: directory.appending(path: fileName))

        let text = resized.cgImage.flatMap { try? recognizeText(in: $0) } ?? ""
        return Attachment(
            id: id,
            name: fileName,
            kind: .image,
            mimeType: "image/jpeg",
            byteCount: Int64(jpeg.count),
            pageCount: nil,
            text: text,
            characterCount: text.count,
            isOCR: !text.isEmpty,
            storedFileName: fileName
        )
    }

    // MARK: - OCR

    /// Vision umí češtinu od iOS 18; jazyky se berou jen z těch, které zařízení opravdu podporuje.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["cs-CZ", "sk-SK", "en-US", "de-DE"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
