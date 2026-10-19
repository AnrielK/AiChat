import Foundation

/// Investiční teze podle skillu thesis-tracker: teze, pilíře, rizika, KPI (kontrolované proti XBRL),
/// katalyzátory, cíl, stop a deník změn. Ukládá se do JSON souboru (`ThesisStore`).
public struct Thesis: Codable, Sendable, Equatable {
    public enum Position: String, Codable, Sendable { case long, short }

    public struct KPI: Codable, Sendable, Equatable {
        public enum Metric: String, Codable, Sendable, CaseIterable {
            case revenueGrowth, grossMargin, operatingMargin, netMargin, fcfMargin, epsGrowth

            public var title: String {
                switch self {
                case .revenueGrowth: "Růst tržeb YoY"
                case .grossMargin: "Hrubá marže"
                case .operatingMargin: "Provozní marže"
                case .netMargin: "Čistá marže"
                case .fcfMargin: "FCF marže"
                case .epsGrowth: "Růst EPS YoY"
                }
            }

            /// „růst tržeb“, „revenue growth“, „hrubá marže“, „fcf“…
            static func parse(_ s: String) -> Metric? {
                let t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                if t.contains("eps") { return .epsGrowth }
                if t.contains("fcf") || t.contains("cash") { return .fcfMargin }
                if t.contains("hrub") || t.contains("gross") { return .grossMargin }
                if t.contains("provoz") || t.contains("operat") || t.contains("ebit") { return .operatingMargin }
                if t.contains("cist") || t.contains("net") { return .netMargin }
                if t.contains("rust") || t.contains("growth") || t.contains("trzb") || t.contains("revenue") { return .revenueGrowth }
                return nil
            }
        }
        public var metric: Metric
        public var above: Bool          // true: hodnota má být > threshold
        public var threshold: Double    // 0.20 = 20 %
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var date: String
        public var text: String
        /// Hodnocení dopadu modelem (posiluje / oslabuje / neutrální …), nil = bez modelu.
        public var impact: String?
    }

    public var ticker: String
    public var position: Position = .long
    public var statement: String = ""
    public var pillars: [String] = []
    public var risks: [String] = []
    public var kpis: [KPI] = []
    public var catalysts: [String] = []
    public var target: Double?
    public var stop: String?
    public var conviction: String?
    public var log: [Entry] = []
    public var updated: String = ""

    public init(ticker: String) { self.ticker = ticker.uppercased() }
}

/// Soubor s tezemi (jeden JSON pro všechny tickery).
public struct ThesisStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func all() -> [String: Thesis] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Thesis].self, from: data)) ?? [:]
    }

    public func get(_ ticker: String) -> Thesis? { all()[ticker.uppercased()] }

    public func save(_ t: Thesis) throws {
        var a = all()
        a[t.ticker] = t
        try write(a)
    }

    public func delete(_ ticker: String) throws {
        var a = all()
        a[ticker.uppercased()] = nil
        try write(a)
    }

    func write(_ a: [String: Thesis]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(a).write(to: url, options: .atomic)
    }
}

/// Úprava teze z příkazu: „teze …“, „pilíř …“, „riziko …“, „kpi růst tržeb > 20 %“, „katalyzátor …“,
/// „cíl 250“, „stop …“, „poznámka …“, „long“ / „short“, „odebrat pilíř 2“, „smazat“.
public enum ThesisEdit: Sendable, Equatable {
    case show
    case statement(String, Thesis.Position?)
    case pillar(String), risk(String), catalyst(String), stop(String), note(String)
    case kpi(Thesis.KPI)
    case target(Double)
    case remove(kind: String, index: Int)
    case delete
    case invalid(String)

