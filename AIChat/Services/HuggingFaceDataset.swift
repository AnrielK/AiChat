import Foundation

/// Trénovací vzorky z Hugging Face. Celý dataset se nestahuje – čte se přes
/// Dataset Viewer API po stránkách, takže se dá vzít prvních pár set řádků
/// a zbytek nechat být. Parquet soubory by znamenaly vlastní parser.
enum HuggingFaceDataset {
    /// Maximum, které endpoint `/rows` povolí na jeden požadavek.
    static let pageLimit = 100

    struct Split: Sendable, Hashable, Identifiable {
        let config: String
        let split: String
        var id: String { config + "/" + split }
        var label: String { config == "default" ? split : "\(config) · \(split)" }
    }

    /// Hodnota v řádku. Textové sloupce jdou použít přímo, sloupce se zprávami
    /// (chat formát) se rozpadají na role a obsah.
    enum Cell: Sendable {
        case text(String)
        case messages([Message])
        case unsupported

        struct Message: Sendable {
            let role: String
            let content: String
        }

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    struct Page: Sendable {
        let columns: [String]
        let rows: [[String: Cell]]
        /// Kolik řádků má split celkem – kvůli zobrazení a zastavení stránkování.
        let total: Int
    }

    // MARK: - Síť

    /// Dostupné konfigurace a splity. Bez toho se `/rows` volat nedá.
    static func splits(dataset: String) async throws -> [Split] {
        var components = URLComponents(string: "https://datasets-server.huggingface.co/splits")
        components?.queryItems = [URLQueryItem(name: "dataset", value: dataset)]
        guard let url = components?.url else {
            throw ProviderError.notConfigured("Neplatné ID datasetu.")
        }
        let object = try await json(url)
        let items = (object["splits"] as? [[String: Any]]) ?? []
        let splits = items.compactMap { item -> Split? in
            guard let config = item["config"] as? String, let split = item["split"] as? String else { return nil }
            return Split(config: config, split: split)
        }
        guard !splits.isEmpty else {
            throw ProviderError.notConfigured("Dataset nemá žádný split, nebo není v prohlížeči datasetů dostupný.")
        }
        // Trénovací split napřed – většinou je to ten, který chceme.
        return splits.sorted { lhs, rhs in
            (lhs.split == "train" ? 0 : 1, lhs.id) < (rhs.split == "train" ? 0 : 1, rhs.id)
        }
    }

    /// Podmínka „sloupec = hodnota“. Vyhodnocuje se v aplikaci, ne na serveru:
    /// endpoint `/filter` prohlížeče datasetů u větších datasetů vrací 500 nebo
    /// nestihne odpovědět. Hodí se u kolekcí poskládaných z více zdrojů
    /// (sloupec typu `origin`), které jsou seřazené podle zdroje.
    struct Filter: Sendable, Hashable {
        let column: String
        let value: String
        let isBool: Bool

        func matches(_ row: [String: Cell]) -> Bool {
            guard let text = row[column]?.text else { return false }
            if isBool {
                // Statistiky hlásí „True“/„False“, řádky vrací JSON bool (NSNumber → „1“/„0“).
                let truthy = ["1", "true"].contains(text.lowercased())
                return truthy == (value.lowercased() == "true")
            }
            return text == value
        }
    }

