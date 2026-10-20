import Foundation

/// Data jedné firmy pro skilly: companyfacts (10-K i 10-Q) a poslední podání.
public struct CompanyData: Sendable {
    public let ticker: String
    public let cik: Int
    public let name: String
    public let facts: [Fact]
    public let filings: [SECFiling]

    public init(ticker: String, cik: Int, name: String, facts: [Fact], filings: [SECFiling]) {
        self.ticker = ticker; self.cik = cik; self.name = name; self.facts = facts; self.filings = filings
    }

    public var quarters: QuarterlyFigures { QuarterlyFigures.compute(facts: facts) }
    public var snapshot: CompanySnapshot { CompanySnapshot.compute(ticker: ticker, name: name, facts: facts) }

    /// 10-Q nebo 10-K, ze kterého je kvartál (Q4 = 10-K).
    public func report(for quarter: FiscalQuarter) -> SECFiling? {
        filings.first { ($0.form == "10-Q" || $0.form == "10-K")
            && abs(DateOnly.days(from: $0.reportDate, to: quarter.end) ?? 999) <= 7 }
    }

    /// 8-K s výsledky za kvartál (zveřejněné do ~10 týdnů po konci).
    public func earningsRelease(for quarter: FiscalQuarter) -> SECFiling? {
        filings.filter(\.isEarningsRelease).last { f in
            (DateOnly.days(from: quarter.end, to: f.filingDate).map { (0...75).contains($0) }) ?? false
        }
    }
}

/// Skilly z anthropics/financial-services (equity-research) převedené na data SEC + model.
///
/// Čísla počítá kód z XBRL; model dostane jen ověřená čísla a píše text podle osnovy skillu.
/// Konsenzus analytiků, ceny a zprávy v datech SEC nejsou – výstupy to říkají.
public struct ResearchSkills: Sendable {
    public typealias Log = @Sendable (String) -> Void

    let sec: SECClient
    let engine: LLMEngine?
    let options: Summarizer.Options
    let log: Log

    public init(userAgent: String, engine: LLMEngine?, language: String = "Czech", log: @escaping Log = { _ in }) {
        self.sec = SECClient(userAgent: userAgent)
        self.engine = engine
        var o = Summarizer.Options()
        o.language = language
        self.options = o
        self.log = log
    }

    var writer: Summarizer? { engine.map { Summarizer(engine: $0, options: options) } }

    // MARK: - Data

    public func load(_ tickers: [String]) async throws -> [CompanyData] {
        let table = try await sec.tickerTable()
        var out: [CompanyData] = []
        for t in tickers {
            guard let entry = table[t.uppercased()] else { log("⚠︎ \(t): ticker není v SEC"); continue }
            log("SEC: \(t) – data…")
            async let factsData = sec.companyFactsData(cik: entry.cik)
            let (name, filings) = try await sec.recentFilings(cik: entry.cik)
            let facts = (try? CompanyFactsParser.parse(try await factsData, forms: CompanyFactsParser.annualAndQuarterlyForms).facts) ?? []
            out.append(CompanyData(ticker: t.uppercased(), cik: entry.cik, name: name.isEmpty ? entry.name : name,
                                   facts: facts, filings: filings))
        }
        return out
    }

    func mda(_ c: CompanyData, filing: SECFiling) async -> String? {
        guard let writer else { return nil }
        do {
            log("\(c.ticker): čtu \(filing.form) \(filing.reportDate)…")
            let html = try await sec.document(SECClient.Filing(form: filing.form, accessionNumber: filing.accessionNumber,
                                                               filingDate: filing.filingDate, reportDate: filing.reportDate,
                                                               primaryDocument: filing.primaryDocument, cik: filing.cik))
            return try await writer.mdaNotes(filingHTML: html, company: c.name, form: filing.form)
        } catch {
            log("⚠︎ \(c.ticker) \(filing.form): \(error.localizedDescription)")
            return nil
        }
    }

    static let disclaimer = "_Zdroj: SEC EDGAR (XBRL a podání). Konsenzus analytiků, ceny akcií a zprávy v datech nejsou. Není to investiční doporučení._"

    // MARK: - /earnings-analysis

