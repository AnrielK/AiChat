import SwiftUI

/// Výběr z několika možností v odpovědi (nabídka sešitů FinFillu). V textu zprávy je jako blok
/// ```aichat-choice s JSONem, takže se uloží s konverzací bez změny databáze a starší verze
/// appky ho ukážou aspoň jako kód.
struct ChoicePrompt: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable {
        var label: String
        var detail: String?
        /// Text, který se po klepnutí odešle jako zpráva.
        var command: String
        /// Zvýrazněná možnost (doporučená).
        var recommended: Bool?
    }

    /// Krátký štítek nad otázkou („Sešit“).
    var header: String
    var question: String
    var options: [Option]
    var footnote: String?

    static let language = "aichat-choice"

    /// Blok do textu odpovědi.
    var markdownBlock: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "```\(Self.language)\n\(json)\n```"
    }

    static func decode(_ json: String) -> ChoicePrompt? {
        try? JSONDecoder().decode(ChoicePrompt.self, from: Data(json.utf8))
    }
}

/// Karta s otázkou a možnostmi pod sebou – klepnutí odešle příkaz možnosti (přes openURL
/// aichat://send, který zpracuje RootView). Napsat číslo možnosti do zprávy funguje taky.
struct ChoiceCardView: View {
    let prompt: ChoicePrompt

    @Environment(\.openURL) private var openURL
    @State private var picked: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.header.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: .capsule)

            Text(MessageBlock.inlineMarkdown(prompt.question))
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index, option)
                }
            }

            if let note = prompt.footnote {
                Text(MessageBlock.inlineMarkdown(note))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func optionRow(_ index: Int, _ option: ChoicePrompt.Option) -> some View {
        let isPicked = picked == index
        let dimmed = picked != nil && !isPicked
        return Button {
            guard picked == nil, let url = Self.sendURL(option.command) else { return }
            withAnimation(.snappy) { picked = index }
            openURL(url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("\(index + 1)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(width: 26, height: 26)
                    .background(isPicked ? Color.accentColor : Color.primary.opacity(0.08), in: .circle)
                    .foregroundStyle(isPicked ? Color.white : Color.primary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        if option.recommended == true {
                            Text("doporučeno")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isPicked ? "checkmark" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isPicked ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: isPicked ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.45 : 1)
        .disabled(picked != nil)
        .accessibilityLabel("\(index + 1). \(option.label)")
    }

    static func sendURL(_ text: String) -> URL? {
        var c = URLComponents()
        c.scheme = "aichat"
        c.host = "send"
        c.queryItems = [URLQueryItem(name: "text", value: text)]
        return c.url
    }
}
