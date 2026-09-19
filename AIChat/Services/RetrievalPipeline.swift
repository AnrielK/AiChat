import Foundation

/// Odpověď nad podklady, které se do kontextu nevejdou: místo ořezaného dokumentu
/// dostane model jen ty pasáže, které se týkají dotazu, a k nim úryvky z minulých chatů.
///
/// Stejně jako `SummaryPipeline` se tváří jako obyčejný `ChatProvider` – `ChatViewModel`
/// o víc kolech neví, průběh chodí jako `.status` a odpověď jako `.text`.
///
/// Dělba práce s `SummaryPipeline`: shrnutí musí projít celý dokument, tahle pipeline
/// naopak z dokumentu skoro nic nečte. Proto se zapíná v režimech `extract` a `chat`,
/// zatímco `summarize` zůstává druhé.
struct RetrievalPipeline: ChatProvider {
    /// Poskytovatel, který píše odpověď uživateli.
    let base: any ChatProvider
    /// Strop délky kontextu z nastavení; skutečná hodnota se bere z enginu.
    let contextCeiling: Int
    /// Rezerva na odpověď při výpočtu rozpočtu na podklady.
    let answerTokens: Int
    /// Hledání v historii. nil = pipeline pracuje jen s přílohami.
    let historySearch: HistoryLookup?
    /// Odkazovat se v odpovědi čísly úryvků. Drží se seznamu podkladů pod zprávou –
    /// bez něj by čísla ukazovala na něco, co uživatel nevidí.
    let cite: Bool
    /// Stručná odpověď místo rozboru toho, co v podkladech je a není.
    let concise: Bool
    /// Nadpisy pro shrnutí kapitoly; prázdné = bez předepsané struktury.
    let summaryOutline: [String]
    /// Nechat model vybrat kapitolu, ve které se má hledat.
    let sectionRouting: Bool

    /// Kolo se skládaným promptem se posílá jako jednorázové: podklady se vybírají
    /// ke každému dotazu znovu, takže na tenhle prompt se příště nenaváže a KV cache
    /// by jen držela paměť.
    private var oneShotBase: any ChatProvider { base.oneShot() }

    /// Kolik kol hledání se nejvýš povolí. Druhé kolo dostane dotaz, o který si model
    /// sám řekl; třetí by už jen opakovalo totéž a stálo minutu generování.
    private static let maxRounds = 2

    /// Značka, kterou model žádá o jiný dotaz. Jeden řádek na začátku odpovědi –
    /// úmyslně ne JSON: 4B model spolehlivě trefí prefix, strukturu s uvozovkami ne.
    private static let marker = "HLEDEJ:"

    /// `EngineLog`, ne holý `Logger`: jen tak se řádky dostanou do logu v appce.
    /// Obyčejný `Logger` s úrovní `.info` skončí v os_log, kde ho u sideloadovaného
    /// buildu stejně nepřečteš. Text dotazu jde přes `debug` – ten do souboru nepíše.
    private static let log = EngineLog(category: "retrieval")

    // MARK: - Zapnutí

    /// Vrátí pipeline, jen když dává smysl: lokální model (nebo Apple Intelligence),
    /// kde je kontext úzký. Cloudové modely mají okno na celý dokument i historii.
    /// Zda se hledání opravdu pustí, se rozhodne až v `stream` – to je poprvé, kdy jsou
    /// vidět přílohy z celé konverzace, ne jen ty právě odeslané.
    @MainActor
    static func wrapping(
        _ base: any ChatProvider,
        settings: SettingsStore,
        profile: TaskProfile,
        historySearch: HistoryLookup?
    ) -> RetrievalPipeline? {
        guard profile != .summarize else { return nil }
        guard settings.provider == .local || settings.provider == .apple else { return nil }
        return RetrievalPipeline(
            base: base,
            contextCeiling: settings.local.contextLength,
            answerTokens: settings.local.maxTokens,
            historySearch: historySearch,
            cite: settings.local.showSources,
            concise: settings.local.conciseAnswers,
            summaryOutline: settings.local.outline(for: .summarize),
            sectionRouting: settings.local.sectionRouting
        )
    }