    /// Výsledky posledního kvartálu: čísla z XBRL, YoY/QoQ a review MD&A modelem.
    public func earningsAnalysis(_ ticker: String) async throws -> String {
        guard let c = try await load([ticker]).first else { return "Ticker \(ticker) v SEC není." }
        let figures = c.quarters
        guard let latest = figures.latest else { return "\(c.name): kvartální data v SEC nejsou." }
        let report = c.report(for: latest.quarter)
        var text: String?
        if let report, let writer {
            do {
                log("\(c.ticker): čtu \(report.form) \(report.reportDate)…")
                let html = try await sec.document(SECClient.Filing(form: report.form, accessionNumber: report.accessionNumber,
                                                                   filingDate: report.filingDate, reportDate: report.reportDate,
                                                                   primaryDocument: report.primaryDocument, cik: report.cik))
                text = try await writer.reviewQuarter(filingHTML: html, company: c.name, figures: figures, form: report.form)
            } catch { log("⚠︎ \(error.localizedDescription)") }
        }
        let review = QuarterlyReview(company: c.name, figures: figures, filing: report.map {
            SECClient.Filing(form: $0.form, accessionNumber: $0.accessionNumber, filingDate: $0.filingDate,
                             reportDate: $0.reportDate, primaryDocument: $0.primaryDocument, cik: $0.cik)
        }, text: text, language: options.language)
        var md = review.markdown()
        var sources: [String] = []
        if let r = report { sources.append("[\(r.form) \(r.filingDate)](\(r.documentURL.absoluteString))") }
        if let e = c.earningsRelease(for: latest.quarter) { sources.append("[8-K výsledky \(e.filingDate)](\(e.documentURL.absoluteString))") }
        if !sources.isEmpty { md += "\nZdroje: " + sources.joined(separator: " · ") + "\n" }
        return md
    }

    // MARK: - /earnings-preview

    public struct Scenario: Sendable {
        public let name: String
        public let revenue: Double
        public let operatingMargin: Double?
        public let eps: Double?
        public let growthQoQ: Double
    }

    /// Mechanické scénáře z posledních 4 kvartálů: medián / max / min růstu QoQ a provozní marže.
    public static func scenarios(_ q: QuarterlyFigures) -> [Scenario] {
        let cols = Array(q.columns.prefix(5))
        guard let last = cols.first, let rev = last.value(.revenue) else { return [] }
        var growths: [Double] = []
        for i in 0..<(cols.count - 1) {
            if let a = cols[i].value(.revenue), let b = cols[i + 1].value(.revenue), b > 0 { growths.append(a / b - 1) }
        }
        let margins = cols.prefix(4).compactMap { c in c.value(.operatingIncome).flatMap { o in c.value(.revenue).map { o / $0 } } }
        guard !growths.isEmpty else { return [] }
        let sorted = growths.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let mSorted = margins.sorted()
        let mMed: Double? = mSorted.isEmpty ? nil : mSorted[mSorted.count / 2]
        let lastMargin = last.value(.operatingIncome).map { $0 / rev }
        func eps(_ r: Double, _ m: Double?) -> Double? {
            guard let e = last.value(.eps), let lm = lastMargin, lm > 0, let m else { return nil }
            return e * (r / rev) * (m / lm)
        }
        func make(_ name: String, _ g: Double, _ m: Double?) -> Scenario {
            let r = rev * (1 + g)
            return Scenario(name: name, revenue: r, operatingMargin: m, eps: eps(r, m), growthQoQ: g)
        }
        return [make("Optimistický", sorted.last!, mSorted.last),
                make("Základní", median, mMed),
                make("Pesimistický", sorted.first!, mSorted.first)]
    }

