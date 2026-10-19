import Foundation
import FinFillCore

/// Skilly z anthropics/financial-services (equity-research) jako lomítkové příkazy v chatu.
/// Data ze SEC, text píše model vybraný v Nastavení; zpráva se modelu jako dotaz neposílá.
///
///     /earnings-analysis NVDA          výsledky posledního kvartálu + review MD&A
///     /earnings-preview NVDA           náhled příštích výsledků: odhad termínu, scénáře, na co se dívat
///     /sector-overview NVDA AMD AVGO   přehled odvětví (jen NVDA = NVDA + uložené peery)
///     /catalyst-calendar NVDA AMD      kalendář katalyzátorů (bez tickerů = watchlist)
///     /morning-note NVDA AMD           ranní poznámka z nových podání (bez tickerů = watchlist)
///     /thesis-tracker NVDA [úprava]    investiční teze, KPI z XBRL, hodnocení pilířů
///
/// `/valuation-reviewer NVDA` patří k sešitu, proto ho obsluhuje `FinFillCommand`.
struct ResearchCommand: Sendable, Equatable {
    enum Skill: String, Sendable, CaseIterable {
        case earningsAnalysis, earningsPreview, sectorOverview, catalystCalendar, morningNote, thesisTracker

        static let aliases: [String: Skill] = [
            "earnings-analysis": .earningsAnalysis, "earnings": .earningsAnalysis, "vysledky": .earningsAnalysis,
            "earnings-preview": .earningsPreview, "preview": .earningsPreview, "nahled": .earningsPreview,
            "sector-overview": .sectorOverview, "sector": .sectorOverview, "odvetvi": .sectorOverview,
            "catalyst-calendar": .catalystCalendar, "catalysts": .catalystCalendar, "kalendar": .catalystCalendar,
            "morning-note": .morningNote, "morning": .morningNote, "rano": .morningNote,
            "thesis-tracker": .thesisTracker, "thesis": .thesisTracker, "teze": .thesisTracker,
        ]
    }

    let skill: Skill
    let tickers: [String]
    /// Slova za tickerem (úpravy teze), v původním tvaru.
    let rest: [String]

    static let tickerPattern = #"^[A-Za-z][A-Za-z.\-]{0,6}$"#

    /// „/earnings-preview nvda“, „finfill earnings-preview nvda“.
    static func parse(_ text: String) -> ResearchCommand? {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard var first = words.first?.lowercased() else { return nil }
        if first == "finfill" || first == "/finfill", words.count >= 2 {
            words.removeFirst()
            first = "/" + words[0].lowercased()
        }
        guard first.hasPrefix("/") else { return nil }
        let key = String(first.dropFirst()).folding(options: .diacriticInsensitive, locale: nil)
        guard let skill = Skill.aliases[key] else { return nil }
        let args = Array(words.dropFirst())

        if skill == .thesisTracker {
            guard let t = args.first, t.range(of: tickerPattern, options: .regularExpression) != nil else {
                return ResearchCommand(skill: skill, tickers: [], rest: [])
            }
            return ResearchCommand(skill: skill, tickers: [t.uppercased()], rest: Array(args.dropFirst()))
        }
        let tickers = args.flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) }
            .filter { $0.range(of: tickerPattern, options: .regularExpression) != nil }
            .map { $0.uppercased() }
        var seen = Set<String>()
        return ResearchCommand(skill: skill, tickers: tickers.filter { seen.insert($0).inserted }, rest: [])
    }

    static let help = """
    **Analytické příkazy** (data SEC, text píše model z Nastavení)

    - `/earnings-analysis NVDA` – výsledky posledního kvartálu, YoY/QoQ a review MD&A
    - `/earnings-preview NVDA` – odhad termínu příštích výsledků, scénáře, na co se dívat
    - `/sector-overview NVDA AMD AVGO` – srovnání odvětví (jen `NVDA` = s uloženými peery)
    - `/catalyst-calendar NVDA AMD` – kalendář na 60 dní (bez tickerů watchlist)
    - `/morning-note NVDA AMD` – ranní poznámka z nových podání (bez tickerů watchlist)
    - `/thesis-tracker NVDA` – teze s KPI z XBRL; úpravy: `teze …`, `long …`, `pilíř …`, `riziko …`, `kpi růst tržeb > 20 %`, `cíl 250`, `stop …`, `poznámka …`, `odebrat pilíř 2`, `smazat`
    - `/valuation-reviewer NVDA` – kontrola ocenění v sešitu: DCF vs. Comps vs. trh, WACC, LTM
    """
}

struct ResearchCommandProvider: ChatProvider {
    let command: ResearchCommand
    let engine: FinFillEngine?