    /// Sloupec s malým počtem různých hodnot a jejich četnosti – z endpointu
    /// `/statistics`. Z nich se nabízí filtr, aby se hodnota nemusela psát ručně.
    struct LabelColumn: Sendable, Hashable, Identifiable {
        let name: String
        let isBool: Bool
        /// Hodnoty seřazené od nejčastější.
        let values: [(value: String, count: Int)]
        var id: String { name }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    /// Sloupce, podle kterých jde filtrovat. Statistiky nemají všechny datasety
    /// (počítají se jen pro menší splity), takže prázdný výsledek není chyba.
    static func labelColumns(dataset: String, split: Split) async throws -> [LabelColumn] {
        var components = URLComponents(string: "https://datasets-server.huggingface.co/statistics")
        components?.queryItems = [
            URLQueryItem(name: "dataset", value: dataset),
            URLQueryItem(name: "config", value: split.config),
            URLQueryItem(name: "split", value: split.split),
        ]
        guard let url = components?.url else { return [] }
        let object = try await json(url)
        let items = (object["statistics"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> LabelColumn? in
            guard let name = item["column_name"] as? String,
                  let type = item["column_type"] as? String,
                  ["string_label", "class_label", "bool"].contains(type),
                  let stats = item["column_statistics"] as? [String: Any],
                  let frequencies = stats["frequencies"] as? [String: Any],
                  frequencies.count > 1
            else { return nil }
            let values = frequencies
                .map { (value: $0.key, count: ($0.value as? NSNumber)?.intValue ?? 0) }
                .sorted { $0.count > $1.count }
            return LabelColumn(name: name, isBool: type == "bool", values: values)
        }
    }

    static func page(
        dataset: String,
        split: Split,
        offset: Int,
        length: Int
    ) async throws -> Page {
        var components = URLComponents(string: "https://datasets-server.huggingface.co/rows")
        components?.queryItems = [
            URLQueryItem(name: "dataset", value: dataset),
            URLQueryItem(name: "config", value: split.config),
            URLQueryItem(name: "split", value: split.split),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "length", value: String(min(length, pageLimit))),
        ]
        guard let url = components?.url else {
            throw ProviderError.notConfigured("Neplatné ID datasetu.")
        }
        let object = try await json(url)

        let features = (object["features"] as? [[String: Any]]) ?? []
        let columns = features.compactMap { $0["name"] as? String }
        let rows = ((object["rows"] as? [[String: Any]]) ?? []).map { entry in
            ((entry["row"] as? [String: Any]) ?? [:]).mapValues(cell)
        }
        let total = (object["num_rows_total"] as? NSNumber)?.intValue ?? rows.count
        return Page(columns: columns, rows: rows, total: total)
    }

    // MARK: - Hledání rozsahu pro filtr

    /// Kde v splitu leží řádky s danou hodnotou, pokud jsou pohromadě (kolekce
    /// seřazené podle zdroje). Čte se po jednom řádku: nejdřív sonda každých
    /// `expected / 2` řádků – souvislý blok té délky tak zasáhne nejméně jednou –
    /// a od zásahu se binárně hledají oba okraje. Pro 100 tisíc řádků a hodnotu
    /// s 11 tisíci výskyty je to kolem 45 malých požadavků.
    ///
    /// nil = hodnota se nenašla, je moc vzácná na sondování, nebo řádky
    /// nejsou pohromadě (nalezený úsek je kratší než počet ze statistik).
    static func locate(
        dataset: String,
        split: Split,
        filter: Filter,
        expected: Int,
        total: Int
    ) async throws -> Range<Int>? {
        guard expected > 0, total > 0 else { return nil }
        if expected >= total { return 0 ..< total }
        let step = max(1, expected / 2)
        let probes = Array(Swift.stride(from: step - 1, to: total, by: step))
        guard probes.count <= 160 else { return nil }

        let hit: @Sendable (Int) async throws -> Bool = { offset in
            guard offset >= 0, offset < total else { return false }
            let page = try await HuggingFaceDataset.page(dataset: dataset, split: split, offset: offset, length: 1)
            return page.rows.first.map { filter.matches($0) } ?? false
        }

        // Sondy po osmi souběžně – sériově by to trvalo zbytečně dlouho.
        var found: Int?
        var index = 0
        while found == nil, index < probes.count {
            let batch = Array(probes[index ..< min(index + 8, probes.count)])
            index += batch.count
            let hits = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
                for offset in batch { group.addTask { (offset, try await hit(offset)) } }
                var result: [Int] = []
                for try await (offset, isHit) in group where isHit { result.append(offset) }
                return result
            }
            found = hits.min()
        }
        guard let first = found else { return nil }