    public func earningsPreview(_ ticker: String) async throws -> String {
        guard let c = try await load([ticker]).first else { return "Ticker \(ticker) v SEC není." }
        let figures = c.quarters
        guard let latest = figures.latest else { return "\(c.name): kvartální data v SEC nejsou." }
        let today = FilingCalendar.today()
        let next = FilingCalendar.nextEarnings(c.filings, today: today)
        let nextLabel = latest.quarter.quarter == 4
            ? "Q1 FY\(String(format: "%02d", (latest.quarter.fiscalYear + 1) % 100))"
            : "Q\(latest.quarter.quarter + 1) FY\(String(format: "%02d", latest.quarter.fiscalYear % 100))"
        let sc = Self.scenarios(figures)

        var md = "# \(c.name) (\(c.ticker)) — náhled výsledků \(nextLabel)\n\n"
        if let next {
            md += "**Odhad termínu:** \(FilingCalendar.czechDay(next.date)) \(next.date) _(\(next.basis); firma termín oznamuje sama, ověř na IR webu)_\n\n"
        }
        md += "## Výchozí bod – posledních 5 kvartálů\n\n" + figures.markdown(maxColumns: 5) + "\n\n"
        if !sc.isEmpty {
            md += "## Scénáře \(nextLabel) (mechanicky z historie)\n\n| Scénář | Tržby | Růst QoQ | Provozní marže | EPS ≈ |\n|---|---:|---:|---:|---:|\n"
            for s in sc {
                md += "| \(s.name) | \(QuarterlyFigures.money(s.revenue)) | \(QuarterlyFigures.pct(s.growthQoQ)) | "
                    + "\(s.operatingMargin.map { String(format: "%.1f %%", $0 * 100) } ?? "—") | \(s.eps.map { String(format: "$%.2f", $0) } ?? "—") |\n"
            }
            md += "\n_Optimistický = nejvyšší růst QoQ a marže z posledních 4 kvartálů, základní = medián, pesimistický = nejnižší. EPS přepočteno z posledního kvartálu, ne konsenzus._\n\n"
        }
        if let writer, let report = c.report(for: latest.quarter) {
            let notes = await mda(c, filing: report) ?? ""
            let table = sc.map { "- \($0.name): revenue \(QuarterlyFigures.money($0.revenue)), QoQ \(QuarterlyFigures.pct($0.growthQoQ))" }.joined(separator: "\n")
            let prompt = """
            Write an earnings preview for \(c.name) (\(c.ticker)) ahead of its \(nextLabel) results, in \(options.language). \
            Use only the verified figures and the MD&A notes below; there is no analyst consensus and no stock price data – do not invent any. \
            Use exactly these markdown headings and keep every bullet under 25 words:

            ## Na co se dívat
            - 3–5 metrics ranked by importance, each with why it matters (refer to the latest figures)
            ## Co by muselo nastat
            - Optimistický: one sentence on what would have to happen operationally
            - Základní: one sentence
            - Pesimistický: one sentence
            ## Výhled a komentář vedení
            - up to 3 bullets: guidance or expectations stated in the MD&A
            ## Otázky pro výsledky
            - 3–4 questions management should answer on the call

            Verified figures (latest quarter \(latest.quarter.label)):
            \(figures.promptTable())

            Mechanical scenarios for \(nextLabel):
            \(table)

            MD&A notes from the latest \(report.form):
            \(String(notes.prefix(12_000)))
            """
            log("Píšu náhled…")
            md += LLMOutput.clean(try await writer.write(prompt)) + "\n\n"
        }
        md += Self.disclaimer + "\n"
        return md
    }

    // MARK: - /sector-overview

