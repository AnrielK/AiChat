import Foundation

/// Shrnutí dokumentu, který se do kontextu nevejde: rozdělí se na kapitoly, každá se
/// shrne zvlášť a dílčí shrnutí se pak složí do jednoho.
///
/// Tváří se jako obyčejný `ChatProvider`, takže `ChatViewModel` nemusí o víc kolech vědět –
/// průběh chodí jako `.reasoning` (schová se do rozbalovacího panelu) a finální shrnutí
/// jako `.text`, přesně jako u jednoprůchodové odpovědi.
struct SummaryPipeline: ChatProvider {
    /// Poskytovatel pro dílčí průchody – krátký strop odpovědi, bez přemýšlení.
    let step: any ChatProvider
    /// Poskytovatel pro poslední kolo, které se streamuje uživateli.
    let base: any ChatProvider

    /// Kola se skládaným promptem se posílají jako jednorázová: prompt je pokaždé jiný
    /// (jiná kapitola, jiný kus), takže KV cache z minulého kola je k ničemu a jen drží
    /// paměť, kterou bude potřebovat prefill toho dalšího.
    private var oneShotBase: any ChatProvider { base.oneShot() }
    private var oneShotStep: any ChatProvider { step.oneShot() }
    /// Strop délky kontextu z nastavení; skutečná hodnota se bere z enginu.
    let contextCeiling: Int
    /// Vlastní strop na velikost kusu (0 = jen podle kontextu). Viz `summaryChunkTokens`.
    let chunkCeiling: Int
    /// Rezerva na odpověď při výpočtu velikosti kusu – strop poslední odpovědi,
    /// ne nastavená *Max. délka odpovědi*.
    let answerTokens: Int

    /// Dílčí shrnutí je seznam odrážek, ne esej. Nastavených několik tisíc tokenů by se
    /// generovalo u každé části zvlášť a je to v celém běhu ta nejdražší položka.
    private static let stepTokens = 768

    /// Strop poslední, streamované odpovědi. Nastavená *Max. délka odpovědi* platí pro
    /// konverzaci, kde delší odpovědi dávají smysl; shrnutí je z principu kratší než
    /// podklad. Na lokálním modelu se generuje 12–20 tokenů za sekundu, takže rozdíl
    /// mezi 1 536 a 4 096 tokeny jsou minuty čekání – u dokumentu, který se vejde do
    /// jednoho průchodu, je psaní odpovědi dokonce dražší než zpracování promptu.
    /// Když má uživatel nastaveno míň, platí jeho hodnota.
    private static let finalTokens = 1_536

    /// Vrátí pipeline, jen když dává smysl: shrnování dlouhé přílohy na modelu s malým
    /// kontextem. Jinak `nil` – volající použije původního poskytovatele.
    @MainActor
    static func wrapping(
        _ base: any ChatProvider,
        settings: SettingsStore,
        models: ModelManager,
        attachments: [Attachment],
        profile: TaskProfile
    ) -> SummaryPipeline? {
        guard profile == .summarize else { return nil }
        // Vypnuté dělení = příloha se pošle jako běžný chat (a případně se ořízne).
        guard settings.local.summarizeLongAttachments else { return nil }
        // Cloudové modely mají okno na celý dokument, dělit ho by jen zhoršilo výsledek.
        guard settings.provider == .local || settings.provider == .apple else { return nil }

        let characters = attachments.reduce(0) { $0 + $1.characterCount }
        guard characters > 0 else { return nil }

        // Nastavená délka kontextu je jen strop – engine ji podle paměti zkracuje.
        // Dokud se v tomhle chatu negenerovalo, skutečná hodnota není známá, tak se
        // odhadne z volné paměti. Bez toho by se u nastavených 131 072 tokenů poslal
        // do jednoho kola celý dokument, na který se v paměti místo nenajde.
        let ceiling = LocalRuntime.shared.effectiveContext ?? Self.estimatedContext()
        let cap = settings.local.summaryChunkTokens
        let context = min(settings.local.contextLength, ceiling, cap > 0 ? cap : .max)
        // Rezerva se počítá ze stropu poslední odpovědi, ne z nastavené délky – jinak by
        // se dělil i dokument, který se ve skutečnosti do jednoho průchodu vejde.
        let answer = min(settings.local.maxTokens, Self.finalTokens)
        guard characters > Self.chunk(context: context, answerTokens: answer) else { return nil }

        // Přemýšlení se tu vypíná natvrdo. Průchodů jsou jednotky až desítky a think blok
        // by se v každém opakoval; vstupem je navíc už jen vytažený text, ne úloha,
        // kde by rozmýšlení pomohlo. Nastavení uživatele platí pro jednoprůchodové odpovědi.
        let quiet = (try? settings.makeProvider(
            models: models, profile: profile,
            reasoningOverride: false, maxTokensOverride: answer)) ?? base
        let short = (try? settings.makeProvider(
            models: models, profile: profile,
            reasoningOverride: false, maxTokensOverride: Self.stepTokens)) ?? quiet

        return SummaryPipeline(
            step: short,
            base: quiet,
            contextCeiling: settings.local.contextLength,
            chunkCeiling: cap,
            answerTokens: answer
        )
    }

