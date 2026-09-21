import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Text odpovědi rozdělený na bloky: běžný text (inline markdown), nadpisy, oddělovače,
/// tabulky a bloky kódu. Kód a tabulky se ukazují v samostatném okně s tlačítky
/// na kopírování a uložení, místo aby se ```značky a | svislítka vypisovaly do textu.
struct MessageContentView: View {
    let text: String

    var body: some View {
        let blocks = MessageBlock.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let content):
                    CollapsibleText(text: content, markdown: true)
                        .lineSpacing(3)
                case .heading(let level, let content):
                    Text(MessageBlock.inlineMarkdown(content))
                        .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 4)
                case .rule:
                    Divider()
                case .code(let language, let code, let closed):
                    CodeBlockView(
                        language: language,
                        code: code,
                        isComplete: closed,
                        fileName: MessageBlock.fileName(for: index, in: blocks)
                    )
                case .table(let table):
                    TableBlockView(table: table, fileName: MessageBlock.tableFileName(for: index, in: blocks))
                }
            }
        }
    }
}

/// Jeden blok odpovědi.
enum MessageBlock: Equatable {
    case text(String)
    case heading(level: Int, String)
    case rule
    /// `closed` = false, dokud model blok ještě píše (chybí uzavírací ```).
    case code(language: String, code: String, closed: Bool)
    case table(MarkdownTable)

