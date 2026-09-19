import SwiftUI

/// Stažení modelu: přepínač MLX / GGUF, doporučené modely a hledání na Hugging Face.
struct ModelDownloadView: View {
    @Environment(ModelManager.self) private var models
    private let downloads = DownloadManager.shared

    @AppStorage("download.kind") private var kind: LocalModelKind = .mlx
    @State private var query = ""
    @State private var results: [HFModelSummary] = []
    /// Pro jaký formát jsou `results` – po přepnutí se nesmí otevřít GGUF detail s MLX repozitářem.
    @State private var resultsKind: LocalModelKind = .mlx
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var customSource = ""

    private struct SearchKey: Equatable {
        let query: String
        let kind: LocalModelKind
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            Section {
                Picker("Formát", selection: $kind) {
                    Text("MLX").tag(LocalModelKind.mlx)
                    Text("GGUF").tag(LocalModelKind.gguf)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text(kind == .mlx
                     ? "MLX je nejrychlejší na čipech Apple. Model je složka se soubory safetensors."
                     : "GGUF běží přes llama.cpp a má největší výběr modelů. Model je jeden soubor – u výsledků hledání si vybereš kvantizaci.")
            }

            if trimmedQuery.isEmpty {
                if !downloads.jobs.isEmpty {
                    Section("Stahování") {
                        ForEach(downloads.jobs) { DownloadJobRow(job: $0) }
                    }
                }
                recommendedSection
                customSection
            } else {
                resultsSection
            }
        }
        .navigationTitle("Stáhnout model")
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Hledat na Hugging Face")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: SearchKey(query: trimmedQuery, kind: kind)) { await runSearch() }
        .onAppear { models.refresh() }
    }

    // MARK: - Sekce

