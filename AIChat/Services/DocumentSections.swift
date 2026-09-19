import Foundation

/// Jedna kapitola dokumentu.
struct DocumentSection: Sendable {
    let title: String
    let text: String
}

/// Rozdělení dlouhého dokumentu na kapitoly a dál na kusy, které se vejdou do kontextu.
enum DocumentSections {
    /// Kratší úsek než tohle je zbytek obsahu nebo hlavička, ne kapitola.
    /// Práh je nízký schválně: v 10-K je většina kapitol části III jediný odkaz
    /// na proxy statement a „Item 1B. Unresolved Staff Comments“ je celé „None.“.
    /// Zahodit je znamená, že dotaz na takovou kapitolu nic nenajde a shrnování
    /// spadne na celý dokument – přesně naopak, než má.
    private static let minimumSection = 40

    /// Jak daleko za přijatou hlavičkou se hledá další. Chrání před týmž nadpisem
    /// zopakovaným v záhlaví stránky; většinu práce ale dělá podmínka rostoucího
    /// pořadí položek, takže stačí krátký odstup. Delší okno zahodí kapitolu, která
    /// začíná hned za předchozí – v 10-K NVDA je „Item 1C. Cybersecurity“ 42 znaků
    /// za koncem hlavičky „Item 1B. Unresolved Staff Comments“.
    private static let headingGap = 40