    /// Rozdělí markdown na bloky. Řeší jen to, co SwiftUI `Text` neumí: bloky kódu,
    /// nadpisy, oddělovače a tabulky. Zbytek (tučné, kurzíva, `kód`, odkazy) zůstane inline markdownu.
    static func parse(_ source: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var paragraph: [Substring] = []
        var code: [Substring] = []
        var fence: String?          // ``` nebo ~~~ otevřeného bloku
        var language = ""

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.text(joined))
            }
            paragraph = []
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if let open = fence {
                // Uzavírací značka: jen backticky/vlnovky, aspoň tolik jako u otevření.
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n"), closed: true))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }

            if let marker = fenceMarker(trimmed) {
                flushParagraph()
                fence = marker
                language = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? ""
                continue
            }

            // Tabulka: řádek se svislítky a pod ním oddělovač |---|:--:|.
            // Během generování se ukáže, jakmile model dopíše oddělovač, a řádky pak přibývají.
            if trimmed.contains("|"), index < lines.count,
               let alignments = tableSeparator(lines[index]) {
                let header = tableCells(trimmed)
                if header.count == alignments.count {
                    flushParagraph()
                    var rows: [[String]] = []
                    index += 1
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard row.contains("|") else { break }
                        var cells = tableCells(row)
                        // Chybějící buňky doplnit, přebytečné zahodit – jako GitHub.
                        if cells.count < header.count {
                            cells += Array(repeating: "", count: header.count - cells.count)
                        }
                        rows.append(Array(cells.prefix(header.count)))
                        index += 1
                    }
                    blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                    continue
                }
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            paragraph.append(line)
        }

        if fence != nil {
            // Model blok ještě dopisuje – ukázat, co už je.
            blocks.append(.code(language: language, code: code.joined(separator: "\n"), closed: false))
        } else {
            flushParagraph()
        }
        return blocks
    }

    /// „```“, „````“ nebo „~~~“ na začátku řádku (i s názvem jazyka za ním).
    private static func fenceMarker(_ line: String) -> String? {
        for char in ["`", "~"] {
            let run = line.prefix { String($0) == char }
            if run.count >= 3 {
                // Inline kód ```x``` na jednom řádku není blok.
                let rest = line.dropFirst(run.count)
                if char == "`", rest.contains("`") { return nil }
                return String(run)
            }
        }
        return nil
    }

    private static func heading(_ line: String) -> MessageBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let content = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .heading(level: hashes.count, content)
    }

    /// Buňky řádku tabulky. Krajní svislítka jsou volitelná, `\|` je svislítko v textu.
    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        let placeholder = "\u{FFFF}"
        return text.replacingOccurrences(of: "\\|", with: placeholder)
            .components(separatedBy: "|")
            .map {
                $0.replacingOccurrences(of: placeholder, with: "|")
                    // Zalomení v buňce píšou modely jako <br>.
                    .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    /// Oddělovač pod hlavičkou tabulky („| --- | :---: | ---: |“) → zarovnání sloupců.
    private static func tableSeparator(_ line: Substring) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in tableCells(trimmed) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .trailing : left ? .leading : .automatic)
        }
        return result.isEmpty ? nil : result
    }

    /// „tabulka.csv“, u další tabulky v odpovědi „tabulka-2.csv“.
    static func tableFileName(for index: Int, in blocks: [MessageBlock]) -> String {
        let before = blocks[..<index].filter { if case .table = $0 { return true }; return false }.count
        return before == 0 ? "tabulka.csv" : "tabulka-\(before + 1).csv"
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// Název souboru pro blok kódu na pozici `index`. Když ho model zmíní v textu před
    /// blokem („ulož jako `snake.html`“) nebo na prvním řádku kódu („// app.js“), vezme
    /// se ten; jinak „kod.<přípona podle jazyka>“, u dalších bloků se stejnou příponou
    /// „kod-2.…“.
    static func fileName(for index: Int, in blocks: [MessageBlock]) -> String {
        guard case .code(let language, let code, _) = blocks[index] else { return "kod.txt" }
        let ext = fileExtension(for: language)

        // Nejbližší text před blokem (přes nadpisy a oddělovače), pak první řádek kódu.
        var candidates: [String] = []
        var i = index - 1
        while i >= 0 {
            if case .text(let text) = blocks[i] { candidates.append(text); break }
            if case .code = blocks[i] { break }
            i -= 1
        }
        if let first = code.split(separator: "\n", maxSplits: 1).first {
            candidates.append(String(first))
        }
        for text in candidates {
            let names = fileNames(in: text)
            if let match = names.last(where: { ($0 as NSString).pathExtension.lowercased() == ext }) {
                return match
            }
            if language.isEmpty, let any = names.last { return any }
        }

        // Pořadí mezi bloky se stejnou příponou, ať se dva soubory nepřepíšou.
        let sameKind = blocks[..<index].filter {
            if case .code(let other, _, _) = $0 { return fileExtension(for: other) == ext }
            return false
        }.count
        return sameKind == 0 ? "kod.\(ext)" : "kod-\(sameKind + 1).\(ext)"
    }

    /// „snake.html“, „src/app.js“ → jen název souboru. Přípona musí obsahovat písmeno,
    /// ať se za název nepovažuje číslo („3.14“).
    private static func fileNames(in text: String) -> [String] {
        let pattern = #"[A-Za-z0-9_\-][A-Za-z0-9_\-.]*\.[A-Za-z][A-Za-z0-9]{0,5}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        .filter { !$0.hasPrefix(".") && !$0.lowercased().hasPrefix("www.") && !notFileNames.contains($0.lowercased()) }
    }

    /// Názvy knihoven a prostředí, které vypadají jako soubor („Spusť v Node.js“).
    private static let notFileNames: Set<String> = [
        "node.js", "vue.js", "next.js", "nuxt.js", "react.js", "three.js", "chart.js",
        "d3.js", "p5.js", "express.js", "ember.js", "backbone.js", "angular.js", "deno.js",
        "socket.io", "asp.net", "vb.net",
    ]

    static func fileExtension(for language: String) -> String {
        switch language.lowercased() {
        case "", "text", "txt", "plaintext", "plain": "txt"
        case "html", "htm": "html"
        case "javascript", "js", "jsx": "js"
        case "typescript", "ts", "tsx": "ts"
        case "python", "py": "py"
        case "bash", "sh", "zsh", "shell", "console": "sh"
        case "yaml", "yml": "yml"
        case "markdown", "md": "md"
        case "c++", "cpp", "cc": "cpp"
        case "csharp", "cs": "cs"
        case "objc", "objective-c": "m"
        case "kotlin", "kt": "kt"
        case "rust", "rs": "rs"
        case "golang", "go": "go"
        case "ruby", "rb": "rb"
        case let other where other.count <= 6 && other.allSatisfy({ $0.isLetter || $0.isNumber }): other
        default: "txt"
        }
    }

    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Okno s kódem: název jazyka, tlačítko Kopírovat a kód neproporcionálním písmem.
/// Dlouhé řádky se nezalamují, okno se dá posouvat do strany.
struct CodeBlockView: View {
    let language: String
    let code: String
    var isComplete = true
    var fileName = "kod.txt"

    @State private var copied = false
    @State private var isExpanded = false

    /// Od kolika řádků se kód sbalí a kolik se jich ve sbaleném stavu ukáže.
    private static let collapseAbove = 30
    private static let collapsedLines = 20
    /// Největší kus do jednoho `Text` – SwiftUI velmi dlouhý text nevykreslí.
    private static let piece = 4_000

    private var lines: [Substring] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Sbalit jde i rozepsaný blok – jinak by dlouhý kód při generování zabral celou
    /// obrazovku a přepínač by se objevil až na konci.
    private var isCollapsible: Bool { lines.count > Self.collapseAbove }

    /// Sbalený hotový kód ukazuje začátek. Rozepsaný ukazuje posledních pár řádků,
    /// ať je vidět, co model právě píše.
    private var visibleCode: String {
        guard isCollapsible, !isExpanded else { return code }
        let shown = isComplete ? lines.prefix(Self.collapsedLines) : lines.suffix(Self.collapsedLines)
        return shown.joined(separator: "\n")
    }

    /// Kolik řádků je ve sbaleném stavu skrytých nad/pod ukázkou.
    private var hiddenLines: Int { max(0, lines.count - Self.collapsedLines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.title(for: language))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // Soubor ke stažení: nabídka sdílení s „Uložit do Souborů“, AirDropem atd.
                // Soubor se zapíše až po klepnutí, ne při každém překreslení.
                ShareLink(
                    item: CodeFile(name: fileName, code: code),
                    preview: SharePreview(fileName, image: Image(systemName: "doc.text"))
                ) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(code.isEmpty || !isComplete)
                .accessibilityLabel("Uložit jako \(fileName)")

                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.snappy) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.body.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(code.isEmpty)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
                .accessibilityLabel(copied ? "Zkopírováno" : "Kopírovat kód")
            }

            if isCollapsible, !isExpanded, !isComplete {
                Text("… \(hiddenLines) \(Self.linesLabel(hiddenLines)) výše")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pieces(of: visibleCode).enumerated()), id: \.offset) { _, part in
                        Text(verbatim: part)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            }

            if isCollapsible {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? "Zobrazit méně" : "Zobrazit celý kód (\(lines.count) \(Self.linesLabel(lines.count)))",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    static func linesLabel(_ count: Int) -> String {
        switch count {
        case 1: "řádek"
        case 2...4: "řádky"
        default: "řádků"
        }
    }

    /// Dělí se po řádcích, ať se kus neutne uprostřed řádku.
    private func pieces(of text: String) -> [String] {
        guard text.count > Self.piece else { return [text] }
        var parts: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > Self.piece, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : "\n" + line
        }
        parts.append(current)
        return parts
    }

    static func title(for language: String) -> String {
        switch language.lowercased() {
        case "": "Plain text"
        case "text", "txt", "plaintext", "plain": "Plain text"
        case "html", "htm": "HTML"
        case "css": "CSS"
        case "js", "javascript", "jsx": "JavaScript"
        case "ts", "typescript", "tsx": "TypeScript"
        case "json": "JSON"
        case "swift": "Swift"
        case "py", "python": "Python"
        case "sh", "bash", "zsh", "shell", "console": "Shell"
        case "yml", "yaml": "YAML"
        case "md", "markdown": "Markdown"
        case "c": "C"
        case "cpp", "c++", "cc": "C++"
        case "cs", "csharp": "C#"
        case "objc", "objective-c": "Objective-C"
        case "kt", "kotlin": "Kotlin"
        case "rs", "rust": "Rust"
        case "go", "golang": "Go"
        case "java": "Java"
        case "sql": "SQL"
        case "xml": "XML"
        case "php": "PHP"
        case "rb", "ruby": "Ruby"
        default: language
        }
    }
}