        // Levý okraj: předchozí sonda (nebo -1) je mimo, `first` uvnitř.
        var outside = first - step
        var inside = first
        while inside - outside > 1 {
            let middle = (outside + inside) / 2
            if try await hit(middle) { inside = middle } else { outside = middle }
        }
        let lower = inside

        // Pravý okraj: za `lower + expected` už blok skončit musí.
        inside = first
        outside = min(total, lower + expected)
        while outside - inside > 1 {
            let middle = (inside + outside) / 2
            if try await hit(middle) { inside = middle } else { outside = middle }
        }
        let range = lower ..< inside + 1
        return range.count == expected ? range : nil
    }

    /// Token z Klíčenky se přidá stejně jako u stahování modelů – gated datasety
    /// bez něj vrátí 401.
    /// Přetížený prohlížeč datasetů občas vrátí 429 nebo 5xx a napodruhé projde,
    /// proto dva opakované pokusy s krátkou pauzou.
    private static func json(_ url: URL) async throws -> [String: Any] {
        var request = HuggingFaceRepo.request(url)
        request.timeoutInterval = 30
        var attempt = 0
        var (data, response) = try await URLSession.shared.data(for: request)
        while let http = response as? HTTPURLResponse,
              http.statusCode == 429 || (500 ..< 600).contains(http.statusCode),
              http.statusCode != 501, attempt < 2 {
            attempt += 1
            try await Task.sleep(for: .seconds(attempt * 2))
            (data, response) = try await URLSession.shared.data(for: request)
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, message: message(forStatus: http.statusCode))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.engine("Odpověď Hugging Face nejde přečíst.")
        }
        return object
    }

    private static func message(forStatus status: Int) -> String {
        switch status {
        case 401, 403:
            "Dataset vyžaduje přihlášení. Vlož token Hugging Face ve Stahování a na webu přijmi jeho podmínky."
        case 404:
            "Dataset neexistuje, nebo pro něj není zapnutý prohlížeč datasetů."
        case 429:
            "Hugging Face omezuje počet požadavků. Zkus to za chvíli, nebo s menším počtem vzorků."
        case 501:
            "Tenhle dataset prohlížeč datasetů nepodporuje – řádky se přes API načíst nedají."
        default:
            "Hugging Face vrátil chybu \(status)."
        }
    }

    private static func cell(_ value: Any) -> Cell {
        switch value {
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            return .text(number.stringValue)
        case let array as [[String: Any]]:
            // Chat formáty se liší: role/content (ChatML) i from/value (ShareGPT).
            let messages = array.compactMap { item -> Cell.Message? in
                guard let role = (item["role"] as? String) ?? (item["from"] as? String),
                      let content = (item["content"] as? String) ?? (item["value"] as? String)
                else { return nil }
                return Cell.Message(role: role, content: content)
            }
            return messages.isEmpty ? .unsupported : .messages(messages)
        default:
            return .unsupported
        }
    }
}

// MARK: - Mapování sloupců

