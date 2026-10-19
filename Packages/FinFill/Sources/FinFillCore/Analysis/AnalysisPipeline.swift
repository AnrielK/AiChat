import Foundation

/// Výsledek analýz nad sešitem (inspirováno skilly dcf-model, comps-analysis a earnings-analysis
/// z anthropics/financial-services).
public struct AnalysisReport: Sendable {
    /// Kontrola DCF (nil = list DCF chybí nebo nemá rozložení šablony).
    public var dcf: DCFReview?
    public var notes: [String] = []
    public var sensitivityWritten = false
    public var target: CompanySnapshot?
    public var peers: [CompanySnapshot] = []
    public var peerErrors: [String] = []
    public var compsWritten = false
    public var quarter: QuarterlyReview?
    public var quarterWritten = false

    public init() {}
    public var isEmpty: Bool { dcf == nil && target == nil && quarter == nil && notes.isEmpty }
}

extension PreparedFiling {
    /// Fakta z companyfacts (10-K i 10-Q) – zdroj kvartálů a LTM. Inline XBRL se nebere (jen jeden rok).
    public var companyFactsAll: [Fact] {
        facts.facts.filter { $0.form != nil } + interimFacts
    }
}

extension FinFillPipeline {
    /// Citlivost + kontrola DCF, Comps, Kvartály – podle `config` (sensitivity, peers, quarterly).
    /// Chyby jednotlivých částí se zapíšou do logu a do `notes`, zbytek doběhne.
    public func runAnalyses(filing: PreparedFiling, sheets: GoogleSheetsClient,
                            log: @escaping @Sendable (Event) -> Void = { _ in }) async -> AnalysisReport {
        var report = AnalysisReport()
        guard config.sensitivity || !config.peers.isEmpty || config.quarterly else { return report }

        let titles = (try? await sheets.sheetTitles()) ?? []
        let hasDCF = titles.contains(DCFLayout.sheet)

        // 1) Citlivost WACC × TGR + kontrola DCF.
        if config.sensitivity {
            if hasDCF {
                do {
                    let values = try await readDCF(sheets: sheets)
                    if DCFLayout.matches(values) {
                        try await replaceSheet(SensitivitySheet.title, after: ["WACC", "DCF"], sheets: sheets,
                                               size: SensitivitySheet.size) { id in SensitivitySheet.requests(sheetId: id) }
                        report.sensitivityWritten = true
                        log(.log("List „\(SensitivitySheet.title)“: cena pro WACC × TGR, potenciál a kontrola modelu"))
                        let review = DCFReview(inputs: .read(values))
                        report.dcf = review
                        for line in review.logLines { log(.log("DCF \(line)")) }
                    } else {
                        let note = "List DCF nemá rozložení šablony FinFill – citlivost a kontrola DCF přeskočeny."
                        report.notes.append(note); log(.log("⚠︎ " + note))
                    }
                } catch {
                    report.notes.append("Citlivost: \(error.localizedDescription)")
                    log(.log("⚠︎ Citlivost: \(error.localizedDescription)"))
                }
            } else {
                report.notes.append("Sešit nemá list DCF – citlivost a kontrola DCF přeskočeny.")
            }
        }

        let companyFacts = filing.companyFactsAll
        let sec = SECClient(userAgent: config.secUserAgent)

        // 2) Comps.
        let peers = Self.normalizedPeers(config.peers, excluding: filing.ticker ?? config.ticker)
        if !peers.isEmpty {
            let target = CompanySnapshot.compute(ticker: filing.ticker ?? config.ticker, name: filing.company, facts: companyFacts)
            report.target = target
            log(.log("Comps: \(peers.count) peerů – stahuji data ze SEC…"))
            var table: [String: (cik: Int, name: String)] = [:]
            do { table = try await sec.tickerTable() } catch { report.peerErrors.append("seznam tickerů SEC: \(error.localizedDescription)") }
            for p in peers {
                guard let entry = table[p] else { report.peerErrors.append("\(p): ticker není v SEC"); continue }
                do {
                    let data = try await sec.companyFactsData(cik: entry.cik)
                    let cf = try CompanyFactsParser.parse(data, forms: CompanyFactsParser.annualAndQuarterlyForms)
                    let s = CompanySnapshot.compute(ticker: p, name: entry.name, facts: cf.facts)
                    report.peers.append(s)
                    log(.log("Comps: \(p) – LTM do \(s.ltmEnd ?? "—")" + (s.missing.isEmpty ? "" : ", chybí \(s.missing.joined(separator: ", "))")))
                } catch {
                    report.peerErrors.append("\(p): \(error.localizedDescription)")
                }
            }
            for e in report.peerErrors { log(.log("⚠︎ Comps: \(e)")) }
            if !report.peers.isEmpty {
                do {
                    let n = report.peers.count
                    try await replaceSheet(CompsSheet.title, after: [SensitivitySheet.title, "WACC", "DCF"], sheets: sheets,
                                           size: CompsSheet.size(peers: n)) { id in
                        CompsSheet.requests(sheetId: id, target: target, peers: report.peers, hasDCF: hasDCF)
                    }
                    report.compsWritten = true
                    log(.log("List „\(CompsSheet.title)“: \(target.ticker) vs. \(report.peers.map(\.ticker).joined(separator: ", "))"))
                } catch {
                    report.notes.append("Comps: \(error.localizedDescription)")
                    log(.log("⚠︎ Comps: \(error.localizedDescription)"))
                }
            }
        }

        // 3) Kvartály + earnings review posledního 10-Q.
        if config.quarterly {
            let figures = QuarterlyFigures.compute(facts: companyFacts)
            if figures.isEmpty {
                report.notes.append("Kvartální data v SEC nejsou (firma nepodává 10-Q?).")
                log(.log("⚠︎ Kvartály: v companyfacts nejsou kvartální údaje"))
            } else {
                var tenQ: SECClient.Filing?
                var text: String?
                if let latest = figures.latest {
                    tenQ = filing.quarterlyFilings.first { abs(DateOnly.days(from: $0.reportDate, to: latest.quarter.end) ?? 999) <= 7 }
                    if tenQ == nil {
                        log(.log("Kvartály: poslední kvartál \(latest.quarter.label) je z 10-K (Q4) – review 10-Q se dělá po dalším 10-Q"))
                    }
                }
                if let f = tenQ, let engine {
                    do {
                        log(.log("Kvartály: stahuji \(f.form) \(f.reportDate)…"))
                        let html = try await sec.document(f)
                        text = try await Summarizer(engine: engine, options: config.summaryOptions)
                            .reviewQuarter(filingHTML: html, company: filing.company, figures: figures) { p in log(.summary(p)) }
                    } catch {
                        report.notes.append("Earnings review: \(error.localizedDescription)")
                        log(.log("⚠︎ Earnings review: \(error.localizedDescription)"))
                    }
                }
                let review = QuarterlyReview(company: filing.company, figures: figures, filing: tenQ, text: text,
                                             language: config.summaryOptions.language)
                report.quarter = review
                do {
                    try await replaceSheet(QuarterSheet.title, after: [CompsSheet.title, SensitivitySheet.title, "WACC", "DCF"],
                                           sheets: sheets, size: QuarterSheet.size(review: review)) { id in
                        QuarterSheet.requests(sheetId: id, review: review, newestFirst: config.newestFirst)
                    }
                    report.quarterWritten = true
                    log(.log("List „\(QuarterSheet.title)“: \(figures.columns.map(\.quarter.label).joined(separator: ", "))"))
                } catch {
                    report.notes.append("Kvartály: \(error.localizedDescription)")
                    log(.log("⚠︎ Kvartály: \(error.localizedDescription)"))
                }
            }
        }
        return report
    }

