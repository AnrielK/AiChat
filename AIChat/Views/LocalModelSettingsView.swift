import SwiftUI

struct LocalModelSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var confirmReset = false
    @State private var confirmPreset = false
    @State private var editedProfile: TaskProfile = .extract
    @State private var storageResults: [StorageBenchmark.Result] = []
    @State private var measuringStorage = false

    private let contextOptions = [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131_072]

    /// Třída vybraného modelu – podle ní se ukazují jen parametry, které na model působí.
    /// nil = žádný model není vybraný, zobrazí se jen společná nastavení.
    private var modelClass: LocalModelClass? {
        settings.selectedLocalModel == nil ? nil : settings.localClass
    }
    private var isMLX: Bool { modelClass == .mlx }
    private var isGGUF: Bool { modelClass == .gguf || modelClass == .ggufMoE }
    private var isMoE: Bool { modelClass == .ggufMoE }
    /// MoE s experty z úložiště – jen tehdy platí dávka promptu, KV cache pro CPU a předčítání.
    private var isStreaming: Bool { isMoE && settings.local.streamExperts }

    var body: some View {
        @Bindable var settings = settings

        Form {
            if let id = settings.selectedLocalModel, let modelClass {
                presetSection(modelClass)
                Section {
                    Toggle(isOn: reasoningBinding(key: "local:" + id)) {
                        Label("Přemýšlení", systemImage: "brain")
                    }
                } header: {
                    Text(LocalModelFile.displayName(forID: id))
                } footer: {
                    Text("Hlavní přepínač pro tento model. Přemýšlí třeba Qwen 3, Qwen 3.5 nebo DeepSeek R1 – vypnutím odpoví hned, ale u složitých úloh méně přesně. U modelů, které nepřemýšlejí, přepínač nic nemění. Když je zapnutý, o přemýšlení u každé zprávy rozhoduje režim: výchozí je zapnuté pro extrakci a shrnutí, vypnuté pro běžný chat.")
                }
            } else {
                Section {
                    Label("Není vybraný žádný lokální model", systemImage: "questionmark.circle")
                } footer: {
                    Text("Vyber model v Modelech v zařízení – pak se tu ukážou i parametry pro jeho typ (GGUF MoE, GGUF nebo MLX). Zatím jsou vidět jen společná nastavení.")
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

                // KV cache a dávka promptu u GGUF jen pro MoE z úložiště – výpočet tam běží
                // na CPU, kde je kvantovaná cache spolehlivá. Hustý GGUF na Metalu jede vždy
                // ve f16 (kvantovaná tam dává nesmysly) a dávku má pevnou.
                if isStreaming {
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
                if isMLX {
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
                    Text("Delší kontext si pamatuje víc z konverzace a z příloh, ale spotřebuje víc paměti a zpomalí začátek odpovědi. Když na něj paměť nestačí, appka ho sama zkrátí – kolik se vejde, ukáže sekce Paměť níže a ukazatel kontextu v chatu. Starší zprávy, které se nevejdou, se vynechají.\(isStreaming ? "\n\nKV cache u MoE z úložiště: při streamování expertů běží výpočet celý na CPU, kde je kvantovaná KV cache spolehlivá (na GPU dává nesmysly, proto se jinde nenabízí). q8 ji zmenší na polovinu – u Qwen3-30B-A3B je to při 16k kontextu skoro 800 MB, které zůstanou fyzické RAM na experty. To je přímo vidět na rychlosti: čím víc expertů se vejde do page cache, tím míň se jich čte z flash." : "")\(isMLX ? "\n\nPrefill po krocích určuje, po kolika tokenech se zpracovává prompt. Větší krok líp vytíží GPU a zkrátí čekání na první slovo u dlouhých příloh, ale zvedne špičku paměti.\n\nSe zapnutým zmenšováním si appka před každou odpovědí změří, kolik paměti drží: nad 80 % limitu použije poloviční krok, nad 90 % jede na 512 tokenech. Ta jedna odpověď je pomalejší, ale nespadne.\n\nKV cache je paměť, ve které si model drží celý kontext – půlka na klíče (K), půlka na hodnoty (V). Snížením přesnosti se do stejné paměti vejde delší kontext: q8 příslušnou půlku zmenší na polovinu, q4 na čtvrtinu. MLX kvantuje obě půlky společně, takže se projeví až nastavení obou naráz; když je jedna na f16, nekvantuje se vůbec." : "")")
                }
            }

            memorySection

            if isGGUF {
                performanceSection
            }

            if isMoE {
                storageSection
            }

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
                Button("Obnovit vše na výchozí", role: .destructive) {
                    confirmReset = true
                }
            } footer: {
                Text("Vrátí předvolby všech typů modelů (GGUF MoE, GGUF, MLX) včetně systémového promptu a instrukcí režimů.")
            }
        }
        .navigationTitle("Parametry")
        .keyboardDoneButton()
        .onAppear {
            // Při pevně zvoleném režimu rovnou upravovat ten.
            if let fixed = settings.local.profileMode.fixedProfile { editedProfile = fixed }
        }
        .confirmationDialog("Obnovit všechny parametry na výchozí hodnoty?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Obnovit", role: .destructive) { settings.resetAllLocal() }
        }
        .confirmationDialog("Použít předvolbu \(settings.localClass.title)?", isPresented: $confirmPreset, titleVisibility: .visible) {
            Button("Použít předvolbu") { settings.applyPreset() }
        } message: {
            Text("Parametry enginu a vzorkování pro \(settings.localClass.title) se vrátí na doporučené. Systémový prompt, instrukce režimů a nastavení příloh zůstanou.")
        }
    }

    // MARK: - Předvolba

    /// Typ modelu, stav předvolby a tlačítko na návrat k ní.
    private func presetSection(_ modelClass: LocalModelClass) -> some View {
        let matches = settings.local.matchesPreset(for: modelClass)
        return Section {
            LabeledContent {
                Text(matches ? "předvolba" : "upraveno")
                    .foregroundStyle(matches ? Color.secondary : Color.orange)
            } label: {
                Label(modelClass.title, systemImage: modelClass.symbol)
            }
            if !matches {
                Button("Použít předvolbu \(modelClass.title)", systemImage: "wand.and.stars") {
                    confirmPreset = true
                }
            }
        } header: {
            Text("Typ modelu")
        } footer: {
            Text(modelClass.summary + " Parametry se ukládají zvlášť pro GGUF MoE, GGUF a MLX – přepnutím na model jiného typu se načte jeho sada. Systémový prompt, instrukce režimů a nastavení příloh jsou společné. Níže jsou jen parametry, které na tento typ modelu působí.")
        }
    }

    // MARK: - Výkon (GGUF)

    private var performanceSection: some View {
        @Bindable var settings = settings
        let local = settings.local

        return Section {
            Toggle("Akcelerace GPU (Metal)", isOn: gpuEnabled)
            if local.gpuLayers > 0 && (!isMoE || !local.streamExperts || local.streamingGPU) {
                Stepper(value: $settings.local.gpuLayers, in: 1...999) {
                    LabeledContent("Vrstev na GPU", value: local.gpuLayers >= 99 ? "všechny" : "\(local.gpuLayers)")
                }
            }
            Stepper(value: $settings.local.threads, in: 1...ProcessInfo.processInfo.activeProcessorCount) {
                LabeledContent("Vlákna – generování", value: "\(local.threads)")
            }
            Stepper(value: $settings.local.threadsBatch, in: 0...ProcessInfo.processInfo.activeProcessorCount) {
                LabeledContent("Vlákna – prompt") {
                    Text(local.threadsBatch == 0
                         ? "stejně (\(local.threads))"
                         : "\(local.threadsBatch)")
                }
            }
            if isMoE {
                Toggle("Experty MoE z úložiště", isOn: $settings.local.streamExperts)
            }
            if isStreaming {
                Stepper(value: $settings.local.expertsPerToken, in: 0...maxExpertsPerToken) {
                    LabeledContent("Aktivních expertů") {
                        Text(local.expertsPerToken == 0 ? "podle modelu" : "\(local.expertsPerToken)")
                    }
                }
                Toggle("Předčítat experty", isOn: $settings.local.prefetchExperts)
                if local.prefetchExperts {
                    if !local.prefetchSplitOnly {
                        Toggle("Mapovat stránky předem", isOn: $settings.local.prefaultPages)
                        if local.prefaultPages {
                            Picker("Předčítat po vlnách", selection: $settings.local.prefetchWaveMB) {
                                Text("vypnuto").tag(0)
                                ForEach([8, 16, 32, 64], id: \.self) { Text("\($0) MB").tag($0) }
                            }
                        }
                        Picker("Předčítat podle odhadu", selection: $settings.local.prefetchAhead) {
                            Text("vypnuto").tag(0)
                            Text("k expertů").tag(1)
                            Text("k+2 expertů").tag(2)
                            Text("k, dvě vrstvy dopředu").tag(3)
                        }
                        Picker("Prefill: celá vrstva", selection: $settings.local.prefillWholeLayerPercent) {
                            Text("vypnuto").tag(0)
                            ForEach([30, 50, 70], id: \.self) { Text("od \($0) % expertů").tag($0) }
                        }
                    }
                    Toggle("Vypsat dělení grafu (diagnostika)", isOn: $settings.local.ggufSchedDebug)
                    Toggle("Jen dělit graf (bez čtení)", isOn: $settings.local.prefetchSplitOnly)
                }
                Toggle("Zaznamenávat experty", isOn: $settings.local.recordExpertTrace)
                NavigationLink {
                    ExpertTraceListView()
                } label: {
                    Label("Simulace cache expertů", systemImage: "chart.bar.doc.horizontal")
                }
                Toggle("Rychlá jádra pro hustou část", isOn: $settings.local.repackDense)
                if local.gpuLayers > 0 {
                    Toggle("GPU pro hustou část MoE", isOn: $settings.local.streamingGPU)
                }
            }
        } header: {
            Text("Výkon – \(isMoE ? "GGUF MoE" : "GGUF")")
        } footer: {
            Text(performanceFooter)
        }
    }

    /// Nápověda jen k tomu, co je v sekci Výkon právě vidět.
    private var performanceFooter: String {
        var parts = ["Změna GPU vrstev znovu načte model."]
        if isMoE {
            parts.append("Vlákna zvlášť pro generování a pro prompt: u MoE z úložiště mají obě fáze jiné optimum. Generování čte na token jen experty jedné volby routeru a víc vláken si u výpadků stránek navzájem trhá readahead okna na kusy – nad tři vlákna rychlost klesá. Zpracování promptu sahá na desítky expertů v každé vrstvě a je omezené spíš počtem operací úložiště než jeho propustností, takže na počtu vláken skoro nezáleží. Nula znamená stejnou hodnotu jako u generování.")
            parts.append("Experty MoE z úložiště: v RAM leží jen hustá část (attention, embeddingy) a routované experty si iOS čte z flash, až je router potřebuje. Model tak nemusí celý zabírat RAM. Běží na CPU, na rychlost má velký vliv počet vláken. Vypnutím se model načte celý do RAM jako hustý GGUF.")
        } else {
            parts.append("Hustý model leží celý v RAM a počítá se na GPU – vlákna CPU se uplatní hlavně při vypnuté akceleraci a u vrstev, které na GPU nejsou. Nula u vláken pro prompt znamená stejnou hodnotu jako u generování.")
        }
        if isStreaming {
            parts.append("Aktivních expertů: kolik jich smí router v každé vrstvě vybrat. Kolik se toho na token přečte z flash, je na tomhle čísle přímo úměrné – u Qwen3-30B-A3B je osm expertů ve 48 vrstvách asi 1 GB na token, šest expertů tři čtvrtiny, čtyři polovina. Model je ale na svoje top-k trénovaný, takže snížením klesá kvalita: 8→6 bývá skoro bez rozdílu, 8→4 už znát je. Změna znovu načte model.")
            parts.append("Předčítat experty: jakmile router vrstvy vybere experty, appka je paralelně načte z flash po celých blocích, místo aby je výpočet dotahoval stránku po stránce. Mapovat stránky předem: předčtené stránky se paralelně namapují do procesu, aby je výpočet nemapoval po jedné sám.")
            parts.append("Předčítat po vlnách: místo aby se naráz ohlásily všechny experty vrstvy, ohlásí se jen kus a počká se na jeho načtení. Měření na iPhonu ukázalo, že na velikosti vlny nezáleží – prefill dostával jednu stránku na operaci při 8, 16, 32 i 64 MB stejně jako bez vln. Výchozí je proto vypnuto, volba zůstává jen pro pokusy na jiném hardwaru. Jen dělit graf (bez čtení) je diagnostika: výpočet se zastavuje ve vrstvách stejně jako při předčítání, ale nic se nečte – porovnáním s vypnutým předčítáním se změří, kolik stojí samotné zastavování.")
            parts.append("Předčítat podle odhadu: při generování se z routeru další vrstvy odhadne, které experty vybere, a jejich čtení se ohlásí o vrstvu dřív – běží pak souběžně s výpočtem místo čekání. Záznamy z iPhonu: odhad s k experty trefí 81 % expertů, kteří v cache chybějí, a zbytečně přečte asi čtvrtinu toho, co se číst musí; k+2 trefí 90 % za zhruba 57 % navíc a v praxi byl pomalejší. „Dvě vrstvy dopředu“ ohlásí k expertů i podle routeru o dvě vrstvy dál, takže čtení má delší náskok: trefí 84 % výpadků za 52 % navíc – na iPhonu ale byl o 9 % pomalejší než k, zbytečné čtení sebere víc, než delší náskok dá. Výchozí je k: proti vypnutému odhadu zhruba +9 %. Stojí jedno zastavení výpočtu na vrstvu navíc a ~25 MB na routery. Porovnej tok/s v Logu enginu s volbou a bez ní – se záznamem expertů vypnutým, jinak čísla zkreslí měření.")
            parts.append("Prefill: celá vrstva – když dávka promptu vybere aspoň daný podíl expertů vrstvy, přečtou se celé tenzory expertů té vrstvy sekvenčně po 8MB blocích. Předčítání jednotlivých expertů dostává z úložiště jednu stránku na operaci (~1,1 GB/s), sekvenční čtení jde ~3,7 GB/s, takže od zhruba 30 % pokrytí je rychlejší přečíst všechno, i když se tím přečte víc bajtů. Týká se jen promptu, generování (jeden token) ne. Do Logu enginu se po prefillu zapíše, kolik vrstev se četlo celých a jakou rychlostí – porovnej dobu prefillu se zapnutou a vypnutou volbou.")
            parts.append("Zaznamenávat experty: appka si zapisuje, které experty router v každé vrstvě vybral, a před předčtením změří, kolik z nich už leželo v paměti (zásah page cache, píše se do Logu enginu). Záznam jde v Simulaci cache expertů přehrát pro různé velikosti cache a politiky – bez spouštění modelu, protože výběr routeru na cache nezávisí. Při generování se navíc z routeru další vrstvy odhaduje, které experty vybere – simulace pak ukáže, kolik by takové předčítání dopředu trefilo. Routery zaberou pár desítek MB (Qwen3-30B-A3B ~25 MB) a výpočet se kvůli odhadu zastavuje v každé vrstvě jednou navíc. Zásah cache se měří jen na každém osmém tokenu – měření každého tokenu stálo až 80 ms na token. I tak je generování se záznamem pomalejší – pro měření rychlosti ho vypni. Se zapnutým předčítáním podle odhadu ukazuje záznam, kolik expertů bylo připravených včas, ne čistou page cache – pro vyhodnocení samotného odhadu nahrávej s předčítáním podle odhadu vypnutým. Když je předčítání vypnuté, výpočet se kvůli záznamu stejně zastavuje za výběrem expertů jako při předčítání, jen se nic nečte.")
            parts.append("Rychlá jádra pro hustou část: attention a výstupní vrstva se při načtení přebalí pro optimalizované ARM instrukce. Stojí asi 1 GB RAM navíc a načtení trvá déle.")
            parts.append("GPU pro hustou část MoE: jen pro pokusy. Na iPhonu je výpočet jen na CPU rychlejší – střídání CPU a GPU v každé vrstvě stojí víc, než GPU ušetří. Funguje jen se souborem přeuspořádaným skriptem tools/gguf_moe_reorder.py.")
        }
        return parts.joined(separator: "\n\n")
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

            if isGGUF {
                Stepper(value: threadsBinding(editedProfile), in: 0...ProcessInfo.processInfo.activeProcessorCount) {
                    LabeledContent("Vlákna CPU") {
                        let value = settings.local.threadProfiles[editedProfile.rawValue] ?? 0
                        Text(value == 0 ? "podle Výkonu (\(settings.local.threads))" : "\(value)")
                    }
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
            Text(samplingFooter)
        }
    }

    /// Nápověda k vzorkování – věty o vláknech jen u GGUF, kde se vlákna nastavují.
    private var samplingFooter: String {
        var text = editedProfile.note
        text += " Nižší teplota dává přesnější a předvídatelnější odpovědi, vyšší kreativnější."
        text += " Přemýšlení v tomto režimu platí jen pro modely, které to umí, a jen když je zapnuté i hlavním přepínačem u modelu nahoře."
        if isGGUF {
            text += " Vlákna CPU přebíjejí hodnotu z Výkonu jen v tomto režimu a mění se za běhu, takže to nezahodí rozpracovaný chat."
        }
        if isMoE {
            text += " U MoE z úložiště se totiž s délkou kontextu mění úzké hrdlo: krátký chat brzdí čtení z flash a nad tři vlákna zpomaluje, práce nad dokumentem je při tisících tokenů omezená hlavně výpočtem attention a tam víc vláken pomáhá."
        }
        if isGGUF {
            text += " Nula znamená společnou hodnotu."
        }
        return text
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
