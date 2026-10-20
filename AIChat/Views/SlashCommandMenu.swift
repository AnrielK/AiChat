import SwiftUI

/// Příkaz nabízený po napsání „/“ na začátek zprávy.
struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    /// Bez lomítka: „earnings-analysis“.
    let name: String
    let summary: String
    let symbol: String
    let tint: Color
    /// Co se vloží do pole (s mezerou na konci, ať jde rovnou psát ticker).
    var insert: String { "/\(name) " }

    static let all: [SlashCommand] = [
        .init(name: "market-brief", summary: "Přehled trhu: včera, zprávy, kalendář dne", symbol: "sun.horizon", tint: .orange),
        .init(name: "morning-note", summary: "Ranní poznámka z nových podání (watchlist)", symbol: "cup.and.saucer", tint: .brown),
        .init(name: "earnings-analysis", summary: "Výsledky posledního kvartálu · NVDA", symbol: "chart.bar.doc.horizontal", tint: .blue),
        .init(name: "earnings-preview", summary: "Náhled příštích výsledků · NVDA", symbol: "calendar.badge.clock", tint: .indigo),
        .init(name: "sector-overview", summary: "Přehled odvětví · NVDA AMD AVGO", symbol: "square.grid.3x3", tint: .teal),
        .init(name: "catalyst-calendar", summary: "Kalendář katalyzátorů na 60 dní", symbol: "calendar", tint: .red),
        .init(name: "thesis-tracker", summary: "Investiční teze a KPI · NVDA", symbol: "target", tint: .green),
        .init(name: "valuation-reviewer", summary: "Kontrola ocenění v sešitu · NVDA", symbol: "checkmark.seal", tint: .mint),
        .init(name: "finfill new", summary: "Nový sešit (10-K → Google Sheets) · AMD", symbol: "tablecells.badge.ellipsis", tint: .green),
        .init(name: "finfill analyze", summary: "Citlivost, Comps a Kvartály do sešitu · NVDA", symbol: "chart.line.uptrend.xyaxis", tint: .purple),
        .init(name: "finfill run", summary: "Zápis posledního 10-K do sešitu (náhled) · NVDA", symbol: "square.and.arrow.down", tint: .gray),
    ]

    /// Nabídka pro rozepsaný text: dokud se píše název příkazu (u „finfill“ i druhé slovo).
    static func matches(for draft: String) -> [SlashCommand] {
        guard draft.hasPrefix("/") else { return [] }
        let typed = String(draft.dropFirst()).lowercased()
        let spaces = typed.filter { $0 == " " }.count
        guard spaces == 0 || (spaces == 1 && typed.hasPrefix("finfill ")) else { return [] }
        if typed.isEmpty { return all }
        return all.filter { c in
            c.name.hasPrefix(typed) || c.name.split(whereSeparator: { $0 == "-" || $0 == " " }).contains { $0.hasPrefix(typed) }
        }
    }
}

/// Seznam příkazů nad polem pro zprávu (jako nabídka „/“ v Claude).
struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    let onPick: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commands) { c in
                    Button { onPick(c) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: c.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(c.tint)
                                .frame(width: 32, height: 32)
                                .background(c.tint.opacity(0.15), in: .rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(c.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(SlashRowStyle())
                }
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 330)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private struct SlashRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 12))
    }
}
