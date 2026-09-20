import Foundation

/// Odpověď nad podklady, kde si nástroje volá model sám.
///
/// `RetrievalPipeline` rozhoduje za model: vybere fakta, vybere úryvky, poskládá prompt.
/// Funguje to, dokud dotaz sedí na heuristiku. Tahle pipeline nechá rozhodnutí na modelu –
/// dostane osnovu dokumentu a seznam nástrojů a sám si řekne, co chce vidět.
///
/// **První krok zůstává deterministický.** Fakta i úryvky k původnímu dotazu jsou
/// v promptu hned, bez jediného volání modelu. Agent je úniková cesta pro případ, že to
/// nestačí – ne náhrada za něco, co je zadarmo. Tím se ušetří dva průchody modelem
/// na dotazech, které první kolo zvládne.
///
/// Nástroje nejsou nic nového: každý je obal nad tím, co už `RetrievalPipeline` volá.
/// Nová je jen smyčka a to, že hranice volání je skutečná – model nemůže napsat půlku
/// věty a značku až za ni, protože se generování na `>>` zastaví.
struct AgentPipeline: ChatProvider {
    let base: any ChatProvider
    let contextCeiling: Int
    let answerTokens: Int
    let cite: Bool
    /// Nadpisy, podle kterých se píše shrnutí kapitoly. Prázdné = model si zvolí sám.
    let summaryOutline: [String]

    /// Kolik volání nástrojů se povolí, než se vynutí odpověď. Každý krok je nový
    /// prompt ke zpracování; na telefonu je pět kroků víc než minuta čekání.
    private static let maxSteps = 5
    /// Strop na celkovou délku výsledků nástrojů v promptu.
    private static let traceBudget = 6_000

    /// Ukončovací značka volání. Na ní se generování zastaví, takže model nestihne
    /// dopsat ani vymyšlený výsledek nástroje.
    static let terminator = ">>"

    /// Kolo, ve kterém si model říká o nástroj. Přemýšlení je tu vypnuté schválně:
    /// výstupem má být jediný řádek `NÁSTROJ argument >>`, a rozvaha před ním stojí
    /// stovky tokenů. Na stejný krok vygeneroval model s přemýšlením 2 795 tokenů;
    /// samotné volání jich má deset.
    private var toolBase: any ChatProvider {
        base.oneShot().thinking(false).stopping(at: [Self.terminator])
    }

    private static let log = EngineLog(category: "retrieval")

    // MARK: - Nástroje

    enum Tool: String, CaseIterable {
        case cisla = "CISLA"
        case vykaz = "VYKAZ"
        case hledej = "HLEDEJ"
        case kapitola = "KAPITOLA"
        case shrn = "SHRN"
        case odpoved = "ODPOVED"

        var help: String {
            switch self {
            case .cisla: "CISLA <co hledáš> – přesné hodnoty z otagovaných čísel (XBRL)"
            case .vykaz: "VYKAZ <název> – celý výkaz (rozvaha, výkaz zisku a ztráty, peněžní toky)"
            case .hledej: "HLEDEJ <slova> – úryvky textu dokumentu"
            case .kapitola: "KAPITOLA <číslo nebo název> – začátek kapitoly"
            case .shrn: "SHRN <číslo nebo název> – shrnutí celé kapitoly (i dlouhé)"
            case .odpoved: "ODPOVED – nic dalšího nepotřebuješ, píšeš odpověď"
            }
        }
    }

    struct Call: Sendable {
        let tool: Tool
        let argument: String
    }

    // MARK: - Zapnutí

