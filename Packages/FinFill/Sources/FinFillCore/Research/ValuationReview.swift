import Foundation

/// Kontrola ocenění v sešitu – obdoba agenta valuation-reviewer z anthropics/financial-services
/// (ten kontroluje ocenění portfoliových firem fondu proti politice). Tady: DCF proti Comps a trhu,
/// předpoklady WACC proti obvyklým pásmům a výchozí rok DCF proti posledním LTM číslům ze SEC.
public struct ValuationReview: Sendable {
    public var dcf: DCFReview?
    public var dcfPrice: Double?
    public var currentPrice: Double?
    public var compsPrice: Double?
    public var compsByMethod: [(method: String, price: Double)] = []
    public var wacc: (rf: Double?, beta: Double?, mrp: Double?, costOfDebt: Double?, wacc: Double?) = (nil, nil, nil, nil, nil)
    public var dcfBaseRevenue: Double?       // USD (DCF!H22 × 1e6)
    public var ltm: CompanySnapshot?
    public var findings: [DCFReview.Finding] = []
    public var notes: [String] = []

    public var worst: DCFReview.Severity {
        max(dcf?.worst ?? .ok, findings.map(\.severity).max() ?? .ok)
    }

    /// Hodnoty listu Comps (B1:H80) → průměr metod a ceny podle metod (medián, sloupec D).
    static func readComps(_ values: [[Any]]) -> (avg: Double?, methods: [(String, Double)]) {
        var avg: Double?
        var methods: [(String, Double)] = []
        for row in values {
            guard let label = row[safe: 0] as? String else { continue }
            let price = (row[safe: 2] as? Double) ?? (row[safe: 2] as? Int).map(Double.init)
            if label.hasPrefix("Průměr metod") { avg = price }
            else if ["EV / Tržby", "EV / EBITDA", "P / E"].contains(label), let price { methods.append((label, price)) }
        }
        return (avg, methods)
    }

    /// Dodatečné kontroly nad DCFReview.
    mutating func crossCheck() {
        func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
        if let d = dcfPrice, let c = compsPrice, c > 0 {
            let gap = d / c - 1
            if abs(gap) > 0.5 {
                findings.append(.init(severity: .warning, title: String(format: "DCF vs. Comps %+.0f %%", gap * 100),
                                      detail: "DCF a ocenění podle peerů se rozcházejí o víc než polovinu – zkontroluj růst, marže a TGR, nebo výběr peerů."))
            } else if abs(gap) > 0.25 {
                findings.append(.init(severity: .info, title: String(format: "DCF vs. Comps %+.0f %%", gap * 100),
                                      detail: "Mírný rozdíl mezi DCF a mediánem peerů."))
            }
        }
        if let rf = wacc.rf, rf < 0.02 || rf > 0.06 {
            findings.append(.init(severity: .warning, title: "Bezriziková sazba \(pct(rf))",
                                  detail: "Obvykle výnos 10letého US dluhopisu (zhruba 3–5 %). Aktualizuj WACC!D16."))
        }
        if let b = wacc.beta, b < 0.3 || b > 3 {
            findings.append(.init(severity: .warning, title: String(format: "Beta %.2f", b), detail: "Neobvyklá beta – ověř zdroj (WACC!D17)."))
        }
        if let m = wacc.mrp, m < 0.03 || m > 0.08 {
            findings.append(.init(severity: .warning, title: "Tržní riziková prémie \(pct(m))", detail: "Obvykle 4–6 % (WACC!D18)."))
        }
        if let kd = wacc.costOfDebt, let rf = wacc.rf, kd < rf {
            findings.append(.init(severity: .info, title: "Náklad dluhu \(pct(kd)) < bezriziková sazba",
                                  detail: "Náklad dluhu bývá nad výnosem státních dluhopisů (WACC!D10)."))
        }
        if let base = dcfBaseRevenue, base > 0, let ltmRev = ltm?.revenue, ltm?.ltmQuarters == 4 {
            let diff = ltmRev / base - 1
            if abs(diff) > 0.1 {
                findings.append(.init(severity: .info, title: String(format: "LTM tržby %+.0f %% vs. výchozí rok DCF", diff * 100),
                                      detail: "DCF startuje z posledního fiskálního roku; od té doby se tržby výrazně změnily (LTM do \(ltm?.ltmEnd ?? "—")). Zvaž aktualizaci růstu 1. roku."))
            }
        }
        findings.sort { $0.severity > $1.severity }
    }

