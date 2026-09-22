# FinFill — 10-K → Google Sheets + on-device souhrn

Swift modul pro AIChat. Stáhne výroční zprávu (10-K) z SEC, doplní finanční data do existujícího
Google Sheets sešitu (šablona „NVDA Valuation – 5y“) a lokálním modelem udělá souhrn dokumentu.

**Čísla nikdy nepočítá model.** Berou se z XBRL, kontrolují se proti součtům, které firma sama vykazuje,
a do tabulky se zapíšou jen když všechny kontroly sedí. Model píše jen text souhrnu.

```
SEC companyfacts JSON ─┐                        ┌─ kontroly součtů (14×) ─┐
                       ├─ FactStore ─ mapování ─┤                         ├─ plán zápisu ─ Sheets API
10-K .htm (iXBRL) ─────┤   (JSON šablony)       └─ backtest min. roku ────┘
                       └─ text → Item 1/1A/7/7A → chunky → poznámky → souhrn sekcí → exec. summary
                                                   (LLMEngine: MLX / llama.cpp / OpenAI-compatible)
```

## Co je v balíčku

| Cesta | Obsah |
|---|---|
| `Sources/FinFillCore/SEC` | `SECClient` (ticker→CIK, companyfacts, submissions, stažení 10-K), `CompanyFactsParser`, `InlineXBRLParser` (včetně dimenzí = segmenty), `HTMLText` |
| `Sources/FinFillCore/Models` | `Fact`, `FactStore` (výběr faktu pro fiskální rok, jednotku a dimenze) |
| `Sources/FinFillCore/Mapping` | `TemplateMapping` (JSON), `MappingResolver` (hodnota + vzorec buňky), `Validator` (kontroly + backtest) |
| `Sources/FinFillCore/Sheets` | `GoogleSheetsClient` (REST v4, bez SDK), `GoogleDriveClient` (seznam sešitů), `SheetPlanner` (sloupec roku, vytvoření chybějícího, nepřepisuje vyplněné buňky) |
| `Sources/FinFillCore/Summary` | `FilingSections`, `KeyFigures` (čísla do souhrnu počítaná kódem), `Summarizer` (map-reduce) |
| `Sources/FinFillCore/LLM` | protokol `LLMEngine`, `OpenAICompatibleEngine`, odstraňování `<think>` |
| `Sources/FinFillCore/Pipeline` | `FinFillPipeline` — celý běh s událostmi pro UI |
| `Sources/FinFillCore/Resources/nvda-valuation-5y.json` | mapování tvé šablony (IncomeStatement / BalanceSheets / CashFlowStatement) |
| `Sources/FinFillUI/FinFillView.swift` | SwiftUI obrazovka (iOS 17+): náhled → zápis → souhrn |
| `Sources/finfill-cli` | CLI pro Mac (offline nad staženým 10-K, nebo online do Sheets) |
| `Sources/FinFillCore/Templates` | `SpreadsheetTemplate` + `TemplateRequests` (Sheets API create/updateCells/merge/šířky), `WorkbookFiller` (všechny roky) |
| `Tests/` | 18 testů nad přiloženým NVDA 10-K |

`FinFillCore` je čistý Foundation (běží na iOS, macOS i Linuxu), `FinFillUI` jen na iOS.

## Zapojení v AIChat

Balíček je v projektu jako lokální Swift package (stejně jako `Packages/LlamaCpp`), target AIChat
používá produkty `FinFillCore` a `FinFillUI`. Na straně aplikace:

| Soubor | Co dělá |
|---|---|
| `AIChat/Services/FinFillEngine.swift` | `LLMEngine` nad `SettingsStore.makeProvider(profile: .summarize, reasoningOverride: false)` + `oneShot()` — souhrn běží na modelu vybraném v Nastavení (GGUF, MLX, Apple Intelligence i cloud) |
| `AIChat/Services/GoogleAuth.swift` | OAuth 2 PKCE přes `ASWebAuthenticationSession`, bez Google SDK; refresh token v Klíčence (`KeychainAccount.googleRefresh`) |
| `AIChat/Views/FinFillScreen.swift` | obrazovka `FinFillView` + nastavení Google účtu |
| `AIChat/Views/SettingsView.swift` | sekce **Nástroje**: „10-K → Google Sheets“ a „Google účet“ |

Kontext pro dělení 10-K se bere jako `min(délka kontextu, LocalRuntime.effectiveContext ?? 8k, summaryChunkTokens)`.
S MLX předvolbou 4k vyjde ~35 průchodů; na souhrn 10-K se vyplatí zvednout kontext na 8k.

## Google Cloud (jednorázově)

1. https://console.cloud.google.com → nový projekt → *APIs & Services → Enable APIs* → **Google Sheets API**.
2. *OAuth consent screen* → External, stav Testing, přidej svůj Gmail jako test user,
   scope `https://www.googleapis.com/auth/spreadsheets`.
3. *Credentials → Create OAuth client ID → iOS*, Bundle ID aplikace.
4. V aplikaci: Nastavení › Nástroje › Google účet → vlož client ID → Přihlásit.
   URL scheme do Info.plist není potřeba, návrat zachytí `ASWebAuthenticationSession`.
   V režimu Testing vyprší přihlášení po 7 dnech, aplikace se pak zeptá znovu.

Na test bez aplikace stačí token z https://developers.google.com/oauthplayground (scope výše) a CLI:

```bash
cd Packages/FinFill
swift run finfill run --ticker NVDA --ua "Anriel tvuj@email.cz" \
  --sheet "https://docs.google.com/spreadsheets/d/…/edit" --token ya29.… # náhled, nic nezapíše
# … --write            # zapíše (jen prázdné buňky / nuly)
# … --write --overwrite
```

