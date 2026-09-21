import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anything that can turn a prompt into text. In AIChat this wraps the existing MLX / llama.cpp
/// backend (see Integration/AIChatEngineAdapter.swift); on a Mac it can be LM Studio / Ollama /
/// mlx-lm server through `OpenAICompatibleEngine`.
public protocol LLMEngine: Sendable {
    /// Context size the engine can handle (prompt + output), in tokens.
    var contextTokens: Int { get }
    /// true = the engine turns reasoning off itself (AIChat providers with reasoningOverride),
    /// so Summarizer does not append the "/no_think" hint.
    var handlesThinking: Bool { get }
    func generate(system: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String
}

public extension LLMEngine {
    var contextTokens: Int { 16_384 }
    var handlesThinking: Bool { false }
}

/// OpenAI-compatible /v1/chat/completions (mlx_lm.server, llama-server, LM Studio, Ollama, vLLM).
public struct OpenAICompatibleEngine: LLMEngine {
    public let baseURL: URL          // e.g. http://192.168.1.10:8080/v1
    public let model: String
    public let apiKey: String?
    public let contextTokens: Int
    let http: HTTP

    public init(baseURL: URL, model: String, apiKey: String? = nil, contextTokens: Int = 32_768,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.contextTokens = contextTokens
        self.http = HTTP(session: session)
    }

    public func generate(system: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await http.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            throw NSError(domain: "OpenAICompatibleEngine", code: resp.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (json?["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        return (message?["content"] as? String) ?? ""
    }
}

public enum LLMOutput {
    /// Removes `<think>…</think>` blocks of reasoning models (Qwen3, distills) and trims.
    public static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: [.regularExpression])
        if let open = t.range(of: "<think>") { t = String(t[..<open.lowerBound]) } // unterminated (hit max tokens)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rough token estimate for English filings (~4 chars/token).
    public static func estimateTokens(_ s: String) -> Int { s.utf8.count / 4 }
}
