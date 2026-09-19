import SwiftUI
import SwiftData

struct HistoryView: View {
    let currentID: UUID?
    let onSelect: (Conversation) -> Void
    let onDelete: (Conversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var searchText = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { conversation in
                            row(conversation)
                        }
                    }
                }
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "Zatím žádné chaty",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Každá nová konverzace se sem uloží automaticky.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "Hledat v chatech")
            .navigationTitle("Historie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Další", systemImage: "ellipsis") {
                        Button("Smazat všechny chaty", systemImage: "trash", role: .destructive) {
                            confirmDeleteAll = true
                        }
                    }
                    .disabled(conversations.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
            .confirmationDialog("Smazat všech \(conversations.count) chatů?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Smazat vše", role: .destructive) { deleteAll() }
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        Button {
            onSelect(conversation)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: conversation.provider.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .fontWeight(conversation.id == currentID ? .semibold : .regular)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                        if !conversation.modelName.isEmpty {
                            Text(conversation.modelName).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        // Bez „full swipe“: dlouhým tahem se chat dřív smazal hned, bez potvrzení.
        // Teď se musí klepnout na tlačítko Smazat, které tah odkryje.
        .swipeActions(allowsFullSwipe: false) {
            Button("Smazat", systemImage: "trash", role: .destructive) {
                delete(conversation)
            }
        }
    }

    // MARK: - Data

    private var filtered: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private var sections: [(title: String, items: [Conversation])] {
        let calendar = Calendar.current
        let titles = ["Dnes", "Včera", "Posledních 7 dní", "Posledních 30 dní", "Starší"]
        let groups = Dictionary(grouping: filtered) { conversation -> Int in
            if calendar.isDateInToday(conversation.updatedAt) { return 0 }
            if calendar.isDateInYesterday(conversation.updatedAt) { return 1 }
            let days = calendar.dateComponents([.day], from: conversation.updatedAt, to: .now).day ?? 0
            if days < 7 { return 2 }
            if days < 30 { return 3 }
            return 4
        }
        return groups.keys.sorted().map { (title: titles[$0], items: groups[$0] ?? []) }
    }

    private func delete(_ conversation: Conversation) {
        onDelete(conversation)
        // Originály příloh leží mimo databázi – kaskádové mazání zpráv je nesmaže.
        AttachmentStore.remove(conversation.messages.flatMap(\.attachments))
        context.delete(conversation)
        try? context.save()
    }

    private func deleteAll() {
        for conversation in conversations { delete(conversation) }
    }
}
