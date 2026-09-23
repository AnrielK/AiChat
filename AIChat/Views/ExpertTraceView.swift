import SwiftUI

/// Záznamy výběru expertů (`ExpertTrace`) – seznam, smazání, sdílení a simulace cache.
struct ExpertTraceListView: View {
    @State private var files: [TraceFile] = []

    struct TraceFile: Identifiable, Hashable {
        let url: URL
        let size: Int
        let modified: Date
        var id: URL { url }
    }

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView(
                    "Žádné záznamy",
                    systemImage: "waveform.path.ecg",
                    description: Text("Zapni v Parametrech › Výkon „Zaznamenávat experty“ a pošli modelu pár zpráv. Záznam vzniká jen u MoE modelu s experty z úložiště.")
                )
            }
            ForEach(files) { file in
                NavigationLink {
                    ExpertTraceDetailView(url: file.url)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.url.deletingPathExtension().lastPathComponent)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { try? FileManager.default.removeItem(at: files[index].url) }
                files.remove(atOffsets: offsets)
            }
        }
        .navigationTitle("Záznamy expertů")
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: ExpertTrace.directory,
            includingPropertiesForKeys: keys
        )) ?? []
        files = urls
            .filter { $0.pathExtension == ExpertTrace.fileExtension }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return TraceFile(url: url, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }
}

/// Výsledek přehrání jednoho záznamu.
struct ExpertTraceDetailView: View {
    let url: URL
    @State private var report: ExpertCacheSimulator.Report?
    @State private var failure: String?

