import Foundation
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif

/// Hotová trénovací data: `LoRATrain` bere pole hotových textů, ne zpráv.
struct TrainingDataset: Sendable {
    var train: [String] = []
    var validate: [String] = []
    /// Vzorky, které se nevešly do `maxTokens` nebo se nepodařilo složit.
    var skipped = 0

    var count: Int { train.count + validate.count }
}

#if canImport(MLXLMCommon)
enum TrainingDatasetBuilder {
    /// Složí vzorky do textů přesně v tom tvaru, v jakém model text vidí při generování.
    ///
    /// Šablona se aplikuje **jen na prompt** (se značkou pro začátek odpovědi) a odpověď
    /// se připojí za ni. Kdyby se šablona pustila na celou konverzaci včetně odpovědi,
    /// přidala by za ni ještě prázdnou hlavičku asistenta (`add_generation_prompt`)
    /// a model by se učil na tvaru, který při generování nikdy neuvidí.
    ///
    /// - Note: `LoRATrain.loss` maskuje ztrátu jen podle délky vzorku, ne podle hranice
    ///   mezi zadáním a odpovědí – model se tedy učí i na promptu. Pro doladění stylu
    ///   to nevadí; kdyby vadilo, musel by se vzorek dávkovat vlastním iterátorem.
    static func make(
        samples: [TrainingSampleData],
        systemPrompt: String,
        reasoning: Bool,
        tokenizer: Tokenizer,
        maxTokens: Int,
        validationShare: Double = 0.15
    ) -> TrainingDataset {
        var texts: [String] = []
        var skipped = 0

        for sample in samples {
            guard let text = render(
                sample, systemPrompt: systemPrompt, reasoning: reasoning, tokenizer: tokenizer
            ) else {
                skipped += 1
                continue
            }
            // Delší vzorek = vyšší špička paměti při backward průchodu. Radši zahodit
            // než shodit appku uprostřed tréninku.
            guard tokenizer.encode(text: text).count <= maxTokens else {
                skipped += 1
                continue
            }
            texts.append(text)
        }

        var dataset = TrainingDataset()
        dataset.skipped = skipped
        guard !texts.isEmpty else { return dataset }

        // Validační část se bere z konce (nejnovější vzorky), ať je rozdělení stabilní
        // mezi běhy – náhodné by u malého datasetu pokaždé měnilo validační ztrátu.
        let validationCount = min(
            max(1, Int(Double(texts.count) * validationShare)),
            max(0, texts.count - 1)
        )
        dataset.validate = Array(texts.suffix(validationCount))
        dataset.train = Array(texts.prefix(texts.count - validationCount))
        return dataset
    }

    private static func render(
        _ sample: TrainingSampleData,
        systemPrompt: String,
        reasoning: Bool,
        tokenizer: Tokenizer
    ) -> String? {
        let prompt = sample.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = sample.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !answer.isEmpty else { return nil }

        var messages: [[String: any Sendable]] = []
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        guard let ids = try? tokenizer.applyChatTemplate(
            messages: messages,
            tools: nil,
            additionalContext: ["enable_thinking": reasoning]
        ) else { return nil }

        let rendered = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
        // U instrukčních modelů je `eosToken` zároveň značka konce odpovědi
        // (u Qwenu `<|im_end|>`), takže se model naučí odpověď i ukončit.
        return rendered + answer + (tokenizer.eosToken ?? "")
    }
}
#endif
