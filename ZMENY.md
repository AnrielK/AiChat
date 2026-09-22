# MoE: celá vrstva při prefillu, rezidence po expertech v záznamu

Podle prvního záznamu z iPhonu (Qwen3-30B-A3B, 797 tokenů, k = 8):

- **Zjištění.** Naměřený zásah page cache 67,3 % odpovídá simulované LRU cache o 2 GB (67,8 %). iOS tedy
  expertům dává zhruba 2 GB a simulace sedí se skutečností. Při 3 GB by zásah byl 80 % a čtení na token
  213 místo 339 MB, při 4 GB 87 % a 140 MB. Jen 0,1 % výpadků byli experti z minulého tokenu, takže
  předpověď „z minulého tokenu“ předčítání nepomůže. Prefill vybírá průměrně 40 % expertů vrstvy
  a 74 % vrstev je nad 30 %.
- **Prefill: celá vrstva** (`prefillWholeLayerPercent`, Parametry › Výkon, výchozí vypnuto; volby
  30 / 50 / 70 %). Při dávce > 1 a pokrytí nad prahem `ExpertPrefetcher` nejdřív přečte celé tenzory
  expertů vrstvy sekvenčně (`pread` po 8 MB, paralelně, přes page cache) a teprve pak jde běžné
  předčítání vybraných expertů. Do logu se zapíše „celé vrstvy N× · X MB za Y s (Z GB/s)“.
- **Záznam v3**: horní bit (0x8000) čísla experta = expert ležel celý v page cache. Měří se i odhadnutí
  experti z routeru. Soubor nevyroste a verze 1 a 2 se dál čtou.
- **Simulace › Předpověď expertů**: nové sloupce „výpadky“ (kolik expertů chybějících v cache by odhad
  načetl dopředu) a „čtení navíc“ (zbytečné čtení z flash vůči nutnému). Experti z minulého tokenu mimo
  odhad z routeru se berou jako v cache. Totéž umí `tools/expert_cache_sim.py`.

Ověřeno v Pythonu: syntetický záznam v3 (LRU 2 GB) dává u minulého tokenu 0 % výpadků, stejně jako
reálná data. Záznamy v1 a v2 se dál čtou a politiky cache sedí s naivními implementacemi. Swift je
nepřeložený.

---

# MoE: vyhodnocení předpovědi expertů a pokrytí prefillu

Navazuje na záznam expertů. Cílem je zjistit, jestli se vyplatí předčítat experty dopředu,
aby čtení z flash běželo souběžně s výpočtem. Zatím se jen měří, podle odhadu se nic nečte.

- **Odhad z routeru další vrstvy** (`RouterPredictor`). Při zapnutém záznamu si callback při generování
  (dávka 1) řekne i o uzel `ffn_inp-L`, tedy reziduální vstup MoE vrstvy L. Vynásobí ho routerem vrstvy
  L+1 (`blk.N.ffn_gate_inp`) a seřazený odhad 2k expertů uloží. Do routeru je při načtení složená RMSNorm
  vrstvy L+1 (`blk.N.ffn_norm`): kladné měřítko 1/rms pořadí nezmění, takže odhad vidí stejný vstup jako
  router L+1, jen bez příspěvku attention vrstvy L+1. Váhy se drží v F16 (u Qwen3-30B-A3B ~25 MB)
  a násobí přes Accelerate.
  Odhad vzniká před MoE vrstvy L, takže náskok je MoE vrstvy L plus attention vrstvy L+1. Routery se
  načtou jen se záznamem a s jeho vypnutím se uvolní. Model bez routerů v F32/F16/BF16 odhad nemá.
- **Formát záznamu v2**: u události je navíc seřazený odhad. Verze 1 se dál čte.
  `GGUFLayout` si pamatuje polohu routerů a norem před MoE (`routerTensors`).
- **Simulace › Předpověď expertů**: kolik potřebných bajtů by odhad trefil a kolik přečetl zbytečně.
  Řádky: minulý token (experti stejné vrstvy z předchozího tokenu), router L+1 s k, k+2, k+4 a 2k experty
  a sjednocení routeru s minulým tokenem.
- **Simulace › Prefill**: průměrné pokrytí vrstvy, podíl vrstev s pokrytím ≥ 30 % a ≥ 50 % a vybraní
  experti proti celým vrstvám. Nad ~30 % by bylo levnější číst celou vrstvu sekvenčně (≈3,7 GB/s)
  než vybrané experty po stránkách (≈1,1 GB/s).
- `tools/expert_cache_sim.py` umí totéž a čte obě verze záznamu.

Cena: se záznamem se graf při generování zastavuje v každé vrstvě dvakrát (u `ffn_inp` a u
`ffn_moe_topk`), takže rychlost naměřená se zapnutým záznamem není srovnatelná s během bez něj.

Ověřeno v Pythonu na syntetických záznamech v1 i v2 (hodnoty rostou s délkou odhadu podle očekávání).
Swift část je nepřeložená.

---

# MoE: záznam výběru expertů, skutečný zásah cache a simulace