    var body: some View {
        Form {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let report {
                if report.requests == 0 {
                    Text("Záznam zatím neobsahuje žádný výběr expertů.")
                        .foregroundStyle(.secondary)
                } else {
                    summarySection(report)
                    tableSection(report)
                    if !report.predictions.isEmpty {
                        predictionSection(report)
                    }
                    if let prefill = report.prefill {
                        prefillSection(prefill)
                    }
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Přehrávám záznam…")
                }
            }
        }
        .navigationTitle("Simulace cache")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = url
        let task = Task.detached(priority: .userInitiated) { () throws -> ExpertCacheSimulator.Report in
            let trace = try ExpertTrace(contentsOf: url)
            return ExpertCacheSimulator.run(trace)
        }
        do {
            report = try await task.value
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Sekce

    private func summarySection(_ report: ExpertCacheSimulator.Report) -> some View {
        Section {
            LabeledContent("Model", value: report.modelName)
            LabeledContent("Požadavky na experty") {
                Text(report.decodeRequests > 0
                     ? "\(report.requests) (\(report.decodeRequests) při generování)"
                     : "\(report.requests)")
            }
            if report.decodeTokens > 0 {
                LabeledContent("Vygenerováno tokenů", value: "\(report.decodeTokens)")
            }
            LabeledContent("Použití experti") {
                Text("\(report.distinctExperts) z \(report.totalExperts) · \(Self.bytes(report.distinctBytes))")
            }
            if let measured = report.measuredHitRate {
                LabeledContent("Naměřený zásah page cache", value: Self.percent(measured))
            }
            if let share = report.topTenthShare {
                LabeledContent("Nejčastějších 10 % expertů", value: "\(Self.percent(share)) požadavků")
            }
            LabeledContent("Strop (povinné výpadky)", value: Self.percent(report.ceilingHitRate))
        } header: {
            Text("Záznam")
        } footer: {
            Text("Naměřený zásah je skutečnost z iPhonu: kolik vybraných expertů leželo celých v paměti ještě před předčtením (mincore). Strop je nejvíc, co dá jakákoli cache – každého experta je potřeba aspoň jednou přečíst. Podíl nejčastějších 10 % ukazuje, jestli má smysl držet v RAM malou „horkou“ skupinu: u rovnoměrného využití (kolem 10 %) ne.")
        }
    }

    private func tableSection(_ report: ExpertCacheSimulator.Report) -> some View {
        let perToken = report.rows.first?.missBytesPerToken != nil
        return Section {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Cache").gridColumnAlignment(.leading)
                    ForEach(ExpertCacheSimulator.Policy.allCases) { Text($0.rawValue) }
                    if perToken { Text("čtení/tok") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(report.rows) { row in
                    GridRow {
                        Text(row.isAll ? "vše" : Self.bytes(row.capacity))
                        ForEach(ExpertCacheSimulator.Policy.allCases) { policy in
                            Text(Self.percent(row.hitRate[policy] ?? 0))
                        }
                        if perToken {
                            Text(Self.bytes(Int(row.missBytesPerToken?[.lru] ?? 0)))
                        }
                    }
                    .font(.footnote)
                    .monospacedDigit()
                }
            }
        } header: {
            Text(report.decodeOnly ? "Zásah cache při generování" : "Zásah cache")
        } footer: {
            Text("""
                Záznam se přehraje pro každou velikost cache a politiku. LRU vyhazuje nejdéle nepoužité – tak se zhruba chová page cache iOS. LFU vyhazuje nejméně často použité. Belady zná budoucnost: není to použitelná politika, ale strop pro danou velikost.\(perToken ? " Čtení/tok je objem, který by se s LRU na token četl z flash." : "")

                Velký rozdíl mezi LRU a Belady znamená, že páka je v tom, co v RAM držet, ne kolik RAM na to dát. Nula u LRU pod velikostí jednoho tokenu (u Qwen3-30B-A3B asi 1 GB) není chyba: vrstvy se procházejí pořád dokola ve stejném pořadí a LRU menší než jeden průchod vyhodí každého experta těsně předtím, než ho další token potřebuje.\(report.decodeOnly ? " Počítá se jen generování, prefill cache jen zahřívá." : "")

                Stejný výpočet s vlastními velikostmi: tools/expert_cache_sim.py (záznam pošli přes tlačítko sdílení).
                """)
        }
    }

    private func predictionSection(_ report: ExpertCacheSimulator.Report) -> some View {
        let onMisses = report.predictions.contains { $0.missRecall != nil }
        return Section {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Odhad").gridColumnAlignment(.leading)
                    Text("trefí")
                    Text("navíc")
                    if onMisses {
                        Text("výpadky")
                        Text("čtení navíc")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(report.predictions) { row in
                    GridRow {
                        Text(row.label)
                        Text(Self.percent(row.recall))
                        Text(Self.percent(row.waste))
                        if onMisses {
                            Text(row.missRecall.map(Self.percent) ?? "–")
                            Text(row.ioWaste.map(Self.percent) ?? "–")
                        }
                    }
                    .font(.footnote)
                    .monospacedDigit()
                }
            }
            if !report.hasRouterPredictions {
                Label("Odhad z routeru v záznamu není – záznam je ze starší verze appky, nebo model nemá routery v F32/F16/BF16.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Předpověď expertů")
        } footer: {
            Text("""
                Kdyby šlo experty poznat dřív, než je router vybere, čtení z flash by běželo souběžně s výpočtem místo čekání. Trefí = podíl potřebných bajtů, které by odhad načetl dopředu. Navíc = zbytečně přečtené bajty vůči potřebným (100 % = dvojnásobné čtení).

                Minulý token: experti stejné vrstvy z předchozího tokenu. Router L+1: router další vrstvy vynásobený skrytým stavem vrstvy L – odhad o vrstvu dřív; k+2, k+4 a 2k je odhad o pár expertů delší (víc trefí, víc čte zbytečně). Router L+2: odhad o dvě vrstvy dřív – čtení má dvojnásobný náskok, ale odhad je méně přesný. L+1 ∪ L+2: experti z obou odhadů.

                Výpadky a čtení navíc (záznam s rezidencí po expertech): trefí a navíc počítají se všemi experty, i s těmi, kteří už v cache leží a předčítání nepotřebují. Skutečný přínos je sloupec výpadky – kolik expertů, kteří v cache chyběli, by odhad načetl dopředu. Čtení navíc je, kolik by odhad přečetl z flash zbytečně, vůči čtení, které je nutné tak jako tak. Experti z minulého tokenu jsou skoro vždy v cache, proto u nich výpadky vycházejí kolem nuly.

                Vyplatí se, když trefí hodně a navíc je málo – zbytečné čtení bere propustnost flash, na které generování stojí. Dokud je čtení hlavní brzdou, odhad s „navíc“ nad ~30 % spíš uškodí.
                """)
        }
    }

    private func prefillSection(_ prefill: ExpertCacheSimulator.PrefillCoverage) -> some View {
        Section {
            LabeledContent("Průměrné pokrytí vrstvy", value: Self.percent(prefill.meanCoverage))
            LabeledContent("Vrstev s pokrytím ≥ 30 %", value: Self.percent(prefill.over30))
            LabeledContent("Vrstev s pokrytím ≥ 50 %", value: Self.percent(prefill.over50))
            LabeledContent("Vybraní experti / celé vrstvy") {
                Text("\(Self.bytes(prefill.selectedBytes)) / \(Self.bytes(prefill.layerBytes))")
            }
        } header: {
            Text("Prefill")
        } footer: {
            Text("Kolik expertů vrstvy vybere dávka promptu. Prefill dostává z úložiště jednu stránku na operaci, takže čte zhruba 1,1 GB/s, zatímco sekvenční čtení zvládne ~3,7 GB/s. Když dávka vybere víc než zhruba 30 % expertů vrstvy, bylo by rychlejší přečíst celou vrstvu naráz, i když se tím přečte víc bajtů.")
        }
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    private static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