    public func sectorOverview(_ tickers: [String]) async throws -> String {
        let companies = try await load(Array(tickers.prefix(8)))
        guard !companies.isEmpty else { return "Žádný z tickerů v SEC není." }
        let snaps = companies.map(\.snapshot)
        let total = snaps.compactMap(\.revenue).reduce(0, +)
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f %%", $0 * 100) } ?? "—" }
        func ratio(_ a: Double?, _ b: Double?) -> Double? { (a != nil && b != nil && b! > 0) ? a! / b! : nil }

        var md = "# Přehled odvětví: \(snaps.map(\.ticker).joined(separator: ", "))\n\n"
        md += "## Srovnání (LTM, USD)\n\n| Firma | Tržby LTM | Podíl ve skupině | Růst tržeb | Hrubá marže | EBIT marže | FCF marže | Čistý dluh | LTM do |\n"
        md += "|---|---:|---:|---:|---:|---:|---:|---:|---|\n"
        for s in snaps.sorted(by: { ($0.revenue ?? 0) > ($1.revenue ?? 0) }) {
            md += "| \(s.name) (\(s.ticker)) | \(QuarterlyFigures.money(s.revenue)) | \(pct(ratio(s.revenue, total))) | \(pct(s.revenueGrowth)) | "
            md += "\(pct(ratio(s.grossProfit, s.revenue))) | \(pct(ratio(s.ebit, s.revenue))) | \(pct(ratio(s.freeCashFlow, s.revenue))) | "
            md += "\(QuarterlyFigures.money(s.netDebt)) | \(s.ltmEnd ?? "—")\(s.ltmQuarters == 4 ? "" : " (FY)") |\n"
        }
        func median(_ xs: [Double]) -> Double? {
            let s = xs.sorted(); guard !s.isEmpty else { return nil }
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        md += "| **Medián** | | | \(pct(median(snaps.compactMap(\.revenueGrowth)))) | \(pct(median(snaps.compactMap { ratio($0.grossProfit, $0.revenue) }))) | "
        md += "\(pct(median(snaps.compactMap { ratio($0.ebit, $0.revenue) }))) | \(pct(median(snaps.compactMap { ratio($0.freeCashFlow, $0.revenue) }))) | | |\n\n"
        md += "_Podíl = podíl na součtu tržeb skupiny, ne na celém trhu. Ocenění (EV/EBITDA, P/E) s živou cenou dá list Comps: `finfill analyze \(snaps[0].ticker)`._\n\n"

        if let writer {
            var profiles: [String] = []
            for c in companies.prefix(6) {
                guard let tenK = c.filings.first(where: { $0.form == "10-K" || $0.form == "20-F" }) else { continue }
                do {
                    log("\(c.ticker): popis byznysu z \(tenK.form)…")
                    let html = try await sec.document(SECClient.Filing(form: tenK.form, accessionNumber: tenK.accessionNumber,
                                                                       filingDate: tenK.filingDate, reportDate: tenK.reportDate,
                                                                       primaryDocument: tenK.primaryDocument, cik: tenK.cik))
                    let business = FilingSections.extract(plainText: HTMLText.toPlainText(html), items: ["1"]).first?.text ?? ""
                    let notes = try await writer.write("""
                    From this excerpt of \(c.name)'s 10-K (Item 1 Business), write 3 short bullets in English: \
                    what it sells, to whom, and its main competitors or competitive edge. Facts only.

                    TEXT:
                    \(String(business.prefix(9_000)))
                    """, maxTokens: 300)
                    profiles.append("### \(c.name) (\(c.ticker))\n\(LLMOutput.clean(notes))")
                } catch { log("⚠︎ \(c.ticker): \(error.localizedDescription)") }
            }
            let table = snaps.map { s in
                "- \(s.ticker): revenue LTM \(QuarterlyFigures.money(s.revenue)), growth \(pct(s.revenueGrowth)), "
                    + "EBIT margin \(pct(ratio(s.ebit, s.revenue))), FCF margin \(pct(ratio(s.freeCashFlow, s.revenue)))"
            }.joined(separator: "\n")
            log("Píšu přehled…")
            md += LLMOutput.clean(try await writer.write("""
            Write a sector overview of this peer group in \(options.language). Use the verified figures for every number; \
            describe businesses only from the 10-K profiles. Do not state market sizes, prices or valuations – they are not in the data. \
            Use exactly these markdown headings, bullets under 25 words:

            ## Dynamika odvětví
            - 3 bullets: growth and profitability across the group, who is gaining share
            ## Konkurenční pozice
            - one bullet per company: positioning and edge
            ## Trendy a rizika
            - 3 bullets
            ## Investiční implikace
            - 2–3 bullets: who looks best positioned on fundamentals and why

            Verified figures:
            \(table)

            10-K profiles:
            \(profiles.joined(separator: "\n\n"))
            """, maxTokens: 1_400)) + "\n\n"
        }
        md += Self.disclaimer + "\n"
        return md
    }

    // MARK: - /catalyst-calendar

    public struct CalendarEvent: Sendable, Hashable {
        public let date: String
        public let ticker: String
        public let event: String
        public let impact: String     // V / S / N
        public let basis: String
        public let estimated: Bool
    }

    public static func catalysts(for c: CompanyData, today: String, horizonDays: Int, recentDays: Int = 14) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        let horizon = QuarterHistory.addDays(today, horizonDays) ?? today
        let recentFrom = QuarterHistory.addDays(today, -recentDays) ?? today
        if let e = FilingCalendar.nextEarnings(c.filings, today: today), e.date <= horizon {
            out.append(.init(date: e.date, ticker: c.ticker, event: "Výsledky hospodaření", impact: "V", basis: e.basis, estimated: true))
        }
        if let r = FilingCalendar.nextPeriodicReport(c.filings, today: today), r.date <= horizon {
            out.append(.init(date: r.date, ticker: c.ticker, event: r.form == "10-K" ? "Výroční zpráva 10-K" : "Kvartální zpráva 10-Q",
                             impact: "S", basis: "loňské podání + 52 týdnů", estimated: true))
        }
        if let p = FilingCalendar.nextProxy(c.filings, today: today), p <= horizon {
            out.append(.init(date: p, ticker: c.ticker, event: "Pozvánka na valnou hromadu (DEF 14A)", impact: "N",
                             basis: "loňská pozvánka + 52 týdnů", estimated: true))
        }
        for f in c.filings where f.filingDate >= recentFrom && f.filingDate <= today && f.importance >= 2 {
            out.append(.init(date: f.filingDate, ticker: c.ticker, event: f.summary,
                             impact: f.importance >= 4 ? "V" : (f.importance == 3 ? "S" : "N"),
                             basis: "[\(f.form)](\(f.documentURL.absoluteString))", estimated: false))
        }
        return out
    }

