import Foundation

/// Učitel: cloudový model dostane zadání a odpověď lokálního modelu, vrátí známku
/// a odpověď, jakou měl lokální model dát. Z toho vznikne trénovací vzorek.
///
/// Běží to jako vědomá dávka ze záložky Trénink, ne u každé zprávy – tak se platí
/// za API jen tehdy, když se dataset opravdu doplňuje, a dá se vybrat, co má smysl.
enum TeacherCapture {
    /// Dvojice zadání + odpověď vytažená z historie chatů.
    struct Pair: Sendable, Identifiable, Hashable {
        let id: UUID
        let prompt: String
        let localAnswer: String
        let conversationTitle: String
        let modelID: String
        let date: Date
    }

    struct Verdict: Sendable {
        let score: Int
        let answer: String
    }

    enum CaptureError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let text):
                "Odpověď učitele nejde přečíst: \(text)"
            }
        }
    }

    /// Instrukce pro učitele. Odpověď se čte jako JSON – učitel je velký model,
    /// na rozdíl od lokálního 4B ho formát netrápí.
    private static func instruction(for pair: Pair) -> String {
        """
        Jsi hodnotitel odpovědí menšího jazykového modelu, který běží na telefonu.
        Dostaneš zadání uživatele a odpověď, kterou model dal.

        Vrať POUZE JSON, bez úvodu, bez komentáře a bez značek ```:
        {"score": <celé číslo 0–10>, "answer": "<odpověď, jakou měl model dát>"}

        score = jak dobrá byla odpověď modelu (10 = nemám co vytknout).
        answer = nejlepší odpověď na zadání. Piš ji tak, jak by ji měl psát ten model:
        stejným jazykem jako zadání, věcně, bez omluv a bez zmínek o tom, že něco opravuješ.
        Když byla odpověď modelu správná, zopakuj ji v answer beze změny.

        ### Zadání
        \(pair.prompt)

        ### Odpověď modelu
        \(pair.localAnswer)
        """
    }

    static func evaluate(_ pair: Pair, teacher: any ChatProvider) async throws -> Verdict {
        var text = ""
        for try await event in teacher.oneShot().stream([ChatTurn(role: .user, text: instruction(for: pair))]) {
            if case .text(let piece) = event { text += piece }
        }
        return try parse(text)
    }

    /// Učitel občas JSON přece jen zabalí do ``` nebo přidá větu navíc – bere se
    /// text mezi první `{` a poslední `}`.
    static func parse(_ raw: String) throws -> Verdict {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw CaptureError.unreadable(String(raw.prefix(200)))
        }
        let json = String(raw[start ... end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = object["answer"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CaptureError.unreadable(String(json.prefix(200)))
        }
        let score = (object["score"] as? NSNumber)?.intValue ?? Int(object["score"] as? String ?? "") ?? 0
        return Verdict(score: max(0, min(10, score)), answer: answer)
    }
}
