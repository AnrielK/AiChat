import SwiftUI

/// Obsazení kontextu v navigační liště: kroužek + „zbývá / okno“. Klepnutím podrobnosti.
///
/// Plný oblouk = co už konverzace zabírá (přesně z tokenizéru / API po poslední odpovědi,
/// během generování živě), světlejší pokračování = kolik zhruba přidá rozepsaná zpráva s přílohami.
struct ContextGauge: View {
    let chat: ChatViewModel
    @Environment(SettingsStore.self) private var settings

    @State private var showDetails = false

    private var usage: TokenUsage? { chat.usage }
    private var window: Int? { usage?.contextWindow ?? settings.expectedContextWindow }
    private var used: Int { usage?.used ?? 0 }
    private var pending: Int { chat.pendingTokens }
    private var remaining: Int? { window.map { max(0, $0 - used) } }

    private func fraction(_ tokens: Int) -> Double {
        guard let window, window > 0 else { return 0 }
        return min(1, Double(tokens) / Double(window))
    }

    /// Barva podle toho, kolik bude obsazeno po odeslání rozepsané zprávy.
    private var tint: Color {
        switch fraction(used + pending) {
        case ..<0.7: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            HStack(spacing: 8) {
                ring
                // Paměť se mění i mezi odpověďmi (KV cache roste s každým tokenem),
                // takže se na rozdíl od kontextu musí číst v čase, ne jen při překreslení.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    memoryRing
                }
            }
            .padding(.horizontal, 4)
            .animation(.smooth, value: used)
        }
        .popover(isPresented: $showDetails) {
            // Obsah je vyšší než popover na malém iPhonu – dá se v něm scrollovat.
            ScrollView {
                details
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 520)
            .presentationCompactAdaptation(.popover)
        }
        .task(id: settings.contextWindowKey) {
            await settings.refreshCloudModelInfo()
        }
        .accessibilityLabel("Kontext")
        .accessibilityValue(accessibilityText)
    }

    // MARK: - Kroužek

    /// Obsazení kontextu. Číslo je uvnitř kroužku – „15,4k / 32,8k“ se sem nevejde
    /// a stejně se pletlo, protože to první číslo je zbytek, ne obsazeno. Přesné
    /// hodnoty jsou po klepnutí v podrobnostech.
    private var ring: some View {
        GaugeRing(
            fraction: fraction(used),
            pending: fraction(used + pending),
            tint: tint,
            label: window == nil ? "–" : "\(Int((fraction(used) * 100).rounded()))"
        )
    }

    /// Obsazení paměti proti limitu appky (nebo proti vlastnímu stropu, když je
    /// nastavený). Bez známého limitu se kroužek neukazuje – prázdný by mátl.
    @ViewBuilder
    private var memoryRing: some View {
        let limit = MemoryBudget.appLimit
        if limit > 0 {
            // Podíl se neořezává: přes sto procent znamená, že je model nad stropem,
            // a to je zrovna ten stav, kvůli kterému se sem člověk dívá. Oblouk víc
            // než celý kruh nakreslit neumí, číslo ano.
            let share = Double(MemoryBudget.footprint) / Double(limit)
            GaugeRing(
                fraction: min(1, share),
                pending: min(1, share),
                tint: share < 0.75 ? .accentColor : (share < 0.9 ? .orange : .red),
                label: "\(Int((share * 100).rounded()))"
            )
        }
    }

    /// „5,9k / 8,2k“ = zbývá / okno. Bez známého okna jen obsazeno.
    private var compactLabel: String {
        guard let window, let remaining else {
            return used > 0 ? "\(used.compactFormatted) tok." : "–"
        }
        return "\(remaining.compactFormatted) / \(window.compactFormatted)"
    }

    private var accessibilityText: String {
        guard let window, let remaining else { return "obsazeno \(used) tokenů" }
        return "zbývá \(remaining) z \(window) tokenů"
    }

    // MARK: - Podrobnosti

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kontext").font(.headline)
                Spacer()
                if window != nil {
                    Text("\(Int((fraction(used) * 100).rounded())) %")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }

            bar

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Obsazeno", used)
                if let remaining { row("Zbývá", remaining, emphasized: true) }
                if let window { row("Okno kontextu", window) }
                if let usage {
                    GridRow {
                        Text("Poslední odpověď").foregroundStyle(.secondary)
                        Text(usage.maxOutputTokens.map { "\(usage.outputTokens.formatted()) / max \($0.formatted())" }
                             ?? usage.outputTokens.formatted())
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                }
                if pending > 0 { row("Rozepsaná zpráva", pending, approximate: true) }
            }
            .font(.subheadline)

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.provider == .local || settings.provider == .apple {
                Divider()
                profileRow
            }

            Divider()

            MemoryUsageView(isLocal: settings.provider == .local, isGenerating: chat.isGenerating)
        }
        .padding(18)
        .frame(width: 300)
    }

    /// Režim, ve kterém poběží další odpověď (a v jakém běžela poslední).
    private var profileRow: some View {
        let next = chat.profile(settings: settings)
        let automatic = settings.local.profileMode == .automatic

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(next.title, systemImage: next.symbol)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if automatic {
                    Text("automaticky")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(parametersSummary(next))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if automatic, chat.pendingTokens > 0, next == .summarize || next == .extract {
                Text(chat.attachments.isEmpty && chat.draft.count >= TaskProfile.longInputCharacters
                     ? "Dlouhý vložený text appka bere jako práci s dokumentem."
                     : "Podle zadání ve zprávě.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if automatic, let last = chat.lastProfile, last != next {
                Text("Poslední odpověď běžela v režimu \(last.title) – režim se mění u každé zprávy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func parametersSummary(_ profile: TaskProfile) -> String {
        let values = settings.local.parameters(for: profile)
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        // Apple Intelligence přebírá jen teplotu, ostatní parametry nenastavuje.
        guard settings.provider == .local else {
            return "teplota \(values.temperature.formatted(number))"
        }
        return "teplota \(values.temperature.formatted(number)) · top-P \(values.topP.formatted(number)) · min-P \(values.minP.formatted(number)) · top-K \(values.topK) · opak. \(values.repeatPenalty.formatted(number))"
    }

    /// Vodorovný pruh se stejnými vrstvami jako kroužek.
    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint.opacity(0.35))
                    .frame(width: geometry.size.width * fraction(used + pending))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * fraction(used))
            }
        }
        .frame(height: 8)
    }

    private func row(_ title: String, _ value: Int, emphasized: Bool = false, approximate: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text((approximate ? "≈ " : "") + value.formatted())
                .fontWeight(emphasized ? .semibold : .regular)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if usage?.isEstimate == true {
            notes.append("Počty jsou odhad (~3 znaky na token) – přesné ukáže další odpověď.")
        }
        if usage?.droppedHistory == true {
            notes.append("Nejstarší zprávy se už do kontextu nevešly, model je při poslední odpovědi neviděl.")
        }
        if let model = usage?.modelContextWindow, let window, model > window {
            notes.append("Okno omezuje tarif účtu (vstupní tokeny za minutu) – model sám zvládne \(model.formatted()) tokenů. Limity najdeš v nastavení \(settings.provider.title).")
        }
        if settings.provider == .local, let limited = LocalRuntime.shared.memoryLimitedContext,
           limited < settings.local.contextLength {
            notes.append("Okno je kvůli paměti zkrácené z \(settings.local.contextLength.formatted()) tokenů.")
        }
        if settings.provider == .local || settings.provider == .apple {
            notes.append("Na odpověď se rezervuje místo podle Max. délky odpovědi. Když se konverzace nevejde, nejstarší zprávy se vynechají a přílohy zkrátí.")
        }
        if usage == nil, window == nil {
            notes.append("Počet tokenů se ukáže po první odpovědi.")
        }
        return notes
    }
}

