import Foundation
import Observation
import os
#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import MLXHuggingFace
import Tokenizers
#endif

/// Parametry tréninku. Výchozí hodnoty jsou proti těm z `LoRATrain.Parameters`
/// posunuté k telefonu: dávka 1 (iterátor paduje na nejdelší vzorek v dávce, takže
/// jeden dlouhý vzorek jinak nafoukne celou dávku) a časté ukládání, protože iOS
/// appku na pozadí ukončí a rozdělaný běh by se ztratil.
struct TrainingConfiguration: Codable, Equatable, Sendable {
    var iterations = 200
    var batchSize = 1
    /// Kolik posledních vrstev dostane adaptér. Míň vrstev = míň paměti i času.
    var numLayers = 8
    var rank = 8
    var scale: Float = 20
    var learningRate: Float = 1e-4
    var saveEvery = 20
    var stepsPerEval = 50
    /// Vzorky delší než tohle se do tréninku nezařadí.
    var maxSampleTokens = 256

    static let storageKey = "training.configuration"

    static func load() -> TrainingConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(TrainingConfiguration.self, from: data)
        else { return TrainingConfiguration() }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Žádost o zastavení. Čte se ze synchronního callbacku uvnitř `LoRATrain.train`,
/// tedy mimo hlavní vlákno a mimo actor – proto zámek, ne `@Observable` vlastnost.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        value = false
    }
}

/// Fáze běhu uložená na disk. Když proces ukončí systém kvůli paměti, nezůstane
/// po něm ani výjimka, ani záznam – tohle je jediná stopa, která pád přežije.
enum TrainingPhase: String, Codable, Sendable {
    case idle
    case loadingModel
    case preparingData
    case applyingAdapter
    case checkingModel
    case tokenizing
    case forward
    case backward
    case optimizerStep
    case firstStep
    case training
    case saving
    case finished

    var label: String {
        switch self {
        case .idle: "nezačalo"
        case .loadingModel: "načítání modelu"
        case .preparingData: "příprava vzorků"
        case .applyingAdapter: "vkládání adaptéru"
        case .checkingModel: "kontrola modelu"
        case .tokenizing: "tokenizace vzorku"
        case .forward: "dopředný průchod"
        case .backward: "zpětný průchod"
        case .optimizerStep: "krok optimizeru"
        case .firstStep: "první krok tréninku"
        case .training: "trénink"
        case .saving: "ukládání adaptéru"
        case .finished: "dokončeno"
        }
    }

    private static let key = "training.phase"

    static var last: TrainingPhase {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .idle }
        return TrainingPhase(rawValue: raw) ?? .idle
    }

    /// Zápis se vynucuje hned. Běžné odložené uložení by pád nepřežilo.
    static func mark(_ phase: TrainingPhase) {
        UserDefaults.standard.set(phase.rawValue, forKey: key)
        UserDefaults.standard.synchronize()
    }
}

/// Odhad špičky paměti při tréninku.
///
/// Drtivou většinu nesou logity. Model je spočítá pro každou pozici přes celý
/// slovník a `LoRATrain.loss` je navíc převede na float32, takže vedle sebe leží
/// původní i převedené pole plus mezivýsledky křížové entropie – a autodiff si
/// je všechny drží až do konce zpětného průchodu. U slovníku se 150 tisíci
/// položkami to při 640 tokenech dělá přes gigabajt, který vznikne během
/// jediného kroku. Proto je délka vzorku ten parametr, na kterém tu všechno visí.
enum TrainingEstimate {
    struct Facts: Sendable {
        var vocabSize = 0
        var weightsBytes = 0
        var modelType = ""
        /// Model má směs expertů (`SwitchGLU`).
        var isMixtureOfExperts = false
        /// Model má vrstvy s lineární pozorností (`GatedDeltaNet`).
        var hasLinearAttention = false

