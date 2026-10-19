#if canImport(UIKit) && canImport(SwiftUI)   // iOS / iPadOS
import SwiftUI
import FinFillCore

/// Screen for AIChat: ticker + Google Sheet → preview (dry run) → write cells → on-device summary.
@available(iOS 17.0, *)
public struct FinFillView: View {
    @State private var model: FinFillViewModel
    @State private var showPicker = false
    /// Hledání, se kterým se výběr sešitu otevře (ticker, když vybraný sešit nesedí).
    @State private var pickerSearch = ""
    @FocusState private var focused: Field?

    enum Field { case ticker, sheet, userAgent, year, peers }

    public init(tokens: AccessTokenProvider, engine: LLMEngine?, mapping: TemplateMapping? = nil) {
        _model = State(initialValue: FinFillViewModel(tokens: tokens, engine: engine, mapping: mapping))
    }

    public var body: some View {
        Form {
            sourceSection
            optionsSection
            analysesSection
            actionSection
            if let w = model.newWorkbook { newWorkbookSection(w) }
            if let a = model.analysis { analysisSections(a) }
            if let r = model.report { reportSections(r) }
            quarterSection
            summarySection
            logSection
        }
        .navigationTitle("10-K → Sheets")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Hotovo") { focused = nil }
            }
        }
        .sheet(isPresented: $showPicker) {
            SpreadsheetPickerView(tokens: model.tokens, initialSearch: pickerSearch) { file in
                model.selectSpreadsheet(id: file.id, name: file.name)
            }
        }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        Section("Zdroj") {
            TextField("Ticker", text: $model.ticker)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused, equals: .ticker)

            Button {
                focused = nil
                pickerSearch = ""
                showPicker = true
            } label: {
                LabeledContent {
                    Text(model.spreadsheetName ?? (model.spreadsheet.isEmpty ? "Vybrat…" : "Zadáno ručně"))
                        .lineLimit(1)
                        .foregroundStyle(model.spreadsheet.isEmpty ? Color.accentColor : Color.secondary)
                } label: {
                    Label("Sešit", systemImage: "tablecells")
                }
            }
            .tint(.primary)

            if model.sheetMismatch {
                Button {
                    focused = nil
                    pickerSearch = model.trimmedTicker
                    showPicker = true
                } label: {
                    Label("Název sešitu neobsahuje \(model.trimmedTicker) – vybrat sešit pro \(model.trimmedTicker)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            DisclosureGroup("Zadat URL nebo ID ručně") {
                TextField("https://docs.google.com/spreadsheets/d/…", text: $model.spreadsheet)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                    .focused($focused, equals: .sheet)
            }

            TextField("SEC User-Agent (jméno + e-mail)", text: $model.userAgent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .focused($focused, equals: .userAgent)
            TextField("Fiskální rok (prázdné = poslední 10-K)", text: $model.fiscalYearText)
                .keyboardType(.numberPad)
                .focused($focused, equals: .year)
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Přepsat neprázdné buňky", isOn: $model.overwrite)
            Toggle("Nový sešit: nejnovější rok vlevo", isOn: $model.newestFirst)
            Toggle("List Segments (segmenty, trhy, regiony + meziroční změna)", isOn: $model.segments)
            Toggle("Souhrn modelem", isOn: $model.summarize)
                .disabled(!model.hasEngine)
            Picker("Jazyk souhrnu", selection: $model.language) {
                Text("English").tag("English")
                Text("Čeština").tag("Czech")
            }
            .disabled(!model.summarize)
        } header: {
            Text("Možnosti")
        } footer: {
            Text("Souhrn se zapíše na list „Souhrn“, který je vždy první v sešitu – nový souhrn ho přepíše. Pořadí let v existujícím sešitu se pozná z hlavičky; nový rok se doplní na správnou stranu.")
        }
    }

    private var analysesSection: some View {
        Section {
            Toggle("Citlivost WACC × TGR + kontrola DCF", isOn: $model.sensitivity)
            Toggle("Kvartály z 10-Q + earnings review", isOn: $model.quarterly)
            TextField("Peery pro Comps, např. AMD, AVGO, INTC", text: $model.peersText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused, equals: .peers)
        } header: {
            Text("Analýzy")
        } footer: {
            Text("Při zápisu (i v novém sešitu) vzniknou listy Citlivost, Comps a Kvartály. Comps: LTM ze SEC, cena živě přes GOOGLEFINANCE, multiply a implikovaná cena z mediánu peerů. Kvartály: posledních 8 kvartálů, YoY a QoQ; konsenzus analytiků v SEC není. Text earnings review píše model z Nastavení, když je zapnutý „Souhrn modelem“.")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                focused = nil
                Task { await model.preview() }
            } label: {
                Label("Náhled (nic nezapíše)", systemImage: "eye")
            }
            .disabled(model.isRunning || model.ticker.isEmpty || model.spreadsheet.isEmpty)

            Button {
                focused = nil
                Task { await model.write() }
            } label: {
                Label("Zapsat do Google Sheets", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isRunning || model.report == nil || !(model.report?.allChecksPassed ?? false))

            Button {
                focused = nil
                Task { await model.createWorkbook() }
            } label: {
                Label("Nový sešit ze šablony (9 let)", systemImage: "doc.badge.plus")
            }
            .disabled(model.isRunning || model.ticker.isEmpty)

            Button {
                focused = nil
                Task { await model.analyze() }
            } label: {
                Label("Jen analýzy do sešitu", systemImage: "chart.line.uptrend.xyaxis")
            }
            .disabled(model.isRunning || model.ticker.isEmpty || model.spreadsheet.isEmpty || !model.hasAnalyses)
        } footer: {
            if model.isRunning { ProgressView(model.status) }
            else if let e = model.errorText { Text(e).foregroundStyle(.red) }
            else if let r = model.report, !r.allChecksPassed {
                Text("Kontroly součtů neprošly – zápis je zablokovaný.").foregroundStyle(.red)
            } else if let r = model.report, r.written > 0 {
                Text("Zapsáno \(r.written) buněk.").foregroundStyle(.green)
            } else if model.report == nil && model.newWorkbook == nil {
                Text("Nový sešit: výkazy, DCF a WACC s prázdnými daty, vyplní se 9 let končících posledním 10-K (nebo zadaným rokem). Uloží se do kořene tvého Disku Google.")
            }
        }
    }

    @ViewBuilder
    private func reportSections(_ r: FinFillPipeline.Report) -> some View {
        if !r.newColumns.isEmpty {
            Section {
                ForEach(r.newColumns) { c in
                    Label("\(c.sheet): nový sloupec \(c.column) (\(String(c.year))) z \(c.sourceColumn)", systemImage: "plus.rectangle.on.rectangle")
                        .font(.subheadline)
                }
            } header: {
                Text("Nové sloupce")
            } footer: {
                Text("Při zápisu se vloží sloupec za předchozí rok a zkopíruje se do něj předchozí sloupec i se vzorci a formátem. Ručně zadaná čísla minulého roku se vymažou a vyplní se nová.")
            }
        }

        if !r.segmentGroups.isEmpty {
            Section {
                ForEach(r.segmentGroups) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title).font(.subheadline.bold())
                        Text(g.lines.map { ($0.parent == nil ? "" : "↳ ") + $0.name }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Segmenty tržeb")
            } footer: {
                Text(r.written > 0 ? "Zapsáno na list Segments i s meziroční změnou a podílem na tržbách." :
                        "Při zápisu se list Segments vytvoří znovu pro všechny roky v sešitu (starší roky ze starších 10-K).")
            }
        }

        Section("Kontroly FY\(String(r.filing.period.fiscalYear)) · \(r.filing.company)") {
            ForEach(r.checks) { c in
                HStack(alignment: .firstTextBaseline) {
                    checkIcon(c.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label)
                        switch c.status {
                        case let .plugged(row, amount):
                            Text("dorovnáno \(NumberFormat.plain(amount)) do ř. \(row)")
                                .font(.caption).foregroundStyle(.orange)
                        case .notReported:
                            Text("firma součet netaguje").font(.caption).foregroundStyle(.secondary)
                        case .incomplete:
                            Text("za tento rok chybí část dat").font(.caption).foregroundStyle(.secondary)
                        case .failed:
                            Text("vykázáno \(c.reported.map(NumberFormat.plain) ?? "–")").font(.caption).foregroundStyle(.red)
                        case .passed:
                            EmptyView()
                        }
                    }
                    Spacer()
                    Text(NumberFormat.plain(c.reported ?? c.computed)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }

        Section("Buňky (\(r.plan.filter { $0.action == .write }.count) k zápisu)") {
            ForEach(r.plan) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(p.sheet)!\(p.column)\(p.row)").font(.caption.monospaced())
                        Spacer()
                        Text(p.action == .write ? "zapsat" : p.action == .skipNotEmpty ? "přeskočit" : "chybí data")
                            .font(.caption2)
                            .foregroundStyle(p.action == .write ? Color.green : Color.orange)
                    }
                    Text(p.label).font(.subheadline)
                    Text(p.content?.display ?? "—").font(.callout.monospaced())
                    if p.adjustment != 0 {
                        Text("vč. dorovnání \(NumberFormat.plain(p.adjustment)) (\(p.adjustedBy.joined(separator: ", ")))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let old = p.existing, !old.isEmpty { Text("teď: \(old)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }

        if !r.backtest.isEmpty {
            Section {
                ForEach(r.backtest) { d in
                    HStack {
                        Text("\(d.sheet.prefix(6))!\(d.row) \(d.label)").font(.caption)
                        Spacer()
                        Text("\(NumberFormat.plain(d.computed)) vs \(d.existing.map(NumberFormat.plain) ?? "prázdné")")
                            .font(.caption.monospaced())
                    }
                }
            } header: {
                Text("Backtest předchozího roku")
            } footer: {
                Text("Řádky, kde se mapování liší od toho, co je v tabulce za minulý rok (obvykle jen jiné rozdělení položek).")
            }
        }
    }

    @ViewBuilder
    private func newWorkbookSection(_ w: FinFillPipeline.NewWorkbookReport) -> some View {
        Section {
            Link(destination: w.url) {
                Label("Otevřít v Google Sheets", systemImage: "arrow.up.right.square")
            }
            ForEach(w.years) { y in
                HStack {
                    Text("FY\(String(y.fiscalYear))").monospacedDigit()
                    Text(y.column).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if y.failed > 0 {
                        Text("vynecháno – \(y.failed) kontrol nesedí").font(.caption).foregroundStyle(.red)
                    } else {
                        Text("\(y.cells) buněk").font(.caption).foregroundStyle(.secondary)
                        if y.plugged > 0 { Text("± \(y.plugged)").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        } header: {
            Text("Nový sešit · \(w.title)")
        } footer: {
            if !w.segmentGroups.isEmpty {
                Text("List Segments: " + w.segmentGroups.map { "\($0.title) (\($0.lines.count))" }.joined(separator: ", ") + ". ")
            }
            Text("Sešit je vybraný pro další práci. Roky, které SEC v datech nemá, zůstanou prázdné; ± je dorovnání do řádku „ostatní“.")
        }
    }

    @ViewBuilder
    private func analysisSections(_ a: AnalysisReport) -> some View {
        if let dcf = a.dcf {
            Section {
                ForEach(dcf.findings) { f in
                    HStack(alignment: .firstTextBaseline) {
                        severityIcon(f.severity)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title)
                            Text(f.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Kontrola DCF")
            } footer: {
                Text(a.sensitivityWritten ? "List Citlivost: cena pro WACC × TGR, potenciál a stejné kontroly jako živé vzorce." : "")
            }
        }

        if let t = a.target, !a.peers.isEmpty || !a.peerErrors.isEmpty {
            Section {
                if !a.peers.isEmpty {
                    Text(LocalizedStringKey(CompsSheet.summary(target: t, peers: a.peers))).font(.callout)
                }
                ForEach(a.peers) { p in
                    HStack {
                        Text(p.ticker).font(.subheadline.monospaced())
                        Text(p.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(p.ltmEnd.map { "LTM \($0)" } ?? "—").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(a.peerErrors, id: \.self) { e in
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Comps · \(t.ticker) vs. \(a.peers.count) peerů")
            } footer: {
                Text(a.compsWritten ? "Multiply, kvartily a implikovaná cena jsou na listu Comps (cena živě z GOOGLEFINANCE)." : "List Comps se nezapsal.")
            }
        }

        if !a.notes.isEmpty {
            Section("Poznámky k analýzám") {
                ForEach(a.notes, id: \.self) { n in Text(n).font(.caption) }
            }
        }
    }

    @ViewBuilder
    private func severityIcon(_ s: DCFReview.Severity) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info: Image(systemName: "info.circle").foregroundStyle(.blue)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var quarterSection: some View {
        if let q = model.quarterMarkdown {
            Section("Kvartál") {
                Text(LocalizedStringKey(q)).textSelection(.enabled).font(.callout)
                ShareLink(item: q)
            }
        }
    }

    @ViewBuilder
    private func checkIcon(_ status: CheckResult.Status) -> some View {
        switch status {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .plugged: Image(systemName: "plusminus.circle.fill").foregroundStyle(.orange)
        case .notReported: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .incomplete: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let s = model.summaryMarkdown {
            Section("Souhrn") {
                Text(LocalizedStringKey(s)).textSelection(.enabled).font(.callout)
                ShareLink(item: s)
            }
        }
    }

    @ViewBuilder
    private var logSection: some View {
        if !model.log.isEmpty {
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced())
                }
            }
        }
    }
}

// MARK: - Spreadsheet picker

@available(iOS 17.0, *)
struct SpreadsheetPickerView: View {
    let tokens: AccessTokenProvider
    let onPick: (GoogleDriveClient.File) -> Void

    init(tokens: AccessTokenProvider, initialSearch: String = "", onPick: @escaping (GoogleDriveClient.File) -> Void) {
        self.tokens = tokens
        self.onPick = onPick
        _search = State(initialValue: initialSearch)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var files: [GoogleDriveClient.File] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                ForEach(files) { f in
                    Button {
                        onPick(f)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                if let d = f.modified { Text(d, format: .relative(presentation: .named)) }
                                if let o = f.owner { Text("· \(o)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if loading && files.isEmpty { ProgressView() }
                else if !loading && files.isEmpty && error == nil {
                    ContentUnavailableView("Žádné sešity", systemImage: "tablecells",
                                           description: Text("Zobrazují se jen Google Sheets. Soubor .xlsx na Disku nejdřív ulož jako Google Sheets."))
                }
            }
            .searchable(text: $search, prompt: "Hledat podle názvu")
            .navigationTitle("Google Sheets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušit") { dismiss() } }
            }
            .refreshable { await load() }
            .task(id: search) {
                // Debounce typing.
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await GoogleDriveClient(tokens: tokens).spreadsheets(search: search)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - View model

@available(iOS 17.0, *)
@MainActor @Observable
final class FinFillViewModel {
    var ticker = UserDefaults.standard.string(forKey: "finfill.ticker") ?? "NVDA" {
        didSet {
            invalidate()
            if ticker != oldValue { peersText = Self.savedPeers(for: ticker) }
        }
    }
    var spreadsheet = UserDefaults.standard.string(forKey: "finfill.sheet") ?? "" {
        didSet {
            if spreadsheet != oldValue { spreadsheetName = nil }
            invalidate()
        }
    }
    var spreadsheetName: String? = UserDefaults.standard.string(forKey: "finfill.sheetName")
    var userAgent = UserDefaults.standard.string(forKey: "finfill.ua") ?? ""
    var fiscalYearText = "" { didSet { invalidate() } }
    var overwrite = false { didSet { invalidate() } }
    var summarize = true
    var language = "Czech"

    var newWorkbook: FinFillPipeline.NewWorkbookReport?
    var segments = UserDefaults.standard.object(forKey: "finfill.segments") as? Bool ?? true {
        didSet { UserDefaults.standard.set(segments, forKey: "finfill.segments") }
    }
    /// Nový sešit: výkazy a Segments od aktuálního roku (vlevo) ke starším (doprava).
    var newestFirst = UserDefaults.standard.object(forKey: "finfill.newestFirst") as? Bool ?? true {
        didSet { UserDefaults.standard.set(newestFirst, forKey: "finfill.newestFirst") }
    }

    /// List Citlivost + kontrola DCF.
    var sensitivity = UserDefaults.standard.object(forKey: "finfill.sensitivity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "finfill.sensitivity") }
    }
    /// List Kvartály + earnings review posledního 10-Q.
    var quarterly = UserDefaults.standard.object(forKey: "finfill.quarterly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quarterly, forKey: "finfill.quarterly") }
    }
    /// Peery pro Comps – pamatují se pro každý ticker zvlášť.
    var peersText = FinFillViewModel.savedPeers(for: UserDefaults.standard.string(forKey: "finfill.ticker") ?? "NVDA") {
        didSet { UserDefaults.standard.set(peersText, forKey: Self.peersKey(ticker)) }
    }
    var analysis: AnalysisReport?
    var quarterMarkdown: String?

    var trimmedTicker: String { ticker.trimmingCharacters(in: .whitespaces).uppercased() }

    /// Vybraný sešit nemá ticker v názvu (např. NVDA, ale vybraný „AMD Valuation FY2025“).
    var sheetMismatch: Bool {
        guard let name = spreadsheetName, !spreadsheet.isEmpty, !trimmedTicker.isEmpty else { return false }
        return !SpreadsheetMatch.name(name, contains: trimmedTicker)
    }

    var hasAnalyses: Bool {
        sensitivity || quarterly || !FinFillPipeline.normalizedPeers([peersText], excluding: ticker).isEmpty
    }

    static func peersKey(_ ticker: String) -> String {
        "finfill.peers." + ticker.trimmingCharacters(in: .whitespaces).uppercased()
    }

    static func savedPeers(for ticker: String) -> String {
        UserDefaults.standard.string(forKey: peersKey(ticker)) ?? ""
    }

    var isRunning = false
    var status = ""
    var errorText: String?
    var report: FinFillPipeline.Report?
    var summaryMarkdown: String?
    var log: [String] = []

    let tokens: AccessTokenProvider
    let engine: LLMEngine?
    let mapping: TemplateMapping?
    var hasEngine: Bool { engine != nil }

    init(tokens: AccessTokenProvider, engine: LLMEngine?, mapping: TemplateMapping?) {
        self.tokens = tokens
        self.engine = engine
        self.mapping = mapping
        if engine == nil { summarize = false }
    }

    /// A preview belongs to one ticker / year / sheet — change any of them and it has to be redone.
    private func invalidate() {
        guard !isRunning else { return }
        report = nil
        summaryMarkdown = nil
        newWorkbook = nil
        analysis = nil
        quarterMarkdown = nil
    }

    func selectSpreadsheet(id: String, name: String) {
        spreadsheet = id
        spreadsheetName = name
        UserDefaults.standard.set(id, forKey: "finfill.sheet")
        UserDefaults.standard.set(name, forKey: "finfill.sheetName")
    }

    func config(dryRun: Bool) throws -> FinFillPipeline.Config {
        UserDefaults.standard.set(ticker, forKey: "finfill.ticker")
        UserDefaults.standard.set(spreadsheet, forKey: "finfill.sheet")
        UserDefaults.standard.set(spreadsheetName, forKey: "finfill.sheetName")
        UserDefaults.standard.set(userAgent, forKey: "finfill.ua")
        var c = FinFillPipeline.Config(ticker: ticker.trimmingCharacters(in: .whitespaces).uppercased(),
                                       secUserAgent: userAgent.isEmpty ? "AIChat FinFill contact@example.com" : userAgent,
                                       spreadsheet: spreadsheet,
                                       mapping: try mapping ?? TemplateMapping.bundledUniversal())
        c.fiscalYear = Int(fiscalYearText.trimmingCharacters(in: .whitespaces))
        c.overwrite = overwrite
        c.dryRun = dryRun
        c.summaryOptions.language = language
        c.segments = segments
        c.newestFirst = newestFirst
        c.sensitivity = sensitivity
        c.quarterly = quarterly
        c.peers = [peersText]
        return c
    }

    func handle(_ e: FinFillPipeline.Event) {
        switch e {
        case let .log(s):
            log.append(s); status = s
        case let .summary(p):
            switch p {
            case let .section(item, chunk, of): status = "Souhrn: Item \(item), část \(chunk)/\(of)"
            case let .reducing(item): status = "Souhrn: slučuji Item \(item)"
            case .final: status = "Souhrn: finální text"
            }
        }
    }

    /// Dry run: downloads the 10-K, maps it, validates and plans — writes nothing, no summary.
    func preview() async {
        report = nil
        summaryMarkdown = nil
        analysis = nil
        quarterMarkdown = nil
        await run {
            let cfg = try self.config(dryRun: true)
            let pipeline = FinFillPipeline(config: cfg, tokens: self.tokens, engine: nil)
            self.report = try await pipeline.run { e in Task { @MainActor in self.handle(e) } }
        }
    }

    /// New workbook from the universal template, all years filled; becomes the selected spreadsheet.
    func createWorkbook() async {
        report = nil
        summaryMarkdown = nil
        newWorkbook = nil
        await run {
            var cfg = try self.config(dryRun: false)
            cfg.mapping = try TemplateMapping.bundledUniversal()
            let pipeline = FinFillPipeline(config: cfg, tokens: self.tokens, engine: self.summarize ? self.engine : nil)
            let w = try await pipeline.createWorkbook(template: try SpreadsheetTemplate.bundledUniversal()) { e in
                Task { @MainActor in self.handle(e) }
            }
            self.selectSpreadsheet(id: w.spreadsheetID, name: w.title)
            self.newWorkbook = w
            self.summaryMarkdown = w.summary?.markdown(company: w.filing.company)
            self.show(w.analysis)
        }
    }

    /// Writes the planned cells (re-using the downloaded filing), then the summary.
    func write() async {
        guard let previous = report else { return }
        await run {
            let cfg = try self.config(dryRun: false)
            let pipeline = FinFillPipeline(config: cfg, tokens: self.tokens, engine: self.summarize ? self.engine : nil)
            let r = try await pipeline.run(filing: previous.filing) { e in Task { @MainActor in self.handle(e) } }
            self.report = r
            self.summaryMarkdown = r.summary?.markdown(company: r.filing.company)
            self.show(r.analysis)
        }
    }

    /// Jen Citlivost, Comps a Kvartály do vybraného sešitu – výkazy se nezapisují.
    func analyze() async {
        let filing = report?.filing
        analysis = nil
        quarterMarkdown = nil
        await run {
            let cfg = try self.config(dryRun: false)
            let pipeline = FinFillPipeline(config: cfg, tokens: self.tokens, engine: self.summarize ? self.engine : nil)
            let (_, a) = try await pipeline.analyzeOnly(filing: filing) { e in Task { @MainActor in self.handle(e) } }
            self.show(a)
        }
    }

    private func show(_ a: AnalysisReport?) {
        guard let a, !a.isEmpty else { analysis = nil; quarterMarkdown = nil; return }
        analysis = a
        quarterMarkdown = a.quarter?.markdown()
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isRunning = true; errorText = nil; log = []
        defer { isRunning = false; status = "" }
        do { try await work() } catch { errorText = error.localizedDescription }
    }
}
#endif
