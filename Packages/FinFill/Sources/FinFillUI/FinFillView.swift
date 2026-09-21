#if canImport(UIKit) && canImport(SwiftUI)   // iOS / iPadOS
import SwiftUI
import FinFillCore

/// Screen for AIChat: ticker + Google Sheet → preview (dry run) → write cells → on-device summary.
///
///     FinFillView(tokens: GoogleSignInTokenProvider(), engine: AIChatEngineAdapter(...))
@available(iOS 17.0, macOS 14.0, *)
public struct FinFillView: View {
    @State private var model: FinFillViewModel

    public init(tokens: AccessTokenProvider, engine: LLMEngine?, mapping: TemplateMapping? = nil) {
        _model = State(initialValue: FinFillViewModel(tokens: tokens, engine: engine, mapping: mapping))
    }

    public var body: some View {
        Form {
            Section("Zdroj") {
                TextField("Ticker", text: $model.ticker)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("Google Sheet (URL nebo ID)", text: $model.spreadsheet)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SEC User-Agent (jméno + e-mail)", text: $model.userAgent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Fiskální rok (prázdné = poslední 10-K)", text: $model.fiscalYearText)
                    .keyboardType(.numberPad)
            }

            Section("Možnosti") {
                Toggle("Přepsat neprázdné buňky", isOn: $model.overwrite)
                Toggle("Souhrn lokálním modelem", isOn: $model.summarize)
                    .disabled(!model.hasEngine)
                Picker("Jazyk souhrnu", selection: $model.language) {
                    Text("English").tag("English")
                    Text("Čeština").tag("Czech")
                }
                .disabled(!model.summarize)
            }

            Section {
                Button {
                    Task { await model.preview() }
                } label: {
                    Label("Náhled (nic nezapíše)", systemImage: "eye")
                }
                .disabled(model.isRunning || model.ticker.isEmpty || model.spreadsheet.isEmpty)

                Button {
                    Task { await model.write() }
                } label: {
                    Label("Zapsat do Google Sheets", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isRunning || model.report == nil || !(model.report?.allChecksPassed ?? false))
            } footer: {
                if model.isRunning { ProgressView(model.status) }
                else if let e = model.errorText { Text(e).foregroundStyle(.red) }
                else if let r = model.report, !r.allChecksPassed {
                    Text("Kontroly součtů neprošly – zápis je zablokovaný.").foregroundStyle(.red)
                }
            }

            if let r = model.report {
                Section("Kontroly FY\(r.filing.period.fiscalYear) (\(r.filing.company))") {
                    ForEach(r.checks) { c in
                        HStack {
                            Image(systemName: c.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(c.passed ? .green : .red)
                            Text(c.label)
                            Spacer()
                            Text(NumberFormat.plain(c.computed)).monospacedDigit().foregroundStyle(.secondary)
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
                                    .foregroundStyle(p.action == .write ? .green : .orange)
                            }
                            Text(p.label).font(.subheadline)
                            Text(p.content?.display ?? "—").font(.callout.monospaced())
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

            if let s = model.summaryMarkdown {
                Section("Souhrn") {
                    Text(LocalizedStringKey(s)).textSelection(.enabled).font(.callout)
                    ShareLink(item: s)
                }
            }

            if !model.log.isEmpty {
                Section("Log") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
            }
        }
        .navigationTitle("10-K → Sheets")
    }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor @Observable
final class FinFillViewModel {
    var ticker = UserDefaults.standard.string(forKey: "finfill.ticker") ?? "NVDA"
    var spreadsheet = UserDefaults.standard.string(forKey: "finfill.sheet") ?? ""
    var userAgent = UserDefaults.standard.string(forKey: "finfill.ua") ?? ""
    var fiscalYearText = ""
    var overwrite = false
    var summarize = true
    var language = "Czech"

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
    }

    func config(dryRun: Bool) throws -> FinFillPipeline.Config {
        UserDefaults.standard.set(ticker, forKey: "finfill.ticker")
        UserDefaults.standard.set(spreadsheet, forKey: "finfill.sheet")
        UserDefaults.standard.set(userAgent, forKey: "finfill.ua")
        var c = FinFillPipeline.Config(ticker: ticker.trimmingCharacters(in: .whitespaces).uppercased(),
                                       secUserAgent: userAgent.isEmpty ? "AIChat FinFill contact@example.com" : userAgent,
                                       spreadsheet: spreadsheet,
                                       mapping: try mapping ?? TemplateMapping.bundledNVDA())
        c.fiscalYear = Int(fiscalYearText)
        c.overwrite = overwrite
        c.dryRun = dryRun
        c.summaryOptions.language = language
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
        await run {
            let cfg = try self.config(dryRun: true)
            let pipeline = FinFillPipeline(config: cfg, tokens: self.tokens, engine: nil)
            self.report = try await pipeline.run { e in Task { @MainActor in self.handle(e) } }
            self.summaryMarkdown = nil
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
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isRunning = true; errorText = nil; log = []
        defer { isRunning = false; status = "" }
        do { try await work() } catch { errorText = error.localizedDescription }
    }
}
#endif