        /// Proč tenhle model natrénovat nejde, nebo nil, když jde.
        ///
        /// Obojí projde dopředným průchodem, ale zpětným ne: směs expertů
        /// se u kvantovaného modelu počítá přes `gather_qmm`, ke kterému MLX
        /// nemá definovaný gradient, a rekurentní gatedDelta vrstva na tom je
        /// stejně. Výsledkem je výjimka z C++ vrstvy, kterou Swift neodchytí –
        /// proces prostě skončí.
        var trainingBlocker: String? {
            if isMixtureOfExperts {
                return "Model má směs expertů (MoE). Zpětný průchod přes kvantované experty MLX neumí, takže trénink aplikaci ukončí."
            }
            if hasLinearAttention {
                return "Model má vrstvy s lineární pozorností. Zpětný průchod přes ně MLX neumí, takže trénink aplikaci ukončí."
            }
            return nil
        }
    }

    static func facts(modelDirectory: URL) -> Facts {
        var facts = Facts()
        if let data = try? Data(contentsOf: modelDirectory.appending(path: "config.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = (object["text_config"] as? [String: Any]) ?? object
            facts.vocabSize = (object["vocab_size"] as? NSNumber)?.intValue
                ?? (text["vocab_size"] as? NSNumber)?.intValue
                ?? 0
            facts.modelType = (object["model_type"] as? String) ?? ""
            // MoE a lineární pozornost poznáme z konfigurace dřív, než se cokoli načte.
            let moeKeys = ["num_experts", "n_routed_experts", "moe_intermediate_size", "num_local_experts"]
            facts.isMixtureOfExperts = moeKeys.contains { text[$0] != nil || object[$0] != nil }
                || facts.modelType.lowercased().contains("moe")
            let linearKeys = ["linear_attn_layers", "layer_types", "linear_conv_kernel_dim", "full_attention_interval"]
            facts.hasLinearAttention = linearKeys.contains { text[$0] != nil || object[$0] != nil }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        facts.weightsBytes = files
            .filter { $0.pathExtension.lowercased() == "safetensors" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return facts
    }

    /// Vrstva, přes kterou MLX neumí spočítat gradient – zjištěno ze skutečných
    /// modulů načteného modelu, ne z konfigurace. Dopředný průchod přes ně funguje,
    /// zpětný skončí výjimkou z C++ vrstvy, kterou Swift neodchytí.
    static func unsupportedLayer(in model: Module) -> String? {
        let names = ["SwitchGLU", "GatedDeltaNet", "MoeBlock"]
        for (_, module) in model.namedModules() {
            let type = String(describing: type(of: module))
            if names.contains(where: { type.contains($0) }) {
                return "Model obsahuje vrstvu \(type), přes kterou MLX neumí spočítat gradient. Trénink by aplikaci ukončil. Vyber hustý model bez MoE – například Qwen3-4B-4bit."
            }
        }
        return nil
    }

    /// Koeficient 4 pokrývá bf16 logity, jejich float32 kopii a mezivýsledky
    /// křížové entropie. Je to odhad shora, ne přesný výpočet.
    static func peak(facts: Facts, sequenceLength: Int, batchSize: Int) -> Int {
        let logits = facts.vocabSize * sequenceLength * batchSize * 4
        return facts.weightsBytes + logits * 4 + 384 * 1_048_576
    }
}

/// Žádost o zastavení sdílená s tréninkem. Mimo `TrainingRuntime`, protože ta je
/// izolovaná na hlavní vlákno a callback `LoRATrain.train` běží jinde.
let trainingStopFlag = StopFlag()

/// Průběh tréninku pro UI.
@MainActor
@Observable
final class TrainingRuntime {
    static let shared = TrainingRuntime()

    private(set) var isRunning = false
    private(set) var iteration = 0
    private(set) var totalIterations = 0
    private(set) var trainLoss: Float?
    private(set) var validationLoss: Float?
    private(set) var tokensPerSecond: Double?
    private(set) var status = ""
    var errorMessage: String?

    var progress: Double {
        totalIterations > 0 ? min(1, Double(iteration) / Double(totalIterations)) : 0
    }

    func requestStop() {
        trainingStopFlag.set()
        status = "Zastavuji po dokončení kroku…"
    }

    fileprivate func begin(iterations: Int) {
        trainingStopFlag.reset()
        isRunning = true
        iteration = 0
        totalIterations = iterations
        trainLoss = nil
        validationLoss = nil
        tokensPerSecond = nil
        errorMessage = nil
        status = "Načítám model…"
    }

    fileprivate func update(iteration: Int, loss: Float, tokensPerSecond: Double) {
        self.iteration = iteration
        trainLoss = loss
        self.tokensPerSecond = tokensPerSecond
        status = "Trénuji…"
    }

    fileprivate func update(validationLoss: Float) {
        self.validationLoss = validationLoss
    }

    fileprivate func note(_ text: String) { status = text }

    fileprivate func finish(error: String?) {
        isRunning = false
        errorMessage = error
        status = error == nil ? "Hotovo." : "Přerušeno."
        AdapterStore.shared.reload()
    }
}

#if canImport(MLXLLM)
/// Zkušební krok rozložený na fáze. `LoRATrain.train` udělá první dopředný i zpětný
/// průchod dřív, než cokoli ohlásí, takže při pádu není poznat, co ho způsobilo.
/// Tohle dělá totéž ručně a mezi kroky zapisuje fázi i špičku paměti.
enum TrainingSmokeTest {
    static func run(
        model: any LanguageModel,
        // Kvalifikovaně: `import Tokenizers` (nutný pro makro tokenizéru) přináší
        // stejnojmenný protokol a nekvalifikovaný zápis je tím pádem nejednoznačný.
        tokenizer: MLXLMCommon.Tokenizer,
        text: String,
        optimizer: Adam,
        runtime: TrainingRuntime,
        log: Logger
    ) async throws {
        TrainingPhase.mark(.checkingModel)

        // `LoRATrain.loss` přetypuje model na LLMModel vynuceně – kdyby konformita
        // chyběla, spadlo by to bez hlášky.
        guard model is any LLMModel else {
            throw ProviderError.engine("Model neimplementuje LLMModel, LoRATrain ho trénovat neumí.")
        }
        if let blocker = TrainingEstimate.unsupportedLayer(in: model) {
            throw ProviderError.engine(blocker)
        }

        let trainable = model.trainableParameters().flattened()
        guard !trainable.isEmpty else {
            throw ProviderError.engine("Po vložení adaptéru nejsou žádné trénovatelné parametry – adaptér se na tenhle model nechytil.")
        }
        log.info("trénovatelných tenzorů: \(trainable.count)")
        await runtime.note("Trénovatelných tenzorů: \(trainable.count)")

        TrainingPhase.mark(.tokenizing)
        let tokens = tokenizer.encode(text: text)
        guard tokens.count > 8 else {
            throw ProviderError.engine("Vzorek je po tokenizaci příliš krátký (\(tokens.count) tokenů).")
        }
        let inputs = MLXArray(Array(tokens.dropLast())).reshaped(1, -1)
        let targets = MLXArray(Array(tokens.dropFirst())).reshaped(1, -1)
        let lengths = MLXArray([tokens.count - 1])
        await runtime.note("Vzorek má \(tokens.count) tokenů. Počítám dopředný průchod…")

        TrainingPhase.mark(.forward)
        let (forwardLoss, _) = LoRATrain.loss(
            model: model, inputs: inputs, targets: targets, lengths: lengths
        )
        eval(forwardLoss)
        let lossValue = forwardLoss.item(Float.self)
        await runtime.note("Dopředný průchod prošel, ztráta \(String(format: "%.3f", lossValue)), špička \(peak()) MB. Počítám gradienty…")
        log.info("dopředný průchod prošel, ztráta \(lossValue), špička \(peak()) MB")

        TrainingPhase.mark(.backward)
        let lossValueGrad = valueAndGrad(model: model) { model, arrays in
            let (ce, ntoks) = LoRATrain.loss(
                model: model, inputs: arrays[0], targets: arrays[1], lengths: arrays[2]
            )
            return [ce, ntoks]
        }
        let (values, gradients) = lossValueGrad(model, [inputs, targets, lengths])
        // Bez vyhodnocení gradientů by se graf jen sestavil a fáze by nic neověřila.
        eval(values, gradients)
        await runtime.note("Zpětný průchod prošel, špička \(peak()) MB. Zkouším krok optimizeru…")
        log.info("zpětný průchod prošel, špička \(peak()) MB")

        TrainingPhase.mark(.optimizerStep)
        optimizer.update(model: model, gradients: gradients)
        eval(model, optimizer)
        log.info("krok optimizeru prošel, špička \(peak()) MB")
    }

    private static func peak() -> Int { Memory.peakMemory / 1_048_576 }
}
#endif

/// Trénink LoRA adaptéru nad lokálním MLX modelem.
///
/// Model si trenér načítá vlastní – ne ten z `MLXEngine`. Trénink model mění na místě
/// (vrstvy se nahradí za `QLoRALinear`) a drží k němu gradienty, takže sdílet ho
/// s chatem by znamenalo buď poškozený stav sezení, nebo dvě kopie vah v paměti.
/// Před startem se proto oba chatovací enginy uvolní a po doběhnutí se model zahodí.
actor LoRATrainer {
    static let shared = LoRATrainer()

    private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "cz.aichat", category: "lora")

    /// Kolik paměti musí zbývat po načtení modelu, aby mělo smysl začít. Na aktivace
    /// při zpětném průchodu, stav optimizeru a výkyvy – LoRA váhy samotné jsou jednotky MB.
    private static let requiredFreeMemory = 700 * 1_048_576

    var isRunning: Bool { task != nil }

    func start(
        model: LocalModelFile,
        samples: [TrainingSampleData],
        systemPrompt: String,
        reasoning: Bool,
        configuration: TrainingConfiguration,
        smokeTest: Bool = false
    ) async {
        guard task == nil else { return }
        await TrainingRuntime.shared.begin(iterations: smokeTest ? 1 : configuration.iterations)

        let work = Task {
            do {
                try await run(
                    model: model,
                    samples: samples,
                    systemPrompt: systemPrompt,
                    reasoning: reasoning,
                    configuration: configuration,
                    smokeTest: smokeTest
                )
                await TrainingRuntime.shared.finish(error: nil)
            } catch {
                Self.log.error("trénink selhal: \(error.localizedDescription, privacy: .public)")
                await TrainingRuntime.shared.finish(error: error.localizedDescription)
            }
        }
        task = work
        await work.value
        task = nil
    }

    private func run(
        model: LocalModelFile,
        samples: [TrainingSampleData],
        systemPrompt: String,
        reasoning: Bool,
        configuration: TrainingConfiguration,
        smokeTest: Bool
    ) async throws {
        #if canImport(MLXLLM)
        guard model.kind == .mlx else {
            throw ProviderError.engine("Trénovat jde zatím jen MLX model – llama.cpp trénink nepodporuje.")
        }
        guard samples.count >= 8 else {
            throw ProviderError.engine("Na trénink je potřeba aspoň 8 vzorků.")
        }

        // Chatovací enginy uvolnit, jinak by v paměti ležely dvě kopie modelu.
        await LocalEngines.keepOnly(nil)
        Memory.cacheLimit = 32 * 1_048_576

        // Odhad se počítá ještě před načtením vah – nemá smysl model načítat,
        // když je předem jasné, že první krok aplikaci shodí.
        let facts = TrainingEstimate.facts(modelDirectory: model.url)
        let estimate = TrainingEstimate.peak(
            facts: facts,
            sequenceLength: configuration.maxSampleTokens,
            batchSize: configuration.batchSize
        )
        // `available` je to, co zbývá do jetsam limitu právě teď – po uvolnění
        // chatovacích enginů, ale ještě před načtením vah.
        if let blocker = facts.trainingBlocker {
            throw ProviderError.engine(
                blocker + " Vyber hustý model bez MoE – například Qwen3-4B-4bit."
            )
        }

        let budget = MemoryBudget.available
        if facts.vocabSize > 0, budget > 0, estimate > budget {
            throw ProviderError.engine(
                """
                Trénink by si vyžádal zhruba \(estimate / 1_048_576) MB, k dispozici je \(budget / 1_048_576) MB. \
                Zkrať délku vzorku – paměť roste přímo úměrně s ní.
                """
            )
        }

        // Backpressure: při překročení limitu MLX počká na rozpracované výpočty
        // místo toho, aby alokoval dál a nechal proces ukončit systém.
        if budget > 0 {
            Memory.memoryLimit = max(budget - MemoryBudget.reserve, 512 * 1_048_576)
        }

        TrainingPhase.mark(.loadingModel)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: model.url,
            using: #huggingFaceTokenizerLoader()
        )

        // Měřit až po načtení vah – teprve teď je vidět, co doopravdy zbývá.
        let free = MemoryBudget.available
        if free > 0, free < Self.requiredFreeMemory {
            let megabytes = free / 1_048_576
            throw ProviderError.engine(
                "Po načtení modelu zbývá jen \(megabytes) MB – na trénink to nestačí. Zkus menší model, nebo kratší vzorky."
            )
        }

        let directory = AdapterPaths.directory(forModelID: model.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let loraConfiguration = LoRAConfiguration(
            numLayers: configuration.numLayers,
            fineTuneType: .lora,
            loraParameters: .init(rank: configuration.rank, scale: configuration.scale)
        )
        // Konfigurace se ukládá dřív než váhy: bez ní se adaptér nedá načíst,
        // a checkpoint může vzniknout kdykoli během běhu.
        try JSONEncoder().encode(loraConfiguration)
            .write(to: AdapterPaths.configuration(in: directory), options: .atomic)

        let weightsURL = AdapterPaths.weights(in: directory)
        let runtime = await TrainingRuntime.shared
        let log = Self.log

        let result = try await container.perform { context -> (iterations: Int, train: Float?, validation: Float?, samples: Int) in
            TrainingPhase.mark(.preparingData)
            await runtime.note("Připravuji vzorky…")
            let dataset = TrainingDatasetBuilder.make(
                samples: samples,
                systemPrompt: systemPrompt,
                reasoning: reasoning,
                tokenizer: context.tokenizer,
                maxTokens: configuration.maxSampleTokens
            )
            guard dataset.train.count >= 4 else {
                throw ProviderError.engine(
                    "Použitelných vzorků je málo (\(dataset.train.count)). Vynecháno pro délku: \(dataset.skipped)."
                )
            }
            log.info("dataset: \(dataset.train.count) trénovacích, \(dataset.validate.count) validačních, \(dataset.skipped) vynecháno")

            // `from(model:)` zmrazí základní váhy a nahradí vrstvy za (Q)LoRA verze.
            // U kvantovaného modelu vznikne `QLoRALinear`, takže 4bitový základ zůstává.
            TrainingPhase.mark(.applyingAdapter)
            let adapter = try LoRAContainer.from(model: context.model, configuration: loraConfiguration)
            let optimizer = Adam(learningRate: configuration.learningRate)

            // Zkušební krok pustí jedinou iteraci nad nejkratším vzorkem. Když
            // projde, projde i celý běh – špička paměti je u každého kroku stejná.
            let trainSet = smokeTest
                ? [dataset.train.min(by: { $0.count < $1.count })].compactMap { $0 }
                : dataset.train

            let parameters = LoRATrain.Parameters(
                batchSize: configuration.batchSize,
                iterations: smokeTest ? 1 : configuration.iterations,
                stepsPerReport: 1,
                stepsPerEval: smokeTest ? .max : configuration.stepsPerEval,
                validationBatches: 4,
                saveEvery: configuration.saveEvery,
                adapterURL: weightsURL
            )

            var lastIteration = 0
            var lastTrainLoss: Float?
            var lastValidationLoss: Float?

            if smokeTest {
                try await TrainingSmokeTest.run(
                    model: context.model,
                    tokenizer: context.tokenizer,
                    text: trainSet[0],
                    optimizer: optimizer,
                    runtime: runtime,
                    log: log
                )
                adapter.unload(from: context.model)
                Memory.clearCache()
                TrainingPhase.mark(.finished)
                return (0, nil, nil, dataset.train.count)
            }

            // Stejná kontrola i pro ostrý běh – lepší hláška než pád bez stopy.
            guard context.model is any LLMModel else {
                throw ProviderError.engine("Model neimplementuje LLMModel, LoRATrain ho trénovat neumí.")
            }
            if let blocker = TrainingEstimate.unsupportedLayer(in: context.model) {
                throw ProviderError.engine(blocker)
            }
            guard !context.model.trainableParameters().flattened().isEmpty else {
                throw ProviderError.engine("Po vložení adaptéru nejsou žádné trénovatelné parametry – adaptér se na tenhle model nechytil.")
            }

            TrainingPhase.mark(.firstStep)
            try LoRATrain.train(
                model: context.model,
                train: trainSet,
                validate: smokeTest ? trainSet : dataset.validate,
                optimizer: optimizer,
                tokenizer: context.tokenizer,
                parameters: parameters
            ) { progress in
                switch progress {
                case .train(let iteration, let loss, _, let tokensPerSecond):
                    if iteration == 0 { TrainingPhase.mark(.training) }
                    lastIteration = iteration + 1
                    lastTrainLoss = loss
                    Task { @MainActor in
                        runtime.update(iteration: iteration + 1, loss: loss, tokensPerSecond: tokensPerSecond)
                    }
                case .validation(let iteration, let loss, _):
                    lastValidationLoss = loss
                    log.info("iterace \(iteration + 1): validační ztráta \(loss)")
                    Task { @MainActor in runtime.update(validationLoss: loss) }
                case .save(let iteration, _):
                    log.info("checkpoint po \(iteration + 1) iteracích")
                }

                if trainingStopFlag.isSet { return .stop }

                // Poslední pojistka: když se paměť propadne pod rezervu, skončit po kroku
                // místo toho, aby appku uprostřed tréninku ukončil jetsam.
                let free = MemoryBudget.available
                if free > 0, free < MemoryBudget.reserve {
                    log.error("trénink zastaven kvůli paměti (\(free / 1_048_576) MB volných)")
                    Task { @MainActor in runtime.note("Zastaveno kvůli paměti – ulož a zkrať vzorky.") }
                    return .stop
                }
                return .more
            }

            // Poslední stav vah – `saveEvery` uloží jen každý N-tý krok.
            // Zkušební krok nic neukládá, jde v něm jen o to, jestli projde.
            TrainingPhase.mark(.saving)
            if !smokeTest {
                try LoRATrain.saveLoRAWeights(model: context.model, url: weightsURL)
            }
            // Vrátit vrstvy do původní podoby: kdyby model zůstal s adaptérem,
            // navazující použití kontejneru by běželo přes natrénované váhy bez vědomí uživatele.
            adapter.unload(from: context.model)
            Memory.clearCache()

            return (lastIteration, lastTrainLoss, lastValidationLoss, dataset.train.count)
        }

        guard !smokeTest else { return }

        var info = AdapterInfo()
        info.baseModelID = model.id
        info.iterations = result.iterations
        info.samples = result.samples
        info.trainLoss = result.train
        info.validationLoss = result.validation
        info.rank = configuration.rank
        info.numLayers = configuration.numLayers
        try? JSONEncoder().encode(info).write(to: AdapterPaths.info(in: directory), options: .atomic)

        Memory.clearCache()
        TrainingPhase.mark(.finished)
        let peak = Memory.peakMemory / 1_048_576
        await runtime.note(
            smokeTest
                ? "Zkušební krok prošel. Špička paměti \(peak) MB."
                : "Hotovo po \(result.iterations) iteracích. Špička paměti \(peak) MB."
        )
        Self.log.info("trénink dokončen po \(result.iterations) iteracích, špička \(peak) MB")
        #else
        throw ProviderError.unavailable("MLX není v tomhle buildu dostupné (simulátor).")
        #endif
    }
}