    /// Rozdělí text podle hlaviček `Item 1.`, `Item 7A.` a podobných (výroční zprávy SEC).
    /// Když žádné nenajde, zkusí číslované a velkými písmeny psané nadpisy; jinak vrátí
    /// dokument jako jedinou kapitolu a o dělení se postará `chunks(of:maxCharacters:)`.
    static func split(_ text: String) -> [DocumentSection] {
        var headings = itemHeadings(in: text) ?? genericHeadings(in: text) ?? []
        // Hranice, které do textu vložil `InlineXBRL` podle otagovaných bloků. Jdou
        // dohromady s hlavičkami `Item N`, ne místo nich: otagované jsou jen přílohy
        // účetní závěrky, kdežto Business, Risk Factors a MD&A se pořád hledají regulárem.
        let tagged = taggedHeadings(in: text)
        if !tagged.isEmpty {
            headings.append(contentsOf: tagged)
            headings.sort { $0.start < $1.start }
        }
        guard headings.count > 1 else {
            return [DocumentSection(title: "", text: text)]
        }

        var sections: [DocumentSection] = []
        // Text před první hlavičkou (titulní strana, obsah) se nepřipojuje – nic neshrnuje.
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].start : text.endIndex
            var body = text[heading.start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            // Značka je jen hranice; název kapitoly v textu zůstane, aby ho našlo i hledání.
            if body.hasPrefix(InlineXBRL.sectionMarker) {
                body.removeFirst(InlineXBRL.sectionMarker.count)
            }
            guard body.count >= minimumSection else { continue }
            sections.append(DocumentSection(title: heading.title, text: body))
        }
        return sections.isEmpty ? [DocumentSection(title: "", text: text)] : sections
    }

    /// Řádky `§§ Název`, které do textu vložil `InlineXBRL.marking` před otagované bloky.
    private static func taggedHeadings(in text: String) -> [Heading] {
        guard text.contains(InlineXBRL.sectionMarker) else { return [] }
        let marker = NSRegularExpression.escapedPattern(for: InlineXBRL.sectionMarker)
        guard let regex = try? NSRegularExpression(pattern: "(?m)^\\s*\(marker)(.{1,90})$")
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let full = Range(match.range, in: text),
                  let title = Range(match.range(at: 1), in: text) else { return nil }
            return Heading(
                title: text[title].trimmingCharacters(in: .whitespaces),
                start: full.lowerBound)
        }
    }

    private struct Heading {
        let title: String
        let start: String.Index
    }

    /// Hlavičky `Item N.` z výročních zpráv. Dvě pasti: každý název je v dokumentu
    /// nejmíň dvakrát (obsah na začátku, pak vlastní kapitola) a některé se objeví i
    /// v záhlaví stránek. Proto se nejdřív přeskočí obsah – hustý shluk hlaviček na malé
    /// ploše – a pak se bere jen rostoucí řada: každá další hlavička musí mít vyšší číslo
    /// položky než předchozí. Kapitola, jejíž hlavička se v textu nenajde, se tím připojí
    /// k předchozí; o obsah se nepřijde, jen je zařazený pod sousední název.
    private static func itemHeadings(in text: String) -> [Heading]? {
        // Zbytek řádku je název kapitoly. Strop musí unést i ty nejdelší – „Item 7.
        // Management's Discussion and Analysis of Financial Condition and Results of
        // Operations“ má za číslem položky 85 znaků a při kratším stropu se hlavička
        // nenajde vůbec: celý MD&A se pak připojí k předchozí kapitole.
        let pattern = #"(?im)^\s*(Item\s+(\d{1,2})([A-C])?)[.:]?\s*(.{0,120})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        struct Match {
            let offset: Int
            let start: String.Index
            let order: (Int, String)
            let title: String
        }

        var matches: [Match] = []
        for match in regex.matches(in: text, range: range) {
            guard let full = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let digitsRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[digitsRange]) else { continue }
            let letter = Range(match.range(at: 3), in: text).map { String(text[$0]).uppercased() } ?? ""
            let rest = Range(match.range(at: 4), in: text)
                .map { text[$0].trimmingCharacters(in: .whitespaces) } ?? ""
            let label = text[numberRange]
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            matches.append(Match(
                offset: text.distance(from: text.startIndex, to: full.lowerBound),
                start: full.lowerBound,
                order: (number, letter),
                title: rest.isEmpty ? label : label + " – " + rest
            ))
        }
        guard matches.count > 2 else { return nil }

        // Obsah: pět a víc hlaviček namačkaných do několika tisíc znaků. Bere se konec
        // posledního takového shluku – od něj dál začíná vlastní text.
        //
        // Hledá se jen v první čtvrtině dokumentu. Obsah je vždycky vepředu, zatímco
        // shluk hlaviček se najde i jinde: kapitoly části III 10-K jsou samé krátké
        // odkazy na proxy statement a bez tohoto omezení by se celý dokument
        // vyhodnotil jako obsah a nezůstala by jediná kapitola.
        let tocLimit = text.count / 4
        var tocEnd = 0
        for index in 0..<max(0, matches.count - 4) where matches[index].offset <= tocLimit
            && matches[index + 4].offset - matches[index].offset < 4_000 {
            var last = index
            while last + 1 < matches.count, matches[last + 1].offset - matches[last].offset < 2_000 {
                last += 1
            }
            tocEnd = max(tocEnd, matches[last].offset + 200)
        }

        var headings: [Heading] = []
        var minimumOffset = tocEnd
        var previousOrder: (Int, String)?
        for match in matches where match.offset >= minimumOffset {
            if let previous = previousOrder,
               match.order.0 < previous.0 || (match.order.0 == previous.0 && match.order.1 <= previous.1) {
                continue
            }
            headings.append(Heading(title: match.title, start: match.start))
            minimumOffset = match.offset + headingGap
            previousOrder = match.order
        }
        return headings.count > 1 ? headings : nil
    }

    /// Záloha pro běžné dokumenty: Markdown nadpisy, `1.2 Název` nebo řádek velkými písmeny.
    private static func genericHeadings(in text: String) -> [Heading]? {
        let pattern = #"(?m)^\s*(#{1,3}\s+\S.{0,80}|\d{1,2}(\.\d{1,2})*[.)]\s+\S.{0,80}|[\p{Lu}][\p{Lu}\d \-–—:,.]{6,70})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        var headings: [Heading] = []
        for match in regex.matches(in: text, range: range) {
            guard let full = Range(match.range, in: text),
                  let titleRange = Range(match.range(at: 1), in: text) else { continue }
            let title = text[titleRange]
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            headings.append(Heading(title: String(title), start: full.lowerBound))
        }
        return headings.count > 1 ? headings : nil
    }

    /// Vybere z kapitol jen ty, na které se uživatel ptá. Rozumí „Part I“ i „část 1“
    /// a přímému odkazu na položku („Item 7“, „položka 1A“). Když v pokynu nic takového
    /// není nebo se nic netrefí, vrátí všechny kapitoly – radši shrnout víc než nic.
    ///
    /// Bez tohohle kroku se u výroční zprávy mele celý dokument i tehdy, když stačí
    /// jediná kapitola: rozdíl mezi dvěma a patnácti průchody.
    static func selected(_ sections: [DocumentSection], for instruction: String) -> [DocumentSection] {
        let request = requested(in: instruction)
        guard !request.isEmpty else { return sections }
        let picked = sections.filter { section in
            guard let key = itemKey(in: section.title) else { return false }
            // „part 1“ bere celou skupinu včetně 1A a 1B, „item 1“ jen samotnou jedničku.
            return request.groups.contains(key.number) || request.exact.contains(key.id)
        }
        return picked.isEmpty ? sections : picked
    }

    /// Položky, které uživatel vyžádal, ale v dokumentu se nenašly. Bez téhle informace
    /// appka mlčky zpracuje jen část zadání a model pak píše o kapitolách, které nedostal.
    static func missing(_ sections: [DocumentSection], for instruction: String) -> [String] {
        let request = requested(in: instruction)
        guard !request.exact.isEmpty else { return [] }
        let present = Set(sections.compactMap { itemKey(in: $0.title)?.id })
        return request.exact.subtracting(present).sorted()
    }

    private struct Request {
        var groups: Set<Int> = []
        var exact: Set<String> = []
        var isEmpty: Bool { groups.isEmpty && exact.isEmpty }
    }

    /// Co si uživatel vyžádal: části výroční zprávy se berou jako skupiny čísel,
    /// přímý odkaz na položku přesně včetně písmene.
    private static func requested(in instruction: String) -> Request {
        let text = instruction.lowercased()
        var request = Request()

        if let regex = try? NSRegularExpression(pattern: #"\b(part|část|cast)\s*(iv|i{1,3}|[1-4])\b"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let numberRange = Range(match.range(at: 2), in: text) else { continue }
                switch String(text[numberRange]) {
                case "1", "i": request.groups.formUnion([1, 2, 3, 4])
                case "2", "ii": request.groups.formUnion([5, 6, 7, 8, 9])
                case "3", "iii": request.groups.formUnion([10, 11, 12, 13, 14])
                case "4", "iv": request.groups.formUnion([15, 16])
                default: break
                }
            }
        }

        if let regex = try? NSRegularExpression(
            // Mezi číslem a písmenem nesmí být mezera, jinak se do „item 1 a item 2“
            // chytne česká spojka jako písmeno položky.
            pattern: #"\b(item|položka|polozka)\s*(\d{1,2})([a-c])?\b"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let numberRange = Range(match.range(at: 2), in: text) else { continue }
                let letter = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
                request.exact.insert((text[numberRange] + letter).uppercased())
            }
        }
        return request
    }

    /// Rozloží název kapitoly na číslo a písmeno („Item 1A – Risk Factors“ → 1, „1A“).
    private static func itemKey(in title: String) -> (number: Int, id: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)^item\s+(\d{1,2})([a-c])?"#),
              let match = regex.firstMatch(
                in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)),
              let numberRange = Range(match.range(at: 1), in: title),
              let number = Int(title[numberRange])
        else { return nil }
        let letter = Range(match.range(at: 2), in: title).map { String(title[$0]) } ?? ""
        return (number, (title[numberRange] + letter).uppercased())
    }

    /// Rozseká text na kusy do `maxCharacters`. Dělí se po odstavcích, a když je odstavec
    /// sám delší než limit, po větách – uprostřed slova nikdy.
    static func chunks(of text: String, maxCharacters: Int) -> [String] {
        guard maxCharacters > 0 else { return [] }
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = String(paragraph)
            if piece.count > maxCharacters {
                flush()
                chunks.append(contentsOf: splitLongParagraph(piece, maxCharacters: maxCharacters))
                continue
            }
            if current.count + piece.count + 1 > maxCharacters { flush() }
            current += current.isEmpty ? piece : "\n" + piece
        }
        flush()
        return carryingCaptions(chunks)
    }

    /// Popisek tabulky zůstal v předchozím kusu.
    ///
    /// Reálný případ: v 10-K NVDA padla hranice přesně za řádek „Operating Income by
    /// Reportable Segments" a další kus začal „Year Ended / Jan 25, 2026 …“. V takovém
    /// úryvku není nic, z čeho by model poznal, že čte provozní zisky, a pod tabulkou
    /// hned pokračuje věta o tržbách – odpověď pak vyjde jako tržby.
    ///
    /// Proto se poslední řádek, který vypadá jako nadpis, předřadí dalšímu kusu.
    /// Kus tím o ten řádek povyroste, což je proti rozpočtu zanedbatelné.
    private static func carryingCaptions(_ chunks: [String]) -> [String] {
        var result: [String] = []
        var carry = ""
        for chunk in chunks {
            result.append(carry.isEmpty ? chunk : carry + "\n" + chunk)
            carry = trailingCaption(of: chunk) ?? ""
        }
        return result
    }

    private static func trailingCaption(of chunk: String) -> String? {
        let lines = chunk
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.suffix(4).reversed() where isCaption(line) { return line }
        return nil
    }

    /// Nadpis nebo popisek tabulky: krátký řádek, převážně písmena, nekončí větou.
    private static func isCaption(_ line: String) -> Bool {
        guard line.count >= 6, line.count <= 90 else { return false }
        guard !line.hasSuffix("."), !line.hasSuffix(":"), !line.hasSuffix(",") else { return false }
        let letters = line.filter(\.isLetter).count
        let digits = line.filter(\.isNumber).count
        return letters >= 6 && digits <= letters / 3
    }

    private static func splitLongParagraph(_ text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        // Hrubé dělení na věty stačí – jde o to netrhat slova, ne o jazykovou správnost.
        for sentence in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " }) {
            let word = String(sentence)
            if current.count + word.count + 1 > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? word : " " + word
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
