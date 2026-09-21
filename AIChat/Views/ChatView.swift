import QuickLook
import SwiftUI

struct ChatView: View {
    let chat: ChatViewModel
    /// Schová klávesnici (zruší fokus pole zprávy v RootView).
    let dismissKeyboard: () -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelManager.self) private var models
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if let conversation = chat.conversation {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(conversation.sortedMessages) { message in
                            MessageRow(
                                message: message,
                                isStreaming: message.id == chat.streamingMessageID,
                                canEdit: !chat.isGenerating,
                                onResend: { edited in
                                    chat.resend(
                                        message, text: edited,
                                        context: context, settings: settings, models: models
                                    )
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .id(conversation.id)
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                // Tažením dolů klávesnice sjede spolu s prstem.
                .scrollDismissesKeyboard(.interactively)
            } else {
                // Úvodní obrazovka nescrolluje, takže tažení dolů musí zachytit vlastní gesto.
                EmptyChatView(provider: settings.provider, modelLabel: settings.activeModelLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 20).onEnded { value in
                            if value.translation.height > 40 { dismissKeyboard() }
                        }
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        // Klepnutí kamkoli mimo lištu klávesnici schová. Tlačítka uvnitř zpráv (přílohy,
        // přemýšlení) mají přednost, kontextové menu je dlouhý stisk – nekoliduje to.
        .onTapGesture { dismissKeyboard() }
        .background { Backdrop().ignoresSafeArea() }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    var canEdit = false
    var onResend: ((String) -> Void)?

    /// Otevřená příloha v náhledu (Quick Look).
    @State private var preview: URL?
    @State private var editedText: String?

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        Button {
                            preview = AttachmentStore.fileURL(for: attachment)
                        } label: {
                            AttachmentChip(attachment: attachment)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Otevře náhled souboru")
                    }
                    if !message.text.isEmpty {
                        CollapsibleText(text: message.text, tint: .white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(Color.accentColor.gradient, in: .rect(cornerRadius: 20))
                            .contextMenu {
                                copyButton
                                if canEdit, onResend != nil {
                                    Button("Upravit a odeslat znovu", systemImage: "pencil") {
                                        editedText = message.text
                                    }
                                }
                            }
                    }
                    MessageTimeView(message: message, isStreaming: false)
                        .padding(.trailing, 4)
                }
            }
            .quickLookPreview($preview)
            .sheet(isPresented: Binding(get: { editedText != nil }, set: { if !$0 { editedText = nil } })) {
                MessageEditor(text: editedText ?? "") { edited in
                    editedText = nil
                    onResend?(edited)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.status.isEmpty {
                    StatusView(
                        text: message.status.trimmingCharacters(in: .whitespacesAndNewlines),
                        isRunning: isStreaming && message.text.isEmpty
                    )
                }
                if !message.reasoning.isEmpty {
                    ReasoningView(
                        text: message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
                        isThinking: isStreaming && message.text.isEmpty
                    )
                }
                if !message.text.isEmpty {
                    // Bloky kódu jsou ve vlastním okně s tlačítkem Kopírovat,
                    // celou odpověď jde dál zkopírovat podržením textu.
                    MessageContentView(text: message.text)
                        .contextMenu { copyButton }
                } else if isStreaming && message.reasoning.isEmpty && message.status.isEmpty {
                    TypingIndicator()
                }
                if !message.sources.isEmpty {
                    SourcesView(sources: message.sources)
                }
                MessageTimeView(message: message, isStreaming: isStreaming)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var copyButton: some View {
        Button("Kopírovat", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.text
        }
    }
}

/// Dlouhý text ve zprávě. Kromě sbalení řeší i to, že SwiftUI `Text` se stotisíci
/// znaky nevykreslí vůbec – bublina zůstane prázdná. Rozbalený text se proto skládá
/// z několika kratších `Text`, každý zvlášť v rámci limitu vykreslování.
struct CollapsibleText: View {
    let text: String
    var markdown = false
    var tint: Color?

    @State private var isExpanded = false

    /// Kolik znaků se ukáže ve sbaleném stavu.
    private static let collapsed = 700
    /// Největší kus, který se posílá do jednoho `Text`.
    private static let piece = 4_000

    private var isLong: Bool { text.count > Self.collapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, part in
                    rendered(part)
                }
            } else {
                rendered(isLong ? String(text.prefix(Self.collapsed)) + "…" : text)
                    .lineLimit(isLong ? 8 : nil)
            }

            if isLong {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? "Zobrazit méně" : "Zobrazit celý text (\(text.count) znaků)",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint ?? .accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func rendered(_ part: String) -> some View {
        if markdown {
            Text(Self.markdown(part))
        } else {
            Text(part)
        }
    }

    /// Dělí se po řádcích, ať se neláme uprostřed slova.
    private var pieces: [String] {
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
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Úprava odeslané zprávy před opětovným odesláním.
struct MessageEditor: View {
    @State var text: String
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding(.horizontal, 12)
                .navigationTitle("Upravit zprávu")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Zrušit") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Odeslat") { onSend(text) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

/// Průběh vícekolového zpracování dokumentu. Schválně vypadá jinak než přemýšlení –
/// je to hlášení aplikace, ne výstup modelu.
struct StatusView: View {
    let text: String
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isRunning ? "gearshape.2" : "checkmark.circle")
                .symbolEffect(.rotate, isActive: isRunning)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

/// Sbalitelné přemýšlení modelu nad odpovědí.
struct ReasoningView: View {
    let text: String
    let isThinking: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, isActive: isThinking)
                    Text(isThinking ? "Přemýšlím…" : "Přemýšlení")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Sbalit přemýšlení" : "Rozbalit přemýšlení")

            if isExpanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
    }
}

/// Úryvky podkladů, na které se odpověď odkazuje čísly v hranatých závorkách.
/// Odpověď z dlouhého dokumentu jinak nejde ověřit – model dostal jen výběr
/// a uživatel nevidí, který to byl.
struct SourcesView: View {
    let sources: [MessageSource]
    @State private var expanded: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Podklady (\(sources.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        expanded = expanded == source.id ? nil : source.id
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(source.id)]")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Text(source.label)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded == source.id ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded == source.id ? "Sbalit úryvek" : "Zobrazit úryvek")

                if expanded == source.id {
                    Text(source.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(width: 2)
                        }
                        .transition(.opacity)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .phaseAnimator([0.25, 1.0]) { content, phase in
                        content.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.55).delay(Double(index) * 0.18)
                    }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .accessibilityLabel("Model píše")
    }
}

struct EmptyChatView: View {
    let provider: AIProvider
    let modelLabel: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: provider.symbol)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .circle)

            Text("Na co se chceš zeptat?")
                .font(.title2.weight(.semibold))

            VStack(spacing: 2) {
                Text(provider.title)
                Text(modelLabel).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 60)
    }
}

/// Jemný barevný podklad – Liquid Glass potřebuje něco, co může lámat.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.12)
        let secondary = Color.teal.opacity(scheme == .dark ? 0.14 : 0.08)
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                accent, .clear, secondary,
                .clear, .clear, .clear,
                secondary, .clear, accent
            ]
        )
        .background(Color(.systemBackground))
    }
}
