import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Načtení hotových trénovacích vzorků: z datasetu na Hugging Face, nebo
/// ze souboru JSONL v Souborech.
struct DatasetImportView: View {
    let modelID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query private var existing: [TrainingSample]

    @State private var datasetID = ""
    @State private var splits: [HuggingFaceDataset.Split] = []
    @State private var selectedSplit: HuggingFaceDataset.Split?
    @State private var page: HuggingFaceDataset.Page?
    @State private var mapping = DatasetMapping()
    @State private var limit = 200
    @State private var onlyCzech = true

    @State private var isLoading = false
    @State private var isImporting = false
    @State private var progress = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var showFileImporter = false
    @State private var localFiles: [URL] = []

    /// Zadání, která už v datasetu jsou – ať se stejný řádek nenaimportuje dvakrát.
    private var existingPrompts: Set<String> {
        Set(existing.filter { $0.modelID == modelID }.map(\.prompt))
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if !splits.isEmpty { splitSection }
                if let page { mappingSection(page) }
                optionsSection
                if !status.isEmpty { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Načíst dataset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "\(progress)" : "Importovat") { startImport() }
                        .disabled(!mapping.isComplete || isImporting || page == nil)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.importTypes
            ) { result in
                switch result {
                case .success(let url): importFile(at: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .onAppear { localFiles = JSONLDataset.localFiles() }
            .alert("Nepovedlo se", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Zdroj

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            HStack {
                TextField("uživatel/dataset", text: $datasetID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { loadSplits() }
                if isLoading {
                    ProgressView()
                } else {
                    Button("Načíst") { loadSplits() }
                        .disabled(datasetID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Vybrat soubor v Souborech", systemImage: "folder")
            }
        } header: {
            Text("Zdroj")
        } footer: {
            Text("Čte se přes prohlížeč datasetů Hugging Face, takže se stáhne jen tolik řádků, kolik nastavíš. U datasetů s omezeným přístupem je potřeba token ve Stahování. Zkontroluj si licenci – hodně českých datasetů má CC-BY-NC, tedy nekomerční použití.")
        }

        if !localFiles.isEmpty {
            Section {
                ForEach(localFiles, id: \.self) { file in
                    Button {
                        importFile(at: file)
                    } label: {
                        Label(file.lastPathComponent, systemImage: "doc.text")
                    }
                }
            } header: {
                Text("Soubory v aplikaci")
            } footer: {
                Text("Soubory nahrané do složky AIChat v Souborech. Když výběr přes Soubory příponu .jsonl nenabídne, přetáhni soubor sem a načti ho odsud.")
            }
        }
    }

    /// Přípona .jsonl nemá v systému registrovaný typ, takže se odvodí za běhu
    /// a jako záchranná síť zůstávají obecné typy.
    private static var importTypes: [UTType] {
        var types: [UTType] = []
        for suffix in ["jsonl", "ndjson"] {
            if let type = UTType(filenameExtension: suffix) { types.append(type) }
        }
        types.append(contentsOf: [.json, .plainText, .text, .data])
        return types
    }

    // MARK: - Split

    @ViewBuilder
    private var splitSection: some View {
        Section("Split") {
            Picker("Split", selection: $selectedSplit) {
                ForEach(splits) { split in
                    Text(split.label).tag(Optional(split))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedSplit) { _, _ in loadPreview() }
        }
    }

    // MARK: - Mapování

    @ViewBuilder
    private func mappingSection(_ page: HuggingFaceDataset.Page) -> some View {
        Section {
            Picker("Tvar", selection: $mapping.kind) {
                ForEach(DatasetMapping.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch mapping.kind {
            case .columns:
                columnPicker("Zadání", selection: $mapping.promptColumn, columns: page.columns)
                columnPicker("Kontext", selection: $mapping.inputColumn, columns: page.columns, allowsNone: true)
                columnPicker("Odpověď", selection: $mapping.outputColumn, columns: page.columns)
            case .messages:
                columnPicker("Konverzace", selection: $mapping.messagesColumn, columns: page.columns)
            }

            if let sample = page.rows.compactMap({ mapping.pair(from: $0) }).first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample.prompt).font(.caption).lineLimit(3)
                    Text(sample.answer).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                .padding(.vertical, 2)
            } else {
                Text("Z těchhle sloupců nejde dvojici složit.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Sloupce")
        } footer: {
            Text("Split má \(page.total) řádků. Ukázka výše je první použitelná dvojice – když nesedí, přepni sloupce.")
        }
    }

    @ViewBuilder
    private func columnPicker(
        _ title: String,
        selection: Binding<String>,
        columns: [String],
        allowsNone: Bool = false
    ) -> some View {
        Picker(title, selection: selection) {
            if allowsNone { Text("žádný").tag("") }
            ForEach(columns, id: \.self) { Text($0).tag($0) }
        }
    }

    // MARK: - Volby

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            Picker("Nejvýš", selection: $limit) {
                ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0) vzorků").tag($0) }
            }
            Toggle("Jen česky vypadající", isOn: $onlyCzech)
        } footer: {
            Text("Strop i filtr platí pro Hugging Face i pro soubor. Filtr češtiny se dívá na podíl znaků s diakritikou – odchytí nepřeložené řádky ve strojově přeložených datasetech, slovenštinu od češtiny ale nepozná. U vlastního datasetu ho můžeš vypnout.")
        }
    }

    // MARK: - Načítání

    private func loadSplits() {
        guard let id = HuggingFaceRepo.normalizedID(datasetID) else {
            errorMessage = "ID datasetu má být ve tvaru uživatel/dataset."
            return
        }
        datasetID = id
        isLoading = true
        status = ""
        page = nil
        Task {
            do {
                splits = try await HuggingFaceDataset.splits(dataset: id)
                selectedSplit = splits.first
                loadPreview()
            } catch {
                errorMessage = error.localizedDescription
                splits = []
            }
            isLoading = false
        }
    }

    private func loadPreview() {
        guard let split = selectedSplit else { return }
        isLoading = true
        Task {
            do {
                let preview = try await HuggingFaceDataset.page(
                    dataset: datasetID, split: split, offset: 0, length: HuggingFaceDataset.pageLimit
                )
                page = preview
                mapping = DatasetMapping.autodetect(page: preview)
            } catch {
                errorMessage = error.localizedDescription
                page = nil
            }
            isLoading = false
        }
    }

    // MARK: - Import

    private func startImport() {
        guard let split = selectedSplit else { return }
        isImporting = true
        progress = 0
        var seen = existingPrompts
        var added = 0
        var skipped = 0

        Task {
            var offset = 0
            do {
                while added < limit {
                    let chunk = try await HuggingFaceDataset.page(
                        dataset: datasetID, split: split,
                        offset: offset, length: HuggingFaceDataset.pageLimit
                    )
                    if chunk.rows.isEmpty { break }
                    offset += chunk.rows.count

                    for row in chunk.rows where added < limit {
                        guard let pair = mapping.pair(from: row) else { skipped += 1; continue }
                        guard !seen.contains(pair.prompt) else { skipped += 1; continue }
                        guard !onlyCzech || DatasetFilter.looksCzech(pair.answer) else { skipped += 1; continue }
                        seen.insert(pair.prompt)
                        insert(pair, source: "hf:" + datasetID)
                        added += 1
                        progress = added
                    }
                    if offset >= chunk.total { break }
                }
                try? context.save()
                status = "Přidáno \(added), přeskočeno \(skipped)."
                if added > 0 { dismiss() }
            } catch {
                try? context.save()
                errorMessage = error.localizedDescription
                status = "Přidáno \(added) před chybou."
            }
            isImporting = false
        }
    }

    private func importFile(at url: URL) {
        do {
            let pairs = try JSONLDataset.pairs(at: url)
            var seen = existingPrompts
            var added = 0
            for pair in pairs where added < limit {
                guard !seen.contains(pair.prompt) else { continue }
                guard !onlyCzech || DatasetFilter.looksCzech(pair.answer) else { continue }
                seen.insert(pair.prompt)
                insert(pair, source: "file:" + url.lastPathComponent)
                added += 1
            }
            try? context.save()
            status = "Ze souboru přidáno \(added) z \(pairs.count)."
            if added > 0 { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func insert(_ pair: (prompt: String, answer: String), source: String) {
        let sample = TrainingSample(
            prompt: pair.prompt,
            localAnswer: "",
            teacherAnswer: pair.answer,
            // Hotový dataset se nehodnotí – známka je tu jen pro řazení v seznamu.
            score: 10,
            teacherModel: source,
            modelID: modelID
        )
        context.insert(sample)
    }
}