    public func catalystCalendar(_ tickers: [String], horizonDays: Int = 60) async throws -> String {
        let companies = try await load(tickers)
        let today = FilingCalendar.today()
        let events = companies.flatMap { Self.catalysts(for: $0, today: today, horizonDays: horizonDays) }
        return Self.calendarMarkdown(events, tickers: companies.map(\.ticker), today: today, horizonDays: horizonDays)
    }

    public static func calendarMarkdown(_ events: [CalendarEvent], tickers: [String], today: String, horizonDays: Int) -> String {
        let weekEnd = QuarterHistory.addDays(today, 7) ?? today
        let upcoming = events.filter { $0.date > today }.sorted { ($0.date, $0.ticker) < ($1.date, $1.ticker) }
        let recent = events.filter { $0.date <= today }.sorted { ($0.date, $0.ticker) > ($1.date, $1.ticker) }
        var md = "# Kalendář katalyzátorů: \(tickers.joined(separator: ", "))\n\n"
        let week = upcoming.filter { $0.date <= weekEnd }
        md += "## Tento týden\n\n"
        md += week.isEmpty ? "- Nic očekávaného.\n\n"
            : week.map { "- **\(FilingCalendar.czechDay($0.date))** \($0.ticker): \($0.event)\($0.estimated ? " _(odhad)_" : "")" }.joined(separator: "\n") + "\n\n"
        md += "## Dalších \(horizonDays) dní\n\n"
        if upcoming.isEmpty {
            md += "Žádné odhadnutelné události.\n\n"
        } else {
            md += "| Datum | Firma | Událost | Dopad | Podle |\n|---|---|---|:---:|---|\n"
            for e in upcoming { md += "| \(FilingCalendar.czechDay(e.date)) \(e.date) | \(e.ticker) | \(e.event) | \(e.impact) | \(e.basis) |\n" }
            md += "\n"
        }
        if !recent.isEmpty {
            md += "## Posledních 14 dní (podání v SEC)\n\n| Datum | Firma | Událost | Dopad | Dokument |\n|---|---|---|:---:|---|\n"
            for e in recent { md += "| \(e.date) | \(e.ticker) | \(e.event) | \(e.impact) | \(e.basis) |\n" }
            md += "\n"
        }
        md += "_Termíny jsou odhady z historie podání v SEC (stejný týden jako loni) – přesné datum výsledků oznamuje firma na IR webu. "
            + "Makro (FOMC, CPI, payrolls) a konference v datech SEC nejsou. Dopad: V vysoký, S střední, N nízký._\n"
        return md
    }

    // MARK: - /morning-note

