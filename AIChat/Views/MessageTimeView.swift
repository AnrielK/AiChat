import SwiftUI

/// Formátování času u zprávy – kdy vznikla a jak dlouho se na ni čekalo.
enum MessageTime {
    /// Dnešní zprávy jen s časem, včerejší se slovem „včera“, starší i s datem.
    /// (Datum u každé zprávy dnešního chatu by bylo jen šum.)
    static func stamp(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "včera \(time)" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.defaultDigits)) + " \(time)"
        }
        return date.formatted(.dateTime.day().month(.defaultDigits).year()) + " \(time)"
    }

    /// Doba běhu: do minuty na desetinu sekundy (`3,4 s`), pak `1:05 min`.
    static func duration(_ seconds: Double) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 {
            return seconds.formatted(.number.precision(.fractionLength(1))) + " s"
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d min", total / 60, total % 60)
    }

    /// Rychlost generování – jen když poskytovatel tokeny opravdu počítá
    /// (llama.cpp, MLX, Claude, Gemini) a odpověď trvala aspoň chvíli.
    static func speed(usage: TokenUsage?, seconds: Double) -> String? {
        guard let usage, !usage.isEstimate, usage.outputTokens > 0, seconds >= 1 else { return nil }
        let perSecond = Double(usage.outputTokens) / seconds
        return perSecond.formatted(.number.precision(.fractionLength(perSecond < 10 ? 1 : 0))) + " tok/s"
    }
}

/// Živý čas běhu. `TimelineView` překresluje jen tenhle popisek, ne celou zprávu.
struct RunningTimeLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.1)) { context in
            Text(MessageTime.duration(context.date.timeIntervalSince(start)))
                .monospacedDigit()
        }
    }
}

/// Řádek pod zprávou: čas odeslání a u odpovědí doba generování –
/// během běhu odpočítávaná, po dokončení celková (a rychlost, když je známá).
struct MessageTimeView: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(MessageTime.stamp(message.createdAt))

            if isStreaming {
                divider
                Image(systemName: "stopwatch")
                    .symbolEffect(.pulse)
                RunningTimeLabel(start: message.createdAt)
            } else if let seconds = message.generationSeconds {
                divider
                Image(systemName: "stopwatch")
                Text(MessageTime.duration(seconds)).monospacedDigit()
                if let speed = MessageTime.speed(usage: message.usage, seconds: seconds) {
                    divider
                    Text(speed).monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Text("·").foregroundStyle(.quaternary)
    }
}