    /// Kolik znaků dokumentu se vejde do jednoho průchodu. 2,5 znaku na token je opatrný
    /// odhad (u češtiny vychází míň než u angličtiny) a 2 000 znaků zbývá na instrukci,
    /// systémový prompt a hlavičky šablony.
    private static func chunk(context: Int, answerTokens: Int) -> Int {
        let promptTokens = max(512, context - answerTokens)
        return max(2_000, Int(Double(promptTokens) * 2.5) - 2_000)
    }

    /// Velikost kusu pro další průchod. Čte se před každým, protože skutečnou délku
    /// kontextu engine ohlásí až po prvním generování – do té doby je to jen odhad
    /// z volné paměti, a ten bývá mimo, když model ještě není načtený.
    @MainActor
    private func nextChunk() -> Int {
        let ceiling = LocalRuntime.shared.effectiveContext ?? Self.estimatedContext()
        let limit = min(contextCeiling, ceiling, chunkCeiling > 0 ? chunkCeiling : .max)
        return Self.chunk(context: limit, answerTokens: Self.stepTokens)
    }

    /// Opatrný odhad kontextu z volné paměti, když engine ještě nic nehlásil.
    /// 144 kB na token odpovídá KV cache modelu velikosti 4B ve f16; u menších modelů
    /// odhad podstřelí, což je bezpečný směr.
    @MainActor
    private static func estimatedContext() -> Int {
        let free = MemoryBudget.available - MemoryBudget.reserve
        guard free > 0 else { return 4_096 }
        return max(2_048, free / 147_456 / 256 * 256)
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

    // MARK: - Průběh

    private func run(
        _ history: [ChatTurn],
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard let last = history.last, !last.attachments.isEmpty else {
            // Není co dělit – chová se jako původní poskytovatel.
            for try await event in base.stream(history) { continuation.yield(event) }
            return
        }

        let instruction = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = last.attachments.map(\.name).joined(separator: ", ")
        let document = last.attachments
            .map { $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // 1) Kapitoly. Na kusy se každá rozseká až těsně před zpracováním – po prvním
        //    průchodu zná engine skutečnou délku kontextu a kusy můžou být větší.
        let all = DocumentSections.split(document)
        let sections = DocumentSections.selected(all, for: instruction)
        if sections.count < all.count {
            continuation.yield(.status(
                "Z \(all.count.czech("kapitoly", "kapitol", "kapitol")) zpracuji \(sections.count) podle zadání: "
                + sections.map(\.title).joined(separator: ", ") + "\n"))
        }
        let missing = DocumentSections.missing(all, for: instruction)
        if !missing.isEmpty {
            let heading = missing.count == 1 ? "se nenašla kapitola" : "se nenašly kapitoly"
            continuation.yield(.status(
                "V dokumentu \(heading): " + missing.map { "Item \($0)" }.joined(separator: ", ") + "\n"))
        }
        // Vejdou-li se vybrané kapitoly do jednoho kola, dělení by jen ubralo přesnost.
        let joined = sections
            .map { $0.title.isEmpty ? $0.text : "## \($0.title)\n\($0.text)" }
            .joined(separator: "\n\n")
        let singlePass = await nextChunk()
        if joined.count <= singlePass {
            if sections.count == all.count {
                // Nic se nevybíralo – původní zpráva i s přílohou projde beze změny.
                for try await event in base.stream(history) { continuation.yield(event) }
            } else {
                // Vybrané kapitoly se musí poslat samy; celá příloha by se nevešla.
                continuation.yield(.status("Vybrané kapitoly se vejdou najednou.\n"))
                try await forward(
                    finalPrompt(name: name, instruction: instruction, body: joined, missing: missing),
                    into: continuation)
            }
            return
        }

        // Zadání může mířit na konkrétní věc uvnitř kapitoly („shrň, co Item 1A říká
        // o TSMC“). Projít kvůli tomu celou kapitolu je desítky průchodů za dva odstavce,
        // takže se z ní vyberou jen pasáže k zadání. Zúžení se nedělá potichu – uživatel
        // chtěl shrnutí a musí vidět, že nedostal celou kapitolu.
        if let focus = await focused(sections, instruction: instruction, name: name, budget: singlePass) {
            let excerpts = focus.excerpts
            let picked = excerpts.reduce(0) { $0 + $1.text.count }
            if let keywords = focus.keywords {
                continuation.yield(.status(
                    "Dotaz je v jiném jazyce než podklad – hledám podle „\(keywords)“.\n"))
            }
            continuation.yield(.status(
                "Zadání míří na konkrétní místo, vybral jsem \(excerpts.count.czech("pasáž", "pasáže", "pasáží")) "
                + "(\(picked.compactFormatted) z \(joined.count.compactFormatted) znaků). "
                + "Úplné shrnutí dostaneš zadáním bez upřesnění.\n"))
            continuation.yield(.sources(excerpts.enumerated().map {
                MessageSource(number: $0.offset + 1, chunk: $0.element)
            }))
            let body = excerpts.enumerated()
                .map { "### [\($0.offset + 1)] \($0.element.label)\n\($0.element.text)" }
                .joined(separator: "\n\n")
            try await forward(
                focusedPrompt(name: name, instruction: instruction, body: body), into: continuation)
            return
        }

        continuation.yield(.status("Zpracuji \(sections.count.czech("kapitolu", "kapitoly", "kapitol")) postupně.\n\n"))

        // 2) Shrnutí jednotlivých částí.
        // Cena celého běhu se sčítá průběžně: ukazatel kontextu v chatu ukazuje jen
        // poslední průchod, takže po vícekolovém shrnutí vypadá skoro prázdný a
        // uživateli to říká pravý opak toho, co se právě stalo.
        var tokens = 0
        var passes = 0
        var summaries: [String] = []
        var done = 0
        for section in sections {
            let size = await nextChunk()
            let pieces = DocumentSections.chunks(of: section.text, maxCharacters: size)
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                done += 1
                let heading = section.title.isEmpty ? "Část \(done)" : section.title
                let label = pieces.count > 1 ? "\(heading) (\(index + 1)/\(pieces.count))" : heading
                continuation.yield(.status("\(label)\n"))

                let prompt = """
                    Níže je část dokumentu „\(name)“ – \(label).

                    Vypiš z ní věcné shrnutí v odrážkách: hlavní tvrzení, čísla, data, názvy \
                    a závazky. Drž se výhradně toho, co je v textu – nic nedoplňuj a nehodnoť. \
                    Nepiš úvod ani závěr, jen odrážky.

                    \(piece)
                    """
                let pass = try await collect(prompt)
                tokens += pass.tokens
                passes += 1
                if !pass.text.isEmpty {
                    summaries.append("## \(label)\n\(pass.text)")
                }
            }
        }

        guard !summaries.isEmpty else {
            throw ProviderError.engine("Z dokumentu se nepodařilo získat žádné shrnutí.")
        }

        // 3) Dílčí shrnutí složit do jednoho. Když jsou dohromady zas moc dlouhá,
        //    projdou dalším kolem slučování – u opravdu velkých dokumentů i víckrát.
        var merged = summaries
        var rounds = 0
        while rounds < 3, merged.count > 1 {
            let limit = await nextChunk()
            guard merged.joined(separator: "\n\n").count > limit else { break }
            rounds += 1
            continuation.yield(.status("\nSlučuji dílčí shrnutí (kolo \(rounds)).\n"))
            var next: [String] = []
            for group in DocumentSections.chunks(
                of: merged.joined(separator: "\n\n"), maxCharacters: limit
            ) {
                try Task.checkCancellation()
                let prompt = """
                    Níže jsou dílčí shrnutí částí dokumentu „\(name)“. Slouč je do jednoho \
                    kratšího celku. Zachovej čísla, data a názvy, odstraň opakování. \
                    Nepiš úvod ani závěr, jen odrážky.

                    \(group)
                    """
                let pass = try await collect(prompt)
                tokens += pass.tokens
                passes += 1
                next.append(pass.text)
            }
            merged = next.filter { !$0.isEmpty }
        }

        // 4) Poslední kolo už se streamuje uživateli.
        try Task.checkCancellation()
        continuation.yield(.status("\nPíšu výsledné shrnutí.\n"))

        tokens += try await forward(
            finalPrompt(
                name: name, instruction: instruction,
                body: merged.joined(separator: "\n\n"), missing: missing),
            into: continuation
        )
        passes += 1
        continuation.yield(.status(
            "\nHotovo – \(passes.czech("průchod", "průchody", "průchodů")), ≈ \(tokens.compactFormatted) tokenů celkem. "
            + "Ukazatel kontextu nahoře ukazuje jen ten poslední.\n"))
    }

    /// Pasáže vybrané podle zadání, když se uživatel ptá na konkrétní věc uvnitř kapitoly.
    /// Vrátí nil, když je zadání obecné („shrň Item 1A“) nebo se v kapitole nic netrefilo –
    /// pak se kapitola poctivě projde celá.
    ///
    /// Práh jsou dvě obsahová slova a dvě nalezené pasáže. Míň znamená, že zadání nic
    /// neupřesňuje a zúžení by z něj udělalo náhodný výsek.
    /// Výsledek zúžení. `keywords` je vyplněné, jen když se muselo sáhnout po modelu –
    /// tedy když je dotaz v jiném jazyce než podklad.
    private struct Focus {
        let excerpts: [IndexedChunk]
        let keywords: String?
    }

    private func focused(
        _ sections: [DocumentSection], instruction: String, name: String, budget: Int
    ) async -> Focus? {
        let terms = Set(Terms.stems(of: instruction).filter { !Self.isNoise($0) })
        guard terms.count >= 2 else { return nil }

        let index = DocumentIndex.build(
            sections: sections, source: name, chunkSize: max(600, min(1_500, budget / 4)))
        guard !index.isEmpty else { return nil }

        let characterBudget = max(1_000, budget - 1_500)
        let hits = index.search(terms.joined(separator: " "), characterBudget: characterBudget)
        if hits.count >= 2 { return Focus(excerpts: hits, keywords: nil) }

        // Netrefilo se to. Než se kapitola projde celá, stojí za jeden krátký průchod
        // zeptat se modelu na klíčová slova v jazyce podkladu – česky položený dotaz
        // nad anglickou výroční zprávou jinak nenajde nic.
        guard let keywords = await QueryExpansion.keywords(
            for: instruction, sample: index.sample, using: step) else { return nil }
        let retry = index.search(keywords, characterBudget: characterBudget)
        return retry.count >= 2 ? Focus(excerpts: retry, keywords: keywords) : nil
    }

    /// Slova, kterými se zadává shrnutí nebo odkazuje na kapitolu. Obsah neupřesňují,
    /// takže se z dotazu vyhodí – jinak by „shrň“ hledalo pasáže, kde je „shrnutí“.
    private static func isNoise(_ term: String) -> Bool {
        if term.count <= 2, term.first?.isNumber == true { return true }
        let stems = [
            "shrn", "souhrn", "struc", "zjednod", "sumar", "podstat", "prehle", "zaver",
            "summar", "overvi", "tldr", "item", "polozk", "kapito", "part", "cast", "oddil",
            "napis", "vypis", "popis", "udel", "dokum", "text", "soubor", "zprav", "prilo"
        ]
        return stems.contains { term.hasPrefix($0) }
    }

    /// Prompt pro zúžené shrnutí. Proti `finalPrompt` říká modelu natvrdo, že nedostal
    /// celou kapitolu, a nechá ho citovat čísla pasáží.
    private func focusedPrompt(name: String, instruction: String, body: String) -> String {
        """
        Níže jsou pasáže z dokumentu „\(name)“, které se týkají zadání. Nejsou to všechny \
        pasáže kapitoly – je to výběr podle zadání.

        Zadání uživatele: \(instruction)

        Odpověz česky a souvisle, jen z pasáží níže. U každého údaje uveď v hranatých \
        závorkách číslo pasáže, ze které pochází. Když v nich odpověď není, napiš to \
        a nedoplňuj ji z vlastní paměti.

        \(body)
        """
    }

    /// - Parameter missing: kapitoly, které uživatel vyžádal a v dokumentu nejsou.
    ///   Pokyn o nich se přidá, jen když opravdu nějaké chybí – podmínka „když zadání
    ///   zmiňuje kapitolu, která tu není“ je pro 4B model příliš; splní ji naprázdno
    ///   a připíše, že nenašel kapitolu, kterou nikdo nechtěl.
    private func finalPrompt(
        name: String, instruction: String, body: String, missing: [String]
    ) -> String {
        let task = instruction.isEmpty
            ? "Napiš souvislé shrnutí celého dokumentu."
            : "Zadání uživatele: \(instruction)"
        var rules = """
            Piš česky, souvisle a bez opakování. Vycházej jen z toho, co je níže \
            a nic nedoplňuj z vlastní paměti.
            """
        if !missing.isEmpty {
            let list = missing.map { "Item \($0)" }.joined(separator: ", ")
            rules += """
                \nTyhle kapitoly uživatel vyžádal, ale v dokumentu nejsou: \(list). \
                Nepiš o nich a na konci odpovědi uveď, že se v dokumentu nenašly.
                """
        }
        return """
            Níže je podklad z dokumentu „\(name)“, v pořadí, v jakém v něm jde za sebou. \(task)

            \(rules)

            \(body)
            """
    }

    /// Poslední kolo se streamuje uživateli; hlášení o průběhu a přemýšlení se zahodí.
    /// Vrátí, kolik tokenů průchod stál – ukazatel kontextu v chatu ukazuje jen tenhle
    /// poslední, takže celkovou cenu běhu si musí spočítat pipeline sama.
    @discardableResult
    private func forward(
        _ prompt: String,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> Int {
        var tokens = 0
        for try await event in oneShotBase.stream([ChatTurn(role: .user, text: prompt)]) {
            switch event {
            case .usage(let usage):
                tokens = max(tokens, usage.used)
                continuation.yield(event)
            case .text:
                continuation.yield(event)
            case .reasoning, .promoteTextToReasoning, .status, .sources:
                break
            }
        }
        return tokens
    }

    /// Jedno kolo bez streamování – text odpovědi a cena průchodu v tokenech.
    private func collect(_ prompt: String) async throws -> (text: String, tokens: Int) {
        var text = ""
        var tokens = 0
        for try await event in oneShotStep.stream([ChatTurn(role: .user, text: prompt)]) {
            switch event {
            case .text(let piece): text += piece
            case .usage(let usage): tokens = max(tokens, usage.used)
            default: break
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), tokens)
    }
}
