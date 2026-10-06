import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelManager.self) private var models
    private let downloads = DownloadManager.shared

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Picker("Používat", selection: $settings.provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Label(provider.title, systemImage: provider.symbol).tag(provider)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Aktivní model")
                } footer: {
                    Text(providerFooter)
                }

                Section("Lokální model") {
                    NavigationLink {
                        LocalModelsView()
                    } label: {
                        // Vybraný model je vidět vždy; stahování je jen druhý řádek pod názvem.
                        // (Label uvnitř obsahu LabeledContent rozbíjel v Formu rozvržení řádku.)
                        LabeledContent {
                            Text(settings.selectedLocalModel.map(LocalModelFile.displayName(forID:)) ?? "Nevybrán")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Modely v zařízení")
                                    if let summary = downloads.progressSummary {
                                        Text("\(Image(systemName: "arrow.down.circle")) \(summary)")
                                            .font(.caption)
                                            .foregroundStyle(downloads.activeCount > 0 ? Color.accentColor : Color.orange)
                                            .monospacedDigit()
                                            .contentTransition(.numericText())
                                    }
                                }
                            } icon: {
                                Image(systemName: "externaldrive")
                            }
                        }
                    }
                    NavigationLink {
                        LocalModelSettingsView()
                    } label: {
                        Label("Parametry generování", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        TrainingView()
                    } label: {
                        Label("Trénink (LoRA)", systemImage: "graduationcap")
                    }
                }

                Section("Cloud") {
                    ForEach(AIProvider.cloud) { provider in
                        NavigationLink {
                            CloudProviderView(provider: provider)
                        } label: {
                            LabeledContent {
                                Text(settings.isConnected(provider) ? "Připojeno" : "Nepřipojeno")
                                    .foregroundStyle(settings.isConnected(provider) ? .green : .secondary)
                            } label: {
                                Label(provider.title, systemImage: provider.symbol)
                            }
                        }
                    }
                }

                Section("Nástroje") {
                    NavigationLink {
                        FinFillScreen()
                    } label: {
                        Label("10-K → Google Sheets", systemImage: "tablecells")
                    }
                    NavigationLink {
                        GoogleAccountView()
                    } label: {
                        LabeledContent {
                            Text(GoogleAuth.shared.isSignedIn ? "Připojeno" : "Nepřipojeno")
                                .foregroundStyle(GoogleAuth.shared.isSignedIn ? Color.green : Color.secondary)
                        } label: {
                            Label("Google účet", systemImage: "person.crop.circle")
                        }
                    }
                }

                Section {
                    LabeledContent("Verze", value: AppVersion.short)
                    if let commit = AppVersion.commit {
                        LabeledContent("Commit", value: commit)
                    }
                    if let llama = AppVersion.llama {
                        LabeledContent("llama.cpp") {
                            Text(llama.replacingOccurrences(of: " · ", with: "\n"))
                                .multilineTextAlignment(.trailing)
                                .font(.footnote)
                        }
                    }
                    if let built = AppVersion.built {
                        LabeledContent("Sestaveno", value: built)
                    }
                } footer: {
                    Text("Číslo v závorce je počet commitů – roste s každým buildem a je stejné na Macu i na GitHubu. „+“ u commitu znamená, že se stavělo z rozpracovaných změn.")
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        // Chyby stahování a importu – na úrovni celého listu, ať se ukážou na kterékoli
        // podobrazovce (Modely, Stáhnout model, detail z Hugging Face).
        .alert("Chyba", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(models.lastError ?? downloads.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { models.lastError != nil || downloads.lastError != nil },
            set: { if !$0 { models.lastError = nil; downloads.lastError = nil } }
        )
    }

    private var providerFooter: String {
        switch settings.provider {
        case .local:
            "Model běží offline přímo v zařízení (GGUF přes llama.cpp, nebo MLX). Rychlost i kvalita závisí na jeho velikosti."
        case .apple:
            AppleIntelligenceProvider.availabilityMessage
                ?? AppleIntelligenceProvider.languageNotice
                ?? "Vestavěný model Apple – nic se nestahuje, běží offline."
        case .claude, .gemini, .openai, .nvidia:
            settings.isConnected(settings.provider)
                ? "Zprávy se posílají do cloudu přes tvůj API klíč."
                : "Nejdřív níže vlož API klíč pro \(settings.provider.title)."
        }
    }
}