/// Kód jako soubor pro `ShareLink`. Zapisuje se do dočasné složky až ve chvíli, kdy ho
/// cíl sdílení opravdu chce – iOS si ji časem uklidí sám.
struct CodeFile: Transferable {
    let name: String
    let code: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "Export-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: file.safeName)
            try file.code.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }

    /// Bez lomítek a dvojteček – název z textu modelu nesmí vést mimo složku.
    var safeName: String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .last?.trimmingCharacters(in: .whitespaces) ?? ""
        return cleaned.isEmpty ? "kod.txt" : cleaned
    }
}

/// Tabulka z markdownu. Buňky jsou pořád inline markdown (tučné, `kód`, odkazy).
struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        /// Bez dvojtečky v oddělovači – čísla doprava, text doleva.
        case automatic, leading, center, trailing
    }

    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    /// Obsah buňky bez markdownu – pro kopírování a CSV.
    static func plain(_ cell: String) -> String {
        String(MessageBlock.inlineMarkdown(cell).characters)
    }

    /// Sloupec, ve kterém jsou jen čísla (částky, procenta, roky) – zarovná se doprava.
    func isNumeric(column: Int) -> Bool {
        let values = rows.map { Self.plain($0[column]).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "–" && $0 != "-" }
        guard !values.isEmpty else { return false }
        let pattern = #"^[+\-−–(]?[\d\s\u00A0.,']+\)?\s*(%|Kč|CZK|€|EUR|\$|USD|mil\.?|mld\.?|tis\.?|[kKMB])?$"#
        return values.allSatisfy { value in
            let stripped = value.replacingOccurrences(of: "$", with: "", options: .anchored)
            return stripped.range(of: pattern, options: .regularExpression) != nil
                && stripped.contains(where: \.isNumber)
        }
    }

    func alignment(column: Int) -> Alignment {
        let stated = column < alignments.count ? alignments[column] : .automatic
        guard stated == .automatic else { return stated }
        return isNumeric(column: column) ? .trailing : .leading
    }

    /// Hlavička a jednotka pro zobrazení. Jednotka v závorce, kterou sdílí víc sloupců
    /// („FY2026 (mil. USD)“, „FY2025 (mil. USD)“), se z hlavičky odstraní a ukáže se jednou
    /// nad tabulkou. Jiné jednotky („Změna (%)“) zůstanou v hlavičce, jak jsou.
    /// Kopírování a CSV berou původní hlavičku, ať se jednotka mimo appku neztratí.
    var displayHeader: (header: [String], unit: String?) {
        let split = header.map(Self.splitUnit)
        var counts: [String: Int] = [:]
        for unit in split.compactMap(\.unit) { counts[unit.lowercased(), default: 0] += 1 }
        // Jediná jednotka v tabulce, nebo ta, která se opakuje nejčastěji (a jednoznačně).
        let ranked = counts.sorted { $0.value > $1.value }
        guard let top = ranked.first,
              counts.count == 1 || (top.value >= 2 && (ranked.count < 2 || ranked[1].value < top.value))
        else { return (header, nil) }
        let unit = split.compactMap(\.unit).first { $0.lowercased() == top.key } ?? top.key
        let titles = zip(header, split).map { original, part in
            part.unit?.lowercased() == top.key ? part.title : original
        }
        return (titles, unit)
    }

    /// „FY2026 (mil. USD)“ → („FY2026“, „mil. USD“). Bere jen závorku na konci, a jen
    /// když v ní je jednotka – „Segment (GAAP)“ zůstane celý.
    static func splitUnit(_ cell: String) -> (title: String, unit: String?) {
        let pattern = #"^(.*\S)\s*[(\[]\s*([^()\[\]]{1,24}?)\s*[)\]]$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)),
              let titleRange = Range(match.range(at: 1), in: cell),
              let unitRange = Range(match.range(at: 2), in: cell)
        else { return (cell, nil) }
        let unit = String(cell[unitRange])
        guard isUnit(unit) else { return (cell, nil) }
        return (String(cell[titleRange]), unit)
    }

    /// Měna, řád (tis., mil., mld.) nebo procenta.
    private static func isUnit(_ text: String) -> Bool {
        let pattern = #"(?i)(^|[\s.,/])(tis|tisíc|mil|mld|milion\w*|miliard\w*|mn|bn|k|m|usd|eur|czk|kč|gbp|chf|jpy|ks|kusů|p\.?\s?b\.?)($|[\s.,/])|[%$€£¥]"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Tabulátory mezi buňkami – po vložení do Numbers nebo Excelu se rozloží do sloupců.
    var tsv: String {
        ([header] + rows).map { row in
            row.map { Self.plain($0).replacingOccurrences(of: "\t", with: " ") }
                .joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    /// CSV se středníkem – česká Excel ho otevře rovnou do sloupců (čárka je desetinný
    /// oddělovač). BOM na začátku, ať Excel pozná UTF-8 a nerozbije diakritiku.
    var csv: String {
        let lines = ([header] + rows).map { row in
            row.map { cell -> String in
                let value = Self.plain(cell)
                guard value.contains(where: { ";\"\n\r".contains($0) }) else { return value }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            .joined(separator: ";")
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}

/// Okno s tabulkou: počet řádků, uložení jako CSV a kopírování (tabulátory, vloží se
/// do Numbers/Excelu po sloupcích). Široká tabulka se posouvá do strany, dlouhý text
/// v buňce se zalomí.
struct TableBlockView: View {
    let table: MarkdownTable
    var fileName = "tabulka.csv"

    @State private var copied = false

    /// Nejširší sloupec; delší obsah se v buňce zalomí na víc řádků.
    private static let maxColumnWidth: CGFloat = 240
    private static let minColumnWidth: CGFloat = 44
    private static let cellPadding: CGFloat = 10

    var body: some View {
        let widths = columnWidths()
        let display = table.displayHeader
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Tabulka")
                            .font(.subheadline.weight(.semibold))
                        Text("\(table.rows.count) \(Self.rowsLabel(table.rows.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let unit = display.unit {
                        Text("Hodnoty v \(unit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ShareLink(
                    item: CodeFile(name: fileName, code: table.csv),
                    preview: SharePreview(fileName, image: Image(systemName: "tablecells"))
                ) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Uložit jako \(fileName)")

                Button {
                    UIPasteboard.general.string = table.tsv
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.snappy) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.body.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
                .accessibilityLabel(copied ? "Zkopírováno" : "Kopírovat tabulku")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(display.header[column], column: column, width: widths[column])
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                    ForEach(table.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(table.header.indices, id: \.self) { column in
                                cell(table.rows[row][column], column: column, width: widths[column])
                                    .font(.subheadline)
                                    .monospacedDigit()
                            }
                        }
                        if row < table.rows.count - 1 {
                            Divider()
                                .gridCellUnsizedAxes(.horizontal)
                                .opacity(0.5)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func cell(_ text: String, column: Int, width: CGFloat) -> some View {
        let alignment = table.alignment(column: column)
        return Text(MessageBlock.inlineMarkdown(text))
            .multilineTextAlignment(alignment.textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: alignment.frameAlignment)
            .padding(.horizontal, Self.cellPadding / 2)
            .padding(.vertical, 7)
    }

    /// Šířka sloupců podle nejdelšího obsahu, změřená skutečným písmem. V ScrollView
    /// do strany by `Text` jinak nedostal žádnou šířku a nikdy by se nezalomil.
    private func columnWidths() -> [CGFloat] {
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let bold = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        let header = table.displayHeader.header
        return table.header.indices.map { column in
            var widest = Self.measure(MarkdownTable.plain(header[column]), font: bold)
            for row in table.rows {
                widest = max(widest, Self.measure(MarkdownTable.plain(row[column]), font: body))
            }
            return min(Self.maxColumnWidth, max(Self.minColumnWidth, ceil(widest) + 2))
        }
    }

    private static func measure(_ text: String, font: UIFont) -> CGFloat {
        // Víceřádková buňka (<br> model píše jako zalomení) se měří po nejdelším řádku.
        text.components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    static func rowsLabel(_ count: Int) -> String {
        switch count {
        case 1: "řádek"
        case 2...4: "řádky"
        default: "řádků"
        }
    }
}

private extension MarkdownTable.Alignment {
    var frameAlignment: SwiftUI.Alignment {
        switch self {
        case .trailing: .trailing
        case .center: .center
        case .leading, .automatic: .leading
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .trailing: .trailing
        case .center: .center
        case .leading, .automatic: .leading
        }
    }
}
