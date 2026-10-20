import FinFillCore
import SwiftUI

/// Kurzy ve stylu Akcií (blok ```aichat-quotes v odpovědi): ticker a jméno vlevo,
/// cena a barevná změna vpravo, klepnutím detail na Yahoo Finance.
struct QuotesCardView: View {
    let board: QuoteBoard

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
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                rowView(row)
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

    private func rowView(_ row: QuoteBoard.Row) -> some View {
        Button {
            if let s = row.url, let url = URL(string: s) { openURL(url) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.symbol)
                        .font(.headline)
                        .lineLimit(1)
                    if let name = row.name, !name.isEmpty {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.price(row))
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                    Text(Self.change(row))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(Self.color(row))
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.symbol), \(Self.price(row)), \(Self.change(row))")
    }

    // MARK: - Formát (česká čísla: 766,48 US$, +0,4 %)

    static func number(_ v: Double, decimals: Int, sign: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        if sign { f.positivePrefix = "+" }
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func price(_ r: QuoteBoard.Row) -> String {
        number(r.price, decimals: r.decimals) + (r.unit.map { " " + $0 } ?? "")
    }

    /// „+2,96 · +1,4 %“ (u výnosů „+4 bb“).
    static func change(_ r: QuoteBoard.Row) -> String {
        if let bps = r.changeBps { return number(bps, decimals: 0, sign: true) + " bb" }
        let pct = r.change * 100
        let percent = number(pct, decimals: abs(pct) < 10 ? 1 : 0, sign: true) + " %"
        guard let a = r.changeAbs else { return percent }
        let decimals = abs(a) >= 100 ? 0 : r.decimals
        return number(a, decimals: decimals, sign: true) + " · " + percent
    }

    static func color(_ r: QuoteBoard.Row) -> Color {
        let v = r.changeBps ?? r.change
        if abs(v) < 0.000_05 { return .secondary }
        return v > 0 ? .green : .red
    }
}