    @MainActor
    static func wrapping(
        _ base: any ChatProvider,
        settings: SettingsStore,
        profile: TaskProfile
    ) -> AgentPipeline? {
        guard profile != .summarize, settings.local.agentTools else { return nil }
        return AgentPipeline(
            base: base,
            contextCeiling: settings.local.contextLength,
            answerTokens: settings.local.maxTokens,
            cite: settings.local.showSources,
            summaryOutline: settings.local.outline(for: .summarize)
        )
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(history, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Smyčka

    private func run(
        _ history: [ChatTurn],
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let question = history.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let documents = Self.documents(in: history)
        guard !documents.isEmpty else {
            for try await event in base.stream(history) { continuation.yield(event) }
            return
        }

        let budget = await promptBudget()
        let tagged = documents.compactMap(\.facts)
        let index = await DocumentIndexCache.shared.index(
            for: documents, chunkSize: max(600, min(1_500, budget / 4)))

        // Zárodek: co by první kolo `RetrievalPipeline` dalo do promptu samo.
        var trace: [String] = []
        let seed = Self.facts(in: tagged, matching: question, budget: 1_500)
        if !seed.isEmpty {
            trace.append("CISLA \(question)\n\(seed)")
            continuation.yield(.status("Beru otagovaná čísla (XBRL) přímo z podkladu.\n"))
        }
        var sources: [IndexedChunk] = []

        // „Shrň mi kapitolu 7“ je zadání pro `SHRN`, ne pro hledání. Kdyby se nechalo
        // na prvním kole, dostane model čtyři úryvky trefené na slova z dotazu –
        // z třiceti tisíc znaků kapitoly pár odstavců, které spolu nesouvisí.
        if let title = Self.summaryTarget(in: question, outline: index.outline) {
            let call = Call(tool: .shrn, argument: title)
            continuation.yield(.status("Shrnuju kapitolu „\(title)“.\n"))
            let output = await run(
                call, index: index, tagged: tagged, budget: budget,
                sources: &sources, into: continuation)
            trace.append("SHRN \(title)\n\(output)")
        } else {
            sources = index.search(question, characterBudget: 3_000, maxChunks: 3)
            if !sources.isEmpty {
                trace.append("HLEDEJ \(question)\n" + Self.render(sources))
            }
        }

        for step in 1...Self.maxSteps {
            try Task.checkCancellation()
            let last = step == Self.maxSteps
            let prompt = Self.prompt(
                question: question,
                outline: index.outline,
                trace: trace,
                allowTools: !last,
                cite: cite,
                summaryOutline: summaryOutline
            )
            Self.log.notice("""
                agent krok \(step)/\(Self.maxSteps) · prompt \(prompt.count) znaků · \
                kroků v paměti \(trace.count)
                """)

            let turn = [ChatTurn(role: .user, text: prompt)]
            let provider = last ? base.oneShot() : toolBase
            let result = try await Self.collect(
                from: provider.stream(turn), into: continuation, allowTools: !last)

            guard let call = result.call else { return }
            if call.tool == .odpoved {
                // Model říká, že už má dost. Další kolo je poslední – jen napíše odpověď.
                trace.append("ODPOVED – teď napiš odpověď uživateli.")
                continue
            }

            continuation.yield(.status("\(call.tool.rawValue) \(call.argument)\n"))
            let output = await run(
                call, index: index, tagged: tagged, budget: budget,
                sources: &sources, into: continuation)
            trace.append("\(call.tool.rawValue) \(call.argument)\n\(output)")
            Self.trim(&trace)
            if cite, !sources.isEmpty {
                continuation.yield(.sources(sources.enumerated().map {
                    MessageSource(number: $0.offset + 1, chunk: $0.element)
                }))
            }
        }
    }

    /// Provede volání a vrátí výsledek tak, jak ho uvidí model.
    private func run(
        _ call: Call,
        index: DocumentIndex,
        tagged: [String],
        budget: Int,
        sources: inout [IndexedChunk],
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async -> String {
        switch call.tool {
        case .cisla:
            let facts = Self.facts(in: tagged, matching: call.argument, budget: 2_000)
            return facts.isEmpty ? "Nic. Otagovaná čísla k tomuhle nic nemají." : facts

        case .vykaz:
            let facts = Self.facts(in: tagged, matching: call.argument, budget: 8_000)
            return facts.isEmpty ? "Nic. Takový výkaz v podkladech není." : facts

        case .hledej:
            let found = index.search(call.argument, characterBudget: 4_000, maxChunks: 4)
            guard !found.isEmpty else { return "Nic. Na tahle slova se v dokumentu nic netrefilo." }
            sources = found
            return Self.render(found)

        case .kapitola:
            guard let title = Self.resolve(call.argument, outline: index.outline) else {
                return "Kapitolu \(call.argument) jsem v osnově nenašel."
            }
            let found = index.section(title, characterBudget: 4_000)
            guard !found.isEmpty else { return "Kapitola „\(title)“ je prázdná." }
            sources = found
            return Self.render(found)

        case .shrn:
            guard let title = Self.resolve(call.argument, outline: index.outline) else {
                return "Kapitolu \(call.argument) jsem v osnově nenašel."
            }
            // Bez stropu: celá kapitola, i kdyby byla na víc průchodů.
            let parts = index.section(title, characterBudget: 2_000_000)
            let text = parts.map(\.text).joined(separator: "\n\n")
            guard !text.isEmpty else { return "Kapitola „\(title)“ je prázdná." }
            sources = Array(parts.prefix(3))
            return await summary(of: text, title: title, budget: budget, into: continuation)

        case .odpoved:
            return ""
        }
    }

    /// Shrnutí celé kapitoly.
    ///
    /// Když se kapitola vejde do jednoho promptu, vrátí se rovnou text – model si ji
    /// shrne sám v dalším kroku a ušetří se průchod. Když ne, jede se po částech:
    /// každá se shrne zvlášť a model nakonec spojí dílčí shrnutí.
    ///
    /// Tohle hledáním nahradit nejde. `HLEDEJ` vrátí čtyři úryvky, které se trefily
    /// na slova z dotazu – u „shrň kapitolu“ je to pár odstavců z třiceti tisíc znaků.
    private func summary(
        of text: String,
        title: String,
        budget: Int,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async -> String {
        let room = max(2_000, budget - 3_000)
        if text.count <= room { return text }

        let pieces = DocumentSections.chunks(of: text, maxCharacters: room)
        var partials: [String] = []
        for (index, piece) in pieces.enumerated() {
            continuation.yield(.status(
                "Shrnuju kapitolu „\(title)“ – část \(index + 1) z \(pieces.count).\n"))
            // Osnova jde do každé části. Bez ní si každá zvolí jiný tvar a výsledek
            // se nedá poskládat dohromady.
            let shape = TaskProfile.outlineBlock(summaryOutline)
                ?? "Vypiš v bodech, co je v ní podstatné."
            let prompt = """
                Toto je část \(index + 1) z \(pieces.count) kapitoly „\(title)“. \
                \(shape) Čísla, názvy a data zachovej přesně. Nepiš úvod ani závěr.

                \(piece)
                """
            guard let partial = try? await answer(to: prompt), !partial.isEmpty else { continue }
            partials.append("Část \(index + 1)/\(pieces.count):\n\(partial)")
        }
        guard !partials.isEmpty else { return "Kapitolu „\(title)“ se nepodařilo shrnout." }
        return partials.joined(separator: "\n\n")
    }

    /// Jeden průchod modelem, ze kterého se bere jen text.
    private func answer(to prompt: String) async throws -> String {
        var text = ""
        // Shrnutí části kapitoly je vytahování, ne úvaha – a násobí se počtem částí.
        let provider = base.oneShot().thinking(false)
        for try await event in provider.stream([ChatTurn(role: .user, text: prompt)]) {
            if case .text(let piece) = event { text += piece }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kapitola, kterou má dotaz shrnout, nebo nil. Musí být obojí: slovo o shrnutí
    /// a odkaz na kapitolu.
    static func summaryTarget(in question: String, outline: [String]) -> String? {
        // `contains` s koncovou closure se u pole řetězců plete s `contains(_ element:)`,
        // protože `String` je `Equatable`. Kompilátor pak neurčí typ téhle funkce a hlásí
        // to až na místě volání jako „AgentPipeline nemá člen summaryTarget“. Proto
        // všude výslovně `contains(where:)` a žádné vnořené closury.
        let stems: [String] = Terms.stems(of: question)
        let asksForSummary = stems.contains(where: { (stem: String) -> Bool in
            for prefix in Self.summaryWords where stem.hasPrefix(prefix) { return true }
            return false
        })
        guard asksForSummary else { return nil }

        let namesChapter = stems.contains(where: { (stem: String) -> Bool in
            stem.hasPrefix("kapito") || stem.hasPrefix("item")
        })
        guard namesChapter || Self.itemNumber(in: question) != nil else { return nil }
        return resolve(question, outline: outline)
    }

    private static let summaryWords = ["shrn", "souhrn", "summar", "prehle"]

    /// Kapitola podle toho, co napsal model: „7“, „Item 7“ i „Income Tax“.
    ///
    /// Samotné číslo dřív bralo pořadí v osnově. Jenže osnova má po zapnutí XBRL kapitol
    /// přes čtyřicet položek, takže „KAPITOLA 7“ sáhlo na sedmou v pořadí – u mě
    /// „Item 9B – Other Information“. Uživatel i model tím číslem myslí `Item 7`.
    static func resolve(_ argument: String, outline: [String]) -> String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // „7“, „7A“, „Item 7“ → hlavička `Item 7`, ne sedmá položka seznamu.
        if let item = Self.itemNumber(in: trimmed) {
            let needle = "item \(item)"
            if let hit = outline.first(where: {
                let lower = $0.lowercased()
                guard lower.hasPrefix(needle) else { return false }
                // `Item 7` nesmí chytit `Item 7A`, když se o něj nežádalo.
                let rest = lower.dropFirst(needle.count).first
                return rest == nil || !(rest!.isLetter || rest!.isNumber)
            }) { return hit }
        }

        // Název kapitoly (i částečný) – „Income Tax“, „Segment Reporting“.
        let terms = Set(Terms.stems(of: trimmed))
        if !terms.isEmpty {
            let best = outline
                .map { ($0, Set(Terms.stems(of: $0)).intersection(terms).count) }
                .filter { $0.1 > 0 }
                .max { $0.1 < $1.1 }
            if let best { return best.0 }
        }

        // Až úplně nakonec pořadí v osnově.
        if let number = Int(trimmed.filter(\.isNumber)), number >= 1, number <= outline.count {
            return outline[number - 1]
        }
        return nil
    }

    /// První číslo položky včetně písmene, kdekoli v textu: „7“ z „Shrň mi kapitolu 7.“,
    /// „7A“ z „Item 7A“. Hledá se v celém řetězci, ne jen na začátku – dotaz chodí
    /// celou větou, ne jako holý argument.
    private static func itemNumber(in text: String) -> String? {
        var digits = ""
        var letter = ""
        for character in text.lowercased() {
            if character.isNumber {
                guard letter.isEmpty else { break }
                digits.append(character)
            } else if character.isLetter, !digits.isEmpty {
                // Písmeno hned za číslem patří k němu („7a“); mezera ho ukončí.
                guard letter.isEmpty else { break }
                letter.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return digits.isEmpty ? nil : digits + letter
    }

    /// Starší kroky vypadnou, jakmile se výsledky přestanou vejít. Poslední krok je
    /// ten, na který se model nejspíš ptal, takže se zahazuje odpředu.
    private static func trim(_ trace: inout [String]) {
        while trace.count > 1, trace.reduce(0, { $0 + $1.count }) > traceBudget {
            trace.removeFirst()
        }
    }

    // MARK: - Čtení odpovědi

    private struct Outcome {
        var call: Call?
    }

    /// Přečte jedno kolo. Dokud není jasné, jestli jde o volání nástroje, text se drží;
    /// jakmile je jasné, že model odpovídá, pustí se nastřádané i zbytek rovnou ven.
    ///
    /// Zadržování je nutné i se stop značkou: značka zastaví generování, ale samotné
    /// slovo `CISLA` by se na obrazovce mihlo dřív.
    private static func collect(
        from stream: AsyncThrowingStream<StreamEvent, Error>,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        allowTools: Bool
    ) async throws -> Outcome {
        var head = ""
        var streaming = !allowTools
        var result = Outcome()

        for try await event in stream {
            guard case .text(let piece) = event else {
                // Usage a přemýšlení jdou ven vždycky; status si řídí smyčka sama.
                if case .status = event {} else { continuation.yield(event) }
                continue
            }
            if streaming {
                continuation.yield(.text(piece))
                continue
            }
            head += piece
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = parse(trimmed) {
                result.call = call
                return result
            }
            // Dokud může jít o začátek volání, čeká se. Jakmile je jasné, že ne,
            // pustí se nastřádaný text ven a dál se streamuje bez zdržení.
            if !couldBeCall(trimmed) {
                streaming = true
                continuation.yield(.text(head))
            }
        }
        if !streaming, !head.isEmpty { continuation.yield(.text(head)) }
        return result
    }

    /// `CISLA revenue 2026 >>` nebo `CISLA revenue 2026` na konci řádku.
    static func parse(_ text: String) -> Call? {
        guard let tool = Tool.allCases.first(where: {
            text.uppercased().hasPrefix($0.rawValue)
        }) else { return nil }
        var rest = String(text.dropFirst(tool.rawValue.count))
        if let cut = rest.range(of: terminator) {
            rest = String(rest[rest.startIndex..<cut.lowerBound])
        } else if let newline = rest.firstIndex(of: "\n") {
            rest = String(rest[rest.startIndex..<newline])
        } else if tool != .odpoved {
            // Řádek ještě nedoběhl – počká se na značku nebo konec řádku.
            return nil
        }
        return Call(tool: tool, argument: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Může z tohohle ještě vzniknout volání nástroje? Porovnává se předpona, takže
    /// „CIS“ čeká, ale „Revenue za“ pustí text hned.
    private static func couldBeCall(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let upper = text.uppercased()
        return Tool.allCases.contains {
            upper.hasPrefix($0.rawValue) || $0.rawValue.hasPrefix(upper)
        }
    }

    // MARK: - Prompt

    private static func prompt(
        question: String,
        outline: [String],
        trace: [String],
        allowTools: Bool,
        cite: Bool,
        // Nadpisy pro shrnutí – jiná věc než `outline`, což je osnova dokumentu.
        summaryOutline: [String]
    ) -> String {
        var parts: [String] = []

        if !outline.isEmpty {
            let list = outline.prefix(60).enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            parts.append("Osnova dokumentu:\n\(list)")
        }
        if !trace.isEmpty {
            parts.append("Co už máš z podkladů:\n\n" + trace.joined(separator: "\n\n"))
        }
        parts.append("Dotaz uživatele: \(question)")

        if allowTools {
            let tools = Tool.allCases.map { "- " + $0.help }.joined(separator: "\n")
            parts.append("""
                Když ti něco chybí, napiš **jediný řádek** ve tvaru `NÁSTROJ argument \(terminator)` \
                a nic dalšího – výsledek dostaneš a budeš pokračovat. Nástroje:

                \(tools)

                Když ti podklady stačí, rovnou odpověz česky. Nikdy nepiš volání nástroje \
                doprostřed věty a nevymýšlej si jeho výsledek. Nástroje jsou tvoje – \
                uživateli o nich nepiš a neposílej ho, ať je volá sám.
                """)
        } else {
            var closing = """
                Teď napiš odpověď česky jen z podkladů výše. Nic dalšího si nevyžaduj. \
                Čísla ber z otagovaných hodnot a opisuj je v jednotkách, ve kterých jsou \
                uvedená – nepřepočítávej je.
                """
            // Dílčí shrnutí přišla už rozdělená podle osnovy, takže výsledek má držet
            // stejné nadpisy – jinak by je model při skládání zase rozhodil.
            if trace.contains(where: { $0.hasPrefix("SHRN ") }),
               let shape = TaskProfile.outlineBlock(summaryOutline) {
                closing += "\n\n" + shape
            }
            parts.append(closing)
        }
        if cite {
            parts.append("U údaje z úryvku uveď v hranatých závorkách jeho číslo.")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Drobnosti

    private static func render(_ chunks: [IndexedChunk]) -> String {
        chunks.enumerated()
            .map { "### [\($0.offset + 1)] \($0.element.label)\n\($0.element.text)" }
            .joined(separator: "\n\n")
    }

    private static func facts(in tables: [String], matching query: String, budget: Int) -> String {
        tables.compactMap { table -> String? in
            let excerpt = InlineXBRL.excerpt(
                from: table, matching: query, maxLines: 160, characterBudget: budget)
            return excerpt.isEmpty ? nil : excerpt
        }.joined(separator: "\n\n")
    }

    private static func documents(in history: [ChatTurn]) -> [Attachment] {
        var seen = Set<UUID>()
        var result: [Attachment] = []
        for turn in history {
            for attachment in turn.attachments where !attachment.text.isEmpty {
                guard seen.insert(attachment.id).inserted else { continue }
                result.append(attachment)
            }
        }
        return result
    }

    /// `LocalRuntime.shared` je `@MainActor`, takže i tohle musí být – jinak se
    /// skutečná délka kontextu (po zkrácení podle paměti) nedá přečíst.
    @MainActor
    private func promptBudget() -> Int {
        let ceiling = LocalRuntime.shared.effectiveContext ?? contextCeiling
        let context = min(contextCeiling, ceiling)
        let promptTokens = max(512, context - answerTokens)
        return max(2_000, Int(Double(promptTokens) * 2.5) - 2_000)
    }
}