## SEC

SEC vyžaduje `User-Agent` ve tvaru `Jméno email` a max. 10 požadavků/s (FinFill jich udělá 4).
Companyfacts **neobsahuje dimenzionální fakta**, proto se segmenty (Graphics / Compute & Networking)
berou z iXBRL přímo z 10-K, který se stahuje i kvůli souhrnu.

## Nový sešit ze šablony

`FinFillPipeline.createWorkbook(template:)` založí Google sešit z `SpreadsheetTemplate`
(`Resources/templates/valuation-universal.json` – výkazy + DCF + WACC, vzorce a formát)
a `WorkbookFiller` vyplní všechny roky, které SEC data pokrývají (9 let končících 10-K).
DCF v univerzální šabloně hledá roky přes `INDEX/MATCH`, takže se s novým sloupcem posune.

Šablona se generuje z .xlsx:

```bash
python3 tools/finfill-template.py "Valuation.xlsx" --universal \
  --json Packages/FinFill/Sources/FinFillCore/Resources/templates/valuation-universal.json
```

## Jak se zapisuje

- Sloupec se najde podle roku v řádku 2 (`O2 = 2026`), předchozí sloupec je `{prev}`.
- Když sloupec pro rok chybí a list končí předchozím rokem, vloží se nový sloupec, zkopíruje se
  do něj předchozí (vzorce + formát), vymažou se ručně zadaná čísla a mapované řádky a zapíše se.
- Kontroly mají řádek na dorovnání (`plugRow`): rozdíl oproti vykázanému součtu jde do řádku
  „ostatní“ a je vidět v UI i ve vzorci. Díky tomu šablona funguje i pro firmy s jinými
  segmenty a položkami (AMD).
- Zapisují se jen řádky se vstupními daty; řádky se vzorci (součty, marže, NWC) se nemění.
- Jedna položka → číslo. Víc položek → vzorec ve stylu šablony, aby byl vidět původ:
  `=10383+2867`, `=21352-O21`, `=11226+15157+84-40616-17502`, `={prev}30`.
- Bez `overwrite` se přepisují jen prázdné buňky a nuly (šablona má v O19:O23 nuly).
- Když neprojde některá z 14 kontrol (tržby ze segmentů, hrubý zisk, EBIT, EBT, čistý zisk, aktiva,
  závazky, VK, L+E, CFO, CFI, CFF), zápis se zablokuje.

### Výsledek pro NVDA FY2026 (10-K k 25. 1. 2026)

Všech 14 kontrol sedí na korunu (v mil. USD). Po doplnění do kopie šablony dávají její vlastní vzorce
tržby 215 938, EBIT 130 387, čistý zisk 120 067, aktiva 206 803 = L+E, CFO 102 718, konečná hotovost
10 605 (= rozvaha).

Backtest FY2025 proti ručně vyplněnému sloupci N: výsledovka i cash flow sedí přesně; v rozvaze se
liší jen rozdělení položek (součty stejné):
- ř. 12/13: dlouhodobé majetkové investice (3 387) mapování dává do „Long-term Investments“,
  ve sloupci N jsou v „Other non-current assets“,
- ř. 21/22: krátkodobý leasing — FY2026 10-K ho za FY2025 znovu netaguje; online z companyfacts přijde 288,
- ř. 29/30: kmenové akcie (24) zvlášť, ve sloupci N jsou přičtené k APIC.

Stojí za zmínku: v CF je nová položka **Groq, Inc. (13 000)**, mapování ji dává do „Cash Acquisitions“
(-14 535 celkem).

## Souhrn na telefonu

- `Summarizer` rozdělí 10-K na Item 1, 1A, 7, 7A, velikost chunků odvodí z `engine.contextTokens`
  (~4 znaky/token). NVDA 10-K má ~87k tokenů; s kontextem 8k to je 12 chunků + 3 slučování + 1 finále.
- Čísla v souhrnu: model dostane tabulku `KeyFigures` spočítanou z XBRL a smí citovat jen ji.
- `temperature 0.6` (greedy dekódování Qwen3.x distilace zacyklí), `/no_think` + odstranění `<think>`.
- Jazyk: `Summarizer.Options.language` (`"English"` / `"Czech"`). U 4B modelu je angličtina výrazně lepší.
- Výstup: markdown + list `Summary FY2026` v sešitu.

Na Macu se dá kvalita souhrnu porovnat přes OpenAI-kompatibilní server:

```bash
mlx_lm.server --model SiddhJagani/Qwen3.8-4B-mlx-4Bit --port 8080
swift run finfill local --html nvda-20260125.htm --llm http://localhost:8080/v1 --model default --ctx 8192
```

## Jiná firma / jiná šablona

Mapování je jen JSON. Pro jinou firmu se stejnou šablonou většinou stačí upravit segmentové řádky
(`dims` — členy os najdeš v iXBRL, např. `nvda:GraphicsSegmentMember`) a firemní koncepty s prefixem
firmy (`nvda:…`); `c` je seznam alternativ, bere se první nalezená. Kontroly pak ukážou, jestli něco chybí
nebo je započteno dvakrát. `swift run finfill local --html <10-K> --mapping muj.json` vypíše všechny
buňky a kontroly bez sítě.

## Testy

```bash
swift test          # 18 testů: iXBRL, mapování FY2026, backtest FY2025 vs. šablona, plánovač, sekce, souhrn (mock), companyfacts, helpery
```
