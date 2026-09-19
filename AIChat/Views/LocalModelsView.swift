import SwiftUI
import UniformTypeIdentifiers

struct LocalModelsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelManager.self) private var models
    private let downloads = DownloadManager.shared

    @State private var importKind: LocalModelKind?
    @State private var huggingFaceToken = ""

    var body: some View {
        @Bindable var downloads = downloads

        List {
            if !downloads.jobs.isEmpty {
                Section {
                    ForEach(downloads.jobs) { job in
                        DownloadJobRow(job: job)
                    }
                } header: {
                    Text("Stahování")
                } footer: {
                    Text("Stahuje se na pozadí – appku můžeš zavřít, systém ji po dokončení probudí a model nainstaluje.")
                }
            }

            installedSection

            Section {
                NavigationLink {
                    ModelDownloadView()
                } label: {
                    Label("Stáhnout model", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Doporučené modely a hledání na Hugging Face – MLX i GGUF.")
            }

            importSection

            Section {
                Toggle("Stahovat přes mobilní data", isOn: $downloads.allowCellular)
                SecureField("Token Hugging Face (volitelné)", text: $huggingFaceToken)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveToken)
                if huggingFaceToken != (KeychainHelper.read(.huggingFace) ?? "") {
                    Button("Uložit token", action: saveToken)
                }
            } header: {
                Text("Nastavení stahování")
            } footer: {
                Text("Bez mobilních dat nové stahování počká na Wi-Fi (změna platí pro nově spuštěná stahování). Token je potřeba jen u modelů s licencí, kterou musíš na Hugging Face nejdřív přijmout – třeba původní Gemma nebo Llama.")
            }
        }
        .navigationTitle("Modely")
        .refreshable { models.refresh() }
        .onAppear {
            models.refresh()
            huggingFaceToken = KeychainHelper.read(.huggingFace) ?? ""
        }
        .keyboardDoneButton()
        // Druh modelu se zachytí při otevření výběru – dřív se `importKind` vynuloval dřív,
        // než přišel výsledek, a složka MLX se pak zkoušela importovat jako GGUF.
        .sheet(item: $importKind) { kind in
            DocumentPicker(contentTypes: kind == .mlx ? [.folder] : [.data]) { urls in
                guard let url = urls.first else { return }
                Task { await models.importModel(from: url, kind: kind) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Sekce

    private var installedSection: some View {
        Section {
            if models.installed.isEmpty {
                Text("Zatím tu není žádný model. Stáhni si některý, nebo připoj vlastní z disku.")
                    .foregroundStyle(.secondary)
            }
            ForEach(models.installed) { model in
                installedRow(model)
            }
            .onDelete { offsets in
                offsets.map { models.installed[$0] }.forEach(delete)
            }
        } header: {
            Text("V zařízení")
        } footer: {
            if !models.installed.isEmpty {
                Text("Klepnutím model vybereš, přejetím doleva smažeš. Přemýšlení se nastavuje pro každý model zvlášť.")
            }
        }
    }

    private var importSection: some View {
        Section {
            Button {
                importKind = .gguf
            } label: {
                Label("Připojit soubor GGUF", systemImage: "doc.badge.plus")
            }
            Button {
                importKind = .mlx
            } label: {
                Label("Připojit složku MLX", systemImage: "folder.badge.plus")
            }
            if models.isImporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Kopíruji model…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Vlastní model z disku")
        } footer: {
            Text("GGUF je jeden soubor – klepnutím ho vybereš. MLX model je složka s config.json, tokenizérem a soubory .safetensors: otevři ji a vpravo nahoře klepni na Otevřít. Obojí jde nahrát i přes Soubory nebo Finder do složky AI Chat › Models (MLX do podsložky MLX).")
        }
        .disabled(models.isImporting)
    }

    // MARK: - Řádky

    private func installedRow(_ model: LocalModelFile) -> some View {
        Button {
            settings.selectedLocalModel = model.id
            settings.provider = .local
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName).lineLimit(1)
                    HStack(spacing: 6) {
                        KindBadge(kind: model.kind)
                        Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                        if !settings.isReasoningEnabled(key: "local:" + model.id) {
                            Label("bez přemýšlení", systemImage: "brain")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if settings.selectedLocalModel == model.id {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .foregroundStyle(.primary)
        }
        .contextMenu {
            let key = "local:" + model.id
            let enabled = settings.isReasoningEnabled(key: key)
            Button(enabled ? "Vypnout přemýšlení" : "Zapnout přemýšlení", systemImage: "brain") {
                settings.setReasoning(!enabled, key: key)
            }
            Button("Smazat", systemImage: "trash", role: .destructive) {
                delete(model)
            }
        }
    }

    private func saveToken() {
        KeychainHelper.save(huggingFaceToken, for: .huggingFace)
        huggingFaceToken = KeychainHelper.read(.huggingFace) ?? ""
    }

    private func delete(_ model: LocalModelFile) {
        if settings.selectedLocalModel == model.id {
            settings.selectedLocalModel = nil
        }
        models.delete(model)
    }
}

/// Štítek formátu modelu.
struct KindBadge: View {
    let kind: LocalModelKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(kind == .mlx ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15)))
            .foregroundStyle(kind == .mlx ? Color.accentColor : Color.secondary)
    }
}