    /// Od kdy brát podání: poslední pracovní den (v pondělí pátek).
    public static func morningSince(today: String) -> String {
        guard let d = DateOnly.parse(today) else { return today }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let wd = cal.component(.weekday, from: d)          // 1 = neděle, 2 = pondělí
        let back = wd == 2 ? 3 : (wd == 1 ? 2 : 1)
        return QuarterHistory.addDays(today, -back) ?? today
    }

    public func morningNote(_ tickers: [String]) async throws -> String {
        let companies = try await load(tickers)
        let today = FilingCalendar.today()
        let since = Self.morningSince(today: today)
        var md = "# Ranní poznámka \(FilingCalendar.czechDay(today)) — \(companies.map(\.ticker).joined(separator: ", "))\n\n"

        var developments: [(c: CompanyData, filings: [SECFiling])] = []
        for c in companies {
            let new = c.filings.filter { $0.filingDate >= since }
            if !new.isEmpty { developments.append((c, new)) }
        }
        let weekEvents = companies.flatMap { Self.catalysts(for: $0, today: today, horizonDays: 7, recentDays: 0) }
            .filter { $0.date > today }.sorted { $0.date < $1.date }

        var facts: [String] = []
        var body = ""
        for (c, list) in developments.sorted(by: { ($0.filings.map(\.importance).max() ?? 0) > ($1.filings.map(\.importance).max() ?? 0) }) {
            let insiders = list.filter { $0.form == "4" }.count
            let important = list.filter { $0.form != "4" }.sorted { $0.importance > $1.importance }
            var line = "- **\(c.ticker)**: "
            line += important.prefix(3).map { "\($0.summary) ([\($0.form)](\($0.documentURL.absoluteString)))" }.joined(separator: "; ")
            if insiders > 0 { line += (important.isEmpty ? "" : "; ") + "\(insiders)× obchod insidera (Form 4)" }
            body += line + "\n"
            facts.append("\(c.ticker): " + list.map { "\($0.form) \($0.summary)" }.joined(separator: "; "))
            // Nové výsledky: rychlé srovnání z XBRL.
            if important.contains(where: { $0.form == "10-Q" || $0.form == "10-K" || $0.isEarningsRelease }),
               let latest = c.quarters.latest, let ya = c.quarters.yearAgo(of: latest) {
                let rev = QuarterlyFigures.change(latest.value(.revenue), ya.value(.revenue))
                let eps = QuarterlyFigures.change(latest.value(.eps), ya.value(.eps))
                let quick = "  - \(latest.quarter.label): tržby \(QuarterlyFigures.money(latest.value(.revenue))) (YoY \(QuarterlyFigures.pct(rev))), "
                    + "EPS \(latest.value(.eps).map { String(format: "$%.2f", $0) } ?? "n/a") (YoY \(QuarterlyFigures.pct(eps)))"
                body += quick + "\n"
                facts.append("\(c.ticker) latest quarter: " + c.quarters.promptTable().replacingOccurrences(of: "\n", with: "; "))
            }
        }

        if let writer, !developments.isEmpty {
            log("Píšu ranní poznámku…")
            md += LLMOutput.clean(try await writer.write("""
            Write the top of a morning note in \(options.language) for an investor following these stocks. \
            Use only the SEC filings and figures below – no prices, news or consensus exist in the data, do not invent them. \
            Output exactly:

            ## Hlavní bod
            2–3 sentences on the single most important development and why it matters.
            ## Náš pohled
            - one bullet per company with a development: what it means (max 20 words)

            Filings since \(since):
            \(facts.joined(separator: "\n"))
            """, maxTokens: 600)) + "\n\n"
        }
        md += "## Nová podání v SEC (od \(since))\n\n"
        md += body.isEmpty ? "Nic podstatného – žádná nová podání.\n\n" : body + "\n"
        md += "## Tento týden\n\n"
        md += weekEvents.isEmpty ? "- Nic očekávaného.\n\n"
            : weekEvents.map { "- **\(FilingCalendar.czechDay($0.date))** \($0.ticker): \($0.event)\($0.estimated ? " _(odhad)_" : "")" }.joined(separator: "\n") + "\n\n"
        md += Self.disclaimer + "\n"
        return md
    }
}
