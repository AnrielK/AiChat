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
    @State private var searchText = ""
    @State private var czechOnly = true
    @State private var results: [HFDatasetSummary] = []
    @State private var isSearching = false
    /// Aby se při psaní neposílal dotaz na každé písmeno.
    @State private var searchTask: Task<Void, Never>?
    @State private var splits: [HuggingFaceDataset.Split] = []
    @State private var selectedSplit: HuggingFaceDataset.Split?
    @State private var page: HuggingFaceDataset.Page?
    @State private var mapping = DatasetMapping()
    @State private var limit = 200
    @State private var onlyCzech = true
    @State private var order: ImportOrder = .sequential
    @State private var startOffset = 0
    @State private var labelColumns: [HuggingFaceDataset.LabelColumn] = []
    @State private var filterColumn = ""
    @State private var filterValue = ""
    /// Úsek splitu, ve kterém leží řádky vybrané filtrem. nil = celý split
    /// (bez filtru, nebo když řádky s hodnotou nejsou pohromadě).
    @State private var filterRange: Range<Int>?
    @State private var filterNote = ""
    @State private var isLocating = false
    @State private var splitTotal = 0

    @State private var isLoading = false
    @State private var isImporting = false
    @State private var progress = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var showFileImporter = false
    @State private var localFiles: [URL] = []

    /// Jak se berou řádky ze splitu. Kolekce poskládané z více zdrojů bývají
    /// seřazené podle zdroje, takže čtení od začátku dá jen ten první.
    enum ImportOrder: String, CaseIterable {
        case sequential
        case random

        var label: String {
            switch self {
            case .sequential: "Po sobě"
            case .random: "Náhodně"
            }
        }
    }

    /// Kolik řádků se v náhodném režimu bere z jednoho místa. Menší blok znamená
    /// pestřejší výběr, ale víc požadavků – 20 je rozumný střed.
    private static let randomBlock = 20

    /// Řádky, ze kterých se importuje.
    private var rowRange: Range<Int> {
        filterRange ?? 0 ..< splitTotal
    }

    /// Nejvýš tolik požadavků na jeden import. Filtr bez nalezeného úseku by
    /// jinak mohl číst celý split po stovkách řádků.
    private static let requestCap = 300

    private var activeFilter: HuggingFaceDataset.Filter? {
        guard !filterColumn.isEmpty, !filterValue.isEmpty,
              let column = labelColumns.first(where: { $0.name == filterColumn })
        else { return nil }
        return HuggingFaceDataset.Filter(column: column.name, value: filterValue, isBool: column.isBool)
    }

    /// Zadání, která už v datasetu jsou – ať se stejný řádek nenaimportuje dvakrát.
    private var existingPrompts: Set<String> {
        Set(existing.filter { $0.modelID == modelID }.map(\.prompt))
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if !splits.isEmpty { splitSection }
                if let page {
                    mappingSection(page)
                    selectionSection(page)
                }
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
                        .disabled(!mapping.isComplete || isImporting || isLoading || isLocating || page == nil)
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

    // MARK: - Hledání

    @ViewBuilder
    private func datasetRow(_ dataset: HFDatasetSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dataset.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text(dataset.author)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(dataset.downloads.compactFormatted, systemImage: "arrow.down.circle")
                Label(dataset.likes.compactFormatted, systemImage: "heart")
                // Licence je u trénovacích dat to první, co člověk potřebuje vědět –
                // spousta českých datasetů je CC-BY-NC, tedy jen nekomerčně.
                if let license = dataset.license {
                    Text(license)
                }
                if dataset.isGated {
                    Label("souhlas", systemImage: "lock")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// Hledání s malým zpožděním, ať se neposílá dotaz na každé písmeno.
    private func search(now: Bool) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            if !now {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            isSearching = true
            defer { isSearching = false }
            do {
                let found = try await HuggingFaceRepo.searchDatasets(
                    query, language: czechOnly ? "cs" : nil)
                if !Task.isCancelled { results = Array(found.prefix(25)) }
            } catch {
                if !Task.isCancelled {
                    results = []
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Zdroj

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            HStack {
                TextField("Hledat na Hugging Face", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { search(now: true) }
                    .onChange(of: searchText) { search(now: false) }
                if isSearching { ProgressView() }
            }
            Toggle("Jen české datasety", isOn: $czechOnly)
                .onChange(of: czechOnly) { search(now: true) }

            ForEach(results) { dataset in
                Button {
                    datasetID = dataset.id
                    loadSplits()
                } label: {
                    datasetRow(dataset)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Vyhledat")
        } footer: {
            if !searchText.isEmpty, results.isEmpty, !isSearching {
                Text("Nic se nenašlo. Hledá se v názvu repozitáře, ne v popisu – zkus kratší slovo.")
            }
        }

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
            .onChange(of: selectedSplit) { _, _ in splitChanged() }
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
            Text("\(filterRange == nil ? "Split má \(page.total)" : "Výběr s filtrem má \(rowRange.count)") řádků. Ukázka výše je první použitelná dvojice – když nesedí, přepni sloupce.")
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

    // MARK: - Výběr řádků

    @ViewBuilder
    private func selectionSection(_ page: HuggingFaceDataset.Page) -> some View {
        Section {
            Picker("Pořadí", selection: $order) {
                ForEach(ImportOrder.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if order == .sequential {
                LabeledContent("Začít od řádku") {
                    TextField("0", value: $startOffset, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            if !labelColumns.isEmpty {
                Picker("Filtr", selection: $filterColumn) {
                    Text("žádný").tag("")
                    ForEach(labelColumns) { Text($0.name).tag($0.name) }
                }
                .onChange(of: filterColumn) { _, _ in
                    filterValue = ""
                    applyFilter()
                }

                if let column = labelColumns.first(where: { $0.name == filterColumn }) {
                    Picker("Hodnota", selection: $filterValue) {
                        Text("vyber").tag("")
                        ForEach(column.values, id: \.value) { item in
                            Text("\(item.value) (\(item.count))").tag(item.value)
                        }
                    }
                    .onChange(of: filterValue) { _, _ in applyFilter() }
                }

                if isLocating {
                    HStack {
                        ProgressView()
                        Text("Hledám, kde řádky leží…").foregroundStyle(.secondary)
                    }
                } else if !filterNote.isEmpty {
                    Text(filterNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Výběr řádků")
        } footer: {
            Text(selectionFooter(total: page.total))
        }
    }

    private func selectionFooter(total: Int) -> String {
        var parts: [String] = []
        switch order {
        case .sequential:
            parts.append(filterRange == nil
                         ? "Čte se od zadaného řádku dál."
                         : "Čte se od zadaného řádku dál, počítáno od začátku úseku s filtrem.")
            if startOffset >= rowRange.count { parts.append("Zadaný řádek je za koncem (\(rowRange.count) řádků).") }
        case .random:
            parts.append("Bere se po \(Self.randomBlock) řádcích z náhodných míst celého \(activeFilter == nil ? "splitu" : "výběru"), takže import trvá déle než po sobě.")
        }
        if labelColumns.isEmpty {
            parts.append("Filtr podle sloupce tu není – prohlížeč datasetů pro tenhle split nemá statistiky.")
        } else {
            parts.append("Filtr nabízí sloupce s malým počtem hodnot, třeba zdroj dat, a čísla v závorce jsou počty řádků. Když řádky s hodnotou leží pohromadě, najde se jejich úsek a čte se jen z něj.")
        }
        return parts.joined(separator: " ")
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
                splitChanged()
            } catch {
                errorMessage = error.localizedDescription
                splits = []
            }
            isLoading = false
        }
    }

    /// Nový split: filtr z předchozího už nemusí platit, statistiky se načtou znovu.
    private func splitChanged() {
        filterColumn = ""
        filterValue = ""
        filterRange = nil
        filterNote = ""
        labelColumns = []
        startOffset = 0
        loadPreview()
        guard let split = selectedSplit else { return }
        let dataset = datasetID
        Task {
            // Bez statistik se dá importovat dál, jen bez filtru – chyba se nehlásí.
            let columns = (try? await HuggingFaceDataset.labelColumns(dataset: dataset, split: split)) ?? []
            if selectedSplit == split { labelColumns = columns }
        }
    }

    private func loadPreview() {
        guard let split = selectedSplit else { return }
        isLoading = true
        let offset = filterRange?.lowerBound ?? 0
        Task {
            do {
                let preview = try await HuggingFaceDataset.page(
                    dataset: datasetID, split: split, offset: offset,
                    length: HuggingFaceDataset.pageLimit
                )
                // Mezitím se filtr mohl změnit – starší odpověď by přepsala novější.
                guard offset == (filterRange?.lowerBound ?? 0) else { return }
                // Ruční mapování přežije změnu filtru, pokud sloupce zůstaly stejné.
                let keepMapping = page?.columns == preview.columns && mapping.isComplete
                page = preview
                splitTotal = preview.total
                if !keepMapping { mapping = DatasetMapping.autodetect(page: preview) }
            } catch {
                errorMessage = error.localizedDescription
                page = nil
            }
            isLoading = false
        }
    }

    /// Najde úsek s vybranou hodnotou. Filtr se vyhodnocuje v aplikaci – endpoint
    /// `/filter` prohlížeče datasetů u větších datasetů padá nebo nestíhá.
    private func applyFilter() {
        filterRange = nil
        filterNote = ""
        startOffset = 0
        guard let filter = activeFilter, let split = selectedSplit else {
            isLocating = false
            loadPreview()
            return
        }
        let expected = labelColumns.first(where: { $0.name == filter.column })?
            .values.first(where: { $0.value == filter.value })?.count ?? 0
        let dataset = datasetID
        let total = splitTotal
        isLocating = true
        Task {
            do {
                let range = try await HuggingFaceDataset.locate(
                    dataset: dataset, split: split, filter: filter,
                    expected: expected, total: total
                )
                guard filter == activeFilter else { return }
                filterRange = range
                if let range {
                    filterNote = "Řádky \(range.lowerBound + 1)–\(range.upperBound) (\(range.count))."
                } else {
                    filterNote = "Řádky s touhle hodnotou nejsou pohromadě, filtr se uplatní až při čtení. Import projde split po stovkách řádků (nejvýš \(Self.requestCap) požadavků) a u vzácné hodnoty najde málo vzorků."
                }
                loadPreview()
            } catch {
                guard filter == activeFilter else { return }
                errorMessage = error.localizedDescription
                filterNote = "Úsek se nepodařilo najít, filtr se uplatní až při čtení."
            }
            isLocating = false
        }
    }

    // MARK: - Import

    private func startImport() {
        guard let split = selectedSplit, page != nil else { return }
        isImporting = true
        progress = 0
        let dataset = datasetID
        let filter = activeFilter
        let range = rowRange
        let selectedOrder = order
        let firstRow = range.lowerBound + max(0, startOffset)

        Task {
            var seen = existingPrompts
            var added = 0
            var skipped = 0
            var requests = 0

            func consider(_ row: [String: HuggingFaceDataset.Cell]) {
                // Na okrajích úseku, nebo když úsek není, projdou i řádky mimo filtr.
                if let filter, !filter.matches(row) { return }
                guard let pair = mapping.pair(from: row) else { skipped += 1; return }
                guard !seen.contains(pair.prompt) else { skipped += 1; return }
                guard !onlyCzech || DatasetFilter.looksCzech(pair.answer) else { skipped += 1; return }
                seen.insert(pair.prompt)
                insert(pair, source: "hf:" + dataset)
                added += 1
                progress = added
            }

            do {
                switch selectedOrder {
                case .sequential:
                    var offset = firstRow
                    while added < limit, offset < range.upperBound, requests < Self.requestCap {
                        let chunk = try await HuggingFaceDataset.page(
                            dataset: dataset, split: split, offset: offset,
                            length: min(HuggingFaceDataset.pageLimit, range.upperBound - offset)
                        )
                        requests += 1
                        if chunk.rows.isEmpty { break }
                        offset += chunk.rows.count
                        for row in chunk.rows where added < limit { consider(row) }
                    }

                case .random:
                    // Náhodné bloky místo náhodných řádků: jeden požadavek na blok
                    // a pořád dost míst napříč splitem, aby se promíchaly zdroje.
                    var starts = Array(stride(from: range.lowerBound, to: range.upperBound, by: Self.randomBlock)).shuffled()
                    while added < limit, requests < Self.requestCap, let start = starts.popLast() {
                        let chunk = try await HuggingFaceDataset.page(
                            dataset: dataset, split: split, offset: start,
                            length: min(Self.randomBlock, range.upperBound - start)
                        )
                        requests += 1
                        for row in chunk.rows.shuffled() where added < limit { consider(row) }
                    }
                }
                try? context.save()
                status = "Přidáno \(added), přeskočeno \(skipped)."
                if requests >= Self.requestCap, added < limit {
                    status += " Zastaveno po \(Self.requestCap) požadavcích."
                }
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