    public static func parse(_ words: [String]) -> ThesisEdit {
        guard let first = words.first else { return .show }
        let key = first.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let rest = words.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        func need(_ c: ThesisEdit) -> ThesisEdit { rest.isEmpty ? .invalid("Za „\(first)“ chybí text.") : c }
        switch key {
        case "teze", "thesis", "statement": return need(.statement(rest, nil))
        case "long", "short":
            return .statement(rest, key == "long" ? .long : .short)
        case "pilir", "pillar": return need(.pillar(rest))
        case "riziko", "risk": return need(.risk(rest))
        case "katalyzator", "catalyst": return need(.catalyst(rest))
        case "stop", "stop-loss": return need(.stop(rest))
        case "poznamka", "note", "update", "data": return need(.note(rest))
        case "cil", "target", "pt":
            guard let v = Double(rest.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }) else {
                return .invalid("Cíl zadej číslem, např. „cíl 250“.")
            }
            return .target(v)
        case "kpi": return parseKPI(rest)
        case "odebrat", "remove":
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count == 2, let i = Int(parts[1]) else { return .invalid("Např. „odebrat pilíř 2“.") }
            return .remove(kind: parts[0].lowercased().folding(options: .diacriticInsensitive, locale: nil), index: i)
        case "smazat", "delete": return .delete
        case "kontrola", "check", "zobrazit", "show": return .show
        default: return .invalid("Neznámá úprava „\(first)“.")
        }
    }

    /// „růst tržeb > 20 %“, „provozní marže >= 60%“, „fcf marže < 10“
    static func parseKPI(_ s: String) -> ThesisEdit {
        guard let r = s.range(of: #"(>=|<=|>|<)"#, options: .regularExpression) else {
            return .invalid("KPI zadej jako „kpi růst tržeb > 20 %“.")
        }
        let name = String(s[..<r.lowerBound]), op = String(s[r]), num = String(s[r.upperBound...])
        guard let metric = Thesis.KPI.Metric.parse(name) else {
            return .invalid("Neznámý ukazatel „\(name.trimmingCharacters(in: .whitespaces))“. Umím: "
                            + Thesis.KPI.Metric.allCases.map(\.title).joined(separator: ", ") + ".")
        }
        guard let v = Double(num.replacingOccurrences(of: ",", with: ".").filter { "-0123456789.".contains($0) }) else {
            return .invalid("Za „\(op)“ chybí číslo.")
        }
        return .kpi(.init(metric: metric, above: op.hasPrefix(">"), threshold: v / 100))
    }

    /// Provede úpravu (bez .show/.delete/.invalid). Vrací text potvrzení.
    public func apply(to t: inout Thesis, today: String) -> String? {
        t.updated = today
        switch self {
        case let .statement(text, pos):
            if let pos { t.position = pos }
            if !text.isEmpty { t.statement = text }
            return "Teze: \(t.position == .long ? "Long" : "Short") – \(t.statement.isEmpty ? "—" : t.statement)"
        case let .pillar(s): t.pillars.append(s); return "Přidán pilíř \(t.pillars.count)."
        case let .risk(s): t.risks.append(s); return "Přidáno riziko \(t.risks.count)."
        case let .catalyst(s): t.catalysts.append(s); return "Přidán katalyzátor."
        case let .stop(s): t.stop = s; return "Stop: \(s)"
        case let .target(v): t.target = v; return String(format: "Cílová cena: $%.2f", v)
        case let .kpi(k): t.kpis.append(k); return "Přidáno KPI: \(k.metric.title) \(k.above ? ">" : "<") \(String(format: "%.1f %%", k.threshold * 100))"
        case let .note(s): t.log.append(.init(date: today, text: s)); return "Zapsáno do deníku."
        case let .remove(kind, i):
            func drop(_ a: inout [String]) -> Bool { guard a.indices.contains(i - 1) else { return false }; a.remove(at: i - 1); return true }
            var ok = false
            if kind.hasPrefix("pilir") || kind.hasPrefix("pillar") { ok = drop(&t.pillars) }
            else if kind.hasPrefix("rizik") || kind.hasPrefix("risk") { ok = drop(&t.risks) }
            else if kind.hasPrefix("katalyz") || kind.hasPrefix("catal") { ok = drop(&t.catalysts) }
            else if kind.hasPrefix("kpi"), t.kpis.indices.contains(i - 1) { t.kpis.remove(at: i - 1); ok = true }
            return ok ? "Odebráno." : "Položka \(kind) \(i) neexistuje."
        default: return nil
        }
    }
}

public struct KPIResult: Sendable {
    public let kpi: Thesis.KPI
    public let value: Double?
    public let period: String
    public var met: Bool? { value.map { kpi.above ? $0 > kpi.threshold : $0 < kpi.threshold } }
}

extension Thesis {
    /// KPI z posledního kvartálu (marže) a meziročního srovnání (růst).
    public func evaluate(_ q: QuarterlyFigures) -> [KPIResult] {
        guard let c = q.latest else { return kpis.map { KPIResult(kpi: $0, value: nil, period: "—") } }
        let ya = q.yearAgo(of: c)
        func margin(_ m: QuarterlyFigures.Metric) -> Double? {
            guard let v = c.value(m), let r = c.value(.revenue), r != 0 else { return nil }
            return v / r
        }
        return kpis.map { k in
            let v: Double?
            switch k.metric {
            case .revenueGrowth: v = QuarterlyFigures.change(c.value(.revenue), ya?.value(.revenue))
            case .epsGrowth: v = QuarterlyFigures.change(c.value(.eps), ya?.value(.eps))
            case .grossMargin: v = margin(.grossProfit)
            case .operatingMargin: v = margin(.operatingIncome)
            case .netMargin: v = margin(.netIncome)
            case .fcfMargin: v = margin(.freeCashFlow)
            }
            return KPIResult(kpi: k, value: v, period: c.quarter.label)
        }
    }