    // MARK: - ChatProvider

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

    private func run(
        _ history: [ChatTurn],
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let question = history.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var searchable = question
        let documents = Self.documents(in: history)
        let characters = documents.reduce(0) { $0 + $1.characterCount }
        let budget = await promptBudget()

        // Otagovaná čísla z inline XBRL. Berou se vždycky, i když se dokument do kontextu
        // vejde celý: v čistém textu je z tabulky výkazu řada čísel bez popisků, kdežto
        // tady si každé nese ukazatel, období i segment.
        // Název souboru nese už hlavička výpisu, takže stačí samotné tabulky.
        let tagged = documents.compactMap(\.facts)

        // Podklady se vejdou celé (nebo žádné nejsou) – hledání by jen ubralo přesnost.
        // U otagovaného podkladu se hledá vždycky: prompt pak vedle úryvků nese i fakta.
        let needsDocument = characters > budget || !tagged.isEmpty
        // V chatu nad dokumentem se historie neprohledává: „poslední odstavec“ nebo
        // „minulý rok“ se skoro vždy týká přílohy, ne starých konverzací.
        let needsHistory = documents.isEmpty
            && historySearch != nil
            && !question.isEmpty
            && ConversationSearch.isHistoryQuestion(question)

        guard needsDocument || needsHistory else {
            for try await event in base.stream(history) { continuation.yield(event) }
            return
        }

        // Rozdělení rozpočtu: dokument dostane většinu, historie zbytek, recap konverzace
        // je pevná malá položka. Nechává se ~15 % na instrukce a hlavičky šablony.
        let recap = Self.recap(of: history, characterBudget: min(1_200, budget / 6))
        var remaining = budget - recap.count - 600
        // Fakta jsou pár desítek krátkých řádků; zbytek rozpočtu zůstává úryvkům.
        let factBudget = tagged.isEmpty ? 0 : max(800, min(3_500, remaining / 3))
        remaining -= factBudget

        var historyBlock = ""
        if needsHistory, let historySearch {
            continuation.yield(.status("Prohledávám historii chatů.\n"))
            historyBlock = await historySearch(question)
            remaining -= historyBlock.count
            continuation.yield(.status(
                historyBlock.isEmpty
                    ? "V historii se nic podobného nenašlo.\n"
                    : "Našel jsem starší zprávy k tématu.\n"))
        }

        // Fakta jdou první. Je to čisté porovnávání řetězců bez volání modelu, takže
        // je zadarmo spočítat je hned – a jejich výsledek rozhoduje, jak moc se má
        // hledat v textu. Obráceně (jak to bylo dřív) se textová větev odpracovala celá,
        // včetně průchodu modelem na výběr kapitoly, i když odpověď ležela v tabulce.
        var factBlocks = Self.facts(
            in: tagged, matching: searchable, characterBudget: factBudget, concise: concise)
        // Když samotná zpráva nic netrefila, zkusí se i s předchozím dotazem.
        if factBlocks.isEmpty, !tagged.isEmpty, let follow = Self.followUp(to: question, in: history) {
            let retry = Self.facts(
                in: tagged, matching: follow, characterBudget: factBudget, concise: concise)
            if !retry.isEmpty {
                searchable = follow
                factBlocks = retry
            }
        }
        if !tagged.isEmpty {
            continuation.yield(.status(
                factBlocks.isEmpty
                    ? "Otagovaná čísla (XBRL) k dotazu nic nemají, hledám v textu.\n"
                    : "Beru otagovaná čísla (XBRL) přímo z podkladu.\n"))
        }

        var index: DocumentIndex?
        if needsDocument {
            let names = documents.map(\.name).joined(separator: ", ")
            // Velikost kusu se zaokrouhlí, aby se kvůli pár znakům v recapu
            // nezahazovala cache indexu.
            let chunkSize = (max(600, min(1_500, remaining / 4)) / 100) * 100
            let built = await DocumentIndexCache.shared.index(for: documents, chunkSize: chunkSize)
            guard !built.isEmpty else {
                throw ProviderError.engine("Z přiložených souborů se nepodařilo získat žádný text.")
            }

            // Příloha visí v konverzaci pořád, ale ne každý dotaz se jí týká. Když s ní
            // dotaz nemá společné jediné slovo a ani se na ni neodkazuje, je to běžná
            // zpráva – hledat v dokumentu by ji jen zpomalilo a zamotalo.
            // Totéž pro hledání v textu: než se dotaz prohlásí za netýkající se přílohy,
            // zkusí se doplnit o předchozí zprávu.
            if built.overlap(with: searchable) == 0,
               let follow = Self.followUp(to: question, in: history),
               built.overlap(with: follow) > 0 {
                searchable = follow
            }
            if factBlocks.isEmpty, !question.isEmpty,
               built.overlap(with: searchable) == 0,
               !Self.mentionsDocument(question, names: documents.map(\.name)) {
                for try await event in base.stream(history) { continuation.yield(event) }
                return
            }

            continuation.yield(.status(
                factBlocks.isEmpty
                    ? "Podklad „\(names)“ má \(characters.compactFormatted) znaků a do kontextu "
                        + "se nevejde – hledám v něm relevantní pasáže.\n"
                    : "Z textu podkladu „\(names)“ přiberu jen pár pasáží k souvislostem.\n"))
            index = built
        }

        Self.log.notice("""
            rozpočet \(budget) znaků · podklady \(characters) znaků · \
            fakta \(factBudget) znaků · zbývá \(remaining) znaků\
            \(tagged.isEmpty ? "" : " · otagovaných podkladů \(tagged.count)")
            """)

        var query = searchable
        for round in 1...Self.maxRounds {
            try Task.checkCancellation()

            // Dotaz na celý výkaz („vypiš rozvahu“) chce tabulku, ne jednu větu. Pro
            // takové kolo se výběr faktů nezkracuje a odpadnou i pravidla stručnosti.
            let wantsStatement = InlineXBRL.statementRequest(in: query)
            // „Shrň Item 7“ není hledání: BM25 na slova „shrň“ a „7“ nemá v anglickém
            // dokumentu co potkat. Kapitola se vezme celá, ne po úryvcích. Detekce je
            // společná s `AgentPipeline`, ať se to chová stejně s agentem i bez něj.
            let summaryTitle = round == 1
                ? index.flatMap { AgentPipeline.summaryTarget(in: query, outline: $0.outline) }
                : nil
            let wantsWholeChapter = summaryTitle != nil
            let brief = concise && !wantsStatement && !wantsWholeChapter

            // V dalších kolech se dotaz změnil, takže se fakta vyberou znovu.
            if round > 1 || wantsStatement {
                factBlocks = Self.facts(
                    in: tagged, matching: query, characterBudget: factBudget, concise: brief)
            }
            // Čísla nese tabulka faktů; text se přibírá jen kvůli souvislostem („proč
            // vzrostly“). Míň úryvků znamená kratší prompt a u lokálního modelu je
            // délka promptu to, co se platí nejvíc.
            let lean = !factBlocks.isEmpty && !wantsWholeChapter

            var excerpts: [IndexedChunk] = []
            if let index {
                let excerptBudget = max(1_000, lean ? remaining / 3 : remaining)

                if let summaryTitle {
                    // Kapitola od začátku, dokud se vejde. Item 7 má u NVDA 34 tisíc
                    // znaků a do rozpočtu se vejde celý; Item 1A má 115 tisíc a ne.
                    let whole = index.section(summaryTitle, characterBudget: 2_000_000)
                    let size = whole.reduce(0) { $0 + $1.text.count }
                    excerpts = index.section(summaryTitle, characterBudget: excerptBudget)
                    continuation.yield(.status(
                        size > excerptBudget
                            ? "Kapitola „\(summaryTitle)“ má \(size.compactFormatted) znaků "
                                + "a celá se do kontextu nevejde – shrnuju její začátek.\n"
                            : "Beru celou kapitolu „\(summaryTitle)“.\n"))
                }

                // Hledání přes celý dokument je základ – běží vždycky.
                if excerpts.isEmpty {
                    excerpts = index.search(
                        query, characterBudget: excerptBudget, maxChunks: lean ? 3 : 8)
                }

                // Výběr kapitoly je jen nápověda, ne filtr. Model se v ní plete
                // (dotaz na tržby → „Item 4 – Mine Safety Disclosures“) a když se
                // hledalo výhradně v ní, zbytek dokumentu se vůbec nepodíval.
                // Zásah z kapitoly se proto předřadí a zbytek rozpočtu doplní
                // globální výsledky.
                if sectionRouting, !lean, !wantsWholeChapter, round == 1, index.outline.count >= 3,
                   let picked = await cachedSection(for: query, outline: index.outline) {
                    let inSection = index.search(
                        query, inSection: picked, characterBudget: excerptBudget / 2)
                    if inSection.isEmpty {
                        // Kapitola dotaz neobsahuje – volba byla nejspíš mimo.
                        continuation.yield(.status(
                            "Kapitola „\(picked)“ k dotazu nic nemá, hledám v celém dokumentu.\n"))
                    } else {
                        continuation.yield(.status("Přednostně kapitola „\(picked)“.\n"))
                        let ids = Set(inSection.map(\.id))
                        excerpts = inSection + excerpts.filter { !ids.contains($0.id) }
                    }
                }

                // Netrefilo se to. Nejčastější důvod není, že by v dokumentu odpověď
                // nebyla, ale že je dotaz v jiném jazyce – hledá se na slovech.
                // Překládat má smysl jen mezi různými jazyky, jinak je to průchod navíc.
                if excerpts.isEmpty, !lean, !wantsWholeChapter, round == 1,
                   Self.needsTranslation(query: query, document: index.language),
                   let keywords = await cachedKeywords(for: query, sample: index.sample) {
                    continuation.yield(.status(
                        "Dotaz je v jiném jazyce než podklad – hledám podle „\(keywords)“.\n"))
                    excerpts = index.search(keywords, characterBudget: excerptBudget)
                }

                if excerpts.isEmpty, !lean {
                    excerpts = index.opening(characterBudget: max(1_000, remaining))
                    continuation.yield(.status(
                        "Na „\(query)“ se nic netrefilo, beru začátek dokumentu.\n"))
                } else if !excerpts.isEmpty {
                    let labels = Set(excerpts.map(\.label)).sorted().joined(separator: ", ")
                    continuation.yield(.status(
                        "Kolo \(round): \(excerpts.count.czech("úryvek", "úryvky", "úryvků")) – \(labels)\n"))
                }
            }

            // Úryvky se uloží ke zprávě, ať jdou po odpovědi rozkliknout. Druhé kolo
            // ty z prvního nahradí – odpověď vznikne z toho, co měl model nakonec.
            let sources = excerpts.enumerated().map {
                MessageSource(number: $0.offset + 1, chunk: $0.element)
            }
            if cite, !sources.isEmpty { continuation.yield(.sources(sources)) }

            let prompt = Self.prompt(
                question: question,
                recap: recap,
                facts: factBlocks,
                excerpts: excerpts,
                outline: index?.outline ?? [],
                historyBlock: historyBlock,
                allowFollowUp: round < Self.maxRounds && index != nil,
                cite: cite,
                concise: brief,
                statement: wantsStatement && !factBlocks.isEmpty,
                summaryOutline: wantsWholeChapter ? summaryOutline : []
            )
            Self.log.notice("""
                kolo \(round) · prompt \(prompt.count) znaků · \
                \(excerpts.count) úryvků\(lean ? " (zeštíhleno)" : "") · \
                fakta \(factBlocks.isEmpty ? "ne" : "ano") \(factBlocks.reduce(0) { $0 + $1.count }) znaků · \
                historie \(historyBlock.count) znaků
                """)
            Self.log.debug("kolo \(round) · dotaz \(query)")

            let result = try await answer(prompt, into: continuation)
            // Značku menší model často nenapíše a místo ní zformuluje větu. Bez téhle
            // záchrany druhé kolo neproběhne a uživateli zůstane půlka odpovědi.
            let followUp = result.followUp ?? Self.salvagedQuery(from: result.streamed)
            guard let followUp, !followUp.isEmpty, round < Self.maxRounds else { return }
            // Model si řekl o jiný dotaz. Původní otázka se k němu přidá, ať se hledání
            // neodkloní úplně jinam, když model navrhne nesmysl.
            continuation.yield(.status("\nZkouším to znovu s dotazem „\(followUp)“.\n"))
            query = followUp + " " + question
        }
    }

