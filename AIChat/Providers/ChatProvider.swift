import Foundation

/// Jeden kousek streamované odpovědi.
enum StreamEvent: Sendable {
    /// Text odpovědi.
    case text(String)
    /// Přemýšlení modelu (reasoning).
    case reasoning(String)
    /// Hlášení o průběhu vícekolového zpracování (`SummaryPipeline`). Není to výstup
    /// modelu – kdyby šlo kanálem `reasoning`, UI to nadepíše „Přemýšlím…“ a vypadá to,
    /// že model přemýšlí i s vypnutým přemýšlením.
    case status(String)
    /// Dosavadní text byl ve skutečnosti přemýšlení – šablona otevřela `<think>`
    /// už v promptu a model poslal jen uzavírací `</think>`.
    case promoteTextToReasoning
    /// Obsazení kontextu – posílá se na začátku odpovědi a průběžně, jak přibývají tokeny.
    case usage(TokenUsage)
    /// Úryvky podkladů, ze kterých odpověď vzniká (`RetrievalPipeline`). Uloží se ke zprávě,
    /// aby šlo i později zkontrolovat, odkud model bral.
    case sources([MessageSource])
}

/// Kolik tokenů zabrala konverzace a kolik se jich do kontextu vejde.
struct TokenUsage: Codable, Hashable, Sendable {
    /// Prompt – systémový prompt, historie a přílohy tak, jak je model opravdu dostal.
    var promptTokens: Int
    /// Odpověď včetně přemýšlení.
    var outputTokens: Int
    /// Kontextové okno (u lokálních modelů po zkrácení podle paměti). nil = neznámé.
    var contextWindow: Int?
    /// Nejdelší možná odpověď (max_tokens).
    var maxOutputTokens: Int?
    /// Jen odhad z počtu znaků (Apple Intelligence, starší konverzace).
    var isEstimate = false
    /// Nejstarší zprávy se už nevešly a model je neviděl.
    var droppedHistory = false
    /// Okno samotného modelu, když je `contextWindow` menší kvůli tarifu (tokeny za minutu).
    var modelContextWindow: Int?

    var used: Int { promptTokens + outputTokens }
}

/// Společné rozhraní všech zdrojů odpovědí.
protocol ChatProvider: Sendable {
    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error>

    /// Kopie, která přestane generovat na některé ze značek. Výchozí implementaci
    /// dodává `StoppingProvider`; engine, který to umí sám, si ji přebije.
    func stopping(at sequences: [String]) -> any ChatProvider

    /// Kopie se zapnutým nebo vypnutým přemýšlením. U vnitřních kol, kde má model
    /// napsat jediný řádek, je přemýšlení jen zdržení. Poskytovatelé, kteří ho neřídí
    /// (cloudové), vrátí sami sebe.
    func thinking(_ enabled: Bool) -> any ChatProvider

    /// Varianta pro jednorázové vnitřní kolo – dílčí shrnutí kapitoly, prompt
    /// s vyhledanými podklady. Takový prompt se v příští zprávě neopakuje, takže
    /// si engine nemá co držet a KV cache by jen zabírala paměť.
    func oneShot() -> any ChatProvider
}

extension ChatProvider {
    /// Engine bez stavu mezi zprávami se jednorázovým kolem nijak neliší.
    func oneShot() -> any ChatProvider { self }
}

/// Model nabízený v účtu u cloudové služby.
struct RemoteModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum ProviderError: LocalizedError {
    case notConfigured(String)
    case unavailable(String)
    case engine(String)
    case api(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message), .unavailable(let message), .engine(let message):
            message
        case .api(let message):
            "Chyba služby: \(message)"
        case .http(let status, let message):
            "Chyba \(status): \(message)"
        }
    }
}

/// Pomocné funkce pro streamované HTTP (Server-Sent Events).
enum HTTPStreaming {
    /// Otevře streamované spojení; u chybového stavu přečte tělo a vyhodí srozumitelnou chybu.
    /// `inspect` dostane odpověď (a u chyby i tělo) – odtud se čtou limity tarifu.
    static func open(
        _ request: URLRequest,
        inspect: (@Sendable (HTTPURLResponse, Data?) async -> Void)? = nil
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { return bytes }
        guard !(200..<300).contains(http.statusCode) else {
            await inspect?(http, nil)
            return bytes
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 64_000 { break }
        }
        await inspect?(http, data)

        var message = errorMessage(from: data)
        if http.statusCode == 429, let retry = http.value(forHTTPHeaderField: "retry-after") {
            message += " Zkus to znovu za \(retry) s."
        }
        throw ProviderError.http(status: http.statusCode, message: message)
    }

    /// Obyčejný GET/POST s JSON odpovědí.
    static func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, message: errorMessage(from: data))
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Payload řádku `data: {...}` jako slovník.
    static func event(fromLine line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Claude i Gemini vrací chybu jako `{"error": {"message": "..."}}` (Gemini někdy v poli).
    static func errorMessage(from data: Data) -> String {
        let root = try? JSONSerialization.jsonObject(with: data)
        if let object = (root as? [String: Any]) ?? (root as? [[String: Any]])?.first,
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        return text.isEmpty ? "Server neposlal žádnou zprávu." : text
    }
}
