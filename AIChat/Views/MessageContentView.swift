import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Text odpovědi rozdělený na bloky: běžný text (inline markdown), nadpisy, oddělovače
/// a bloky kódu. Kód se ukazuje v samostatném okně s názvem jazyka a tlačítkem
/// na kopírování, místo aby se ```značky vypisovaly do textu.
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

    /// Rozdělí markdown na bloky. Řeší jen to, co SwiftUI `Text` neumí: bloky kódu,
    /// nadpisy a oddělovače. Zbytek (tučné, kurzíva, `kód`, odkazy) zůstane inline markdownu.
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

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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
    private static let collapseAbove = 40
    private static let collapsedLines = 20
    /// Největší kus do jednoho `Text` – SwiftUI velmi dlouhý text nevykreslí.
    private static let piece = 4_000

    private var lines: [Substring] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Rozepsaný blok se ukazuje celý, ať je vidět, jak přibývá.
    private var isCollapsible: Bool { isComplete && lines.count > Self.collapseAbove }

    private var visibleCode: String {
        guard isCollapsible, !isExpanded else { return code }
        return lines.prefix(Self.collapsedLines).joined(separator: "\n")
    }

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
                        isExpanded ? "Zobrazit méně" : "Zobrazit celý kód (\(lines.count) řádků)",
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