    @MainActor
    static func wrapping(text: String, settings: SettingsStore, models: ModelManager) -> ResearchCommandProvider? {
        guard let command = ResearchCommand.parse(text) else { return nil }
        return ResearchCommandProvider(command: command, engine: FinFillEngine.current(settings: settings, models: models))
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Nastavení

    static let defaults = UserDefaults.standard
    static var userAgent: String {
        defaults.string(forKey: "finfill.ua").flatMap { $0.isEmpty ? nil : $0 } ?? "AIChat FinFill contact@example.com"
    }
    static var watchlist: [String] {
        (defaults.string(forKey: "finfill.watchlist") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    static func peers(_ ticker: String) -> [String] {
        FinFillPipeline.normalizedPeers([defaults.string(forKey: "finfill.peers." + ticker) ?? ""], excluding: ticker)
    }
    static var thesisStore: ThesisStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ThesisStore(url: base.appendingPathComponent("FinFill/theses.json"))
    }

    // MARK: - Běh

    private func run(into out: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        let skills = ResearchSkills(userAgent: Self.userAgent, engine: engine, language: "Czech") { line in
            out.yield(.status(line + "\n"))
        }
        let tickers = command.tickers
        let md: String

        switch command.skill {
        case .earningsAnalysis:
            guard let t = tickers.first else { out.yield(.text("Zadej ticker: `/earnings-analysis NVDA`")); return }
            md = try await skills.earningsAnalysis(t)

        case .earningsPreview:
            guard let t = tickers.first else { out.yield(.text("Zadej ticker: `/earnings-preview NVDA`")); return }
            md = try await skills.earningsPreview(t)

        case .sectorOverview:
            var list = tickers
            if list.count == 1 { list += Self.peers(list[0]) }
            guard list.count >= 2 else {
                out.yield(.text("Přehled odvětví potřebuje aspoň dvě firmy: `/sector-overview NVDA AMD AVGO`, "
                                + "nebo ulož peery (`finfill new NVDA peers AMD,AVGO`) a pak stačí `/sector-overview NVDA`."))
                return
            }
            md = try await skills.sectorOverview(list)

        case .catalystCalendar, .morningNote:
            let list = tickers.isEmpty ? Self.watchlist : tickers
            guard !list.isEmpty else {
                out.yield(.text("Zadej tickery, např. `/\(command.skill == .morningNote ? "morning-note" : "catalyst-calendar") NVDA AMD MSFT` – uloží se jako watchlist a příště stačí příkaz bez nich."))
                return
            }
            if !tickers.isEmpty { Self.defaults.set(tickers.joined(separator: ","), forKey: "finfill.watchlist") }
            let body = command.skill == .morningNote ? try await skills.morningNote(list) : try await skills.catalystCalendar(list)
            md = body + (tickers.isEmpty ? "" : "\n_Watchlist uložen: \(list.joined(separator: ", ")) – příště stačí příkaz bez tickerů._\n")

        case .thesisTracker:
            md = try await thesis(skills)
        }
        out.yield(.text(md))
    }

    private func thesis(_ skills: ResearchSkills) async throws -> String {
        let store = Self.thesisStore
        guard let ticker = command.tickers.first else {
            let all = store.all().values.sorted { $0.ticker < $1.ticker }
            guard !all.isEmpty else { return ResearchCommand.help }
            return "# Uložené teze\n\n| Ticker | Pozice | Teze | Přesvědčení | Upraveno |\n|---|---|---|---|---|\n"
                + all.map { "| \($0.ticker) | \($0.position == .long ? "Long" : "Short") | \($0.statement.isEmpty ? "—" : $0.statement) | \($0.conviction ?? "—") | \($0.updated) |" }
                    .joined(separator: "\n") + "\n\nDetail: `/thesis-tracker NVDA`"
        }
        let today = FilingCalendar.today()
        var t = store.get(ticker) ?? Thesis(ticker: ticker)
        let edit = ThesisEdit.parse(command.rest)
        switch edit {
        case .show:
            let (md, conviction) = try await skills.thesisReview(t)
            if let conviction, store.get(ticker) != nil { t.conviction = conviction; try store.save(t) }
            return md
        case .delete:
            try store.delete(ticker)
            return "Teze \(ticker) smazána."
        case let .invalid(msg):
            return msg + "\n\n" + ResearchCommand.help
        case let .note(text):
            let impact = await skills.noteImpact(t, note: text)
            _ = edit.apply(to: &t, today: today)
            if let impact, !t.log.isEmpty { t.log[t.log.count - 1].impact = impact }
            try store.save(t)
            return "Zapsáno do deníku \(ticker)" + (impact.map { ": _\($0)_" } ?? ".") + "\n\nCelá teze: `/thesis-tracker \(ticker)`"
        default:
            let msg = edit.apply(to: &t, today: today) ?? ""
            try store.save(t)
            return msg + "\n\n" + t.markdown(results: [], assessment: nil)
        }
    }
}