    public func markdown(results: [KPIResult], assessment: String?) -> String {
        func pct(_ v: Double) -> String { String(format: "%.1f %%", v * 100) }
        var md = "# Teze: \(ticker) — \(position == .long ? "Long" : "Short")\n\n"
        md += statement.isEmpty ? "_Teze zatím chybí – `/thesis-tracker \(ticker) teze <text>`._\n\n" : "> \(statement)\n\n"
        var meta: [String] = []
        if let target { meta.append(String(format: "**Cíl:** $%.2f", target)) }
        if let stop { meta.append("**Stop:** \(stop)") }
        if let conviction { meta.append("**Přesvědčení:** \(conviction)") }
        if !updated.isEmpty { meta.append("_upraveno \(updated)_") }
        if !meta.isEmpty { md += meta.joined(separator: " · ") + "\n\n" }

        if !results.isEmpty {
            md += "## KPI (\(results.first?.period ?? "—"), z XBRL)\n\n| # | Ukazatel | Cíl | Skutečnost | Stav |\n|---|---|---|---:|:---:|\n"
            for (i, r) in results.enumerated() {
                md += "| \(i + 1) | \(r.kpi.metric.title) | \(r.kpi.above ? ">" : "<") \(pct(r.kpi.threshold)) | "
                    + "\(r.value.map(pct) ?? "n/a") | \(r.met.map { $0 ? "✓" : "✗" } ?? "–") |\n"
            }
            md += "\n"
        }
        if let assessment, !assessment.isEmpty { md += assessment + "\n\n" }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            md += "## \(title)\n\n" + items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n\n"
        }
        list("Pilíře", pillars)
        list("Rizika", risks)
        list("Katalyzátory", catalysts)
        if !log.isEmpty {
            md += "## Deník\n\n" + log.suffix(8).reversed().map { e in
                "- **\(e.date)** \(e.text)" + (e.impact.map { " — _\($0)_" } ?? "")
            }.joined(separator: "\n") + "\n\n"
        }
        if pillars.isEmpty && kpis.isEmpty {
            md += "_Doplň: `pilíř <text>`, `riziko <text>`, `kpi růst tržeb > 20 %`, `cíl 250`, `poznámka <text>`._\n"
        }
        return md
    }
}

extension ResearchSkills {
    /// Zobrazení teze s KPI a (s modelem) hodnocením pilířů proti poslednímu kvartálu.
    public func thesisReview(_ thesis: Thesis) async throws -> (markdown: String, conviction: String?) {
        guard let c = try await load([thesis.ticker]).first else { return (thesis.markdown(results: [], assessment: nil), nil) }
        let q = c.quarters
        let results = thesis.evaluate(q)
        var assessment: String?
        var conviction: String?
        if let writer, !thesis.pillars.isEmpty || !thesis.risks.isEmpty {
            let kpiText = results.map { r in
                "- \(r.kpi.metric.title) target \(r.kpi.above ? ">" : "<") \(String(format: "%.1f%%", r.kpi.threshold * 100)): "
                    + "actual \(r.value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a") → \(r.met.map { $0 ? "met" : "missed" } ?? "unknown")"
            }.joined(separator: "\n")
            log("Hodnotím tezi…")
            let out = LLMOutput.clean(try await writer.write("""
            Assess an investment thesis against the latest reported data, in \(options.language). Be falsifiable and honest – \
            treat disconfirming evidence as seriously as confirming. Use only the data below. Output exactly:

            ## Hodnocení pilířů
            | Pilíř | Stav | Proč |
            |---|---|---|
            (one row per pillar; Stav is one of: drží, sledovat, porušen)
            ## Rizika
            - one bullet per risk: has it materialised? (max 20 words)
            ## Závěr
            One or two sentences. Then a final line exactly: PŘESVĚDČENÍ: vysoké | střední | nízké

            Thesis (\(thesis.position.rawValue) \(thesis.ticker)): \(thesis.statement)
            Pillars:
            \(thesis.pillars.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            Risks:
            \(thesis.risks.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            KPI check:
            \(kpiText)
            Recent log:
            \(thesis.log.suffix(5).map { "- \($0.date): \($0.text)" }.joined(separator: "\n"))
            Latest quarter figures:
            \(q.promptTable())
            """, maxTokens: 900))
            if let r = out.range(of: #"PŘESVĚDČENÍ:\s*(\S+)"#, options: [.regularExpression, .caseInsensitive]) {
                conviction = String(out[r]).components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                assessment = out.replacingCharacters(in: r, with: "**Přesvědčení:** \(conviction ?? "")")
            } else {
                assessment = out
            }
        }
        return (thesis.markdown(results: results, assessment: assessment), conviction)
    }

    /// Dopad nové poznámky na tezi (jedna věta), nil bez modelu.
    public func noteImpact(_ thesis: Thesis, note: String) async -> String? {
        guard let writer else { return nil }
        let out = try? await writer.write("""
        In \(options.language), in at most 15 words: does this new data point strengthen, weaken or not affect the thesis, \
        and which pillar? Start with one word: posiluje / oslabuje / neutrální.

        Thesis: \(thesis.statement)
        Pillars: \(thesis.pillars.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; "))
        New data point: \(note)
        """, maxTokens: 80)
        return out.map(LLMOutput.clean)
    }
}