    /// Jen analýzy do vybraného sešitu (bez zápisu výkazů) – např. po novém 10-Q nebo s jinými peery.
    public func analyzeOnly(filing prepared: PreparedFiling? = nil,
                            log: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> (filing: PreparedFiling, analysis: AnalysisReport) {
        let sheets = GoogleSheetsClient(spreadsheetID: GoogleSheetsClient.spreadsheetID(from: config.spreadsheet), tokens: tokens)
        try await checkWorkbookTicker(sheets: sheets)
        let filing: PreparedFiling
        if let prepared { filing = prepared } else { filing = try await fetchFiling(log: log) }
        return (filing, await runAnalyses(filing: filing, sheets: sheets, log: log))
    }

    /// Ticker sešitu ze šablony (DCF!C4). nil = sešit DCF nemá nebo je C4 prázdné (vlastní sešit).
    public func workbookTicker(sheets: GoogleSheetsClient) async -> String? {
        guard let titles = try? await sheets.sheetTitles(), titles.contains(DCFLayout.sheet),
              let v = try? await sheets.batchGet(["\(A1.quote(DCFLayout.sheet))!C4"], render: .unformatted).first?.first?.first as? String
        else { return nil }
        let t = v.trimmingCharacters(in: .whitespaces).uppercased()
        return t.isEmpty ? nil : t
    }

    /// Nedovolí zapsat jinou firmu do sešitu ze šablony (NVDA do „AMD Valuation“).
    func checkWorkbookTicker(sheets: GoogleSheetsClient) async throws {
        guard let t = await workbookTicker(sheets: sheets) else { return }
        guard Self.sameTicker(t, config.ticker) else {
            throw AnalysisError.tickerMismatch(workbook: t, requested: config.ticker.uppercased())
        }
    }

    /// „BRK.B“ = „BRK-B“ = „brk.b“; burzovní předpona („NASDAQ:NVDA“) se ignoruje.
    static func sameTicker(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            let t = s.split(separator: ":").last.map(String.init) ?? s
            return t.uppercased().replacingOccurrences(of: "-", with: ".").trimmingCharacters(in: .whitespaces)
        }
        return norm(a) == norm(b)
    }

