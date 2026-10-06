import SwiftUI

/// Připojení ke cloudové službě (Claude, Gemini, ChatGPT, NVIDIA): API klíč, výběr modelu, test spojení.
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
                Text("Klíč se ukládá jen do Klíčenky v tomto zařízení a posílá se výhradně na servery \(vendor).")
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
                .disabled(settings.reasoningKey(for: provider) == nil)
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
                if provider == .gemini || provider == .nvidia || (provider == .openai && !openAICaps.isReasoning) {
                    Toggle("Vlastní teplota", isOn: $settings.cloud.overrideTemperature)
                    if settings.cloud.overrideTemperature {
                        SliderRow(title: "Teplota", value: $settings.cloud.temperature, range: 0...2, step: 0.05)
                    }
                }
            } header: {
                Text("Společné pro všechny cloudové služby")
            } footer: {
                Text(parametersFooter)
            }

            if provider == .nvidia {
                nvidiaTierSection
            } else {
                tierSection
            }
            remainingSection
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

    /// NVIDIA má jen limit dotazů za minutu (tokeny za minutu neomezuje), tarif se nevybírá.
    private var nvidiaTierSection: some View {
        Section {
            LabeledContent("Tarif", value: "Free (vývojářský)")
            LabeledContent("Dotazů za minutu", value: "~40")
        } header: {
            Text("Tarif")
        } footer: {
            Text("Free API NVIDIA je zdarma a bez kreditní karty, ale jen pro vývoj a testování – ne pro produkční nasazení. Limit je zhruba 40 dotazů za minutu (liší se podle modelu). Shrnutí dlouhého dokumentu po kapitolách posílá víc dotazů za sebou – při překročení limitu appka počká a zkusí to znovu.")
        }
    }

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
        if provider == .openai {
            LabeledContent("Tarif", value: "Automaticky")
        } else if provider == .claude {
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
        switch provider {
        case .claude: settings.cloud.claudeTier.note
        case .openai: "OpenAI limit tokenů za minutu (vstup i max. délka odpovědi dohromady) posílá v hlavičkách každé odpovědi – zjistí se po prvním dotazu (stačí Otestovat připojení). Přesnou hodnotu pro model najdeš v nastavení projektu › Limits."
        default: settings.cloud.geminiTier.note
        }
    }

    private var manualInputPerMinute: Binding<Int?> {
        Binding(
            get: {
                switch provider {
                case .claude: settings.cloud.claudeInputPerMinute
                case .openai: settings.cloud.openaiInputPerMinute
                default: settings.cloud.geminiInputPerMinute
                }
            },
            set: { newValue in
                let value = newValue.flatMap { $0 > 0 ? $0 : nil }
                switch provider {
                case .claude: settings.cloud.claudeInputPerMinute = value
                case .openai: settings.cloud.openaiInputPerMinute = value
                default: settings.cloud.geminiInputPerMinute = value
                }
            }
        )
    }

    /// Po změně tarifu zapomenout hodnoty zjištěné z API – mohly patřit starému tarifu.
    private func tierChanged(_ apply: () -> Void) {
        apply()
        CloudLimitsStore.shared.resetTier(provider: provider, model: modelID.wrappedValue)
    }

    /// Kolik zbývá z limitů – z hlaviček poslední odpovědi, odpočet do obnovy běží živě.
    private var remainingSection: some View {
        let model = modelID.wrappedValue
        let status = RateLimitStatusStore.shared
        let snapshot = status.snapshot(provider: provider, model: model)

        return Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 10) {
                    if let snapshot {
                        if let left = snapshot.requestsLeft(now: now) {
                            remainingRow(
                                title: snapshot.requestsAreDaily ? "Dotazy (denní limit)" : "Dotazy za minutu",
                                left: left,
                                limit: snapshot.limitRequests,
                                reset: RateLimitSnapshot.countdown(to: snapshot.requestsResetAt, now: now)
                            )
                        }
                        if let left = snapshot.tokensLeft(now: now) {
                            remainingRow(
                                title: "Tokeny za minutu",
                                left: left,
                                limit: snapshot.limitTokens,
                                reset: RateLimitSnapshot.countdown(to: snapshot.tokensResetAt, now: now)
                            )
                        }
                    }
                    LabeledContent("Odesláno za minutu",
                                   value: "\(status.sentCount(provider: provider, model: model, within: 60))")
                    LabeledContent("Odesláno za 24 h",
                                   value: "\(status.sentCount(provider: provider, model: model, within: 86_400))")
                }
            }
        } header: {
            Text("Zbývá – \(model)")
        } footer: {
            Text(remainingFooter(snapshot))
        }
    }

    private func remainingRow(title: String, left: Int, limit: Int?, reset: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: limit.map { "\(left.formatted()) z \($0.formatted())" } ?? left.formatted())
            if let limit, limit > 0 {
                ProgressView(value: Double(max(0, min(left, limit))), total: Double(limit))
                    .tint(Double(left) / Double(limit) < 0.2 ? .red : .accentColor)
            }
            if let reset, left != limit {
                Text("Plně obnoveno \(reset)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func remainingFooter(_ snapshot: RateLimitSnapshot?) -> String {
        switch provider {
        case .nvidia:
            return "NVIDIA zbývající limity neposílá – počítadlo ukazuje dotazy odeslané z tohoto zařízení (limit ~40 za minutu)."
        case .gemini:
            return "Gemini zbývající limity neposílá – počítadlo ukazuje dotazy odeslané z tohoto zařízení. Denní limit tvého projektu najdeš v AI Studiu › Rate limit."
        default:
            guard let snapshot else {
                return "Zatím žádná odpověď – stav limitů se ukáže po prvním dotazu (stačí Otestovat připojení)."
            }
            let age = snapshot.date.formatted(.relative(presentation: .named))
            let daily = provider == .openai && snapshot.requestsAreDaily == false
                ? " Denní limit dotazů (RPD) API v hlavičkách nemusí hlásit – hlídej počítadlo za 24 h."
                : ""
            return "Podle poslední odpovědi (\(age)). Počítadla odeslaných dotazů jsou jen z tohoto zařízení.\(daily)"
        }
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
                    if provider != .gemini, settings.isConnected(provider) { await runTest() }
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
            get: { settings.cloudModel(for: provider) },
            set: { newValue in
                let value = newValue.trimmingCharacters(in: .whitespaces)
                switch provider {
                case .claude: settings.cloud.claudeModel = value
                case .openai: settings.cloud.openaiModel = value
                case .nvidia: settings.cloud.nvidiaModel = value
                default: settings.cloud.geminiModel = value
                }
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
        switch provider {
        case .claude:
            "Claude před odpovědí promyslí postup a shrnutí přemýšlení se zobrazí sbalené nad odpovědí. Vypnuto = rychlejší a levnější odpovědi."
        case .nvidia:
            "Přemýšlení se zobrazí sbalené nad odpovědí (u modelů, které ho posílají). Vypnuto = rychlejší odpovědi."
        case .openai:
            "Model před odpovědí přemýšlí, shrnutí se zobrazí sbalené nad odpovědí (u nejnovějších modelů jen s ověřenou organizací – jinak odpoví bez shrnutí). Vypnuto = bez přemýšlení, rychlejší a levnější."
        default:
            "Gemini před odpovědí přemýšlí, shrnutí se zobrazí sbalené nad odpovědí. Vypnutím se přemýšlení omezí na minimum."
        }
    }

    private var openAICaps: OpenAIProvider.Capabilities {
        OpenAIProvider.Capabilities(model: settings.cloud.openaiModel)
    }

    private var vendor: String {
        switch provider {
        case .claude: "Anthropic"
        case .openai: "OpenAI"
        case .nvidia: "NVIDIA"
        default: "Google"
        }
    }

    private var parametersFooter: String {
        switch provider {
        case .claude:
            "Při zapnutém přemýšlení se do max. délky počítá i přemýšlení. Teplotu novější modely Claude nepřijímají, proto se neposílá."
        case .openai:
            openAICaps.isReasoning
                ? "Do max. délky odpovědi se počítá i přemýšlení. Přemýšlející modely OpenAI vlastní teplotu nepřijímají, proto se neposílá."
                : "Bez vlastní teploty použije model výchozí hodnotu."
        case .nvidia:
            "Do max. délky odpovědi se počítá i přemýšlení. Okno modelu katalog neposílá – počítá se se 128k, menší okno appka zjistí z první chyby a prompt zkrátí."
        default:
            "Bez vlastní teploty použije model hodnotu doporučenou výrobcem – Gemini 3 ji výslovně doporučuje neměnit."
        }
    }

    private var maskedKey: String {
        guard let key = settings.apiKey(for: provider), key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    private var keyPageURL: URL {
        switch provider {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .nvidia: URL(string: "https://build.nvidia.com/settings/api-keys")!
        default: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    private func loadModels() async {
        guard let key = settings.apiKey(for: provider) else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            switch provider {
            case .claude: remoteModels = try await ClaudeProvider.listModels(apiKey: key)
            case .openai: remoteModels = try await OpenAIProvider.listModels(apiKey: key)
            case .nvidia: remoteModels = try await NvidiaProvider.listModels(apiKey: key)
            default: remoteModels = try await GeminiProvider.listModels(apiKey: key)
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
