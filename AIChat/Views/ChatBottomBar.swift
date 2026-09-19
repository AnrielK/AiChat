import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Spodní Liquid Glass lišta: Historie · pole pro zprávu · Nastavení.
/// Při psaní se boční tlačítka „vlijí“ do pole zprávy (glassEffectID + GlassEffectContainer).
struct ChatBottomBar: View {
    @Bindable var chat: ChatViewModel
    /// Fokus pole zprávy drží RootView – jen tak ho jde zrušit klepnutím mimo lištu.
    var isFocused: FocusState<Bool>.Binding
    @Environment(SettingsStore.self) private var settings
    let onHistory: () -> Void
    let onSettings: () -> Void
    let onSend: () -> Void

    @Namespace private var glass
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []

    private static let buttonSize: CGFloat = 50

    var body: some View {
        let downloading = DownloadManager.shared.activeCount

        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                if !isFocused.wrappedValue {
                    circleButton("Historie", symbol: "clock.arrow.circlepath", id: "history", action: onHistory)
                }
                composer
                if !isFocused.wrappedValue {
                    circleButton("Nastavení", symbol: "gearshape", id: "settings", action: onSettings)
                        .accessibilityValue(downloading > 0 ? "stahuje se \(downloading)" : "")
                }
            }
        }
        // Odznak musí být MIMO GlassEffectContainer – kontejner kreslí sklo všech tlačítek
        // v jedné vrstvě nad jejich overlayi, takže odznak na tlačítku skončil pod okrajem skla.
        // Tlačítko Nastavení je vždy vpravo dole, rámeček 50×50 v rohu leží přesně na něm.
        .overlay(alignment: .bottomTrailing) {
            if !isFocused.wrappedValue && downloading > 0 {
                downloadBadge(downloading)
                    .frame(width: Self.buttonSize, height: Self.buttonSize, alignment: .topTrailing)
                    .offset(x: 5, y: -5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.35), value: isFocused.wrappedValue)
        .animation(.smooth(duration: 0.25), value: downloading)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            chat.addPhotos(items)
            photoItems = []
        }
        // .item = cokoli; co nejde přečíst jako text, odmítne až AttachmentLoader se srozumitelnou chybou.
        // Jeden soubor na výběr: klepnutí ho rovnou přidá (ve vícenásobném výběru se muselo
        // hledat „Otevřít“). asCopy = systém soubor zkopíruje, i když je v iCloudu jen jako odkaz.
        .sheet(isPresented: $showFileImporter) {
            DocumentPicker(contentTypes: [.item], asCopy: true) { urls in
                chat.addFiles(urls, removeAfterLoading: true)
            }
            .ignoresSafeArea()
        }
    }

    private func circleButton(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(id, in: glass)
        .accessibilityLabel(title)
    }

    /// Počet běžících stahování – v rohu tlačítka Nastavení.
    private func downloadBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Color.accentColor))
            // Tenký lem v barvě pozadí odznak oddělí od skla pod ním.
            .overlay(Capsule().strokeBorder(Color(.systemBackground).opacity(0.9), lineWidth: 1.5))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !chat.attachments.isEmpty || chat.loadingAttachments > 0 {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 2) {
                attachButton
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
                TextField("Zpráva", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(isFocused)
                    .padding(.leading, 4)
                    .padding(.vertical, 15)

                sendButton
                    .padding(8)
            }
        }
        .frame(minHeight: 50)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 25))
        .glassEffectID("composer", in: glass)
    }

    /// Přiložit fotky nebo soubory.
    private var attachButton: some View {
        Menu {
            Button("Fotky", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            Button("Soubory", systemImage: "folder") { showFileImporter = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Přiložit")
    }

    /// Přílohy čekající na odeslání + upozornění, když se nevejdou do kontextu.
    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(chat.attachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            chat.removeAttachment(attachment)
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    if chat.loadingAttachments > 0 {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Načítám…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)

            if let hint = attachmentHint {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(hint)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 10)
    }

    /// Lokální modely mají malý kontext a obrázky nevidí – ať to uživatel ví dopředu.
    private var attachmentHint: String? {
        let files = chat.attachments
        guard !files.isEmpty else { return nil }
        let provider = settings.provider
        guard provider == .local || provider == .apple else { return nil }

        let tokens = files.reduce(0) { $0 + $1.estimatedTokens }
        // Kontext mohl engine zkrátit podle volné paměti – počítat se skutečným.
        let context = min(settings.local.contextLength, LocalRuntime.shared.memoryLimitedContext ?? .max)
        let capacity = provider == .apple ? 2_000 : max(0, context - min(settings.local.maxTokens, context / 2))
        var notes: [String] = []
        if tokens > capacity {
            // Příloha, která se nevejde, se neořízne – podle režimu ji převezme
            // SummaryPipeline (po částech) nebo RetrievalPipeline (vyhledá pasáže).
            // Tvrdit „uvidí jen začátek“ by bylo zavádějící, model dostane celý obsah,
            // jen ne najednou.
            let subject = files.count == 1 ? "Příloha má" : "Přílohy mají"
            let capacities = "\(subject) ≈ \(tokens.compactFormatted) tokenů, do kontextu (≈ \(capacity.compactFormatted)) se nevejdou"
            var note: String
            switch chat.profile(settings: settings) {
            case .summarize:
                note = capacities + " – zpracují se po částech, chvíli to potrvá."
            case .extract, .chat:
                note = capacities + " – vyhledají se v nich pasáže k dotazu."
            }
            if provider == .local, LocalRuntime.shared.memoryLimitedContext == nil {
                note += " Delší kontext nastavíš v Parametrech generování."
            }
            notes.append(note)
        }
        if files.contains(where: { $0.kind == .image }) {
            notes.append("Model v zařízení obrázek nevidí, dostane jen text v něm rozpoznaný.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private var sendButton: some View {
        let active = chat.isGenerating || chat.canSend
        return Button {
            if chat.isGenerating { chat.stop() } else { onSend() }
        } label: {
            Image(systemName: chat.isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(active ? Color.accentColor : Color.gray.opacity(0.35)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .accessibilityLabel(chat.isGenerating ? "Zastavit" : "Odeslat")
    }
}
