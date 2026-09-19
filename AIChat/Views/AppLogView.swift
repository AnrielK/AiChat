import SwiftUI
import UIKit

/// Log enginu přímo v telefonu – bez Macu a Konzole.
///
/// Čte vlastní záznamy appky z `EngineLogStore` (ne z `OSLogStore`, ten u sideloadovaných
/// buildů vrací jen `<compose failure>`). Obsahuje i záznamy z minulých spuštění.
struct AppLogView: View {
    @State private var entries: [AppLogEntry] = []
    @State private var category: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var copied = false

    private var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    private var visible: [AppLogEntry] {
        guard let category else { return entries }
        return entries.filter { $0.category == category }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if !isLoading, visible.isEmpty, errorMessage == nil {
                ContentUnavailableView(
                    "Zatím nic",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Pošli zprávu lokálnímu modelu a obnov stažením dolů.")
                )
            }

            ForEach(visible) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.level.symbol)
                            .foregroundStyle(entry.level.color)
                            .accessibilityLabel(entry.level.label)
                        Text(entry.category)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
        .overlay {
            if isLoading && entries.isEmpty { ProgressView() }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Kategorie", selection: $category) {
                        Text("Vše").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Button("Smazat log", systemImage: "trash", role: .destructive) {
                        EngineLogStore.shared.clear()
                        entries = []
                    }
                } label: {
                    Label("Filtr", systemImage: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = AppLogEntry.export(visible)
                    copied = true
                } label: {
                    Label(copied ? "Zkopírováno" : "Kopírovat", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(visible.isEmpty)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .onChange(of: copied) { _, new in
            guard new else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        entries = EngineLogStore.shared.entries()
        errorMessage = nil
    }
}

struct AppLogEntry: Identifiable, Sendable {
    let id: Int
    let date: Date
    let category: String
    let level: Level
    let message: String

    enum Level: String, Sendable {
        case debug, info, notice, error, fault

        var symbol: String {
            switch self {
            case .debug, .info, .notice: "info.circle"
            case .error: "exclamationmark.triangle.fill"
            case .fault: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .debug, .info, .notice: .secondary
            case .error: .orange
            case .fault: .red
            }
        }

        var label: String {
            switch self {
            case .debug, .info, .notice: "Informace"
            case .error: "Chyba"
            case .fault: "Závažná chyba"
            }
        }
    }

    /// Text ke zkopírování – chronologicky, jeden záznam na řádek.
    static func export(_ entries: [AppLogEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.reversed()
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }
}