Převzato z [kimi-k3-in-c](https://github.com/FareedKhan-dev/kimi-k3-in-c), sekce 12–13 a „The cache
that was not participating“. Samotná LRU aréna odtamtud se nepřebírá: Kimi násobí experty z vlastní
paměti, tady je llama.cpp násobí přímo z mmapu a roli LRU cache hraje page cache iOS. Přenáší se měření
a analýza:

- **Skutečný zásah cache.** `ExpertPrefetcher` před předčtením zavolá `mincore` nad vlastním mapováním
  souboru a spočítá, kolik vybraných expertů leží v page cache celých. Po prefillu a po generování jde do
  Logu enginu řádek „zásah cache expertů X % (N z M celých v RAM, Y % bajtů)“. Expert, kterému chybí
  jediná stránka, se jako zásah nepočítá, protože i jedna chybějící stránka znamená čekání na flash.
- **Záznam (trace).** Každý výběr routeru (vrstva, velikost dávky, experti, kolik jich bylo v cache)
  jde do `Documents/ExpertTraces/<model>-<čas>.axtr`, jeden soubor na načtený model. Formát je popsaný
  v `ExpertTrace.swift`. Zapisuje se po odpovědi, v callbacku se jen plní buffer.
- **Simulace** (Parametry › Výkon › Simulace cache expertů). Záznam se přehraje pro 0,25–6 GB a politiky
  LRU / LFU / Belady, plus strop povinných výpadků a podíl nejčastějších 10 % expertů. Počítá se
  generování, prefill cache jen zahřívá. Záznam jde sdílet a na počítači přehrát nástrojem
  `tools/expert_cache_sim.py` (bez balíčků) se stejným výpočtem a vlastními velikostmi.
- Přepínač **Zaznamenávat experty** je mimo předvolby. S vypnutým předčítáním callback běží jen kvůli
  záznamu a nic nečte. Změna záznamu při zapnutém předčítání nezahodí kontext ani KV cache.

Ověřeno: politiky Python nástroje odpovídají naivním implementacím LRU/LFU/Belady (300 náhodných
posloupností) a na syntetickém záznamu (48 vrstev × 128 expertů, 8 na token) vychází LRU pod 1 GB
na 0 %, přesně podle cyklického průchodu vrstvami. Swift část je napsaná, ale nepřeložená, takže
první build v Xcode je její kontrola.

---

# FinFill: list Segments – tržby po segmentech, trzích a regionech

Nový list **Segments** (v novém sešitu hned za IncomeStatement, v existujícím se při zápisu
přegeneruje) se sloupci stejnými jako výkazy:

- tři skupiny podle toho, co firma v XBRL vykazuje: **Segmenty** (`StatementBusinessSegmentsAxis`),
  **Trhy / produkty** (`ProductOrServiceAxis`), **Regiony** (`StatementGeographicalAxis`),
- pro každou skupinu: řádky, **Celkem**, **Tržby ve výsledovce** (`=IncomeStatement!…5`),
  **Rozdíl** (eliminace, nezařazené), pak **meziroční změna** a **podíl na tržbách**,
- podskupiny se poznají samy (Compute + Networking = Data Center): odsazené, šedě a nejsou
  v součtu,
- názvy z XBRL členů („nvda:ComputeAndNetworkingSegmentMember“ → „Compute & Networking“),
  země česky.

Segmenty jsou jen v iXBRL jednotlivých 10-K (companyfacts dimenze nemá) a jeden 10-K pokrývá
3 roky – na 9 let se stáhnou i 10-K z doby před 3 a 6 lety. Hodnoty z novějšího podání mají
přednost (přepočtené segmenty). Ze starších 10-K se berou jen segmentové tržby, ostatní čísla
dál z companyfacts.

Ověřeno v LibreOffice na NVDA FY2024–2026: všechny tři skupiny sečtené = tržby ve výsledovce,
rozdíl 0; např. Compute & Networking +66,5 %, Data Center 89,7 % tržeb, Čína −21,4 %.

Přepínač **List Segments** v Možnostech (výchozí zapnuto). Mapování „NVDA (segmenty)“ dál plní
ř. 3/4 původního NVDA sešitu; nový sešit má v ř. 3 celkové tržby a segmenty na listu Segments.

Testy: 21.

---

# FinFill: univerzální šablona a nové sešity

## Nový sešit ze šablony

Tlačítko **Nový sešit ze šablony (9 let)** založí přes Sheets API nový Google sešit (listy
DCF, WACC, IncomeStatement, BalanceSheets, CashFlowStatement se vzorci i formátem) a vyplní
9 fiskálních let končících posledním 10-K (nebo rokem v poli Fiskální rok). Sešit se pak
rovnou vybere pro další práci. Leží v kořeni Disku Google (do složky by bylo potřeba plné
oprávnění k Disku).

- Starší roky se berou z companyfacts, přednost má **naposledy podaný** údaj (přepočty,
  splity akcií – EPS a počty akcií jsou v celé řadě srovnatelné).
- Každý rok má vlastní kontroly a dorovnání; rok s nesedící kontrolou zůstane prázdný.
- Výkaz, který za daný rok v datech není (10-K má 3 výsledovky, ale 2 rozvahy), se nevyplní
  nulami, sloupec zůstane prázdný.
- První sloupec: „hotovost na začátku“ nemá předchozí sloupec, bere se zůstatek z konce
  předchozího roku (`opening` v mapování).

## Univerzální šablona

`Resources/templates/valuation-universal.json` vzniká z NVDA sešitu nástrojem
`tools/finfill-template.py --universal`:

- výkazy: 9 sloupců G–O, typovaná čísla pryč (i vzorce jako `=(1112+6081+4500)-M12`),
  součty a poměry zůstávají, hlavička `G2 = první rok`, dál `=G2+1`,
- ř. 3 „Revenue“ (celkové tržby), ř. 4 „Other revenue“ – univerzální mapování nepočítá
  se segmenty,
- **DCF se posouvá sám:** roky `=MAX(IncomeStatement!$G$2:$Z$2)-4`, historie přes
  `INDEX/MATCH` podle roku. Po přidání sloupce dalšího roku (vytvoření sloupce z minula)
  se DCF posune o rok bez úprav,
- předpoklady z historie firmy místo čísel NVIDIE: růst `=MIN(MEDIAN(4 roky), poslední)`,
  EBIT marže začíná poslední skutečnou a končí průměrem, D&A / CapEx / ΔNWC jako průměr
  % z tržeb, WACC scénáře = `WACC!D22 ± 0,5 %`, beta a cena z `GOOGLEFINANCE`,
  daň = poslední efektivní sazba, přepínače scénářů na základní (2),
- zástupné hodnoty `{{TICKER}}`, `{{FY_FIRST}}`, `{{TODAY}}`, `{{FYEND}}`.

Ověřeno v LibreOffice na plně vyplněném sešitu (2018–2023 z původní tabulky, 2024–2026
z FinFillu): žádná chybová buňka, aktiva = pasiva, konečná hotovost v CF = rozvaha,
DCF 2022–2026 → projekce 2027–2031.

Vlastní šablonu jde udělat stejně: upravit sešit v Google Sheets, stáhnout jako .xlsx
a pustit nástroj (bez `--universal` se převezme tak, jak je).

## Ostatní

- Volba **Mapování**: Univerzální (výchozí) / NVDA (segmenty) pro původní sešit.
- Nový stav kontroly „chybí data“: dorovnání se nepoužije, když chybí jiný než dorovnávací
  řádek (FY2024 v NVDA 10-K: VK z výkazu změn VK by jinak skončil celý v „ostatním“).
- Vytvoření sloupce roku maže i vzorce s ručně zadanými čísly.
- CLI: `finfill new --ticker AMD --ua … --token …`, offline `local --universal --all-years`.

Testy: 18.

---

# FinFill: výběr sešitu, nový sloupec roku, jiné firmy než NVIDIA

## Výběr sešitu z Disku Google

Místo kopírování URL tlačítko **Sešit** otevře seznam Google Sheets (Drive API, řazeno podle
poslední změny, hledání podle názvu). Ruční URL/ID zůstává pod „Zadat URL nebo ID ručně“.
Nové oprávnění `drive.metadata.readonly` – jen názvy souborů, ne obsah. Stávající přihlášení
ho nemá, aplikace si o nové přihlášení řekne sama (Nastavení › Google účet ukazuje „Chybí
oprávnění“). V Google Cloud Console je potřeba zapnout **Google Drive API** a přidat scope.
Soubor .xlsx nahraný na Disk v seznamu není – Sheets API upravuje jen nativní Google Sheets.

## Chybějící sloupec roku se vytvoří

Dřív: „no column with year 2023 in the header row“. Teď, když v listu chybí jen následující
rok, se při zápisu:

1. vloží sloupec hned za předchozí rok (`insertDimension`, převezme šířku),
2. zkopíruje do něj předchozí sloupec **se vzorci i formátem** (`copyPaste PASTE_NORMAL` –
   relativní odkazy se posunou: `=K3+K4` → `=L3+L4`, `=J2+1` → `=K2+1`),
3. vymažou se ručně zadaná čísla minulého roku (hodnoty a vzorce bez odkazů jako
   `=6283+1793`) a všechny mapované řádky, rok v hlavičce se zapíše, pokud tam nebyl vzorec,
4. zapíšou se nová data.

Náhled nic nemění, jen ukáže „Nové sloupce“. Mezera (poslední 2020, chceš 2023) se odmítne
s návodem doplnit nejdřív 2021 a 2022. Vložení sloupce posune odkazy vpravo od něj, ale
nerozšíří rozsahy typu `SUM(G5:K5)` v jiných listech – ty je potřeba upravit ručně.

## Jiné firmy (AMD)

Mapování bylo psané pro NVIDII – segmenty hledalo pod `nvda:GraphicsSegmentMember`, tržby
vyšly 0 a všechny kontroly padly. Teď:

- **Dorovnání:** každá kontrola má řádek „ostatní“ (`plugRow`), kam se rozdíl oproti vykázanému
  součtu zapíše: neznámé segmenty → celé tržby do ř. 3, položky navíc ve výsledovce (AMD:
  amortizace, restrukturalizace, licenční zisk) → ř. 10, rozvaha → ostatní aktiva/závazky,
  CF → ostatní. Kontroly jdou postupně, další vidí už dorovnané hodnoty. Dorovnání je vidět
  oranžově u kontroly i u buňky a ve vzorci jako další sčítanec. NVIDIA žádné nepotřebuje.
- **Alternativní koncepty** součtů (`RevenueFromContractWithCustomerExcludingAssessedTax`,
  `ProfitLoss`, `…IncludingPortionAttributableToNoncontrollingInterest`, …).
- Součet, který firma netaguje, je „netagováno“ (šedě) a zápis neblokuje.

## Drobnosti

- Po chybě už nezůstává výsledek předchozího běhu; změna tickeru, roku nebo sešitu náhled zruší.
- Rok v nadpisu kontrol bez oddělovače tisíců („FY2 022“ → „FY2022“).
- Klávesnice s číslicemi má „Hotovo“ a schová se posunutím.

Testy: 15 (nové: dorovnání neznámých segmentů a chybějícího řádku, netagovaný součet,
vytvoření sloupce a výběr řádků k vymazání, odkazy ve vzorcích, plán pro nový sloupec,
seznam z Drive API).

---

# 10-K → Google Sheets (FinFill)

Nový lokální balíček **`Packages/FinFill`** (vedle `LlamaCpp`, target používá `FinFillCore`
a `FinFillUI`) a v Nastavení nová sekce **Nástroje**.

## Co dělá

Pro ticker stáhne ze SEC poslední 10-K a companyfacts JSON, doplní čísla do existujícího
Google Sheets sešitu (šablona „NVDA Valuation – 5y“, listy IncomeStatement / BalanceSheets /
CashFlowStatement, sloupec podle roku v řádku 2) a modelem vybraným v Nastavení udělá souhrn.

- **Čísla nepočítá model.** Mapování buňka ← XBRL koncepty je JSON
  (`Resources/nvda-valuation-5y.json`). Segmenty (Graphics / Compute & Networking) jsou
  dimenzionální fakta – companyfacts je nemá, berou se z iXBRL samotného 10-K.
- Víc položek v jedné buňce se zapíše jako vzorec ve stylu šablony (`=10383+2867`,
  `=21352-O21`, `={prev}30`), aby byl vidět původ.
- **14 kontrol součtů** proti tomu, co firma vykazuje (tržby, hrubý zisk, EBIT, EBT, čistý
  zisk, aktiva, závazky, VK, L+E, CFO, CFI, CFF). Když některá nesedí, zápis je zablokovaný.
- Přepisují se jen prázdné buňky a nuly (přepínač „Přepsat neprázdné buňky“).
- Backtest: mapování se spustí i na minulý rok a porovná se sloupcem, který už v sešitu je.
- Souhrn: Item 1, 1A, 7, 7A → kusy podle kontextu → body → souhrn sekcí → shrnutí pro
  valuaci. Čísla do něj dostane model jako hotovou tabulku z XBRL a smí citovat jen ji.
  Výsledek se zapíše na list `Summary FY<rok>`.

NVDA FY2026: všech 14 kontrol sedí na milion, backtest FY2025 proti ručně vyplněnému
sloupci N sedí ve výsledovce i cash flow; v rozvaze se liší jen rozdělení položek
(dlouhodobé investice, leasing, kmenové akcie), součty stejné. V CF je nová položka Groq, Inc.
(13 000) – jde do Cash Acquisitions.

## Aplikace

- `Services/FinFillEngine.swift` – `LLMEngine` nad `makeProvider(profile: .summarize,
  reasoningOverride: false, maxTokensOverride:)` a `oneShot()`, stejně jako `SummaryPipeline`.
  Kontext `min(délka kontextu, effectiveContext ?? 8k, summaryChunkTokens)`.
- `Services/GoogleAuth.swift` – OAuth 2 + PKCE přes `ASWebAuthenticationSession`, bez Google
  SDK a bez URL scheme v Info.plist. Refresh token v Klíčence (`KeychainAccount.googleRefresh`),
  access token jen v paměti.
- `Views/FinFillScreen.swift` – obrazovka „10-K → Google Sheets“ (náhled → zápis → souhrn)
  a „Google účet“ (client ID, přihlášení, návod ke Google Cloud Console).

## Testy

`cd Packages/FinFill && swift test` – 8 testů nad přiloženým NVDA 10-K (fixture 2 MB).
CLI pro Mac: `swift run finfill local --html <10-K>` vypíše buňky a kontroly bez sítě.

## Známá omezení

- `FinFillCore` (SEC, iXBRL, mapování, Sheets, souhrn) je přeložený a otestovaný mimo Xcode;
  SwiftUI obrazovky a `GoogleAuth` jen syntakticky – první build v Xcode je ověří.
- Mapování je pro šablonu NVDA; jiná firma = upravit segmentové řádky (`dims`) a koncepty
  s prefixem firmy (`nvda:…`). Kontroly ukážou, co chybí.
- Vedle `Services/InlineXBRL.swift` (výběr faktů pro chat) je to druhý parser iXBRL –
  FinFill je samostatný modul, aby šel testovat bez aplikace.

---

# Kód v odpovědi ve vlastním okně

`Views/MessageContentView.swift` (nový): odpověď se dělí na bloky. Blok ```jazyk … ```
se ukáže v okně s názvem jazyka („HTML“, „JavaScript“, bez jazyka „Plain text“),
tlačítkem Kopírovat (po zkopírování na chvíli fajfka + haptika) a neproporcionálním
písmem bez zalamování – dlouhé řádky se posouvají do strany. Kód nad 40 řádků se sbalí
na 20 s tlačítkem „Zobrazit celý kód“; rozepsaný blok (během generování) je vidět celý.
Nadpisy `#`–`######` a oddělovače `---` se vykreslí jako nadpis a čára místo syrových
značek. Podržením odpovědi jde dál zkopírovat celý text.

Vedle kopírování je tlačítko **Uložit** (`ShareLink` + `CodeFile: Transferable`): kód se
až po klepnutí zapíše do dočasného souboru a otevře se nabídka sdílení – Uložit do
Souborů, AirDrop, jiná appka. Název souboru se vezme z textu před blokem („ulož jako
`snake.html`“) nebo z prvního řádku kódu, jinak `kod.<přípona podle jazyka>`
(`kod-2.js` u dalšího bloku stejného typu). Během generování je tlačítko neaktivní.

---

# Výběr llama.cpp v buildu IPA + předvolby podle typu modelu

## Workflow

- **`build.yml`** se spouští jen ručně a tagem `v*` – push na `main` a pull requesty
  build nespouští. Nová volba **llama**: *automaticky*, *originální b10894*,
  *b10894 · GGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm · GGML_BLAS=ON / OFF*.
  Zkompilovaná varianta se bere z Release `llama-cpu-opt-blas-on|off` (starší
  `llama-cpu-opt` se použije, když sedí BLAS). Když vybraná neexistuje, build skončí
  hned po checkoutu, ne po půlhodině. Jiná verze v Release než v popisku = varování.
- **`llama-xcframework.yml`** nahrává každou variantu BLAS do vlastního Release, takže
  ON i OFF můžou existovat vedle sebe; volba *obojí* je přeloží paralelně.
- **`make-ipa.sh`** zapisuje variantu do `Info.plist` (`LlamaBuild`), appka ji ukáže
  v Nastavení pod verzí.

## Parametry podle typu modelu

`SettingsStore` drží tři sady `LocalModelSettings` – **GGUF MoE**, **GGUF**, **MLX**.
`settings.local` čte a zapisuje sadu vybraného modelu, takže zbytek kódu se nezměnil.
Typ se u GGUF pozná z hlavičky souboru (`GGUFLayout.isMoE`), výsledek se cachuje.
Společné zůstává: systémový prompt, instrukce a osnovy režimů, přemýšlení v režimech,
práce s přílohami, strop paměti, seed.

Předvolby: MoE – 3 vlákna na generování (víc na extrakci a shrnutí), kontext 8k,
experti z úložiště, předčítání, dávka 2048. GGUF – vlákna podle CPU, kontext 4k, vše
na GPU. MLX – kontext 4k, prefill 1024, KV f16.

Parametry zobrazují jen to, co na model působí: MLX nevidí Výkon ani vlákna,
hustý GGUF nevidí experty, KV cache pro CPU ani měření úložiště. Nahoře je typ modelu,
stav „předvolba / upraveno“ a tlačítko na návrat k předvolbě.

Přechod: stávající nastavení dostane celé GGUF MoE (výchozí hodnoty byly laděné na něj),
GGUF a MLX začnou od předvolby se společnými věcmi a vzorkováním převzatým.

---

# Stop sekvence + agentní smyčka

Dvě nové věci nad rámec XBRL práce. První dává smysl sáma o sobě, druhá na ní stojí.

## `Providers/StoppingProvider.swift` (nový) + `ChatProvider`

`ChatProvider` má nový požadavek `stopping(at:)`. Výchozí implementace obalí
poskytovatele `StoppingProvider`em, který čte stream, uříšne text na první značce
a stream ukončí — tím se zruší úloha pod ním a engine generování opravdu přestane
(oba lokální enginy mají ve smyčce `Task.isCancelled`). Funguje to tedy i pro Claude
a Gemini, bez zásahu do nich.

Text se poslá dál se zpožděním o délku nejdelší značky minus jedna — značka může přijít
rozdělená mezi dva tokeny a bez toho by se `>` mihlo uživateli na obrazovce.

`MLXProvider` si `stopping(at:)` přebijí vlastní: značky se předávají až do
`MLXEngine.generate` a kontrolují se přímo v generační smyčce, takže se nečeká ani na
zrušení streamu. Přerušená generace navíc zahodí sezení (`dropSession`) — KV cache
i `sessionTurns` by jinak seděly na odpověď, která nikdy nedoběhla.

U llama.cpp jsem nativní cestu **nešel dělat**: patří do `LlamaEngine` a správně by to
měla být GBNF gramatika, ne porovnávání řetězců. Zatím ho pokrývá obecný wrapper.

## `Services/AgentPipeline.swift` (nový)

Pět nástrojů, každý obal nad tím, co už `RetrievalPipeline` volá:

| Volání | Co je pod tím |
|---|---|
| `CISLA <dotaz> >>` | `InlineXBRL.excerpt` |
| `VYKAZ <název> >>` | statement větev v `excerpt` (8 000 znaků) |
| `HLEDEJ <slova> >>` | `DocumentIndex.search` |
| `KAPITOLA <číslo> >>` | `search(_:inSection:)` podle osnovy |
| `ODPOVED >>` | konec smyčky |

**První krok zůstává deterministický.** Fakta i úryvky k původnímu dotazu jsou v promptu
hned, bez jediného volání modelu — to je proti agentovi výhoda, ne nevýhoda, protože
na stejný výsledek by potřeboval dva průchody navíc. Agent je úniková cesta, když to
nestačí.

Strop je pět kroků a 6 000 znaků na výsledky nástrojů; starší kroky vypadnou odpředu.
Poslední krok je bez nástrojů — model už jen píše odpověď.

Hranice volání je skutečná: `>>` je stop značka, takže model za ní nic nedopíše.
Parser je ale pojíštění na to, že ji 4B model zapomene — bere i konec řádku.
Zadržování textu (`couldBeCall`) zůstává: značka zastaví generování, ale samotné slovo
`CISLA` by se na obrazovce mihlo dřív.

## Zapnutí

`AppSettings.local.agentTools`, výchozí **vypnuto**. V `ChatViewModel` se řadí mezi
`SummaryPipeline` a `RetrievalPipeline`. Vypnutý agent = dnešní chování beze změny.

V `LocalModelSettingsView` je přepínač **„Hledat si nechat řídit modelem“**, ve stejné
sekci jako „Stručné odpovědi nad přílohou“, s popiskem o ceně (každý krok je nový prompt).

Poznámka: `sectionRouting` přepínač v UI nemá žádný — není to nová věc, jen si toho všimni,
když budeš tu obrazovku procházet.

## Nezkompilováno

V prostředí není Swift toolchain. U téhle dávky to váží víc než u předchozích: sáhl jsem
do `ChatProvider` protokolu, takže kdyby některý poskytovatel `stopping(at:)` nedostal
z extensionu (např. proto, že je v jiném modulu), build spadne až tam.

# Otagovaná čísla z inline XBRL + oprava dělení na kusy

Pět souborů: jeden nový, čtyři upravené. Nahraj je do `AIChat/Services/` a `AIChat/Models/`
přes stávající. `project.pbxproj` se needituje — projekt používá
`PBXFileSystemSynchronizedRootGroup`, takže nový `.swift` stačí zkopírovat do složky.

## Nové: `Services/InlineXBRL.swift`

Parser inline XBRL a výběr faktů k dotazu.

- `factTable(from:fileName:)` → tabulka faktů, nebo `nil`, když soubor iXBRL není.
  Formát: pár řádků hlavičky, `---`, pak `ukazatel | období | rozpad | hodnota`.
- `excerpt(from:matching:...)` → řádky k dotazu i s hlavičkou (kvůli mapování FY na data).
- `factCount(in:)` → jen na odznak v UI.

Parsuje se `ix:nonFraction` (čísla) a pět `dei:` údajů z hlavičky. Textové bloky
(`ix:nonNumeric`) se ignorují — to jsou celé kapitoly zprávy a ty patří hledání v textu.

Skenuje se přes `range(of:)`, ne regexem: na 2 MB dokumentu je to předvídatelné a hledá se
vždycky od místa, kde skončilo minulé kolo. Předpona jmenného prostoru se u filerů liší,
takže se hledá `context id="` a `context>` — v otevírací značce se `context>` nevyskytuje.

**Fiskální rok** se počítá od `dei:DocumentFiscalYearFocus` zpátky po rocích, ne z kalendáře.
NVIDII končí FY2026 25. ledna 2026; podle kalendáře by srovnávací rok končící 26. ledna 2025
vyšel jako 2024, ne 2025.

**Výběr k dotazu běží na dvě kola.** Nejdřív se vyberou ukazatele podle toho, jakou část názvu
dotaz pokryl — bez toho vyhrává `Revenue Remaining Performance Obligation` nad `Revenues`,
protože obojí obsahuje hledané slovo jednou. Pak se k vybraným ukazatelům doberou řádky
s přednostmi: žádaný rok, shoda rozpadu („tržby v Číně"), celkové hodnoty před rozpady,
novější roky dřív.

Je tam i malý česko-anglický slovník (`synonyms`) — bez něj „tržby" nepotká `Revenues`.
Je to seznam hlavních řádků výkazů, ne slovník; doplň si, co budeš potřebovat.

## `Models/Attachment.swift`

Nová vlastnost `facts: String?`. Optional s výchozím `nil`, takže staré zprávy se z SwiftData
dekódují beze změny a stávající volání memberwise initu platí dál.
V `detail` přibyl odznak `XBRL <počet>`.

## `Services/AttachmentLoader.swift`

Ve větvi pro `.htm`/`.html` se z originálu nejdřív vytáhnou fakta, teprve pak se přes
`HTMLText.extract` zahodí značky — v čistém textu už se to poznat nedá.

## `Services/RetrievalPipeline.swift`

- `tagged` = tabulky faktů z příloh konverzace.
- `needsDocument` je nově true i tehdy, když je podklad otagovaný a do kontextu by se vešel.
- Fakta dostanou `max(800, min(3 500, remaining / 3))` znaků, zbytek zůstává úryvkům.
- **Fakta se vybírají první**, ještě před textovou větví. Je to čisté porovnávání řetězců
  bez volání modelu, takže je zadarmo spočítat je hned — a jejich výsledek rozhoduje,
  jak moc se má hledat v textu.
- Když se trefila (`lean`), textová větev se zeštíhlí: přeskočí se výběr kapitoly
  (`QueryExpansion.section`) i překlad dotazu (`QueryExpansion.keywords`) — obojí je celý
  průchod modelem — úryvky se stáhnou na tři a třetinu rozpočtu a vypne se náhradní
  „beru začátek dokumentu". Text tak zůstává jen jako pozadí pro souvislosti.
- Když se netrefila, chování je beze změny.
- Předčasný odchod na `base.stream` při nulovém překryvu dotazu s dokumentem se použije
  jen tehdy, když fakta nic nemají — jinak by se zahodila i tabulka.
- Hlášení jsou přerovnaná: nejdřív věta o otagovaných číslech, pak o textu, a ta o tom,
  že se podklad nevejde do kontextu, se objeví jen když textová větev jede naplno.
- V promptu jdou fakta **před** úryvky, s pravidlem, že při rozporu s textem platí ona
  a že zdrojem je přiložený soubor — bez toho si model k číslu vymyslel odkaz na
  `docs.nvidia.com`, který v podkladech nikde není.

## `Services/DocumentSections.swift`

`chunks(of:maxCharacters:)` nově předřadí dalšímu kusu poslední řádek, který vypadá jako
nadpis (`carryingCaptions`).

Tohle je příčina té konkrétní chyby z fotky. Hranice kusu padla přesně za řádek
`Operating Income by Reportable Segments` a další kus začal `Year Ended / Jan 25, 2026 …
Total $ 139,297`. V takovém úryvku není nic, z čeho by model poznal, že čte provozní zisky,
a hned pod tabulkou pokračuje věta o tržbách. Model to přečetl tak, jak to dostal.

## Ověřeno na `nvda-20260125.htm`

Algoritmus jsem si přepsal do Pythonu a pustil na tvém souboru:

- 281 kontextů, 1 102 číselných faktů, po odstranění duplicit 970 řádků tabulky
- `Revenues | FY2026 | 215 938 mil. USD`, `Operating Segments / Compute And Networking
  Segment | 193 479`, geografie i koncové trhy
- „Vyhledej revenue pro rok 2026" → první tři řádky výběru jsou celkové tržby FY2026
  a jejich rozpady; dřív byl na 9. místě a ořez na 8 úryvcích ho odřízl
- „tržby v Číně", „hrubá marže", „výzkum a vývoj", „čistý zisk 2026" trefují správný ukazatel
- Sticky caption: kus s tabulkou provozních zisků teď začíná svým popiskem

**Swift jsem nezkompiloval** — v prostředí není toolchain. Ověřená je logika, ne syntax.

## Stručný režim

Ve `concise` režimu se výběr faktů zkrátí na 12 řádků a 1 200 znaků. Se čtyřiceti řádky
v promptu malý model celou tabulku přepsal do odpovědi jako markdown — na dotaz, který
chtěl jedno číslo. K tomu tři pravidla navíc: výpis je podklad a ne odpověď, rozpad jen
na vyžádání, stručná odpověď bez nadpisů a tabulek.

V hlavičce výpisu je navíc věta, že se rozpady překrývají a nesčítají. Jeden ukazatel je
rozepsaný po segmentech, po regionech i po koncových trzích zvlášť, takže `Data Center`
už v sobě obsahuje `Compute` i `Networking`. XBRL vztah nadřazenosti mezi členy nenese,
z řádků se to poznat nedá.

## Navazující dotaz

Hledalo se jen podle poslední zprávy. „Celou tabulku se všema daty prosím“ neobsahuje
jediný pojem z dokumentu, takže fakta nenašla nic, vybrala se náhodná kapitola
(`Item 6 – [Reserved]`), spustil se překlad dotazu do jazyka dokumentu a model dostal
úryvky z `Item 1 – Business`.

`followUp(to:in:)` přilepí předchozí dotaz uživatele — ale **jen když hledání podle
samotné zprávy nic nenašlo**, jinak by přilepený text přebil dotaz, který je v pořádku.
Zkouší se to na dvou místech: u faktů, když je výběr prázdný, a u textu, když
`index.overlap` vyjde nula — tam ještě před tím, než se dotaz prohlásí za netýkající se
přílohy.

Ověřeno: `"Celou tabulku se všema daty prosím"` sám → nic; doplněný o
`"Muzes mi vypsat income statement tabulku"` → Consolidated Statements of Income.

## Vypsat celý výkaz

Když dotaz žádá výkaz a výběr ho našel, přibude do pravidel věta, že má model přepsat
**všechny** řádky výpisu jako tabulku, ve stejném pořadí, s původními názvy a jednotkami,
nic nevynechávat, nepřepočítávat a nekomentovat. Bez toho vypsal tři řádky `Revenues`
a zbytek okomentoval úvahou o tom, jestli má psát „mil.“.

## Výkazy jako celek

Dotaz „vypiš mi rozvahu“ nechce jeden ukazatel, ale celou tabulku. Výběr po ukazatelích
na to odpovídál nesmysly: na „balance sheet“ vrátil `Valuation Allowances And Reserves
Balance`, protože má v názvu slovo Balance, a na „Consolidated Statements of Income“
vrátil `Income Tax Reconciliation State And Local Income Taxes`.

Fakt si přitom nenese, do kterého výkazu patří — ta informace je v presentation linkbase,
což je jiný soubor, který u přílohy není. Dá se ale zjistit z **pozice v dokumentu**: mezi
nadpisem `Consolidated Balance Sheets` a nadpisem dalšího výkazu leží přesně fakta té rozvahy.

`statementRanges` najde pět kanonických nadpisů. Každý je v souboru víckrát (obsah, vlastní
výkaz, pak odkazy uvnitř příloh typu „recorded in our Consolidated Balance Sheets“), takže
se bere první výskyt, za kterým následuje aspoň 15 čísel, a každý nadpis se použije jen
jednou. Poslední výkaz končí tam, kde začínají otagované přílohy — jinak by pobral i účetní
postupy.

Tabulka faktů je teď rozdělená řádky `## Název výkazu`; uvnitř výkazu zůstávají řádky
v pořadí, v jakém je dokument tiskne, jinde abecedně.

`InlineXBRL.statementRequest(in:)` pozná takový dotaz. Pro něj se výběr nezkracuje
(8 000 znaků, 160 řádků místo 1 200 a 12) a odpadnou pravidla stručnosti — odpovědí má být
tabulka, ne jedna věta.

Pozor na jednotné a množné číslo: „sheet“ má pět znaků, „sheets“ šest, takže se ořezáváním
na šest znaků rozejdou. Proto jsou v `statementSynonyms` i `sheet` a `flow`.

### Měřeno na `nvda-20260125.htm`

Pět výkazů: Income 54 řádků, Comprehensive Income 12, Balance Sheets 72, Shareholders
Equity 75, Cash Flows 103. Zbytek (654 řádků) je pod `## Ostatní údaje`. Výkaz zisku a
ztráty začíná `Revenues | FY2026 | 215 938`, `FY2025 | 130 497`, `FY2024 | 60 922` a pokračuje
přes Cost Of Revenue, Gross Profit až k Net Income Loss.

## Pořadí v promptu: fakta až za úryvky

Původně šel výpis faktů před úryvky. Na 4B modelu to nefungovalo: úryvky jsou v štíhlém
režimu až 4 500 znaků, fakta 1 200, a to, co je blíž k dotazu, vyhrává. Model pak vyčetl
číslo z tabulky v textu a k řádku `Revenues | FY2026 | 215 938 mil. USD`, který měl přímo
v promptu, napsal, že čísla za 2026 nejsou k dispozici.

Výpis je teď poslední blok před dotazem a pravidlo k němu říká výslovně, že je pro číselné
údaje závazný a že když je údaj v něm, nemá model psát, že v podkladech není.

## Kapitoly z otagovaných textových bloků

`InlineXBRL.marking(_:)` vloží před každý otagovaný textový blok značku `§§ Název`,
`DocumentSections.taggedHeadings` ji přijme jako hranici kapitoly vedle hlaviček `Item N`.

Přílohy účetní závěrky jsou v iXBRL obalené blokem `…TextBlock`, jehož jméno je rovnou název
poznámky (`IncomeTaxDisclosureTextBlock`, `SegmentReportingDisclosureTextBlock`). Vlastní
nadpisy poznámek ale žádné číslo položky nenesou, takže je regulár na `Item N` nevidí a celá
tahle část 10-K spadla pod jedinou hlavičku — proto byly na screenshotech všechny úryvky
označené jako `Item 15 – Exhibits and Financial Statement Schedules`.

Dvě věci, které to komplikují a jsou v kódu ošetřené:

- **Bloky jsou vnořené.** V `SignificantAccountingPolicies` sedí jednotlivé `…PolicyTextBlock`,
  v poznámce k dani jednotlivé tabulky. Bere se jen nejvyšší úroveň: zametákem zleva doprava,
  co začíná uvnitř už přijatého bloku, se zahodí.
- **Dlouhé bloky jsou rozsekané na `ix:continuation`.** `IncomeTaxDisclosureTextBlock` má sám
  o sobě 151 bajtů a zbytek poznámky leží jinde. Skutečný konec se dopočítá podle řetězu
  `continuedAt` — bez toho vyjde 69 falešných kapitol místo 22.

Značka se vkládá jako `</p><p>§§ Název</p>`. Ta uzavírací na začátku je schválně: `HTMLText`
dělá nový řádek jen z uzavíracích značek, a bez ní se marker uvnitř tabulky přilepí na konec
předchozího řádku. Ze 22 kapitol jich tak na začátku řádku skončilo 5.

Osnova v `QueryExpansion.section` má strop zvednutý ze 40 na 60 položek — jinak by se uřízly
zrovna ty nové kapitoly, které jsou v seznamu poslední.

### Měřeno na `nvda-20260125.htm`

Kapitol 28 → 45, `Item 15` 98 932 → 18 223 znaků. Nově se samostatně jmenují mimo jiné
Significant Accounting Policies, Commitments And Contingencies, Income Tax, Segment Reporting,
Lessee Operating Leases, Valuation And Qualifying Accounts.

**Čeho se to netýká:** otagované jsou přílohy účetní závěrky, kybernetická bezpečnost a pár
položek obálky. `Item 1A – Risk Factors` (115 tisíc znaků) a `Item 7 – MD&A` (34 tisíc) tagy
nemají a zůstávají jednou kapitolou jako dřív. Na ty by bylo potřeba hledat nadpisy uvnitř
kapitoly, což s XBRL nesouvisí.

## `Services/QueryExpansion.swift` + logování

`RetrievalPipeline`, `QueryExpansion` i `InlineXBRL` psaly přes holý
`Logger(subsystem:category:"retrieval")` s úrovní `.info`. To jde jen do os_log, takže se to
v appce nikdy neukázalo a u sideloadovaného buildu se to nepřečte ani v Konzoli. Všechny tři
teď používají `EngineLog(category: "retrieval")`, takže řádky přistanou v `AppLogView`
vedle `[mlx]`.

Co se loguje jako `notice` (jde do logu v appce):

```
rozpočet 74800 znaků · podklady 360924 znaků · fakta 1200 znaků · zbývá 73000 znaků · otagovaných podkladů 1
XBRL: 1102 faktů, 970 řádků, 281 období
vybraná kapitola 10/23: Item 7 – Management's Discussion and Analysis…
kolo 1 · prompt 9312 znaků · 3 úryvků (zeštíhleno) · fakta ano 1187 znaků · historie 0 znaků
```

Text dotazu a název souboru jdou přes `log.debug`, který podle vlastní poznámky v `EngineLog`
do souboru v appce nepíše — obsah promptu tam nepatří.

Jedno rozhodnutí, které si přepiš, pokud s ním nesouhlasíš: název vybrané kapitoly jsem nechal
v `notice`. Je to struktura dokumentu, ne obsah dotazu, a uživatel ho stejně vidí v hlášení nad
odpovědí. Kdyby ti vadil v souboru v Caches, přesuň ho do `debug` a nech tam jen `10/23`.

## Na co si dát pozor

- **Jen čísla.** Rizikové faktory, komentář v MD&A, smlouvy — tam pořád jede `DocumentIndex`.
- **Jen americké emitenty s iXBRL.** Starší zprávy a evropské firmy tuhle větev minou.
- `format="ixt:num-comma-decimal"` je ošetřený, ale netestovaný — nemám na čem.
- Parsování 2 MB souboru na telefonu chvíli trvá. Běží v `Task.detached` uvnitř
  `AttachmentLoader`, takže UI to nezdrží, ale příloha se objeví o něco později.
- Hlavička výpisu se opakuje u každého souboru. Při víc otagovaných přílohách najednou
  to ukrojí pár set znaků navíc.

## Další krok

Tímhle je připravená polovina nástrojů pro tu agentní smyčku: `excerpt` je v podstatě
hotový `fakt(dotaz)` a vrací pár krátkých řádků místo tisíců znaků úryvků. Zbývá
`AgentPipeline` a stop sekvence v `LlamaProvider`/`MLXProvider` — bez nich model po
volání nástroje mluví dál a ty čekáš.