    /// Dotaz doplněný o předchozí zprávu uživatele, nebo nil, když žádná není.
    ///
    /// Navazující zpráva sama o sobě nemá čím hledat: „Celou tabulku se všema daty
    /// prosím“ neobsahuje jediný pojem z dokumentu. Bez doplnění se vybere náhodná
    /// kapitola (u mě „Item 6 – [Reserved]“), spustí se překlad dotazu do jazyka
    /// dokumentu a model dostane úryvky z Item 1 – Business.
    ///
    /// Nepoužívá se vždycky, jen když hledání podle samotné zprávy nic nenašlo –
    /// jinak by přilepený text přebil dotaz, který je v pořádku.
    private static func followUp(to question: String, in history: [ChatTurn]) -> String? {
        guard let previous = history.dropLast().last(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty
        else { return nil }
        return question + " " + String(previous.prefix(200))
    }

    /// Řádky tabulek faktů, které se týkají dotazu. Prázdné pole = žádný otagovaný
    /// podklad, nebo se v něm k dotazu nic nenašlo.
    private static func facts(
        in tables: [String], matching query: String, characterBudget: Int, concise: Bool
    ) -> [String] {
        guard characterBudget > 0 else { return [] }
        // Ve stručném režimu se výběr zkrátí. Čtyřicet řádků v promptu malý model svádí
        // k tomu, že je celé přepíše do odpovědi jako markdown tabulku – na dotaz,
        // který chtěl jedno číslo.
        let budget = concise ? min(characterBudget, 1_200) : characterBudget
        return tables.compactMap { table in
            let excerpt = InlineXBRL.excerpt(
                from: table, matching: query,
                maxLines: concise ? 12 : 40, characterBudget: budget)
            return excerpt.isEmpty ? nil : excerpt
        }
    }

    // MARK: - Jedno kolo

    /// Odešle prompt a streamuje odpověď uživateli. Vrátí dotaz, o který si model řekl
    /// značkou `HLEDEJ:`, jinak nil.
    ///
    /// Začátek odpovědi se drží v bufferu, dokud je jasné, jestli jde o značku –
    /// jinak by uživatel v odpovědi na chvíli uviděl „HLEDEJ: …“, než by se to zahodilo.
    private func answer(
        _ prompt: String,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> (followUp: String?, streamed: String) {
        var buffer = ""
        var streaming = false
        var streamed = ""

        for try await event in oneShotBase.stream([ChatTurn(role: .user, text: prompt)]) {
            switch event {
            case .usage, .reasoning, .promoteTextToReasoning:
                continuation.yield(event)
            case .status, .sources:
                break  // hlášení podřízeného kola patří nám, ne uživateli
            case .text(let piece):
                if streaming {
                    streamed += piece
                    continuation.yield(.text(piece))
                    continue
                }
                buffer += piece
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isMarker(trimmed) {
                    // Konec řádku = značka je celá; dřív generovat nemá smysl.
                    guard let line = trimmed.split(separator: "\n", maxSplits: 1).first,
                          trimmed.contains("\n") || line.count > 120 else { continue }
                    return (line.dropFirst(Self.marker.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines), streamed)
                }
                if Self.couldBeMarker(trimmed) { continue }
                streaming = true
                streamed += buffer
                continuation.yield(.text(buffer))
                buffer = ""
            }
        }
        // Odpověď skončila dřív, než se rozhodlo (velmi krátká odpověď nebo samotná značka).
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isMarker(trimmed) {
            let query = trimmed.dropFirst(Self.marker.count)
                .split(separator: "\n").first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return (query, streamed)
        }
        if !buffer.isEmpty {
            streamed += buffer
            continuation.yield(.text(buffer))
        }
        return (nil, streamed)
    }

    /// Dotaz pro další kolo, když model značku nepoužil. Odpověď už uživatel vidí,
    /// takže druhé kolo na ni naváže, místo aby ji nahradilo.
    private static func salvagedQuery(from text: String) -> String? {
        impliedQuery(in: text)
    }


    private static func isMarker(_ text: String) -> Bool {
        text.uppercased().hasPrefix(marker)
    }

    /// Menší model značku často nenapíše a místo ní zformuluje větu („…vyhledávám
    /// klíčová slova: revenue, 2026“). Tím se druhé kolo nespustí a uživatel dostane
    /// půlku odpovědi. Když se taková věta objeví, vezmou se slova za dvojtečkou.
    private static func impliedQuery(in text: String) -> String? {
        let lower = text.lowercased()
        let phrases = ["klíčová slova:", "klicova slova:", "hledám:", "hledam:",
                       "vyhledávám:", "vyhledavam:", "keywords:"]
        guard let phrase = phrases.first(where: { lower.contains($0) }),
              let range = lower.range(of: phrase) else { return nil }
        let tail = text[range.upperBound...]
            .prefix(120)
            .split(whereSeparator: { "\n.;".contains($0) })
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return tail.count >= 3 ? tail : nil
    }

    /// Text je zatím kratší než značka a může se jí ještě stát.
    private static func couldBeMarker(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < marker.count else { return false }
        return marker.hasPrefix(text.uppercased())
    }

    // MARK: - Prompt

    private static func prompt(
        question: String,
        recap: String,
        facts: [String],
        excerpts: [IndexedChunk],
        outline: [String],
        historyBlock: String,
        allowFollowUp: Bool,
        cite: Bool,
        concise: Bool,
        statement: Bool,
        // Nadpisy pro shrnutí – jiná věc než `outline`, což je osnova dokumentu.
        summaryOutline: [String]
    ) -> String {
        var parts: [String] = []

        if !outline.isEmpty {
            let list = outline.prefix(25).joined(separator: " · ")
            parts.append("Osnova dokumentu: \(list)")
        }
        if !excerpts.isEmpty {
            let blocks = excerpts.enumerated().map { index, chunk in
                "### [\(index + 1)] \(chunk.label)\n\(chunk.text)"
            }
            parts.append("""
                Úryvky z dokumentu, které se nejvíc týkají dotazu. Dokument je delší, \
                tohle je výběr – co v něm není, v úryvcích prostě chybí.

                \(blocks.joined(separator: "\n\n"))
                """)
        }
        if !historyBlock.isEmpty {
            parts.append("""
                Úryvky z minulých konverzací s tímhle uživatelem:

                \(historyBlock)
                """)
        }
        if !recap.isEmpty {
            parts.append("Dosavadní konverzace:\n\(recap)")
        }

        // Fakta jdou záměrně až za úryvky, těsně před dotaz. Když byla nahоře, přehlušily
        // je úryvky pod nimi – model vyčetl číslo z tabulky v textu a k řádku
        // „Revenues | FY2026“, který měl přímo v promptu, napsal, že data za 2026 nejsou.
        if !facts.isEmpty {
            parts.append("""
                Čísla, která firma ve zprávě sama otagovala – tohle je pro číselné údaje \
                závazný zdroj. Každý řádek nese ukazatel, období i rozpad, takže se z nich \
                nedá splést sloupec ani řádek tabulky. Když se liší od čísla vyčteného \
                z úryvků výše, platí tenhle výpis – a když je údaj tady, nepiš, že v podkladech \
                není. Je to podklad, ne odpověď: vyber z něj, na co se uživatel ptá, \
                a zbytek neopisuj.

                \(facts.joined(separator: "\n\n"))
                """)
        }

        parts.append("Dotaz uživatele: \(question.isEmpty ? Attachment.defaultPrompt : question)")

        var rules = "Odpověz česky a jen z podkladů výše – nic nedoplňuj z vlastní paměti."
        if let shape = TaskProfile.outlineBlock(summaryOutline) {
            rules += "\n\n" + shape
        }
        if statement {
            // Bez tohohle model vypíše tři řádky a zbytek okomentuje. Výpis je tabulka,
            // kterou si uživatel vyžádal – má se přepsat, ne shrnout.
            rules += """
                 Uživatel si vyžádal celý výkaz: přepiš **všechny** řádky z výpisu \
                otagovaných čísel jako tabulku, ve stejném pořadí, s původními názvy \
                a jednotkami. Nic nevynechávej, nepřepočítávej a nekomentuj.
                """
        }
        if !facts.isEmpty {
            rules += """
                 Číselné údaje ber z otagovaných čísel, ne z tabulek v textu. \
                Zdrojem je přiložený soubor – neuváděj k odpovědi žádné odkazy ani adresy, \
                v podkladech nejsou. Rozpad po segmentech nebo regionech uveď jen tehdy, \
                když si o něj dotaz říká.
                """
        }
        if cite {
            rules += " U každého údaje uveď v hranatých závorkách číslo úryvku, ze kterého pochází."
        }
        if concise {
            // Bez tohohle model rozebírá, že dostal jen výběr z dokumentu, a vlastní
            // odpověď se ztratí. Na dotaz typu „najdi v souboru X“ stačí jedno číslo.
            rules += """
                \nOdpověz co nejstručněji – jednou větou, bez nadpisů a tabulek. \
                Nekomentuj, že máš jen výběr z dokumentu, ani jak jsi k údaji došel. \
                Rozepisuj se jen tam, kde si dotaz o rozbor výslovně říká.
                """
        }
        if allowFollowUp {
            rules += """
                \nKdyž v podkladech odpověď není, nevymýšlej si a nepiš omluvu. Napiš jediný \
                řádek ve tvaru:
                \(marker) klíčová slova, pod kterými by to v dokumentu mohlo být
                a nic dalšího. Vyhledá se podle nich znovu.
                """
        } else {
            rules += "\nKdyž v podkladech odpověď není, napiš rovnou, že se v dokumentu nenašla."
        }
        parts.append(rules)

        return parts.joined(separator: "\n\n")
    }

    /// Má smysl dotaz překládat? Jen když je podklad prokazatelně v jiném jazyce.
    /// Když se jazyk určit nedá, překlad se radši zkusí – stálo to dosud vždycky.
    private static func needsTranslation(query: String, document: TextLanguage) -> Bool {
        guard document != .unknown else { return true }
        let asked = TextLanguage.of(query)
        return asked == .unknown || asked != document
    }

    /// Klíčová slova k dotazu z cache, jinak jeden průchod modelem.
    private func cachedKeywords(for query: String, sample: String) async -> String? {
        if let stored = await DocumentIndexCache.shared.keywords(for: query) { return stored }
        guard let fresh = await QueryExpansion.keywords(for: query, sample: sample, using: base)
        else { return nil }
        await DocumentIndexCache.shared.store(keywords: fresh, for: query)
        return fresh
    }

    /// Kapitola k dotazu z cache, jinak jeden průchod modelem. Prázdná hodnota v cache
    /// znamená „model nevybral“ – aby se na stejný dotaz nezkoušel znovu.
    private func cachedSection(for query: String, outline: [String]) async -> String? {
        if let stored = await DocumentIndexCache.shared.section(for: query) {
            return stored.isEmpty ? nil : stored
        }
        let picked = await QueryExpansion.section(for: query, outline: outline, using: base)
        await DocumentIndexCache.shared.store(section: picked ?? "", for: query)
        return picked
    }

    /// Odkazuje se dotaz na přílohu, i když s ní nesdílí žádné slovo? („shrň to“,
    /// „co je v tom souboru“). Bez tohohle by se takový dotaz vyhodnotil jako běžná
    /// zpráva a dokument by se přeskočil.
    private static func mentionsDocument(_ question: String, names: [String]) -> Bool {
        let text = question.lowercased()
        for name in names {
            let stem = (name as NSString).deletingPathExtension.lowercased()
            if !stem.isEmpty, text.contains(stem) { return true }
        }
        let markers = ["soubor", "dokument", "příloh", "priloh", "text", "tabulk", "report",
                       "zpráv", "zprav", "smlouv", "faktur", "výkaz", "vykaz", "pdf",
                       "shrň", "shrn", "výtah", "vytah", "obsah", "kapitol"]
        return markers.contains { text.contains($0) }
    }

    /// Posledních pár výměn bez příloh – aby navazující dotaz („a kolik to bylo loni?“)
    /// dával smysl. Přílohy se sem nevkládají, od toho jsou úryvky.
    private static func recap(of history: [ChatTurn], characterBudget: Int) -> String {
        var lines: [String] = []
        var remaining = characterBudget
        for turn in history.dropLast().reversed() {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = text.count > 400 ? String(text.prefix(400)) + " […]" : text
            let line = (turn.role == .user ? "Uživatel: " : "Asistent: ") + clipped
            guard line.count <= remaining else { break }
            remaining -= line.count
            lines.insert(line, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rozpočet

    /// Přílohy z celé konverzace, každá jednou a jen ty, ze kterých je text.
    private static func documents(in history: [ChatTurn]) -> [Attachment] {
        var seen = Set<UUID>()
        var result: [Attachment] = []
        // V pořadí, v jakém přišly – index podle toho čísluje úryvky.
        for turn in history {
            for attachment in turn.attachments where !attachment.text.isEmpty {
                guard seen.insert(attachment.id).inserted else { continue }
                result.append(attachment)
            }
        }
        return result
    }

    /// Kolik znaků podkladů se vejde do jednoho promptu. Stejný odhad jako
    /// v `SummaryPipeline`: 2,5 znaku na token a 2 000 znaků rezerva na systémový
    /// prompt a hlavičky šablony.
    @MainActor
    private func promptBudget() -> Int {
        let ceiling = LocalRuntime.shared.effectiveContext ?? Self.estimatedContext()
        let context = min(contextCeiling, ceiling)
        let promptTokens = max(512, context - answerTokens)
        return max(2_000, Int(Double(promptTokens) * 2.5) - 2_000)
    }

    /// Odhad kontextu z volné paměti, dokud engine neohlásí skutečnou hodnotu.
    private static func estimatedContext() -> Int {
        let free = MemoryBudget.available - MemoryBudget.reserve
        guard free > 0 else { return 4_096 }
        return max(2_048, free / 147_456 / 256 * 256)
    }
}
