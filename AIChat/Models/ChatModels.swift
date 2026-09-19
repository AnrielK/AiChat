import Foundation
import SwiftData

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

/// Jedna konverzace v historii.
@Model
final class Conversation {
    var id: UUID = UUID()
    var title: String = "Nový chat"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var providerRaw: String = "local"
    var modelName: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(provider: AIProvider, modelName: String) {
        self.providerRaw = provider.rawValue
        self.modelName = modelName
    }

    var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .local }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var roleRaw: String = "user"
    var text: String = ""
    /// Přemýšlení modelu (reasoning). Zobrazuje se sbalené, zpět modelu se neposílá.
    var reasoning: String = ""
    /// Průběh vícekolového zpracování dokumentu. Zobrazuje se zvlášť od přemýšlení.
    var status: String = ""
    var createdAt: Date = Date.now
    var conversation: Conversation?
    /// Přílohy jako JSON `[Attachment]` (metadata + vytažený text); originály jsou v `AttachmentStore`.
    /// Nový volitelný atribut – SwiftData starší databázi převede sama.
    var attachmentsData: Data?
    /// Obsazení kontextu po této odpovědi (JSON `TokenUsage`), jen u odpovědí asistenta.
    var usageData: Data?
    /// Úryvky podkladů (JSON `[MessageSource]`), na které se odpověď odkazuje čísly v závorkách.
    /// Volitelný atribut – SwiftData starší databázi převede sama.
    var sourcesData: Data?
    /// Režim (`TaskProfile`), ve kterém odpověď vznikla – navazující dotazy se ho drží.
    var profileRaw: String?
    /// Jak dlouho odpověď vznikala (sekundy od založení zprávy po poslední token).
    /// Jen u odpovědí asistenta; `nil` = přerušeno nebo starší konverzace.
    /// Volitelný atribut – SwiftData starší databázi převede sama.
    var generationSeconds: Double?

    init(role: ChatRole, text: String) {
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = .now
    }

    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .user }
}

/// Odlehčená, vláknově bezpečná kopie zprávy, která se posílá poskytovateli.
struct ChatTurn: Sendable {
    let role: ChatRole
    let text: String
    /// Přílohy zprávy. Poskytovatelé je buď vloží do textu (`inliningAttachments`),
    /// nebo pošlou jako obrázek / dokument (Claude, Gemini).
    var attachments: [Attachment] = []

    /// Kopie s textem zkráceným na `characters` znaků. Zkracuje se konec, aby zůstal
    /// začátek zprávy (zadání), a doplní se značka, ať model ví, že text není celý.
    func prefixed(characters: Int) -> ChatTurn {
        guard text.count > characters else { return self }
        let cut = String(text.prefix(characters))
        return ChatTurn(role: role, text: cut + "\n\n[…zkráceno, nevešlo se do kontextu]", attachments: attachments)
    }

    /// Zahodí prázdné zprávy, slepí po sobě jdoucí zprávy stejné role
    /// a zajistí, že konverzace začíná uživatelem (vyžaduje to Claude i šablony llama.cpp).
    static func normalized(_ turns: [ChatTurn]) -> [ChatTurn] {
        var result: [ChatTurn] = []
        for turn in turns where !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !turn.attachments.isEmpty {
            if let last = result.last, last.role == turn.role {
                let text = [last.text, turn.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                result[result.count - 1] = ChatTurn(role: turn.role, text: text, attachments: last.attachments + turn.attachments)
            } else {
                result.append(turn)
            }
        }
        while result.first?.role == .assistant { result.removeFirst() }
        return result
    }
}
