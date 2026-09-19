import SwiftUI

/// Připojení ke Claude nebo Gemini: API klíč, výběr modelu, test spojení.
struct CloudProviderView: View {
    let provider: AIProvider

    @Environment(SettingsStore.self) private var settings
    @State private var keyDraft = ""
    @State private var remoteModels: [RemoteModel] = []
    @State private var isLoadingModels = false
    @State private var test: TestState = .idle

    private enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                if settings.isConnected(provider) {
                    LabeledContent("API klíč") {
                        Text(maskedKey).monospaced()
                    }
                    Button("Odebrat klíč", role: .destructive) {
                        settings.setAPIKey("", for: provider)
                        remoteModels = []
                        test = .idle
                    }
                } else {
                    SecureField("Vlož API klíč", text: $keyDraft)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Uložit a připojit") {
                        settings.setAPIKey(keyDraft, for: provider)
                        keyDraft = ""
                        Task { await loadModels() }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link(destination: keyPageURL) {
                    Label("Kde klíč získat", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("Připojení")
            } footer: {
                Text("Klíč se ukládá jen do Klíčenky v tomto zařízení a posílá se výhradně na servery \(provider == .claude ? "Anthropic" : "Google").")
            }

            Section {
                TextField("ID modelu", text: modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()

                if isLoadingModels {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Načítám modely…").foregroundStyle(.secondary)
                    }
                } else if !remoteModels.isEmpty {
                    Menu {
                        ForEach(remoteModels) { model in
                            Button {
                                modelID.wrappedValue = model.id
                            } label: {
                                if model.id == modelID.wrappedValue {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    } label: {
                        Label("Vybrat z \(remoteModels.count) modelů", systemImage: "list.bullet")
                    }
                }

                Button("Načíst modely z účtu", systemImage: "arrow.clockwise") {
                    Task { await loadModels() }
                }
                .disabled(!settings.isConnected(provider) || isLoadingModels)
            } header: {
                Text("Model")
            }

            Section {
                Toggle(isOn: reasoningBinding) {
                    Label("Přemýšlení", systemImage: "brain")
                }
            } header: {
                Text("Přemýšlení – \(modelID.wrappedValue)")
            } footer: {
                Text(settings.reasoningNote(for: provider) ?? reasoningFooter)
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("Otestovat připojení", systemImage: "bolt.horizontal")
                        Spacer()
                        if test == .running { ProgressView() }
                    }
                }
                .disabled(!settings.isConnected(provider) || test == .running)

                switch test {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                default:
                    EmptyView()
                }

                Button(settings.provider == provider ? "\(provider.title) je aktivní" : "Používat \(provider.title)") {
                    settings.provider = provider
                }
                .disabled(settings.provider == provider || !settings.isConnected(provider))
            }

            Section {
                TextField("Systémový prompt", text: $settings.cloud.systemPrompt, axis: .vertical)
                    .lineLimit(2...6)
                Stepper(value: $settings.cloud.maxTokens, in: 256...128_000, step: 512) {
                    LabeledContent("Max. délka odpovědi", value: "\(settings.cloud.maxTokens)")
                }
                if provider == .gemini {
                    Toggle("Vlastní teplota", isOn: $settings.cloud.overrideTemperature)
                    if settings.cloud.overrideTemperature {
                        SliderRow(title: "Teplota", value: $settings.cloud.temperature, range: 0...2, step: 0.05)
                    }
                }
            } header: {
                Text("Parametry pro Claude i Gemini")
            } footer: {
                Text(provider == .claude
                     ? "Při zapnutém přemýšlení se do max. délky počítá i přemýšlení. Teplotu novější modely Claude nepřijímají, proto se neposílá."
                     : "Bez vlastní teploty použije model hodnotu doporučenou výrobcem – Gemini 3 ji výslovně doporučuje neměnit.")
            }

            tierSection
            limitsSection
        }
        .navigationTitle(provider.title)
        .keyboardDoneButton()
        .task {
            if settings.isConnected(provider) && remoteModels.isEmpty {
                await loadModels()
            }
        }
        .task(id: modelID.wrappedValue) {
            await settings.refreshCloudModelInfo(for: provider)
        }
    }

    // MARK: - Tarif a limity

    /// Tarif vybraný ručně – podle něj se nastaví limity. Ruční hodnota má přednost,
    /// hodnota zjištěná z API platí, když je nižší.
    private var tierSection: some View {
        let preset = settings.tierLimits(for: provider)

        return Section {
            tierPicker

            if let preset {
                LabeledContent("Vstup za minutu", value: preset.inputPerMinute.formatted())
                if let output = preset.outputPerMinute {
                    LabeledContent("Výstup za minutu", value: output.formatted())
                }
                if let requests = preset.requestsPerMinute {
                    LabeledContent("Požadavků za minutu", value: requests.formatted())
                }
            }

            LabeledContent("Vlastní limit vstupu") {
                TextField(preset == nil ? "automaticky" : "podle tarifu", value: manualInputPerMinute, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
        } header: {
            Text("Tarif")
        } footer: {
            Text(tierNote + " Vlastní limit (vstupní tokeny za minutu) přepíše hodnotu tarifu – nech prázdné, pokud ji neznáš.")
        }
    }

    @ViewBuilder
    private var tierPicker: some View {
        if provider == .claude {
            Picker("Tarif", selection: Binding(
                get: { settings.cloud.claudeTier },
                set: { tier in tierChanged { settings.cloud.claudeTier = tier } }
            )) {
                ForEach(ClaudeTier.allCases) { Text($0.title).tag($0) }
            }
        } else {
            Picker("Tarif", selection: Binding(
                get: { settings.cloud.geminiTier },
                set: { tier in tierChanged { settings.cloud.geminiTier = tier } }
            )) {
                ForEach(GeminiTier.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var tierNote: String {
        provider == .claude ? settings.cloud.claudeTier.note : settings.cloud.geminiTier.note
    }

    private var manualInputPerMinute: Binding<Int?> {
        Binding(
            get: { provider == .claude ? settings.cloud.claudeInputPerMinute : settings.cloud.geminiInputPerMinute },
            set: { newValue in
                let value = newValue.flatMap { $0 > 0 ? $0 : nil }
                if provider == .claude { settings.cloud.claudeInputPerMinute = value } else { settings.cloud.geminiInputPerMinute = value }
            }
        )
    }

    /// Po změně tarifu zapomenout hodnoty zjištěné z API – mohly patřit starému tarifu.
    private func tierChanged(_ apply: () -> Void) {
        apply()
        CloudLimitsStore.shared.resetTier(provider: provider, model: modelID.wrappedValue)
    }

    /// Limity modelu (Models API), hodnoty zjištěné z API a z nich parametry dalšího požadavku.
    private var limitsSection: some View {
        let model = modelID.wrappedValue
        let detected = CloudLimitsStore.shared.limits(for: provider, model: model)
        let plan = settings.cloudPlan(for: provider)
        let unknown = "zatím neznámé"

        return Section {
            LabeledContent("Okno modelu", value: detected.contextWindow.map { $0.formatted() } ?? unknown)
            LabeledContent("Max. odpověď modelu", value: detected.maxOutputTokens.map { $0.formatted() } ?? unknown)

            if let input = detected.inputTokensPerMinute {
                LabeledContent("Z API: vstup za minutu", value: input.formatted())
            }
            if let isFree = detected.isFreeTier {
                LabeledContent("Z API: tarif", value: isFree ? "Free tier" : "placený")
            }

            Toggle("Přizpůsobit tarifu", isOn: Binding(
                get: { settings.cloud.adaptToTier },
                set: { settings.cloud.adaptToTier = $0 }
            ))

            LabeledContent("Prompt teď nejvýš", value: "\(plan.inputTokenBudget.formatted()) tok.")
            LabeledContent("Odpověď nejvýš", value: "\(plan.maxOutputTokens.formatted()) tok.")

            Button("Znovu zjistit limity", systemImage: "arrow.clockwise") {
                CloudLimitsStore.shared.resetTier(provider: provider, model: model)
                Task {
                    await settings.refreshCloudModelInfo(for: provider, force: true)
                    if provider == .claude, settings.isConnected(provider) { await runTest() }
                }
            }
            .disabled(!settings.isConnected(provider))
        } header: {
            Text("Limity a parametry")
        } footer: {
            Text(plan.limitedByTier
                 ? "Prompt omezuje tarif: větší požadavek by překročil limit vstupních tokenů za minutu a API by ho odmítlo. Když se konverzace nevejde, vynechají se nejstarší zprávy a přílohy se zkrátí."
                 : "Prompt omezuje jen okno modelu – limit tarifu za minutu je vyšší. Max. délka odpovědi se drží pod limitem modelu.")
        }
    }

    // MARK: -

    private var modelID: Binding<String> {
        Binding(
            get: { provider == .claude ? settings.cloud.claudeModel : settings.cloud.geminiModel },
            set: { newValue in
                let value = newValue.trimmingCharacters(in: .whitespaces)
                if provider == .claude { settings.cloud.claudeModel = value } else { settings.cloud.geminiModel = value }
            }
        )
    }

    /// Přemýšlení se ukládá pro konkrétní ID modelu – každý model si pamatuje své.
    private var reasoningBinding: Binding<Bool> {
        Binding(
            get: { settings.reasoningKey(for: provider).map(settings.isReasoningEnabled(key:)) ?? false },
            set: { newValue in
                if let key = settings.reasoningKey(for: provider) { settings.setReasoning(newValue, key: key) }
            }
        )
    }

    private var reasoningFooter: String {
        provider == .claude
            ? "Claude před odpovědí promyslí postup a shrnutí přemýšlení se zobrazí sbalené nad odpovědí. Vypnuto = rychlejší a levnější odpovědi."
            : "Gemini před odpovědí přemýšlí, shrnutí se zobrazí sbalené nad odpovědí. Vypnutím se přemýšlení omezí na minimum."
    }

    private var maskedKey: String {
        guard let key = settings.apiKey(for: provider), key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    private var keyPageURL: URL {
        provider == .claude
            ? URL(string: "https://console.anthropic.com/settings/keys")!
            : URL(string: "https://aistudio.google.com/apikey")!
    }

    private func loadModels() async {
        guard let key = settings.apiKey(for: provider) else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            if provider == .claude {
                remoteModels = try await ClaudeProvider.listModels(apiKey: key)
            } else {
                remoteModels = try await GeminiProvider.listModels(apiKey: key)
            }
        } catch {
            test = .failure(error.localizedDescription)
        }
    }

    private func runTest() async {
        test = .running
        do {
            let client = try settings.cloudProvider(for: provider, maxTokens: 512)
            var answer = ""
            for try await event in client.stream([ChatTurn(role: .user, text: "Odpověz jednou krátkou větou: funguje spojení?")]) {
                if case .text(let text) = event { answer += text }
            }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            test = .success(trimmed.isEmpty ? "Spojení funguje." : String(trimmed.prefix(120)))
        } catch {
            test = .failure(error.localizedDescription)
        }
    }
}
