import SwiftUI
import SwiftData

/// Trénink LoRA adaptéru nad vybraným lokálním MLX modelem: sběr vzorků učitelem,
/// vlastní běh a správa hotového adaptéru.
struct TrainingView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelManager.self) private var models
    @Environment(\.modelContext) private var context

    @Query(sort: \TrainingSample.createdAt, order: .reverse)
    private var allSamples: [TrainingSample]

    private let adapters = AdapterStore.shared
    private let runtime = TrainingRuntime.shared

    @State private var configuration = TrainingConfiguration.load()
    @State private var showCapture = false
    @State private var showImport = false
    @State private var confirmDeleteAdapter = false
    @State private var lastPhase = TrainingPhase.last

    /// Vybraný lokální model – trénuje se vždy ten, se kterým se chatuje.
    private var model: LocalModelFile? {
        settings.selectedLocalModel.flatMap { models.model(id: $0) }
    }

    private var samples: [TrainingSample] {
        guard let model else { return [] }
        return allSamples.filter { $0.modelID == model.id }
    }

    private var approved: [TrainingSample] {
        samples.filter(\.isApproved)
    }

    /// Proč tenhle model natrénovat nejde, nebo nil. Čte se z `config.json`,
    /// takže se pozná ještě před načtením vah.
    private var architectureBlocker: String? {
        guard let model, model.kind == .mlx else { return nil }
        // Posílá se i počet vrstev s adaptérem: když jsou všechny s plnou pozorností,
        // rekurentní vrstvy pod nimi se při zpětném průchodu vůbec neprojdou.
        return TrainingEstimate.facts(modelDirectory: model.url)
            .blocker(adapterLayers: configuration.numLayers)
    }

    /// Kolik si trénink při současném nastavení nejspíš vezme. Počítá se z velikosti
    /// slovníku a délky vzorku, tedy z toho, co špičku doopravdy tvoří.
    private var peakEstimate: Int? {
        guard let model, model.kind == .mlx else { return nil }
        let facts = TrainingEstimate.facts(modelDirectory: model.url)
        guard facts.vocabSize > 0 else { return nil }
        return TrainingEstimate.peak(
            facts: facts,
            sequenceLength: configuration.maxSampleTokens,
            batchSize: configuration.batchSize
        )
    }

    var body: some View {
        Form {
            modelSection
            datasetSection
            if model?.kind == .mlx {
                parametersSection
                runSection
                adapterSection
            }
        }
        .navigationTitle("Trénink")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCapture) {
            TeacherCaptureView(modelID: model?.id ?? "")
        }
        .sheet(isPresented: $showImport) {
            DatasetImportView(modelID: model?.id ?? "")
        }
        .onChange(of: configuration) { _, new in new.save() }
        .alert("Trénink se nepovedl", isPresented: Binding(
            get: { runtime.errorMessage != nil },
            set: { if !$0 { runtime.errorMessage = nil } }
        )) {
            Button("OK") { runtime.errorMessage = nil }
        } message: {
            Text(runtime.errorMessage ?? "")
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        Section {
            LabeledContent("Model", value: model?.displayName ?? "Nevybrán")
        } footer: {
            switch model?.kind {
            case .mlx:
                if let blocker = architectureBlocker {
                    Text(blocker).foregroundStyle(.orange)
                } else {
                    Text("Trénuje se adaptér nad tímhle modelem. Základní váhy zůstanou nedotčené – vzniká jen malý soubor s LoRA vahami, který jde kdykoli vypnout nebo smazat.")
                }
            case .gguf:
                Text("Vybraný model je GGUF. llama.cpp trénink nepodporuje – přepni v Nastavení na MLX model.")
            case nil:
                Text("Nejdřív vyber lokální model v Nastavení › Modely v zařízení.")
            }
        }
    }

    // MARK: - Dataset

    @ViewBuilder
    private var datasetSection: some View {
        Section {
            LabeledContent("Vzorků") {
                Text("\(approved.count) z \(samples.count)")
                    .monospacedDigit()
            }
            NavigationLink {
                TrainingSamplesView(modelID: model?.id ?? "")
            } label: {
                Label("Procházet vzorky", systemImage: "list.bullet.rectangle")
            }
            .disabled(samples.isEmpty)

            Button {
                showCapture = true
            } label: {
                Label("Sesbírat z historie", systemImage: "graduationcap")
            }
            .disabled(model == nil || !hasTeacher)

            Button {
                showImport = true
            } label: {
                Label("Načíst dataset", systemImage: "square.and.arrow.down")
            }
            .disabled(model == nil)
        } header: {
            Text("Dataset")
        } footer: {
            Text(hasTeacher
                 ? "Učitel (Claude nebo Gemini) projde vybrané odpovědi lokálního modelu, ohodnotí je a napíše, jak měly vypadat. Platí se za API jen při tomhle kroku. Hotová data jdou místo toho načíst z Hugging Face nebo ze souboru."
                 : "Pro sběr vzorků učitelem doplň API klíč pro Claude nebo Gemini v Nastavení. Hotový dataset jde načíst i bez toho.")
        }
    }

    private var hasTeacher: Bool {
        settings.isConnected(.claude) || settings.isConnected(.gemini)
    }

    // MARK: - Parametry

    @ViewBuilder
    private var parametersSection: some View {
        Section {
            Stepper(value: $configuration.iterations, in: 20 ... 2000, step: 20) {
                LabeledContent("Iterací", value: "\(configuration.iterations)")
            }
            Stepper(value: $configuration.numLayers, in: 2 ... 32, step: 2) {
                LabeledContent("Vrstev s adaptérem", value: "\(configuration.numLayers)")
            }
            Picker("Rank", selection: $configuration.rank) {
                ForEach([4, 8, 16, 32], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Délka vzorku", selection: $configuration.maxSampleTokens) {
                ForEach([128, 192, 256, 384, 512], id: \.self) { Text("\($0) tokenů").tag($0) }
            }
            Stepper(value: $configuration.batchSize, in: 1 ... 4) {
                LabeledContent("Dávka", value: "\(configuration.batchSize)")
            }
        } header: {
            Text("Parametry")
        } footer: {
            Text("Na paměti rozhoduje hlavně délka vzorku. Model počítá pro každou pozici hodnoty přes celý slovník a drží si je až do konce zpětného průchodu – u slovníku se 150 tisíci položkami to při 640 tokenech dělá přes gigabajt, který vznikne během jediného kroku. Vrstvy a rank ovlivňují spíš čas.")
        }
    }

    // MARK: - Běh

    @ViewBuilder
    private var runSection: some View {
        Section {
            if runtime.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: runtime.progress)
                    HStack {
                        Text("\(runtime.iteration) / \(runtime.totalIterations)")
                            .monospacedDigit()
                        Spacer()
                        if let speed = runtime.tokensPerSecond {
                            Text("\(speed, format: .number.precision(.fractionLength(1))) tok/s")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let loss = runtime.trainLoss {
                        LabeledContent("Ztráta") {
                            Text("\(loss, format: .number.precision(.fractionLength(3)))")
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                    if let loss = runtime.validationLoss {
                        LabeledContent("Validační ztráta") {
                            Text("\(loss, format: .number.precision(.fractionLength(3)))")
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                    Text(runtime.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    runtime.requestStop()
                } label: {
                    Label("Zastavit", systemImage: "stop.circle")
                }
            } else {
                Button {
                    start()
                } label: {
                    Label("Spustit trénink", systemImage: "play.circle")
                }
                .disabled(approved.count < 8 || model == nil || architectureBlocker != nil)
                if !runtime.status.isEmpty {
                    Text(runtime.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            MemoryReadout()
            if let estimate = peakEstimate {
                LabeledContent("Odhad špičky") {
                    Text("\(estimate / 1_048_576) MB")
                        .monospacedDigit()
                        .foregroundStyle(estimate > MemoryBudget.available && MemoryBudget.available > 0 ? .orange : .secondary)
                }
                .font(.caption)
            }
            if !runtime.isRunning {
                Button {
                    start(smokeTest: true)
                } label: {
                    Label("Zkušební krok", systemImage: "testtube.2")
                }
                .disabled(approved.isEmpty || model == nil || architectureBlocker != nil)
            }
            if !runtime.isRunning, lastPhase != .idle, lastPhase != .finished {
                Label("Minulý pokus skončil ve fázi: \(lastPhase.label)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Trénink")
        } footer: {
            Text("Nech appku v popředí a telefon u nabíječky. Na pozadí iOS trénink ukončí; rozdělaná práce se ztratí až po poslední uložený checkpoint. Po pár minutách čekej zpomalení, jak se telefon zahřeje.")
        }
    }

    private func start(smokeTest: Bool = false) {
        guard let model else { return }
        let data = approved.map(TrainingSampleData.init)
        let systemPrompt = settings.local.systemPrompt
        let reasoning = settings.selectedLocalModel
            .map { settings.isReasoningEnabled(key: "local:" + $0) } ?? false
        let configuration = configuration
        Task {
            await LoRATrainer.shared.start(
                model: model,
                samples: data,
                systemPrompt: systemPrompt,
                reasoning: reasoning,
                configuration: configuration,
                smokeTest: smokeTest
            )
        }
    }

    // MARK: - Adaptér

    @ViewBuilder
    private var adapterSection: some View {
        if let model, adapters.exists(modelID: model.id) {
            Section {
                Toggle(isOn: Binding(
                    get: { adapters.isEnabled(modelID: model.id) },
                    set: { adapters.setEnabled($0, modelID: model.id) }
                )) {
                    Label("Používat adaptér", systemImage: "wand.and.stars")
                }
                if let info = adapters.info(modelID: model.id) {
                    LabeledContent("Iterací", value: "\(info.iterations)")
                    LabeledContent("Vzorků", value: "\(info.samples)")
                    if let loss = info.validationLoss {
                        LabeledContent("Validační ztráta") {
                            Text("\(loss, format: .number.precision(.fractionLength(3)))")
                                .monospacedDigit()
                        }
                    }
                    LabeledContent("Natrénováno", value: info.finishedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button(role: .destructive) {
                    confirmDeleteAdapter = true
                } label: {
                    Label("Smazat adaptér", systemImage: "trash")
                }
            } header: {
                Text("Adaptér")
            } footer: {
                Text("Přepínač se projeví při příštím načtení modelu. Než adaptér necháš zapnutý natrvalo, porovnej si na svých dotazech odpovědi s ním a bez něj – LoRA umí model i zhoršit a validační ztráta sama o sobě to nepozná.")
            }
            .confirmationDialog("Smazat adaptér?", isPresented: $confirmDeleteAdapter, titleVisibility: .visible) {
                Button("Smazat", role: .destructive) { adapters.delete(modelID: model.id) }
            } message: {
                Text("Vzorky zůstanou, smažou se jen natrénované váhy.")
            }
        }
    }
}

/// Živá paměť – stejná čísla jako v detailu ukazatele kontextu, jen zkráceně.
private struct MemoryReadout: View {
    @State private var free = MemoryBudget.available
    @State private var footprint = MemoryBudget.footprint
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        LabeledContent("Paměť") {
            Text(free > 0
                 ? "\(footprint / 1_048_576) MB · volné \(free / 1_048_576) MB"
                 : "neznámá")
                .monospacedDigit()
                .foregroundStyle(free > 0 && free < MemoryBudget.reserve ? .orange : .secondary)
        }
        .font(.caption)
        .onReceive(timer) { _ in
            free = MemoryBudget.available
            footprint = MemoryBudget.footprint
        }
    }
}

/// Seznam vzorků – dá se u nich vypnout zařazení do tréninku nebo je smazat.
struct TrainingSamplesView: View {
    let modelID: String
    @Environment(\.modelContext) private var context
    @Query(sort: \TrainingSample.createdAt, order: .reverse)
    private var allSamples: [TrainingSample]

    private var samples: [TrainingSample] {
        allSamples.filter { $0.modelID == modelID }
    }

    var body: some View {
        List {
            ForEach(samples) { sample in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(sample.score)/10")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sample.score >= 8 ? .green : sample.score >= 5 ? .orange : .red)
                        Text(sample.teacherModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { sample.isApproved },
                            set: { sample.isApproved = $0 }
                        ))
                        .labelsHidden()
                    }
                    Text(sample.prompt)
                        .font(.callout)
                        .lineLimit(2)
                    Text(sample.teacherAnswer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(samples[index]) }
                try? context.save()
            }
        }
        .navigationTitle("Vzorky")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if samples.isEmpty {
                ContentUnavailableView("Zatím žádné vzorky", systemImage: "tray")
            }
        }
    }
}

/// Výběr odpovědí z historie, které má projít učitel.
struct TeacherCaptureView: View {
    let modelID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings

    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @State private var selection: Set<UUID> = []
    @State private var teacher: AIProvider = .claude
    @State private var isRunning = false
    @State private var done = 0
    @State private var failed = 0
    @State private var errorMessage: String?

    /// Dvojice zadání + odpověď z chatů, které běžely na tomhle lokálním modelu.
    private var pairs: [TeacherCapture.Pair] {
        conversations
            .filter { $0.provider == .local }
            .flatMap { conversation -> [TeacherCapture.Pair] in
                let ordered = conversation.sortedMessages
                return ordered.indices.compactMap { index in
                    let message = ordered[index]
                    guard message.role == .user, index + 1 < ordered.count else { return nil }
                    let reply = ordered[index + 1]
                    guard reply.role == .assistant, !reply.text.isEmpty, !message.text.isEmpty else { return nil }
                    return TeacherCapture.Pair(
                        id: message.id,
                        prompt: message.text,
                        localAnswer: reply.text,
                        conversationTitle: conversation.title,
                        modelID: modelID,
                        date: message.createdAt
                    )
                }
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Učitel", selection: $teacher) {
                        if settings.isConnected(.claude) { Text("Claude").tag(AIProvider.claude) }
                        if settings.isConnected(.gemini) { Text("Gemini").tag(AIProvider.gemini) }
                    }
                } footer: {
                    Text("Každá vybraná odpověď je jeden požadavek na API.")
                }

                Section("Odpovědi z historie") {
                    ForEach(pairs) { pair in
                        Button {
                            if selection.contains(pair.id) { selection.remove(pair.id) } else { selection.insert(pair.id) }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: selection.contains(pair.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(pair.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.prompt)
                                        .lineLimit(2)
                                    Text(pair.conversationTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Sesbírat vzorky")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRunning ? "\(done)/\(selection.count)" : "Spustit") { run() }
                        .disabled(selection.isEmpty || isRunning)
                }
            }
            .overlay {
                if pairs.isEmpty {
                    ContentUnavailableView("Žádné odpovědi lokálního modelu", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .alert("Učitel neodpověděl", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear {
            if !settings.isConnected(.claude) { teacher = .gemini }
        }
    }

    private func run() {
        let chosen = pairs.filter { selection.contains($0.id) }
        let teacherModel = teacher == .claude ? settings.cloud.claudeModel : settings.cloud.geminiModel
        isRunning = true
        done = 0
        failed = 0

        Task {
            for pair in chosen {
                do {
                    let provider = try settings.cloudProvider(for: teacher)
                    let verdict = try await TeacherCapture.evaluate(pair, teacher: provider)
                    let sample = TrainingSample(
                        prompt: pair.prompt,
                        localAnswer: pair.localAnswer,
                        teacherAnswer: verdict.answer,
                        score: verdict.score,
                        teacherModel: teacherModel,
                        modelID: modelID
                    )
                    context.insert(sample)
                    done += 1
                } catch {
                    failed += 1
                    errorMessage = error.localizedDescription
                }
            }
            try? context.save()
            isRunning = false
            if failed == 0 { dismiss() }
        }
    }
}