/// Aktuální využití paměti appky – obnovuje se každou sekundu, dokud je popover otevřený.
///
/// „Zabráno“ je phys_footprint (to, podle čeho iOS appku ukončí), limit = zabráno + ještě
/// volné (`os_proc_available_memory`). U lokálního modelu v tom jsou váhy i KV cache.
struct MemoryUsageView: View {
    let isLocal: Bool
    let isGenerating: Bool
    @State private var isUnloading = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let used = MemoryBudget.footprint
            let limit = MemoryBudget.appLimit
            let fraction = limit > 0 ? min(1, Double(used) / Double(limit)) : 0
            let tint: Color = fraction < 0.75 ? .accentColor : (fraction < 0.9 ? .orange : .red)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Paměť").font(.headline)
                    Spacer()
                    if limit > 0 {
                        Text("\(Int((fraction * 100).rounded())) %")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .contentTransition(.numericText())
                    }
                }

                if limit > 0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(tint)
                                .frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 8)
                    .animation(.smooth, value: fraction)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    memoryRow("Appka zabírá", used, emphasized: true)
                    if let mlx = MemoryBudget.mlxMemory {
                        memoryRow("z toho MLX", mlx.active)
                        // Zobrazuje se i při nule – mizející řádek posouvá celou tabulku.
                        memoryRow("MLX cache", mlx.cache)
                    }
                    if limit > 0 {
                        memoryRow("Volné do limitu", max(0, limit - used))
                        memoryRow("Limit appky", limit)
                    }
                    memoryRow("RAM zařízení", MemoryBudget.deviceMemory)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)

                Text(note(fraction: fraction, limit: limit))
                    .font(.caption)
                    .foregroundStyle(fraction >= 0.9 ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Lokální model zůstává načtený mezi odpověďmi (i po přepnutí na cloud).
                Button {
                    isUnloading = true
                    Task {
                        await LlamaEngine.shared.unload()
                        await MLXEngine.shared.unload()
                        isUnloading = false
                    }
                } label: {
                    HStack {
                        Label("Uvolnit lokální model", systemImage: "memorychip")
                        if isUnloading {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .font(.subheadline)
                .disabled(isGenerating || isUnloading)
            }
        }
    }

    /// Číslo a jednotka jdou do vlastních sloupců: `ByteCountFormatter` střídá GB a MB
    /// i počet desetinných míst, takže zarovnaný na jeden sloupec vypadá text rozskákaně.
    private func memoryRow(_ title: String, _ bytes: Int, emphasized: Bool = false) -> some View {
        let amount = Self.amount(bytes)
        return GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(amount.value)
                .fontWeight(emphasized ? .semibold : .regular)
                .monospacedDigit()
                .contentTransition(.numericText())
                .gridColumnAlignment(.trailing)
            Text(amount.unit)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
        }
    }

    /// Nad gigabajt se zaokrouhluje na dvě desetinná místa, pod ním na jedno –
    /// v obou případech pevně, ať mají všechny řádky stejnou šířku čísla.
    private static func amount(_ bytes: Int) -> (value: String, unit: String) {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 {
            return (gigabytes.formatted(.number.precision(.fractionLength(2))), "GB")
        }
        let megabytes = Double(bytes) / 1_048_576
        return (megabytes.formatted(.number.precision(.fractionLength(1))), "MB")
    }

    private func note(fraction: Double, limit: Int) -> String {
        if limit == 0 {
            return "Limit paměti tady nejde zjistit (simulátor)."
        }
        if fraction >= 0.9 {
            return "Appka je těsně pod limitem – při delším textu ji iOS může ukončit. Zkrať kontext nebo použij menší model."
        }
        return isLocal
            ? "Lokální model zabírá paměť appky (váhy + kontext). Když se limit blíží, appka kontext sama zkrátí. Po uvolnění se model při další zprávě znovu načte."
            : "Načtený lokální model zůstává v paměti i při použití cloudu – uvolnit ho jde tlačítkem níže."
    }
}

/// Kroužek s číslem uvnitř. Světlejší oblouk je odhad po odeslání rozepsané zprávy,
/// plný je skutečnost.
private struct GaugeRing: View {
    let fraction: Double
    let pending: Double
    let tint: Color
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: pending)
                .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .rotationEffect(.degrees(-90))
        .overlay {
            // Popisek se otáčet nesmí, proto je v overlay a ne uvnitř otočeného ZStacku.
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(fraction >= 0.9 ? tint : .primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: 26, height: 26)
        .animation(.smooth, value: pending)
        .animation(.smooth, value: fraction)
    }
}
