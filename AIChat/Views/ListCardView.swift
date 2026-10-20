import FinFillCore
import SwiftUI

/// Karta se seznamem (blok ```aichat-list): název a popis vlevo, hodnota a detail vpravo,
/// barevná tečka podle dopadu, šipka u řádků s odkazem. Stejný vzhled jako `QuotesCardView`.
struct ListCardView: View {
    let board: ListBoard

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(board.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let subtitle = board.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ForEach(Array(board.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, 16) }
                rowView(row)
            }

            if let note = board.footnote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func rowView(_ row: ListBoard.Row) -> some View {
        Button {
            if let s = row.url, let url = URL(string: s) { openURL(url) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if let tone = row.tone, [.high, .medium, .low].contains(tone) {
                    Circle()
                        .fill(Self.color(tone))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(row.badge ?? "")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let value = row.value {
                        Text(value)
                            .font(.headline.monospacedDigit())
                            .lineLimit(1)
                            .foregroundStyle(row.tone == .up ? Color.green : row.tone == .down ? Color.red : Color.primary)
                    }
                    if let detail = row.detail {
                        Text(detail)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if row.url != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row.url == nil)
        .accessibilityElement(children: .combine)
    }

    static func color(_ tone: ListBoard.Tone) -> Color {
        switch tone {
        case .high: .red
        case .medium: .orange
        case .low: Color.secondary.opacity(0.5)
        case .up: .green
        case .down: .red
        }
    }
}