    private var recommendedSection: some View {
        Section("Doporučené pro iPhone") {
            ForEach(kind == .mlx ? CatalogModel.mlx : CatalogModel.gguf) { item in
                catalogRow(item)
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if results.isEmpty {
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Hledám…").foregroundStyle(.secondary)
                    }
                } else if let searchError {
                    Text(searchError).foregroundStyle(.orange)
                } else {
                    Text("Pro „\(trimmedQuery)“ se nic nenašlo.").foregroundStyle(.secondary)
                }
            }
            ForEach(results) { model in
                NavigationLink {
                    HFModelDetailView(model: model, kind: resultsKind)
                } label: {
                    resultRow(model)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Hugging Face")
                if isSearching && !results.isEmpty {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            if !results.isEmpty {
                Text(resultsKind == .mlx
                     ? "Seřazeno podle počtu stažení. Velikost uvidíš po otevření modelu."
                     : "Seřazeno podle počtu stažení. Po otevření vybereš kvantizaci.")
            }
        }
    }

    private var customSection: some View {
        Section {
            TextField(kind == .mlx ? "mlx-community/…" : "https://huggingface.co/…/model.gguf", text: $customSource)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Stáhnout", systemImage: "arrow.down.circle") {
                downloads.start(custom: customSource)
                customSource = ""
            }
            .disabled(customSource.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Vlastní odkaz")
        } footer: {
            Text("MLX: ID repozitáře z Hugging Face, třeba mlx-community/Qwen3-4B-4bit. GGUF: přímý odkaz na soubor. Tato appka má \(DeviceMemory.label) – doporučuji modely do \(DeviceMemory.recommendedLabel), zbytek si vezme kontext.")
        }
    }

    // MARK: - Řádky

    private func catalogRow(_ item: CatalogModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    if item.thinks {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("umí přemýšlet")
                    }
                }
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(item.repo)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if DownloadStatusBadge.isActive(item.id, models: models) {
                DownloadStatusBadge(modelID: item.id)
            } else {
                Button(item.sizeLabel, systemImage: "arrow.down") {
                    downloads.start(item)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
    }

    private func resultRow(_ model: HFModelSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.author + "/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.name)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            let mlxID = "mlx:" + ModelPaths.mlxFolderName(repo: model.id)
            if resultsKind == .mlx, DownloadStatusBadge.isActive(mlxID, models: models) {
                DownloadStatusBadge(modelID: mlxID)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                    Text(model.downloads.compactFormatted)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.downloads) stažení")
            }
        }
    }

    // MARK: - Hledání

    private func runSearch() async {
        let text = trimmedQuery
        let searchedKind = kind
        guard !text.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        if searchedKind != resultsKind { results = [] }
        isSearching = true
        do {
            // Počkat, až uživatel dopíše – každé další písmeno tenhle task zruší.
            try await Task.sleep(for: .milliseconds(350))
            let found = try await HuggingFaceRepo.search(text, kind: searchedKind)
            try Task.checkCancellation()
            results = found
            resultsKind = searchedKind
            searchError = nil
        } catch {
            // Zrušený task (další písmeno, odchod z obrazovky) stav nemění – už běží nový.
            if Task.isCancelled || error is CancellationError { return }
            results = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }
}

/// Detail repozitáře z Hugging Face: velikost MLX modelu, nebo výběr kvantizace GGUF.
struct HFModelDetailView: View {
    let model: HFModelSummary
    let kind: LocalModelKind

    @Environment(ModelManager.self) private var models
    private let downloads = DownloadManager.shared

    @State private var files: [HuggingFaceRepo.File] = []
    @State private var isLoading = true
    @State private var loadError: String?

    private var mlxID: String { "mlx:" + ModelPaths.mlxFolderName(repo: model.id) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(model.name)
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 14) {
                        stat("arrow.down", model.downloads.compactFormatted)
                        stat("heart", model.likes.compactFormatted)
                        if let tag = model.pipelineTag {
                            Text(tag)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if let url = model.webURL {
                    Link(destination: url) {
                        Label("Otevřít na Hugging Face", systemImage: "safari")
                    }
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Načítám soubory…").foregroundStyle(.secondary)
                    }
                }
            } else if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.orange)
                    Button("Zkusit znovu", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                }
            } else if kind == .mlx {
                mlxSection
            } else {
                ggufSection
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - MLX

    @ViewBuilder
    private var mlxSection: some View {
        let isMLX = files.contains { $0.path == "config.json" } && files.contains { $0.path.hasSuffix(".safetensors") }
        let total = files.reduce(Int64(0)) { $0 + $1.size }

        Section {
            if !isMLX {
                Text("V repozitáři chybí config.json nebo soubory .safetensors – tohle není MLX model, který by šel stáhnout.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Velikost", value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                LabeledContent("Souborů", value: "\(files.count)")
                mlxAction(total: total)
            }
        } footer: {
            if isMLX {
                fitNote(total)
            }
        }

        if let job = downloads.job(for: mlxID) {
            Section("Stahování") {
                DownloadJobRow(job: job)
            }
        }
    }

    @ViewBuilder
    private func mlxAction(total: Int64) -> some View {
        if models.model(id: mlxID) != nil {
            Label("Staženo – najdeš ho v Modelech v zařízení", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if downloads.preparing.contains(mlxID) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Připravuji stahování…").foregroundStyle(.secondary)
            }
        } else if downloads.job(for: mlxID) == nil {
            Button {
                downloads.startMLX(repo: model.id, title: nil)
            } label: {
                Label("Stáhnout · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))", systemImage: "arrow.down.circle.fill")
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - GGUF

    private var ggufSection: some View {
        Section {
            if files.isEmpty {
                Text("V repozitáři nejsou samostatné soubory .gguf (rozdělené modely appka nepodporuje).")
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.path) { file in
                ggufRow(file)
            }
        } header: {
            Text("Kvantizace")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Q4_K_M je dobrý kompromis mezi velikostí a kvalitou – nižší číslo znamená menší, ale méně přesný model. Tato appka má \(DeviceMemory.label), doporučuji soubory do \(DeviceMemory.recommendedLabel).")
                if files.contains(where: { DeviceMemory.isStreamableMoE(($0.path as NSString).lastPathComponent) }) {
                    Text("Tohle je MoE model: do paměti se načte jen hustá část a experti se čtou z úložiště (Parametry › Experty MoE z úložiště). Velikost souboru tedy omezuje hlavně volné místo\(DeviceMemory.freeStorage.map { " – teď je volných " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "").")
                }
            }
        }
    }

    private func ggufRow(_ file: HuggingFaceRepo.File) -> some View {
        let fileName = (file.path as NSString).lastPathComponent
        let quant = HuggingFaceRepo.quantLabel(for: fileName)
        let isMoE = DeviceMemory.isStreamableMoE(fileName)
        let fits = DeviceMemory.fits(file.size, fileName: fileName) && DeviceMemory.hasStorage(for: file.size)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(quant).fontWeight(.medium)
                    if isMoE {
                        Text("MoE")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("MoE, experti se čtou z úložiště")
                    }
                    if quant == "Q4_K_M" {
                        Text("doporučeno")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(fileName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if DownloadStatusBadge.isActive(fileName, models: models) {
                DownloadStatusBadge(modelID: fileName)
            } else {
                Button(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), systemImage: "arrow.down") {
                    if let url = HuggingFaceRepo.fileURL(repo: model.id, path: file.path) {
                        downloads.startGGUF(url: url, title: nil, knownSize: file.size)
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(fits ? Color.accentColor : Color.orange)
                .accessibilityHint(fits ? "" : (DeviceMemory.hasStorage(for: file.size) ? "Na tento iPhone je nejspíš moc velký" : "Na úložišti není dost místa"))
            }
        }
    }

    // MARK: -

    private func stat(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(value).monospacedDigit()
        }
    }

    @ViewBuilder
    private func fitNote(_ size: Int64) -> some View {
        if DeviceMemory.fits(size) {
            Text("Tato appka má \(DeviceMemory.label) – model by se měl vejít, na kontext zbyde místo.")
        } else {
            Text("Model je nejspíš moc velký: appka má \(DeviceMemory.label), doporučuji modely do \(DeviceMemory.recommendedLabel). Stáhnout ho můžeš, ale při načtení ho iOS nejspíš ukončí.")
                .foregroundStyle(.orange)
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            files = kind == .mlx
                ? try await HuggingFaceRepo.files(repo: model.id)
                : try await HuggingFaceRepo.ggufFiles(repo: model.id)
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