    /// DCF!A1:M60 – po vytvoření sešitu GOOGLEFINANCE chvíli načítá (WACC v chybě), proto až 3 pokusy.
    func readDCF(sheets: GoogleSheetsClient) async throws -> [[Any]] {
        var values: [[Any]] = []
        for attempt in 0..<3 {
            values = try await sheets.batchGet(["\(A1.quote(DCFLayout.sheet))!A1:M60"], render: .unformatted).first ?? []
            if DCFReview.Inputs.read(values).wacc != nil || !DCFLayout.matches(values) { break }
            if attempt < 2 { try await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        return values
    }

    /// Smaže list `title` (pokud je) a vytvoří ho znovu za prvním existujícím listem z `after`.
    func replaceSheet(_ title: String, after: [String], sheets: GoogleSheetsClient, size: (rows: Int, columns: Int),
                      content: (Int) -> [[String: Any]]) async throws {
        let info = try await sheets.sheetInfo()
        let existing = info.first { $0.title == title }
        let others = info.filter { $0.title != title }
        var index: Int?
        for a in after {
            if let i = others.firstIndex(where: { $0.title == a }) { index = i + 1; break }
        }
        let used = Set(info.map(\.sheetId))
        var newId = Int.random(in: 100_000...900_000)
        while used.contains(newId) { newId = Int.random(in: 100_000...900_000) }
        try await sheets.structuralUpdate(SheetGrid.replaceSheet(title: title, existingId: existing?.sheetId, newId: newId,
                                                                 index: index, size: size) + content(newId))
    }

    /// „amd, AVGO;intc  NVDA“ → ["AMD", "AVGO", "INTC"] (bez cílové firmy a duplicit, max. 12).
    public static func normalizedPeers(_ list: [String], excluding target: String) -> [String] {
        var seen = Set<String>([target.uppercased()])
        var out: [String] = []
        for raw in list.flatMap({ $0.components(separatedBy: CharacterSet(charactersIn: ",; \n\t")) }) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !t.isEmpty, !seen.contains(t) else { continue }
            seen.insert(t); out.append(t)
        }
        return Array(out.prefix(12))
    }
}

public enum AnalysisError: Error, LocalizedError, Equatable {
    case tickerMismatch(workbook: String, requested: String)
    public var errorDescription: String? {
        switch self {
        case let .tickerMismatch(w, r):
            return "Vybraný sešit patří k \(w) (DCF!C4), ne k \(r). Nic se nezapsalo – vyber sešit pro \(r), nebo založ nový."
        }
    }
}

public extension CompanyFactsParser {
    static let annualForms: Set<String> = ["10-K", "10-K/A", "20-F", "40-F"]
    static let annualAndQuarterlyForms: Set<String> = annualForms.union(["10-Q", "10-Q/A"])
}

public extension SECClient {
    /// Celý company_tickers.json najednou (ticker → CIK, název) – pro víc peerů jedno stažení.
    func tickerTable() async throws -> [String: (cik: Int, name: String)] {
        struct Row: Decodable { let cik_str: Int; let ticker: String; let title: String }
        let data = try await get("https://www.sec.gov/files/company_tickers.json")
        let rows = try JSONDecoder().decode([String: Row].self, from: data)
        var out: [String: (cik: Int, name: String)] = [:]
        for r in rows.values where out[r.ticker.uppercased()] == nil { out[r.ticker.uppercased()] = (r.cik_str, r.title) }
        return out
    }
}
