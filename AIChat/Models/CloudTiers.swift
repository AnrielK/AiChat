import Foundation

/// Limity tarifu za minutu.
struct TierLimits: Equatable, Sendable {
    let inputPerMinute: Int
    let outputPerMinute: Int?
    let requestsPerMinute: Int?
}

/// Tarif Claude API. Od 26. 6. 2026 Anthropic místo Tier 1–4 používá Start, Build, Scale
/// a Custom; nové organizace můžou začínat v tarifu Evaluation s nižšími, nezveřejněnými limity.
enum ClaudeTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, evaluation, start, build, scale, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automaticky"
        case .evaluation: "Evaluation"
        case .start: "Start"
        case .build: "Build"
        case .scale: "Scale"
        case .custom: "Custom"
        }
    }

    /// Standardní limity podle tabulky na platform.claude.com/docs/en/api/rate-limits
    /// (stav září 2026). Limity jsou po rodinách modelů: Fable/Mythos, Haiku 3.5 a zbytek
    /// (Opus 4.x/5, Sonnet 4.x/5, Haiku 4.5). nil = tarif limity nezveřejňuje.
    func limits(model: String) -> TierLimits? {
        let id = model.lowercased()
        let family: Family = if id.contains("fable") || id.contains("mythos") {
            .fable
        } else if id.contains("haiku-3-5") || id.contains("3-5-haiku") {
            .haiku35
        } else {
            .standard
        }

        switch (self, family) {
        case (.start, .standard): return TierLimits(inputPerMinute: 2_000_000, outputPerMinute: 400_000, requestsPerMinute: 1_000)
        case (.start, .fable): return TierLimits(inputPerMinute: 500_000, outputPerMinute: 100_000, requestsPerMinute: 1_000)
        case (.start, .haiku35): return TierLimits(inputPerMinute: 100_000, outputPerMinute: 20_000, requestsPerMinute: 1_000)
        case (.build, .standard): return TierLimits(inputPerMinute: 5_000_000, outputPerMinute: 1_000_000, requestsPerMinute: 5_000)
        case (.build, .fable): return TierLimits(inputPerMinute: 1_500_000, outputPerMinute: 300_000, requestsPerMinute: 2_000)
        case (.build, .haiku35): return TierLimits(inputPerMinute: 200_000, outputPerMinute: 40_000, requestsPerMinute: 2_000)
        case (.scale, .standard): return TierLimits(inputPerMinute: 10_000_000, outputPerMinute: 2_000_000, requestsPerMinute: 10_000)
        case (.scale, .fable): return TierLimits(inputPerMinute: 4_000_000, outputPerMinute: 800_000, requestsPerMinute: 4_000)
        case (.scale, .haiku35): return TierLimits(inputPerMinute: 400_000, outputPerMinute: 80_000, requestsPerMinute: 4_000)
        case (.automatic, _), (.evaluation, _), (.custom, _): return nil
        }
    }

    var note: String {
        switch self {
        case .automatic: "Limity se zjistí z hlaviček odpovědí API (stačí Otestovat připojení)."
        case .evaluation: "Nový účet s nižšími limity, které Anthropic nezveřejňuje – přesný limit vstupu opiš z Console › Settings › Limits, jinak se zjistí z odpovědí API."
        case .custom: "Limity sjednané s Anthropicem – opiš je z Console › Settings › Limits, jinak se zjistí z odpovědí API."
        default: "Standardní limity tarifu podle dokumentace Anthropic."
        }
    }

    private enum Family { case standard, fable, haiku35 }
}

/// Tarif Gemini API (usage tier projektu v AI Studiu).
enum GeminiTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, free, tier1, tier2, tier3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automaticky"
        case .free: "Free"
        case .tier1: "Tier 1"
        case .tier2: "Tier 2"
        case .tier3: "Tier 3"
        }
    }

    /// Google limity po modelech už v dokumentaci neuvádí – jsou jen v AI Studiu
    /// (Rate limit). Tohle jsou orientační hodnoty vstupních tokenů za minutu pro modely
    /// Flash; placené tarify stejně převyšují okno modelu (1M tokenů), takže kontext
    /// reálně omezuje jen Free. Přesnou hodnotu lze zadat ručně.
    var limits: TierLimits? {
        switch self {
        case .automatic: nil
        case .free: TierLimits(inputPerMinute: 250_000, outputPerMinute: nil, requestsPerMinute: nil)
        case .tier1: TierLimits(inputPerMinute: 1_000_000, outputPerMinute: nil, requestsPerMinute: nil)
        case .tier2: TierLimits(inputPerMinute: 3_000_000, outputPerMinute: nil, requestsPerMinute: nil)
        case .tier3: TierLimits(inputPerMinute: 8_000_000, outputPerMinute: nil, requestsPerMinute: nil)
        }
    }

    var note: String {
        switch self {
        case .automatic: "Gemini limity dopředu neprozradí – zjistí se z první chyby překročení limitu (429)."
        case .free: "Free tier má nízký limit tokenů za minutu – velké přílohy se zkrátí. Přesnou hodnotu pro svůj model najdeš v AI Studiu › Rate limit."
        default: "Placený tarif: limit za minutu je vyšší než okno modelu, kontext omezuje jen model. Přesné hodnoty jsou v AI Studiu › Rate limit."
        }
    }
}
