import SwiftUI

struct LocalModelSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var confirmReset = false
    @State private var editedProfile: TaskProfile = .extract
    @State private var storageResults: [StorageBenchmark.Result] = []
    @State private var measuringStorage = false

    private let contextOptions = [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131_072]

    /// Přesnost KV cache se nabízí jen u MLX modelů.
    private var isMLXSelected: Bool {
        settings.selectedLocalModel.map { LocalModelFile.kind(forID: $0) == .mlx } ?? false
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            if let id = settings.selectedLocalModel {
                Section {
                    Toggle(isOn: reasoningBinding(key: "local:" + id)) {
                        Label("Přemýšlení", systemImage: "brain")
                    }
                } header: {
                    Text(LocalModelFile.displayName(forID: id))
                } footer: {
                    Text("Hlavní přepínač pro tento model. Přemýšlí třeba Qwen 3, Qwen 3.5 nebo DeepSeek R1 – vypnutím odpoví hned, ale u složitých úloh méně přesně. U modelů, které nepřemýšlejí, přepínač nic nemění. Když je zapnutý, o přemýšlení u každé zprávy rozhoduje režim: výchozí je zapnuté pro extrakci a shrnutí, vypnuté pro běžný chat.")
                }
            }

            Section {
                TextField("Systémový prompt", text: $settings.local.systemPrompt, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Systémový prompt")
            } footer: {
                Text("Instrukce, které model dostane před každou konverzací. Platí i pro Apple Intelligence.")
            }

            Section {
                Picker("Režim", selection: $settings.local.profileMode) {
                    ForEach(TaskProfileMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Režim podle úkolu")
            } footer: {
                Text(settings.local.profileMode == .automatic
                     ? "Režim se vybírá u každé zprávy zvlášť, i uprostřed chatu: „vytáhni, najdi, kolik, částka“ je extrakce, „shrň, o čem je“ shrnutí, tvůrčí zadání běžný chat. Navazující dotaz bez klíčových slov zůstane u režimu, ve kterém chat nad dokumentem běžel. Co právě platí, ukáže ukazatel kontextu v chatu."
                     : "Všechny zprávy poběží v režimu \(settings.local.profileMode.title).")
            }

            samplingSection

            Section {
                Stepper(value: $settings.local.maxTokens, in: 64...16384, step: 64) {
                    LabeledContent("Max. délka odpovědi", value: "\(settings.local.maxTokens) tokenů")
                }
                Picker("Délka kontextu", selection: $settings.local.contextLength) {
                    ForEach(contextOptions, id: \.self) { value in
                        Text("\(value) tokenů").tag(value)
                    }
                }
                Toggle("Ukazovat podklady pod odpovědí", isOn: $settings.local.showSources)
                Toggle("Stručné odpovědi nad přílohou", isOn: $settings.local.conciseAnswers)
                if !settings.local.agentTools {
                    Toggle("Vybírat kapitolu podle osnovy", isOn: $settings.local.sectionRouting)
                }
                Toggle("Hledat si nechat řídit modelem", isOn: $settings.local.agentTools)
                if settings.local.agentTools {
                    Text("Model si sám říká, co chce z přílohy vidět – čísla, celý výkaz, úryvky textu nebo kapitolu – místo pevného postupu. Trefí i dotazy, na které pevné hledání nesedí, ale každý krok je nový prompt ke zpracování: na lokálním modelu to znamená i minutu čekání navíc. Vyplatí se u cloudových modelů a se zapnutým přemýšlením.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Dlouhou přílohu shrnovat po částech", isOn: $settings.local.summarizeLongAttachments)
                if settings.local.summarizeLongAttachments {
                    Picker("Část dokumentu", selection: $settings.local.summaryChunkTokens) {
                        Text("podle kontextu").tag(0)
                        ForEach([2048, 4096, 8192, 16384], id: \.self) { Text("\($0) tokenů").tag($0) }
                    }
                    Text("Menší část znamená víc průchodů, ale každý s kratším kontextem – a generování je na dlouhém kontextu výrazně pomalejší. Vypnutím se příloha pošle jako běžná zpráva a co se nevejde, ořízne se.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Jen pro MLX. GGUF přes llama.cpp jede vždy ve f16 – kvantovaná KV cache
                // tam na Metalu produkuje nesmysly, takže se volba vůbec nenabízí.
                if !isMLXSelected && settings.local.streamExperts {
                    Picker("KV cache (MoE z úložiště)", selection: $settings.local.ggufKVCache) {
                        ForEach(KVCachePrecision.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Dávka promptu", selection: $settings.local.ggufPrefillBatch) {
                        ForEach([512, 1024, 2048, 4096], id: \.self) { Text("\($0) tokenů").tag($0) }
                    }
                    Text("Větší dávka zkracuje prefill dlouhého promptu – experti se čtou jednou na dávku, ne na každých 512 tokenů. Ubere ale z dostupného kontextu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Prefill na GPU", isOn: $settings.local.ggufGPUPrefill)
                    Text("Zpracování promptu je omezené výpočtem, ne úložištěm – GPU ho může výrazně zkrátit. Generování zůstává na CPU. Nekombinuj s kvantovanou KV cache, ta vyřadí flash attention na Metalu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Zmenšit prefill při plné paměti", isOn: $settings.local.adaptivePrefill)
                }
                if isMLXSelected {
                    Picker("Prefill po krocích", selection: $settings.local.prefillStep) {
                        ForEach([512, 1024, 2048, 3072, 4096], id: \.self) { Text("\($0) tokenů").tag($0) }
                    }
                    Toggle("Zmenšit prefill při plné paměti", isOn: $settings.local.adaptivePrefill)
                    Picker("KV cache – klíče (K)", selection: $settings.local.kvCacheK) {
                        ForEach(KVCachePrecision.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("KV cache – hodnoty (V)", selection: $settings.local.kvCacheV) {
                        ForEach(KVCachePrecision.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Délka")
            } footer: {
                if let limited = LocalRuntime.shared.memoryLimitedContext {
                    Text("Delší kontext si pamatuje víc z konverzace a z příloh, ale spotřebuje víc paměti. Na nastavenou délku posledně nestačila paměť, model běžel s kontextem \(limited) tokenů – appka ho zkracuje sama, aby ji iOS neukončil.")
                } else {
                    Text("Delší kontext si pamatuje víc z konverzace a z příloh, ale spotřebuje víc paměti a zpomalí začátek odpovědi. Když na něj paměť nestačí, appka ho sama zkrátí – kolik se vejde, ukáže sekce Paměť níže a ukazatel kontextu v chatu. Starší zprávy, které se nevejdou, se vynechají.\(!isMLXSelected && settings.local.streamExperts ? "\n\nKV cache u MoE z úložiště: při streamování expertů běží výpočet celý na CPU, kde je kvantovaná KV cache spolehlivá (na GPU dává nesmysly, proto se jinde nenabízí). q8 ji zmenší na polovinu – u Qwen3-30B-A3B je to při 16k kontextu skoro 800 MB, které zůstanou fyzické RAM na experty. To je přímo vidět na rychlosti: čím víc expertů se vejde do page cache, tím míň se jich čte z flash." : "")\(isMLXSelected ? "\n\nPrefill po krocích určuje, po kolika tokenech se zpracovává prompt. Větší krok líp vytíží GPU a zkrátí čekání na první slovo u dlouhých příloh, ale zvedne špičku paměti.\n\nSe zapnutým zmenšováním si appka před každou odpovědí změří, kolik paměti drží: nad 80 % limitu použije poloviční krok, nad 90 % jede na 512 tokenech. Ta jedna odpověď je pomalejší, ale nespadne.\n\nKV cache je paměť, ve které si model drží celý kontext – půlka na klíče (K), půlka na hodnoty (V). Snížením přesnosti se do stejné paměti vejde delší kontext: q8 příslušnou půlku zmenší na polovinu, q4 na čtvrtinu. MLX kvantuje obě půlky společně, takže se projeví až nastavení obou naráz; když je jedna na f16, nekvantuje se vůbec." : "")")
                }
            }

            memorySection

            Section {
                Toggle("Akcelerace GPU (Metal)", isOn: gpuEnabled)
                if settings.local.gpuLayers > 0 {
                    Stepper(value: $settings.local.gpuLayers, in: 1...999) {
                        LabeledContent("Vrstev na GPU", value: settings.local.gpuLayers >= 99 ? "všechny" : "\(settings.local.gpuLayers)")
                    }
                }
                Stepper(value: $settings.local.threads, in: 1...ProcessInfo.processInfo.activeProcessorCount) {
                    LabeledContent("Vlákna – generování", value: "\(settings.local.threads)")
                }
                Stepper(value: $settings.local.threadsBatch, in: 0...ProcessInfo.processInfo.activeProcessorCount) {
                    LabeledContent("Vlákna – prompt") {
                        Text(settings.local.threadsBatch == 0
                             ? "stejně (\(settings.local.threads))"
                             : "\(settings.local.threadsBatch)")
                    }
                }
                Toggle("Experty MoE z úložiště", isOn: $settings.local.streamExperts)
                Stepper(value: $settings.local.expertsPerToken, in: 0...maxExpertsPerToken) {
                    LabeledContent("Aktivních expertů") {
                        Text(settings.local.expertsPerToken == 0 ? "podle modelu" : "\(settings.local.expertsPerToken)")
                    }
                }
                .disabled(!settings.local.streamExperts)
                Toggle("Předčítat experty", isOn: $settings.local.prefetchExperts)
                    .disabled(!settings.local.streamExperts)
                if settings.local.prefetchExperts {
                    Toggle("Mapovat stránky předem", isOn: $settings.local.prefaultPages)
                        .disabled(!settings.local.streamExperts || settings.local.prefetchSplitOnly)
                    if settings.local.prefaultPages {
                        Picker("Předčítat po vlnách", selection: $settings.local.prefetchWaveMB) {
                            Text("vypnuto").tag(0)
                            ForEach([8, 16, 32, 64], id: \.self) { Text("\($0) MB").tag($0) }
                        }
                        .disabled(!settings.local.streamExperts || settings.local.prefetchSplitOnly)
                    }
                    Toggle("Vypsat dělení grafu (diagnostika)", isOn: $settings.local.ggufSchedDebug)
                    Toggle("Jen dělit graf (bez čtení)", isOn: $settings.local.prefetchSplitOnly)
                        .disabled(!settings.local.streamExperts)
                }
                Toggle("Rychlá jádra pro hustou část", isOn: $settings.local.repackDense)
                    .disabled(!settings.local.streamExperts)
                Toggle("GPU pro hustou část MoE", isOn: $settings.local.streamingGPU)
                    .disabled(!settings.local.streamExperts || settings.local.gpuLayers == 0)
            } header: {
                Text("Výkon (jen GGUF)")
            } footer: {
                Text("MLX běží vždy na GPU a tato nastavení nepoužívá. Změna GPU vrstev znovu načte GGUF model.\n\nVlákna zvlášť pro generování a pro prompt: u MoE z úložiště mají obě fáze jiné optimum. Generování čte na token jen experty jedné volby routeru a víc vláken si u výpadků stránek navzájem trhá readahead okna na kusy – nad tři vlákna rychlost klesá. Zpracování promptu sahá na desítky expertů v každé vrstvě a je omezené spíš počtem operací úložiště než jeho propustností, takže na počtu vláken skoro nezáleží. Nula znamená stejnou hodnotu jako u generování.\n\nAktivních expertů: kolik jich smí router v každé vrstvě vybrat. Kolik se toho na token přečte z flash, je na tomhle čísle přímo úměrné – u Qwen3-30B-A3B je osm expertů ve 48 vrstvách asi 1 GB na token, šest expertů tři čtvrtiny, čtyři polovina. Model je ale na svoje top-k trénovaný, takže snížením klesá kvalita: 8→6 bývá skoro bez rozdílu, 8→4 už znát je. Změna znovu načte model.\n\nExperty MoE z úložiště: u modelů jako Qwen3-30B-A3B nebo Gemma 4 26B-A4B leží v RAM jen hustá část (attention, embeddingy) a routované experty si iOS čte z flash, až je router potřebuje. Model tak nemusí celý zabírat RAM. Běží na CPU, na rychlost má velký vliv počet vláken. U modelů bez expertů se nic nemění.\n\nPředčítat experty: jakmile router vrstvy vybere experty, appka je paralelně načte z flash po celých blocích, místo aby je výpočet dotahoval stránku po stránce. Mapovat stránky předem: předčtené stránky se paralelně namapují do procesu, aby je výpočet nemapoval po jedné sám.\n\nPředčítat po vlnách: místo aby se naráz ohlásily všechny experty vrstvy, ohlásí se jen kus, počká se na jeho načtení a teprve pak jde další. Zpracování promptu sahá na desítky expertů na vrstvu, ohlásí tím přes 100 MB naráz a z úložiště pak dostává jednu 16kB stránku na operaci místo pěti – readahead se u takového objemu neuplatní a prefill je omezený počtem operací, ne propustností. Měření na iPhonu ale ukázalo, že na velikosti vlny nezáleží – prefill dostával jednu stránku na operaci při 8, 16, 32 i 64 MB stejně jako bez vln. Výchozí je proto vypnuto, volba zůstává jen pro pokusy na jiném hardwaru. Jen dělit graf (bez čtení) je diagnostika: výpočet se zastavuje ve vrstvách stejně jako při předčítání, ale nic se nečte – porovnáním s vypnutým předčítáním se změří, kolik stojí samotné zastavování.\n\nRychlá jádra pro hustou část: attention a výstupní vrstva se při načtení přebalí pro optimalizované ARM instrukce. Stojí asi 1 GB RAM navíc a načtení trvá déle.\n\nGPU pro hustou část MoE: jen pro pokusy. Na iPhonu je výpočet jen na CPU rychlejší – střídání CPU a GPU v každé vrstvě stojí víc, než GPU ušetří. Funguje jen se souborem přeuspořádaným skriptem tools/gguf_moe_reorder.py.")
            }

            storageSection

            Section {
                Toggle("Náhodný seed", isOn: $settings.local.useRandomSeed)
                if !settings.local.useRandomSeed {
                    LabeledContent("Seed") {
                        TextField("Seed", value: $settings.local.seed, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Opakovatelnost")
            } footer: {
                Text("S pevným seedem dá stejná otázka stejnou odpověď.")
            }

            Section {
                NavigationLink {
                    AppLogView()
                } label: {
                    Label("Log enginu", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                Text("Co se dělo při načtení modelu a generování: délka kontextu, rychlost prefillu, předčítání expertů a chyby. Jen od posledního spuštění appky.")
            }

            Section {
                Button("Obnovit výchozí hodnoty", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle("Parametry")
        .keyboardDoneButton()
        .onAppear {
            // Při pevně zvoleném režimu rovnou upravovat ten.
            if let fixed = settings.local.profileMode.fixedProfile { editedProfile = fixed }
        }
        .confirmationDialog("Obnovit všechny parametry na výchozí hodnoty?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Obnovit", role: .destructive) { settings.local = LocalModelSettings() }
        }
    }

    // MARK: - Vzorkování

    /// Parametry se ladí zvlášť pro každý režim; přepínač nahoře určuje, který se upravuje.
    private var samplingSection: some View {
        let parameters = parametersBinding(editedProfile)

        return Section {
            Picker("Režim", selection: $editedProfile) {
                ForEach(TaskProfile.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            SliderRow(title: "Teplota", value: parameters.temperature, range: 0...2, step: 0.05)
            SliderRow(title: "Top-P", value: parameters.topP, range: 0.05...1, step: 0.01)
            SliderRow(title: "Min-P", value: parameters.minP, range: 0...0.5, step: 0.01)
            Stepper(value: parameters.topK, in: 0...200, step: 5) {
                LabeledContent("Top-K", value: parameters.topK.wrappedValue == 0 ? "vypnuto" : "\(parameters.topK.wrappedValue)")
            }
            SliderRow(title: "Penalizace opakování", value: parameters.repeatPenalty, range: 1...2, step: 0.01)

            Stepper(value: threadsBinding(editedProfile), in: 0...ProcessInfo.processInfo.activeProcessorCount) {
                LabeledContent("Vlákna CPU") {
                    let value = settings.local.threadProfiles[editedProfile.rawValue] ?? 0
                    Text(value == 0 ? "podle Výkonu (\(settings.local.threads))" : "\(value)")
                }
            }
            Toggle(isOn: reasoningBinding(editedProfile)) {
                Label("Přemýšlení v tomto režimu", systemImage: "brain")
            }

            TextField("Instrukce pro tento režim", text: instructionsBinding(editedProfile),
                      axis: .vertical)
                .lineLimit(2...6)
            if editedProfile == .summarize {
                TextField("Osnova shrnutí – jeden nadpis na řádek",
                          text: outlineBinding(editedProfile), axis: .vertical)
                    .lineLimit(3...10)
            }

            if settings.local.parameters(for: editedProfile) != editedProfile.defaults
                || (settings.local.threadProfiles[editedProfile.rawValue] ?? 0) != 0 {
                Button("Obnovit doporučené hodnoty", systemImage: "arrow.counterclockwise") {
                    settings.local.profiles[editedProfile.rawValue] = editedProfile.defaults
                    settings.local.threadProfiles[editedProfile.rawValue] = 0
                }
            }
        } header: {
            Text("Vzorkování – \(editedProfile.title)")
        } footer: {
            Text(editedProfile.note
                 + " Nižší teplota dává přesnější a předvídatelnější odpovědi, vyšší kreativnější."
                 + " Přemýšlení v tomto režimu platí jen pro modely, které to umí, a jen když je zapnuté i hlavním přepínačem u modelu nahoře."
                 + " Vlákna CPU přebíjejí hodnotu z Výkonu jen v tomto režimu a mění se za běhu, takže to nezahodí rozpracovaný chat. U MoE z úložiště se totiž s délkou kontextu mění úzké hrdlo: krátký chat brzdí čtení z flash a nad tři vlákna zpomaluje, práce nad dokumentem je při tisících tokenů omezená hlavně výpočtem attention a tam víc vláken pomáhá. Nula znamená společnou hodnotu.")
        }
    }

    /// Vlákna pro jeden režim; 0 znamená společnou hodnotu z Výkonu.
    private func threadsBinding(_ profile: TaskProfile) -> Binding<Int> {
        Binding(
            get: { settings.local.threadProfiles[profile.rawValue] ?? 0 },
            set: { settings.local.threadProfiles[profile.rawValue] = $0 }
        )
    }

    /// Přemýšlení pro jeden režim; když není uložené, platí výchozí stav režimu.
    private func reasoningBinding(_ profile: TaskProfile) -> Binding<Bool> {
        Binding(
            get: { settings.local.reasoning(for: profile) },
            set: { settings.local.reasoningProfiles[profile.rawValue] = $0 }
        )
    }

    /// Zápis do `profiles` slovníku; když tam režim ještě není, vyjde se z doporučených hodnot.
    private func parametersBinding(_ profile: TaskProfile) -> Binding<SamplingParameters> {
        Binding(
            get: { settings.local.parameters(for: profile) },
            set: { settings.local.profiles[profile.rawValue] = $0 }
        )
    }

    // MARK: - Úložiště

    /// Horní mez posuvníku: kolik expertů model ve skutečnosti používá (když je načtený),
    /// jinak rozumný strop. Nad hodnotu z metadat se stejně nic nepřepisuje.
    private var maxExpertsPerToken: Int {
        max(1, LocalRuntime.shared.streamedExperts?.expertUsed ?? 16)
    }

    /// Cesta k vybranému GGUF souboru – měření se dělá přímo na něm, ať sedí velikost
    /// i umístění na disku.
    private var selectedGGUFPath: String? {
        guard let id = settings.selectedLocalModel, LocalModelFile.kind(forID: id) == .gguf else { return nil }
        return ModelPaths.root.appending(path: id).path(percentEncoded: false)
    }

    /// Kolik bajtů se u načteného streamovaného modelu přečte na jeden token.
    private var streamedBytesPerToken: Int {
        guard let layout = LocalRuntime.shared.streamedExperts else { return 0 }
        let used = LocalRuntime.shared.activeExperts > 0 ? LocalRuntime.shared.activeExperts : layout.expertUsed
        return StorageBenchmark.bytesPerToken(layout: layout, expertUsed: used)
    }

    private var storageSection: some View {
        Section {
            Button {
                measureStorage()
            } label: {
                if measuringStorage {
                    HStack {
                        ProgressView()
                        Text("Měřím…")
                    }
                } else {
                    Label("Změřit rychlost úložiště", systemImage: "speedometer")
                }
            }
            .disabled(measuringStorage || selectedGGUFPath == nil)

            ForEach(storageResults) { result in
                LabeledContent("\(result.threads) vláken") {
                    HStack(spacing: 6) {
                        if !result.isCold {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if streamedBytesPerToken > 0 {
                            Text("\(result.gigabytesPerSecond, format: .number.precision(.fractionLength(2))) GB/s · ≤ \(result.tokensPerSecond(bytesPerToken: streamedBytesPerToken), format: .number.precision(.fractionLength(1))) tok/s")
                                .monospacedDigit()
                        } else {
                            Text("\(result.gigabytesPerSecond, format: .number.precision(.fractionLength(2))) GB/s")
                                .monospacedDigit()
                        }
                    }
                }
            }
            if storageResults.contains(where: { !$0.isCold }) {
                Label("Část bloků byla v page cache – označená měření jsou nadhodnocená a nejsou stropem úložiště.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Rychlost úložiště")
        } footer: {
            Text("Přečte z vybraného GGUF souboru náhodné bloky po 1 MB, pro různý počet souběžných vláken. Čte se stejnou cestou jako při generování – namapovaný soubor, ohlášení přes F_RDADVISE, pak dotyk stránek – aby výsledek odpovídal tomu, co engine opravdu zvládne. Trvá to pár desítek sekund a je to jen čtení, souboru se to nedotkne.\n\nU MoE modelů streamovaných z úložiště je tohle číslo strop rychlosti: na každý token se přečte pevný objem dat a rychleji než flash to nepůjde. Druhý sloupec ukazuje, kolik tokenů za sekundu z toho vychází pro právě načtený model.\n\nKde se křivka láme, tam je nasycené úložiště – nastav vlákna CPU zhruba na tu hodnotu. Víc vláken už propustnost nezvedne a na výkonu ubere, protože si překážejí u výpadků stránek. Když ani nejvyšší hodnota nestačí, pomůže jen číst na token míň dat: méně aktivních expertů nebo model s nižší kvantizací expertů.")
        }
    }

    private func measureStorage() {
        guard let path = selectedGGUFPath else { return }
        measuringStorage = true
        storageResults = []
        Task {
            // Měření je synchronní a trvá desítky sekund – musí mimo hlavní vlákno.
            let results = await Task.detached(priority: .userInitiated) {
                StorageBenchmark.run(path: path)
            }.value
            storageResults = results
            measuringStorage = false
        }
    }

    /// Skutečný limit paměti appky – podle něj je vidět, jestli sideload předal
    /// entitlement increased-memory-limit (bez něj se do paměti vejdou jen menší modely).
    /// Instrukce navíc k systémovému promptu, jen pro tenhle režim.
    private func instructionsBinding(_ profile: TaskProfile) -> Binding<String> {
        Binding(
            get: { settings.local.instructionProfiles[profile.rawValue] ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Prázdné se nedrží, ať se v uloženém nastavení nehromadí prázdné klíče.
                settings.local.instructionProfiles[profile.rawValue] = trimmed.isEmpty ? nil : text
            }
        )
    }

    /// Osnova jako text po řádcích; do nastavení se ukládá jako pole nadpisů.
    private func outlineBinding(_ profile: TaskProfile) -> Binding<String> {
        Binding(
            get: {
                let stored = settings.local.outlineProfiles[profile.rawValue]
                return (stored ?? profile.defaultOutline).joined(separator: "\n")
            },
            set: { text in
                let headings = text.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                settings.local.outlineProfiles[profile.rawValue] =
                    headings == profile.defaultOutline ? nil : headings
            }
        )
    }

    private var memorySection: some View {
        // `settings` je z prostředí, ne `@Bindable`. V `body` se stíní vlastní kopií,
        // sem ale to stínění nedosáhne, takže si ho tahle sekce udělá taky – jinak
        // se na `$settings` nedá sáhnout.
        @Bindable var settings = settings
        let limit = MemoryBudget.appLimit
        let device = MemoryBudget.deviceMemory
        let format: (Int) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }

        return Section {
            Picker("Strop pro model", selection: $settings.local.memoryCapMB) {
                Text("Bez stropu").tag(0)
                ForEach([2_048, 3_072, 4_096, 5_120, 6_144], id: \.self) {
                    Text(format($0 * 1_048_576)).tag($0)
                }
            }
            LabeledContent("Limit aplikace", value: limit > 0 ? format(limit) : "neznámý")
            LabeledContent("Právě zabráno", value: format(MemoryBudget.footprint))
            LabeledContent("Fyzická RAM appky", value: format(MemoryBudget.resident))
            LabeledContent("RAM zařízení", value: format(device))
            if let streamed = LocalRuntime.shared.streamedExperts {
                LabeledContent("Hustá část modelu (RAM)", value: format(streamed.denseBytes))
                LabeledContent("Experti (z úložiště)", value: format(streamed.expertBytes))
                if streamed.expertCount > 0 {
                    let used = LocalRuntime.shared.activeExperts > 0 ? LocalRuntime.shared.activeExperts : streamed.expertUsed
                    LabeledContent("Aktivní experti", value: used < streamed.expertUsed
                                   ? "\(used) z \(streamed.expertCount) na vrstvu (sníženo z \(streamed.expertUsed))"
                                   : "\(used) z \(streamed.expertCount) na vrstvu")
                    LabeledContent("Čtení na token", value: format(StorageBenchmark.bytesPerToken(layout: streamed, expertUsed: used)))
                }
                LabeledContent("Výpočet", value: LocalRuntime.shared.streamingPlacement == .hybrid ? "CPU + GPU" : "CPU")
                if LocalRuntime.shared.repackedDenseBytes > 0 {
                    LabeledContent("Přebalená hustá část", value: format(LocalRuntime.shared.repackedDenseBytes))
                }
                if LocalRuntime.shared.streamingPlacement == .cpuOnlyInterleaved {
                    Label("GPU pro hustou část je zapnuté, ale v tomto souboru se attention a experti střídají – Metal by musel držet v paměti celý model. Běží jen na CPU. Pro GPU je potřeba soubor přeuspořádaný skriptem tools/gguf_moe_reorder.py.", systemImage: "cpu")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if limit > 0, limit > device / 2 {
                Label("Rozšířený limit paměti je aktivní", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Paměť")
        } footer: {
            Text("Strop drží model pod vlastní hranicí, nižší než systémový limit. Není to zeď, na které by alokace selhala – to by znamenalo pád místo zpomalení. Počítá se z něj délka kontextu i velikost prefill kroku, takže se model ke stropu nepřiblíží. Za běhu navíc hlídka po každých šestnácti tokenech uvolní cache, a kdyby došlo i tak, odpověď radši usekne. Hodí se, protože jetsam nesleduje jen tuhle appku: sáhnout si na systémový limit znamená, že iOS začne zabíjet i to, co běží na pozadí.\n\nLimit je, kolik paměti smí appka zabrat, než ji iOS ukončí – s modelem a kontextem se musí vejít pod něj. Rozšířený limit (entitlement increased-memory-limit) musí předat sideload nástroj, třeba SideStore nebo AltStore. Hodnota se načte při otevření obrazovky.\n\nU GGUF je „právě zabráno“ výrazně nižší než „fyzická RAM appky“: llama.cpp si váhy mapuje ze souboru a takové stránky se do limitu nepočítají, i když RAM zabírají. Do limitu se tedy vejdeš, ale paměť zařízení je tím obsazená – appka to při výpočtu kontextu bere v úvahu. U MLX jsou obě čísla skoro stejná.")
        }
    }

    private func reasoningBinding(key: String) -> Binding<Bool> {
        Binding(
            get: { settings.isReasoningEnabled(key: key) },
            set: { settings.setReasoning($0, key: key) }
        )
    }

    private var gpuEnabled: Binding<Bool> {
        Binding(
            get: { settings.local.gpuLayers > 0 },
            set: { settings.local.gpuLayers = $0 ? 99 : 0 }
        )
    }
}

/// Posuvník s popiskem a aktuální hodnotou.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
