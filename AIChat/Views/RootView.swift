import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// Databázi historie se nepodařilo otevřít (appka pak běží jen v paměti).
    var storageError: String?
    @State private var storageErrorShown = false
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelManager.self) private var models

    @State private var chat = ChatViewModel()
    @State private var sheet: Sheet?
    /// Fokus pole zprávy – sdílený s ChatView (klepnutí mimo) i s lištou.
    @FocusState private var composerFocused: Bool

    private enum Sheet: String, Identifiable {
        case history, settings
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ChatView(chat: chat, dismissKeyboard: { composerFocused = false })
                // Odkazy aichat://send?text=… v odpovědi (nabídka sešitů FinFillu) odešlou text jako zprávu.
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "aichat", url.host == "send",
                          let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                              .queryItems?.first(where: { $0.name == "text" })?.value,
                          !chat.isGenerating
                    else { return .systemAction }
                    chat.draft = text
                    send()
                    return .handled
                })
                .alert("Historii nejde otevřít", isPresented: Binding(
                    get: { storageError != nil && !storageErrorShown },
                    set: { if !$0 { storageErrorShown = true } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Chaty se teď ukládají jen do zavření appky. Původní databáze zůstala beze změny.\n\n\(storageError ?? "")")
                }
                .navigationTitle(chat.conversation?.title ?? "Nový chat")
                .navigationSubtitle(settings.activeModelLabel)
                .navigationBarTitleDisplayMode(.inline)
                // Klepnutím na titulek jde rychle přepnout poskytovatele.
                .toolbarTitleMenu {
                    Picker("Model", selection: $settings.provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Label(provider.title, systemImage: provider.symbol).tag(provider)
                        }
                    }
                    // U lokálního poskytovatele jde rovnou vybrat i konkrétní model,
                    // ať se kvůli přepnutí nemusí chodit do nastavení.
                    if settings.provider == .local, models.installed.count > 1 {
                        Picker("Lokální model", selection: $settings.selectedLocalModel) {
                            ForEach(models.installed) { model in
                                Text(model.displayName).tag(Optional(model.id))
                            }
                        }
                    }
                    if settings.activeReasoningKey != nil {
                        Toggle("Přemýšlení", systemImage: "brain", isOn: $settings.activeReasoningEnabled)
                    }
                    // Zbývající limity cloudové služby (z hlaviček poslední odpovědi).
                    if settings.provider.isCloud,
                       let limits = RateLimitStatusStore.shared.summary(
                           provider: settings.provider,
                           model: settings.cloudModel(for: settings.provider)) {
                        Section {
                            Label(limits, systemImage: "gauge.with.dots.needle.33percent")
                        }
                    }
                }
                .toolbar {
                    // V otevřené konverzaci šipka zpět na úvodní obrazovku (ta je zároveň nový chat).
                    // Na úvodní obrazovce není kam se vracet, tlačítko se skryje.
                    if chat.conversation != nil {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Zpět", systemImage: "chevron.backward") {
                                composerFocused = false
                                withAnimation(.smooth) { chat.startNewChat() }
                            }
                        }
                    }
                    // Zbývající kontext – v konverzaci, nebo jakmile se začne psát.
                    if chat.conversation != nil || chat.pendingTokens > 0 {
                        ToolbarItem(placement: .topBarTrailing) {
                            ContextGauge(chat: chat)
                        }
                    }
                }
                // safeAreaBar = vlastní lišta s efektem rozostření okraje scrollu (iOS 26).
                .safeAreaBar(edge: .bottom) {
                    ChatBottomBar(
                        chat: chat,
                        isFocused: $composerFocused,
                        onHistory: { sheet = .history },
                        onSettings: { sheet = .settings },
                        onSend: send
                    )
                }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .history:
                HistoryView(
                    currentID: chat.conversation?.id,
                    onSelect: { chat.open($0) },
                    onDelete: { deleted in
                        if chat.conversation?.id == deleted.id { chat.startNewChat() }
                    }
                )
                .presentationDetents([.medium, .large])
            case .settings:
                SettingsView()
            }
        }
        // Při odchodu z appky uložit – iOS ji na pozadí může kdykoli ukončit.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { try? context.save() }
        }
        .alert(chat.errorTitle, isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(chat.errorMessage ?? "")
        }
    }

    private func send() {
        chat.send(context: context, settings: settings, models: models)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { chat.errorMessage != nil },
            set: { if !$0 { chat.errorMessage = nil } }
        )
    }
}
