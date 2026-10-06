import Foundation
import SwiftData

/// Jeden trénovací vzorek: zadání, odpověď lokálního modelu a oprava od učitele
/// (Claude / Gemini). Do tréninku jde `prompt` + `teacherAnswer`; odpověď lokálního
/// modelu se nechává kvůli porovnání, ať je vidět, co se vlastně opravilo.
@Model
final class TrainingSample {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    /// Zadání uživatele tak, jak ho model dostal.
    var prompt: String = ""
    /// Co odpověděl lokální model.
    var localAnswer: String = ""
    /// Odpověď, kterou měl podle učitele dát. Tahle se trénuje.
    var teacherAnswer: String = ""
    /// Hodnocení odpovědi lokálního modelu učitelem, 0–10.
    var score: Int = 0
    /// Který učitel vzorek vytvořil (např. „claude-sonnet-5“).
    var teacherModel: String = ""
    /// Pro který lokální model vzorek vznikl („mlx:…“).
    var modelID: String = ""
    /// Zařadit do tréninku? Vypnuté vzorky zůstanou uložené, ale nepoužijí se.
    var isApproved: Bool = true

    init(
        prompt: String,
        localAnswer: String,
        teacherAnswer: String,
        score: Int,
        teacherModel: String,
        modelID: String
    ) {
        self.prompt = prompt
        self.localAnswer = localAnswer
        self.teacherAnswer = teacherAnswer
        self.score = score
        self.teacherModel = teacherModel
        self.modelID = modelID
        self.createdAt = .now
    }
}

extension TrainingSample {
    /// Vzorek z importu datasetu (`hf:<dataset>` / `file:<soubor>`), ne od učitele.
    var isImported: Bool {
        teacherModel.hasPrefix("hf:") || teacherModel.hasPrefix("file:")
    }

    /// Čitelný název zdroje pro menu a dialogy.
    static func sourceLabel(_ source: String) -> String {
        if source.hasPrefix("hf:") { return String(source.dropFirst(3)) }
        if source.hasPrefix("file:") { return "soubor " + String(source.dropFirst(5)) }
        return source
    }
}

/// Kopie vzorku, která se dá poslat mimo hlavní vlákno. SwiftData modely
/// `Sendable` nejsou, a trénink běží v actoru.
struct TrainingSampleData: Sendable, Identifiable {
    let id: UUID
    let prompt: String
    let answer: String

    init(_ sample: TrainingSample) {
        id = sample.id
        prompt = sample.prompt
        answer = sample.teacherAnswer
    }
}