/// Který sloupec je zadání a který odpověď. Datasety se v pojmenování neshodnou,
/// takže se odhadne a uživatel to může přepsat.
struct DatasetMapping: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case columns
        case messages

        var label: String {
            switch self {
            case .columns: "Sloupce"
            case .messages: "Konverzace"
            }
        }
    }

    var kind: Kind = .columns
    var promptColumn = ""
    /// Volitelný kontext, který se připojí pod zadání (alpaca `input`).
    var inputColumn = ""
    var outputColumn = ""
    var messagesColumn = ""

    var isComplete: Bool {
        switch kind {
        case .columns: !promptColumn.isEmpty && !outputColumn.isEmpty
        case .messages: !messagesColumn.isEmpty
        }
    }

    private static let promptNames = ["instruction", "prompt", "question", "query", "input", "text"]
    private static let inputNames = ["input", "context", "passage"]
    private static let outputNames = ["output", "response", "answer", "completion", "chosen", "target"]
    private static let messagesNames = ["messages", "conversations", "conversation", "turns"]

    static func autodetect(page: HuggingFaceDataset.Page) -> DatasetMapping {
        var mapping = DatasetMapping()
        let sample = page.rows.first ?? [:]

        if let column = page.columns.first(where: { column in
            messagesNames.contains(column.lowercased()) && isMessages(sample[column])
        }) {
            mapping.kind = .messages
            mapping.messagesColumn = column
            return mapping
        }

        mapping.outputColumn = match(page.columns, outputNames) ?? ""
        mapping.promptColumn = match(page.columns, promptNames.filter { $0 != mapping.outputColumn }) ?? ""
        // `input` je zadání jen tehdy, když vedle něj není instruction.
        if mapping.promptColumn != "input", let input = match(page.columns, inputNames) {
            mapping.inputColumn = input
        }
        return mapping
    }

    private static func match(_ columns: [String], _ names: [String]) -> String? {
        for name in names {
            if let column = columns.first(where: { $0.lowercased() == name }) { return column }
        }
        return nil
    }

    private static func isMessages(_ cell: HuggingFaceDataset.Cell?) -> Bool {
        if case .messages = cell { return true }
        return false
    }

    /// Z řádku udělá dvojici zadání/odpověď. nil = řádek se použít nedá.
    func pair(from row: [String: HuggingFaceDataset.Cell]) -> (prompt: String, answer: String)? {
        switch kind {
        case .columns:
            guard let prompt = row[promptColumn]?.text, let answer = row[outputColumn]?.text else { return nil }
            var full = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inputColumn.isEmpty, let context = row[inputColumn]?.text,
               !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                full += "\n\n" + context.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return make(full, answer)

        case .messages:
            guard case .messages(let messages)? = row[messagesColumn] else { return nil }
            // Bere se první výměna. Víceotáčkové konverzace by se do jednoho
            // vzorku vešly jen s vlastním formátováním historie.
            guard let userIndex = messages.firstIndex(where: { $0.role == "user" || $0.role == "human" }),
                  let reply = messages[(userIndex + 1)...].first(where: {
                      $0.role == "assistant" || $0.role == "gpt"
                  })
            else { return nil }
            return make(messages[userIndex].content, reply.content)
        }
    }

    private func make(_ prompt: String, _ answer: String) -> (prompt: String, answer: String)? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !answer.isEmpty else { return nil }
        return (prompt, answer)
    }
}

// MARK: - Filtr

enum DatasetFilter {
    /// Hrubý test „vypadá to česky“: podíl znaků s českou diakritikou. Strojově
    /// přeložené datasety obsahují i nepřeložené řádky a ty do tréninku češtiny
    /// nepatří. Není to detekce jazyka – slovenštinu ani polštinu nerozezná.
    static func looksCzech(_ text: String) -> Bool {
        let marks = CharacterSet(charactersIn: "ěščřžýáíéúůňťďóĚŠČŘŽÝÁÍÉÚŮŇŤĎÓ")
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 20 else { return false }
        let accented = letters.filter { marks.contains($0) }.count
        return Double(accented) / Double(letters.count) >= 0.03
    }
}

// MARK: - Soubory

