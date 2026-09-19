import Compression
import Foundation

/// Text z Office dokumentů (docx, xlsx, pptx). Jsou to ZIP archivy s XML uvnitř –
/// iOS je sám otevřít neumí, tak stačí malá čtečka ZIPu a XMLParser.
enum OfficeText {
    enum Format: String {
        case docx, xlsx, pptx
    }

    static func extract(from url: URL, format: Format) throws -> String {
        let zip = try ZipReader(data: Data(contentsOf: url, options: .mappedIfSafe))
        switch format {
        case .docx:
            guard let xml = try zip.data(for: "word/document.xml") else { throw invalid }
            return WordParser.text(from: xml)
        case .pptx:
            return try slides(in: zip)
        case .xlsx:
            return try sheets(in: zip)
        }
    }

    private static var invalid: AttachmentLoader.LoadError {
        .unreadable("Dokument je poškozený nebo to není formát Office Open XML.")
    }

    // MARK: - PowerPoint

    private static func slides(in zip: ZipReader) throws -> String {
        let names = zip.entryNames
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }
        guard !names.isEmpty else { throw invalid }

        var parts: [String] = []
        for (index, name) in names.enumerated() {
            guard let xml = try zip.data(for: name) else { continue }
            let text = TextRunParser.text(from: xml, runElement: "a:t", paragraphElement: "a:p")
            parts.append("[snímek \(index + 1)]\n" + text)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Excel

    private static func sheets(in zip: ZipReader) throws -> String {
        let shared = try zip.data(for: "xl/sharedStrings.xml").map(SharedStringsParser.strings(from:)) ?? []

        // Názvy listů: workbook.xml (name + r:id) → workbook.xml.rels (Id → cesta k souboru).
        var ordered: [(name: String, path: String)] = []
        if let workbook = try zip.data(for: "xl/workbook.xml"),
           let rels = try zip.data(for: "xl/_rels/workbook.xml.rels") {
            let targets = Dictionary(
                AttributeCollector.collect(from: rels, element: "Relationship").compactMap { attributes -> (String, String)? in
                    guard let id = attributes["Id"], let target = attributes["Target"] else { return nil }
                    let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                    return (id, path)
                },
                uniquingKeysWith: { first, _ in first }
            )
            for sheet in AttributeCollector.collect(from: workbook, element: "sheet") {
                if let name = sheet["name"], let id = sheet["r:id"], let path = targets[id] {
                    ordered.append((name: name, path: path))
                }
            }
        }
        if ordered.isEmpty {
            ordered = zip.entryNames
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { number(in: $0) < number(in: $1) }
                .enumerated()
                .map { (name: "List \($0.offset + 1)", path: $0.element) }
        }
        guard !ordered.isEmpty else { throw invalid }

        var parts: [String] = []
        for sheet in ordered {
            guard let xml = try zip.data(for: sheet.path) else { continue }
            let rows = SheetParser.rows(from: xml, shared: shared)
            parts.append("[list „\(sheet.name)“ – hodnoty oddělené tabulátorem]\n" + rows.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// „ppt/slides/slide12.xml“ → 12
    private static func number(in path: String) -> Int {
        let digits = (path as NSString).lastPathComponent.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

// MARK: - ZIP

/// Jen čtení: centrální adresář + metody „stored“ a „deflate“ (to pokryje Office i většinu ZIPů).
struct ZipReader {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]

    var entryNames: [String] { Array(entries.keys) }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        let invalid = AttachmentLoader.LoadError.unreadable("Soubor není platný ZIP/Office dokument.")

        // Konec centrálního adresáře (EOCD) hledáme odzadu – za ním může být komentář až 64 kB.
        guard bytes.count >= 22 else { throw invalid }
        var eocd = -1
        var position = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while position >= lowest {
            if Self.u32(bytes, position) == 0x0605_4B50 {
                eocd = position
                break
            }
            position -= 1
        }
        guard eocd >= 0 else { throw invalid }

        let count = Int(Self.u16(bytes, eocd + 10))
        var offset = Int(Self.u32(bytes, eocd + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, Self.u32(bytes, offset) == 0x0201_4B50 else { throw invalid }
            let nameLength = Int(Self.u16(bytes, offset + 28))
            let extraLength = Int(Self.u16(bytes, offset + 30))
            let commentLength = Int(Self.u16(bytes, offset + 32))
            guard offset + 46 + nameLength <= bytes.count else { throw invalid }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(
                method: Self.u16(bytes, offset + 10),
                compressedSize: Int(Self.u32(bytes, offset + 20)),
                uncompressedSize: Int(Self.u32(bytes, offset + 24)),
                localHeaderOffset: Int(Self.u32(bytes, offset + 42))
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Obsah souboru v archivu; nil = v archivu není.
    func data(for name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let invalid = AttachmentLoader.LoadError.unreadable("Dokument je poškozený.")
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4B50 else { throw invalid }
        let start = header + 30 + Int(Self.u16(bytes, header + 26)) + Int(Self.u16(bytes, header + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw invalid }
        let compressed = bytes[start..<end]

        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            // Ochrana proti „zip bombě“ – XML v Office souboru nemá 200 MB.
            guard entry.uncompressedSize > 0, entry.uncompressedSize < 200_000_000 else { throw invalid }
            return try Self.inflate(compressed, size: entry.uncompressedSize)
        default:
            throw AttachmentLoader.LoadError.unreadable("Dokument používá nepodporovanou kompresi.")
        }
    }

    /// COMPRESSION_ZLIB v Compression frameworku je „raw deflate“ (RFC 1951) – přesně jako v ZIPu.
    private static func inflate(_ input: ArraySlice<UInt8>, size: Int) throws -> Data {
        var output = [UInt8](repeating: 0, count: size)
        let written = input.withUnsafeBufferPointer { source -> Int in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, size, sourceBase, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw AttachmentLoader.LoadError.unreadable("Dokument nejde rozbalit.") }
        return Data(output.prefix(written))
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        let low = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
        let high = UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        return low | high
    }
}

// MARK: - XML

/// Word: odstavce, tabulky (buňky tabulátorem), tvrdé zalomení.
private final class WordParser: NSObject, XMLParserDelegate {
    private var output = ""
    private var inText = false

    static func text(from data: Data) -> String {
        let delegate = WordParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "w:t": inText = true
        case "w:tab": output += "\t"
        case "w:br", "w:cr": output += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p": output += "\n"
        case "w:tc": output += "\t"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { output += string }
    }
}

/// PowerPoint: textové běhy `a:t`, konec odstavce `a:p`.
private final class TextRunParser: NSObject, XMLParserDelegate {
    private let runElement: String
    private let paragraphElement: String
    private var output = ""
    private var inText = false

    private init(runElement: String, paragraphElement: String) {
        self.runElement = runElement
        self.paragraphElement = paragraphElement
    }

    static func text(from data: Data, runElement: String, paragraphElement: String) -> String {
        let delegate = TextRunParser(runElement: runElement, paragraphElement: paragraphElement)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == runElement { inText = true }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == runElement { inText = false }
        if elementName == paragraphElement { output += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { output += string }
    }
}

/// Excel: tabulka sdílených řetězců (`si` → text ze všech `t`, bez fonetiky `rPh`).
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false
    private var inPhonetic = false

    static func strings(from data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "si": current = ""
        case "rPh": inPhonetic = true
        case "t": inText = !inPhonetic
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "si": strings.append(current)
        case "rPh": inPhonetic = false
        case "t": inText = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }
}

/// Excel: list → řádky s hodnotami oddělenými tabulátorem (prázdné buňky zachovají sloupce).
private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [String] = []
    private var cells: [Int: String] = [:]
    private var column = 0
    private var cellType = ""
    private var value = ""
    private var capturing = false

    private init(shared: [String]) {
        self.shared = shared
    }

    static func rows(from data: Data, shared: [String]) -> [String] {
        let delegate = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "row":
            cells = [:]
            column = 0
        case "c":
            column = attributes["r"].map(Self.columnIndex) ?? column
            cellType = attributes["t"] ?? ""
            value = ""
        case "v", "t":
            capturing = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "v", "t":
            capturing = false
        case "c":
            let text: String
            switch cellType {
            case "s": text = Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
            case "b": text = value == "1" ? "PRAVDA" : "NEPRAVDA"
            default: text = value
            }
            if !text.isEmpty { cells[column] = text.replacingOccurrences(of: "\n", with: " ") }
            column += 1
        case "row":
            if let last = cells.keys.max() {
                rows.append((0...last).map { cells[$0] ?? "" }.joined(separator: "\t"))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value += string }
    }

    /// „AB12“ → 27
    private static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(0, index - 1)
    }
}

/// Atributy všech elementů daného jména (listy v sešitu, vztahy v .rels).
private final class AttributeCollector: NSObject, XMLParserDelegate {
    private let element: String
    private var found: [[String: String]] = []

    private init(element: String) {
        self.element = element
    }

    static func collect(from data: Data, element: String) -> [[String: String]] {
        let delegate = AttributeCollector(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == element { found.append(attributes) }
    }
}