    public func markdown(ticker: String, sheet: String, commentary: String?) -> String {
        func price(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "—" }
        func up(_ v: Double?) -> String {
            guard let v, let c = currentPrice, c > 0 else { return "—" }
            return String(format: "%+.0f %%", (v / c - 1) * 100)
        }
        var md = "# Kontrola ocenění: \(ticker)\n\n**Sešit:** \(sheet)\n\n"
        md += "| Metoda | Cena na akcii | vs. trh |\n|---|---:|---:|\n"
        md += "| Aktuální cena (DCF!H5) | \(price(currentPrice)) | |\n"
        md += "| DCF (DCF!H4) | \(price(dcfPrice)) | \(up(dcfPrice)) |\n"
        for m in compsByMethod { md += "| Comps – \(m.method) (medián) | \(price(m.price)) | \(up(m.price)) |\n" }
        if compsPrice != nil { md += "| **Comps – průměr metod** | **\(price(compsPrice))** | \(up(compsPrice)) |\n" }
        md += "\n"
        if let w = wacc.wacc {
            md += String(format: "**WACC %.1f %%**", w * 100)
            var parts: [String] = []
            if let rf = wacc.rf { parts.append(String(format: "rf %.2f %%", rf * 100)) }
            if let b = wacc.beta { parts.append(String(format: "beta %.2f", b)) }
            if let m = wacc.mrp { parts.append(String(format: "prémie %.1f %%", m * 100)) }
            if let k = wacc.costOfDebt { parts.append(String(format: "náklad dluhu %.2f %%", k * 100)) }
            md += parts.isEmpty ? "\n\n" : " – " + parts.joined(separator: ", ") + "\n\n"
        }
        let all = (dcf?.findings.filter { $0.severity != .ok } ?? []) + findings
        md += "## Zjištění\n\n"
        md += all.isEmpty ? "- ✓ Bez nálezů – DCF, WACC i srovnání s peery v obvyklých mezích.\n\n"
            : all.sorted { $0.severity > $1.severity }.map { "- \($0.severity.symbol) **\($0.title)** – \($0.detail)" }.joined(separator: "\n") + "\n\n"
        if let commentary, !commentary.isEmpty { md += commentary + "\n\n" }
        for n in notes { md += "_\(n)_\n\n" }
        md += "_Kontrola předpokladů, ne investiční doporučení. Rozhodnutí je na tobě._\n"
        return md
    }
}

extension FinFillPipeline {
    /// Kontrola ocenění ve vybraném sešitu (config.spreadsheet). Ticker sešitu musí sedět (DCF!C4).
    public func valuationReview(log: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> ValuationReview {
        let sheets = GoogleSheetsClient(spreadsheetID: GoogleSheetsClient.spreadsheetID(from: config.spreadsheet), tokens: tokens)
        try await checkWorkbookTicker(sheets: sheets)
        var r = ValuationReview()
        let titles = (try? await sheets.sheetTitles()) ?? []

        guard titles.contains(DCFLayout.sheet) else {
            r.notes.append("Sešit nemá list DCF – kontrola DCF se nedá udělat.")
            return r
        }
        log(.log("Čtu DCF…"))
        let values = try await readDCF(sheets: sheets)
        guard DCFLayout.matches(values) else {
            r.notes.append("List DCF nemá rozložení šablony FinFill – kontrola přeskočena.")
            return r
        }
        let inputs = DCFReview.Inputs.read(values)
        r.dcf = DCFReview(inputs: inputs)
        r.currentPrice = inputs.currentPrice
        func cell(_ a1: String) -> Double? {
            guard let (row, col) = A1.parseCell(a1), let v = values[safe: row]?[safe: col] else { return nil }
            return (v as? Double) ?? (v as? Int).map(Double.init)
        }
        r.dcfPrice = cell("H4") ?? inputs.sharePrice
        r.dcfBaseRevenue = cell("H22").map { $0 * 1_000_000 }

        if titles.contains("WACC"), let w = try? await sheets.batchGet(["WACC!D10:D22"], render: .unformatted).first {
            func d(_ row: Int) -> Double? {
                let v = w[safe: row - 10]?.first
                return (v as? Double) ?? (v as? Int).map(Double.init)
            }
            r.wacc = (rf: d(16), beta: d(17), mrp: d(18), costOfDebt: d(10), wacc: d(22))
        }
        if titles.contains(CompsSheet.title),
           let c = try? await sheets.batchGet(["\(A1.quote(CompsSheet.title))!B1:H80"], render: .unformatted).first {
            let comps = ValuationReview.readComps(c)
            r.compsPrice = comps.avg
            r.compsByMethod = comps.methods
        } else {
            r.notes.append("List Comps chybí – srovnání s peery dodá `finfill analyze \(config.ticker) peers …`.")
        }

        // LTM ze SEC (výchozí rok DCF vs. posledních 12 měsíců).
        do {
            let sec = SECClient(userAgent: config.secUserAgent)
            let (cik, name) = try await sec.cik(forTicker: config.ticker)
            let cf = try CompanyFactsParser.parse(try await sec.companyFactsData(cik: cik), forms: CompanyFactsParser.annualAndQuarterlyForms)
            r.ltm = CompanySnapshot.compute(ticker: config.ticker, name: name, facts: cf.facts)
        } catch {
            log(.log("⚠︎ LTM ze SEC: \(error.localizedDescription)"))
        }
        r.crossCheck()
        return r
    }

    /// Komentář modelu ke kontrole (3 body), nil bez modelu.
    public func valuationCommentary(_ r: ValuationReview) async -> String? {
        guard let engine else { return nil }
        let findings = ((r.dcf?.findings ?? []) + r.findings).map { "- \($0.severity.symbol) \($0.title): \($0.detail)" }.joined(separator: "\n")
        func p(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "n/a" }
        let prompt = """
        You review a DCF valuation of \(config.ticker) like a fund valuation reviewer: challenge the assumptions, do not recommend buying or selling. \
        Write in \(config.summaryOptions.language). Output exactly:

        ## Komentář
        - 3 bullets (max 25 words each): which assumptions drive the gap to the market and what to change or verify first

        Prices: DCF \(p(r.dcfPrice)), comps average \(p(r.compsPrice)), market \(p(r.currentPrice)).
        WACC \(r.wacc.wacc.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"), TGR \(r.dcf?.inputs.tgr.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"), \
        terminal value share of EV \(r.dcf?.inputs.tvShare.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a").
        Findings:
        \(findings)
        """
        let out = try? await Summarizer(engine: engine, options: config.summaryOptions).write(prompt, maxTokens: 500)
        return out.map(LLMOutput.clean)
    }
}