/// Čtení datasetu ze souboru. Zvládne JSONL (jeden objekt na řádek) i klasické
/// JSON pole – většina alpaca datasetů se šíří jako jedno velké pole, ne po řádcích.
/// Podporované tvary objektu: `instruction`/`input`/`output`, `prompt`/`response`,
/// `question`/`answer` a `messages`.
enum JSONLDataset {
    /// Soubory, které uživatel nahrál do složky aplikace v Souborech. Díky
    /// `UIFileSharingEnabled` je ta složka vidět a dá se do ní soubor přetáhnout,
    /// což funguje i tam, kde výběr přes Soubory soubor s příponou .jsonl nenabídne.
    static func localFiles() -> [URL] {
        let extensions = ["jsonl", "json", "ndjson", "txt"]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: .documentsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func pairs(at url: URL) throws -> [(prompt: String, answer: String)] {
        // Soubor vybraný přes Soubory leží mimo sandbox aplikace a je potřeba
        // si k němu říct o přístup. U souboru z Documents to vrátí false a nevadí.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw ProviderError.engine("Soubor je prázdný.")
        }

        // Celý soubor jako jeden JSON – pole objektů, nebo jeden objekt.
        if let root = try? JSONSerialization.jsonObject(with: data) {
            if let array = root as? [[String: Any]] {
                return array.compactMap(pair(from:))
            }
            if let object = root as? [String: Any] {
                // Některé datasety balí data do klíče "data" nebo "rows".
                for key in ["data", "rows", "train", "examples"] {
                    if let array = object[key] as? [[String: Any]] {
                        return array.compactMap(pair(from:))
                    }
                }
                return [pair(from: object)].compactMap { $0 }
            }
        }

        // Jinak JSONL. Windows-1250 kvůli souborům, které prošly starším editorem.
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1250)
        else {
            throw ProviderError.engine("Soubor není v kódování UTF-8 ani Windows-1250.")
        }

        var pairs: [(prompt: String, answer: String)] = []
        var malformed = 0
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "[", trimmed != "]" else { continue }
            // Pole rozdělené na řádky má za objektem čárku.
            let cleaned = trimmed.hasSuffix(",") ? String(trimmed.dropLast()) : trimmed
            guard let lineData = cleaned.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                malformed += 1
                continue
            }
            if let pair = pair(from: object) { pairs.append(pair) }
        }

        guard !pairs.isEmpty else {
            throw ProviderError.engine(
                malformed > 0
                    ? "V souboru nejsou čitelné vzorky – \(malformed) řádků není platný JSON."
                    : "V souboru nejsou vzorky ve tvaru, který umím přečíst (instruction/output, prompt/response nebo messages)."
            )
        }
        return pairs
    }

    private static func pair(from object: [String: Any]) -> (prompt: String, answer: String)? {
        if let messages = object["messages"] as? [[String: Any]] ?? object["conversations"] as? [[String: Any]] {
            return self.pair(fromMessages: messages)
        }

        var prompt = (object["instruction"] as? String)
            ?? (object["prompt"] as? String)
            ?? (object["question"] as? String)
            ?? (object["input"] as? String)
            ?? ""
        let answer = (object["output"] as? String)
            ?? (object["response"] as? String)
            ?? (object["answer"] as? String)
            ?? (object["completion"] as? String)
            ?? (object["chosen"] as? String)
            ?? ""

        // `input` je kontext jen tehdy, když zadání nese `instruction`.
        if object["instruction"] != nil, let context = object["input"] as? String,
           !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + context
        }
        return make(prompt, answer)
    }

    private static func pair(fromMessages messages: [[String: Any]]) -> (prompt: String, answer: String)? {
        let parsed = messages.compactMap { item -> (role: String, content: String)? in
            guard let role = (item["role"] as? String) ?? (item["from"] as? String),
                  let content = (item["content"] as? String) ?? (item["value"] as? String)
            else { return nil }
            return (role, content)
        }
        guard let userIndex = parsed.firstIndex(where: { $0.role == "user" || $0.role == "human" }),
              let reply = parsed[(userIndex + 1)...].first(where: { $0.role == "assistant" || $0.role == "gpt" })
        else { return nil }
        return make(parsed[userIndex].content, reply.content)
    }

    private static func make(_ prompt: String, _ answer: String) -> (prompt: String, answer: String)? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !answer.isEmpty else { return nil }
        return (prompt, answer)
    }
}
