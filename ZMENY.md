# FinFill: Citlivost, Comps, Kvartály a kontrola DCF

Podle skillů dcf-model, comps-analysis a earnings-analysis z `anthropics/financial-services`, ale
počítané kódem z SEC a zapsané jako vzorce. V obrazovce 10-K → Sheets nová sekce **Analýzy** a tlačítko
**Jen analýzy do sešitu**; listy vzniknou při zápisu, v novém sešitu i samostatně.

- **Citlivost** (za WACC): cena na akcii pro WACC × TGR kolem předpokladů vybraného scénáře, potenciál vůči
  aktuální ceně a **Kontrola modelu** živými vzorci (TGR < WACC, podíl TV na EV, pásmo WACC, exit
  EV/EBITDA, FCF v posledním roce, marže a růst vs. historie). Střed tabulky = DCF!M58.
- **Kontrola DCF v appce**: po zápisu se DCF přečte a ukáže ✓ / ℹ︎ / ⚠︎ / ✗ se stejnými hranicemi.
  Když GOOGLEFINANCE v novém sešitu ještě načítá, čte se znovu (až 3×).
- **Comps**: peery tickerem (pamatují se pro každý ticker). LTM ze součtu 4 kvartálů, EBITDA, čistý dluh,
  počet akcií ze SEC; cena GOOGLEFINANCE, EV, marže, EV/Tržby, EV/EBITDA, P/E, FCF výnos jako vzorce;
  statistiky jen z peerů a implikovaná cena z kvartilů vs. aktuální cena a DCF.
- **Kvartály**: 8 posledních kvartálů z companyfacts (výsledovka přímo nebo z YTD, cash flow z YTD,
  Q4 = rok − 9 měsíců, dopočtené kurzívou), marže, YoY a QoQ. Earnings review posledního 10-Q modelem
  (MD&A → šablona: v kostce, výsledky, co táhlo, výhled, co upravit v modelu, rizika). Bez konsenzu analytiků.
- Stahování: submissions i companyfacts se stahují jednou pro 10-K i 10-Q; do mapování výkazů jdou
  dál jen roční údaje.
- CLI: `finfill analyze` (analýzy do sešitu) a `finfill quarters` (offline kvartály + LTM z companyfacts).
- **Příkazy v chatu**: zpráva `finfill new AMD` (i `/finfill`, velikost písmen nevadí) se neposílá modelu, ale
  spustí FinFill – průběh jde do stavového řádku, odpověď je odkaz na sešit, kontrola DCF, Comps, kvartál
  a souhrn. Dál `finfill analyze NVDA`, `finfill run NVDA` (náhled) / `finfill run NVDA zapsat`,
  `peers AMD,INTC` a `fy2025` kdekoli v příkazu. Nastavení bere z obrazovky 10-K → Sheets (User-Agent,
  vybraný sešit, přepínače, peery) a přihlášení ke Google; nový sešit se tam rovnou vybere.
- CLI s nastavením: stačí `finfill new AMD` / `finfill run NVDA --write` / `finfill analyze NVDA`. User-Agent,
  token (nebo `token_command`), sešit, model, jazyk, kvartály a peery pro každý ticker se ukládají přes
  `finfill config` do `~/.config/finfill/config.json`; přepínače mají přednost.
- Testy: 11 nových (syntetická firma s 10-K a 10-Q), celkem 43.

---

# Segments: jeden řádek na segment

- Firmy identifikátor segmentu mezi lety přejmenují (NVIDIA `ComputeAndNetworkingMember` →
  `ComputeAndNetworkingSegmentMember`), takže list Segments měl „Compute & Networking“ a „Graphics“
  dvakrát (novější a starší roky zvlášť) a meziroční změna na rozhraní chyběla. Řádky se teď
  slučují podle názvu.

---

# Šablona souhrnu 10-K

- Souhrn má pevnou šablonu (`SummaryBrief`): **Teze** (1–2 věty) · **Klíčová čísla** (tabulka
  z XBRL) · **Co se změnilo** (max 4) · **Tahouni byznysu** (3) · **Hlavní rizika** (3) ·
  **Kapitál a akcionáři** (3) · **Výhled vedení** (2) · **Pro valuaci (DCF)** (3). Body max ~20 slov,
  oddíl bez informací = „—“. Model vyplňuje značky (`THESIS:` …); když šablonu nedodrží, jednou
  se zeptá znovu, jinak se ukáže text, jak je.
- List **Souhrn**: tabulka jen s podstatnými čísly (tržby, marže, čistý zisk, EPS, FCF, hotovost,
  dluh, segmenty), změna u částek v %, u marží v p.b., růst zeleně / pokles červeně. Souhrny
  jednotlivých kapitol 10-K jsou dole jako sbalená skupina řádků „Podklady“.

---

# 10-K → Sheets: nejnovější rok vlevo, list Souhrn na začátku

- **Nový sešit ze šablony:** výkazy (Income statement, Balance sheet, Cash flow) i list Segments
  mají aktuální rok v prvním sloupci (G) a starší roky doprava. Šablona se při vytvoření zrcadlí
  (`SpreadsheetTemplate.newestFirst()`): buňky, šířky a vzorce – „tento rok − předchozí“ míří
  na sloupec vpravo, počáteční hotovost bere konec roku vpravo. DCF/WACC hledají rok přes
  `INDEX/MATCH`, jejich rozsahy začínají o sloupec dřív (`$F:$Z`), aby nový rok vložený do G
  byl uvnitř rozsahu. Přepínač **Nový sešit: nejnovější rok vlevo** (výchozí zapnuto).
- **Existující sešit:** pořadí se pozná z hlavičky. Ve starém pořadí se nový rok přidá vpravo
  jako dřív; v novém se vloží do G (kopie z dosavadního nejnovějšího roku) a `{prev}` míří vpravo.
- **Souhrn:** místo listu `Summary FY<rok>` jeden list **Souhrn**, vždy první v sešitu; nový
  souhrn ho vyčistí a přepíše. Text se zalamuje, nadpisy tučně, klíčová čísla z XBRL jako
  tabulka se skutečnými čísly (USD mld., %, změna).

---

# Tabulky: jednotka z buněk jednou nad tabulkou

- Model, který jednotku zopakuje v každé buňce („63,338 mld. USD“), ji teď nemá v tabulce
  stokrát: pokud ji mají všechny číselné buňky sloupce, přesune se do hlavičky a společná se
  ukáže jednou („Hodnoty v mld. USD“). Kopírování a CSV berou původní buňky.

---

# NVIDIA API (build.nvidia.com)

- Nová cloudová služba **NVIDIA**: hostované modely (DeepSeek, Qwen, Llama, Nemotron, Kimi…)
  přes OpenAI-kompatibilní Chat Completions. Free tier ~40 dotazů/min – při 429 se čeká 15/30/60 s.
- Přemýšlení z `reasoning_content` i z `<think>`; přepínač přes `chat_template_kwargs`.
- Okno modelu katalog neposílá: výchozí 128k, skutečné se zjistí z chyby „maximum context length“.

---

# Gemini: opakování při přetížení (503)

- Chyba 503 „high demand“ (i uprostřed streamu) se zkusí znovu po 3/8/20 s, dokud nepřišel
  text odpovědi. Po vyčerpání pokusů srozumitelná hláška.

---

# Filtr importu bez endpointu /filter

- Filtr podle sloupce dával „Chyba 500“ a import s ním vypršel: endpoint `/filter` prohlížeče
  datasetů u větších datasetů padá. Filtr se teď vyhodnocuje v aplikaci – nejdřív se najde úsek,
  kde řádky s hodnotou leží (u `origin` → `questions_ujc_cas` řádky kolem 90 tisíc), a import čte
  jen z něj. Pod filtrem se ukáže nalezený rozsah.
- Požadavky na Hugging Face mají časový limit 30 s a při 429/5xx se dvakrát zopakují.

---

# Hromadné mazání trénovacích vzorků

- **Trénink › Procházet vzorky › koš vpravo nahoře:** smaže vzorky z jednoho importu (dataset z Hugging
  Face nebo soubor, s počtem), všechny importované najednou, nebo úplně všechny. Vzorky od učitele
  se při mazání importovaných nechávají. Vždy s potvrzením; hotový adaptér to neovlivní.
- Oprava překladu: `HuggingFaceDataset.page` četl a zapisoval `components` v jednom výrazu
  (overlapping access).

---

# Import datasetu: výběr řádků a filtr

- **Načíst dataset › Výběr řádků:** pořadí „Po sobě“ s volbou **Začít od řádku**, nebo **Náhodně** –
  bloky po 20 řádcích z náhodných míst celého splitu, uvnitř bloku zamíchané.
- **Filtr sloupec = hodnota** (např. `origin` → `questions_ujc_cas`): sloupce a četnosti hodnot
  z endpointu `/statistics`, filtruje se na serveru přes `/filter`. Náhled i počet řádků se po změně
  načtou znovu, ruční mapování sloupců zůstane. Bez statistik se filtr nenabídne.
- Důvod: kolekce seřazené podle zdroje (`ctu-aic/cs_instruction_tuning_collection`) šly dřív načíst
  jen od začátku, takže se k nativním českým zdrojům nedalo dostat.

---

# Zbývající limity cloudových služeb

- **Nastavení › Cloud › (služba) › „Zbývá“:** kolik dotazů a tokenů zbývá podle hlaviček poslední odpovědi
  (OpenAI `x-ratelimit-remaining-*`, Claude `anthropic-ratelimit-*-remaining`), s ukazatelem a živým
  odpočtem do obnovy. Když se limit dotazů obnovuje po hodinách (free tier OpenAI: 50 dotazů za den),
  popisek říká „denní limit“. K tomu počítadla odeslaných dotazů za minutu a za 24 h (z tohoto zařízení) –
  jediný údaj, který jde ukázat u Gemini (limity v hlavičkách neposílá).
- **Menu titulku chatu** ukáže u cloudové služby krátký řádek „Zbývá 47/50 dotazů dnes · obnova za …“.

---

# ChatGPT (OpenAI API) jako třetí cloudový poskytovatel

- **Nový poskytovatel „ChatGPT“** vedle Clauda a Gemini: Nastavení › Cloud › ChatGPT – API klíč
  (platform.openai.com/api-keys, ukládá se do Klíčenky), ID modelu, načtení modelů z účtu, test spojení.
  Výchozí model `gpt-6-sol` (levnější `gpt-6-luna`, nejsilnější `gpt-6-astra`).
- **Responses API** (`/v1/responses`) se streamováním – jen tam OpenAI vrací shrnutí přemýšlení.
  Systémový prompt jde jako `instructions`, `store: false` (konverzace se na serveru neukládá).
  Obrázky jako `input_image`, PDF jako `input_file` (data URL), textové přílohy vložené do textu.
- **Přemýšlení:** zapnuto = výchozí úsilí modelu + shrnutí (`reasoning.summary: auto`); vypnuto = `effort: none`
  (GPT-6 Sol/Luna, GPT-5.1+), `minimal` (GPT-5), `low` (Astra, o3/o4). GPT-4.x přemýšlení nemá a přijímá
  vlastní teplotu. Když organizace není ověřená a shrnutí nejde, požadavek se zopakuje bez nich.
- **Limity:** okno a max. odpověď z tabulky podle ID (Models API OpenAI je nevrací; GPT-6 1,05M / 128k).
  Limit tokenů za minutu se čte z hlaviček `x-ratelimit-limit-tokens`; OpenAI do něj počítá i
  max_output_tokens, takže rozpočet promptu = limit − max. odpověď. Při 429 kvůli velikosti jeden pokus
  s menším promptem. Vlastní limit jde zadat ručně.
- ChatGPT jde vybrat i jako učitel v Tréninku (LoRA) a používá ho FinFill.

---

# MLX-MoE: test komprese expertů; počítání během čtení výchozí vypnuto

- **Výsledek fáze 3b** („Počítat během čtení“): 4,71 / 4,96 / 4,62 tok/s proti 5,13–5,18 bez ní – žádný
  měřitelný přínos (spíš rozptyl), výchozí proto vypnuto. Cache 3,5 GB s prefillem po 512 tokenech se
  vešla a dala 5,32 tok/s (412 tokenů), zatím nejlepší běh.
- **Test komprese expertů** (tlačítko vedle testu čtení): 64 náhodných expertů bez page cache, komprese
  LZ4 / LZFSE / ZLIB z frameworku Compression. Ukáže poměr velikosti (zvlášť 4bitové váhy a BF16 škály
  s posuny), rychlost rozbalení na jednom a na všech jádrech a efektivní rychlost čtení při 1,45 GB/s z flash
  (flash / poměr, pokud rozbalení stíhá). Komprese dává smysl jen od ~20 % úspory.
- **Výsledek:** LZ4 99,8 % (nic), LZFSE 91,2 % (váhy 94,3 %, škály a posuny 66 %), rozbalení 3,1–3,3 GB/s
  na všech jádrech → efektivně 1,59 GB/s místo 1,45 (+10 %); ZLIB 90,7 %, ale rozbalení jen ~1 GB/s.
  4bitové váhy jsou skoro náhodná data. +10 % nestojí za přebalení 16 GB a zatížení CPU – **nedělá se**.
- **Nejlepší nastavení MLX** (26. 9. večer): cache 3,5 GB (29 slotů), KV q8, prefill 512, předčítání zap:
  436 tokenů 5,78 a 5,70 tok/s (dva stejné běhy), zásah slotů 94,1 %, 44 MB/token ve výpočtu. Delší odpověď
  (752 tokenů) 4,59 tok/s – čekání na předčítání vyrostlo na 25 s (pravděpodobně zahřátí telefonu).
  Kontext při tomhle nastavení jen ~2–3 tisíce tokenů.
- **Počet expertů** (cache 3,5 GB, KV q8, prefill 512): 6 expertů 5,70–5,78 tok/s · 5 expertů 6,47–6,64 tok/s
  (34 MB/token ve výpočtu) · 4 experti 7,65 tok/s (29 MB/token). Méně expertů = méně čtení i výpočtu;
  kvalitu je potřeba posoudit v odpovědích (8→6 skoro beze změny, 4 bývá znát).
- **Uzavření MLX-MoE enginu:** funkční experimentální volba, nejlépe 5,32 tok/s (cache 3,5 GB, prefill 512),
  běžně 5,1–5,2 (cache 3 GB) – na úrovni GGUF (4,6–5,5). Oba narážejí na náhodné čtení z flash ~1,45 GB/s.

---

# MLX-MoE engine, fáze 3b: počítat během čtení chybějících expertů

- Když ve vrstvě někteří experti chybějí, `lookup` jim jen přidělí sloty a GPU hned (asyncEval) počítá
  váženou část přes přítomné experty; mezitím se chybějící čtou (`load`). Pak se dopočítá část přes
  chybějící a obě se sečtou (MoE je vážený součet). V první části se chybějící mapují na slot přítomného
  experta s nulovou vahou – do rozepsaného slotu GPU nesahá (rozepsaná data mohou dát NaN × 0 = NaN).
- Volba „Počítat během čtení“ (výchozí zapnuto). Očekávání je skromné: výpočet expertů jedné vrstvy je
  zlomek milisekundy, čtení chybějícího experta ~2–3 ms, schová se tedy jen malá část čekání (odhad +3–5 %).

---

# MLX-MoE: test čtení expertů (rozhoduje o přebalení souboru)

- **Výsledek fáze 3a** (3 GB, předčítání, page cache zap/vyp): 5,13 a 5,15 tok/s – beze změny proti fázi 2.
  Čtení ve výpočtu 27–28 s, předčítání 59 s na pozadí, čekání na něj 12 s (558 tokenů). Flash dává pořád
  jen ~1 GB/s, page cache ani víc souběžných čtení nepomohly. Na token se čte ~156 MB (46 ve výpočtu +
  ~110 předčítání) → při ~1 GB/s ~150 ms, víc než výpočet (~125 ms). Brzdou je propustnost čtení.
- Podezření: expert v MLX souboru leží v 9 kouscích (3 × 786 kB vah + 6 × 49 kB škál a posunů) na různých
  místech a nezarovnaně – malá nezarovnaná čtení bez page cache flash nevytíží.
- **Test čtení expertů** (Parametry › Délka u MLX MoE s experty z úložiště): změří GB/s pro čtení jako teď
  (9 kousků) vs. jeden souvislý blok stejné velikosti zarovnaný na stránku (a totéž ve 4 souběžných kouscích).
  Když souvislé čtení vyjde výrazně rychleji, další krok je jednorázově přebalit experty do souboru, kde
  každý expert leží v celku (jako Flash-iOS), a očekávání je ~7 tok/s.
- **Výsledek testu** (7 běhů): jako teď 1,25–1,32 GB/s, souvislý blok 1,43–1,45 GB/s, souvislý ve 4 kouscích
  1,43–1,48 GB/s. Přebalení by dalo ~10 % – nevyplatí se (16 GB navíc). Náhodné čtení bez page cache je na
  tomhle iPhonu ~1,45 GB/s bez ohledu na tvar čtení (sedí i s celovrstvovým prefillem v GGUF: 1,5 GB/s).

---

# MLX-MoE engine, fáze 3a: rychlejší čtení expertů a page cache jako druhá úroveň

- **Výsledek fáze 2** (cache 3 GB, předčítání zapnuté): 5,18 tok/s (558 tokenů) a 5,06 tok/s (734 tokenů),
  fáze 1 4,6 tok/s. Zásah slotů 94 %, ve výpočtu jen 44–46 MB/token, předčtení experti použití z 81 %.
  Pořád ale blokuje čtení: u 734 tokenů 37,8 s čtení ve výpočtu + 12,4 s čekání na předčítání ze 145 s.
  Čtení jde jen ~1,1 GB/s (krátká čtení bez page cache, souběžně jen tolik, kolik je jader). Výpočet sám
  ~129 ms/token → strop ~7,7 tok/s. Cache 2,5 GB: 4,3–4,6 tok/s (bez předčítání 3,95). KV q8 rychlost nemění.
- **Souběžnější čtení:** každé čtení (expert × tenzor) je samostatná úloha na globální frontě místo
  `concurrentPerform` omezeného počtem jader – víc souběžných požadavků na flash.
- **Page cache jako druhá úroveň** (nová volba, výchozí zapnuto): soubory vah bez `F_NOCACHE`. Expert
  vyhozený ze slotu často leží ve volné RAM systému (čisté stránky se do limitu appky nepočítají),
  takže se místo čtení z flash jen zkopíruje. Stejný princip, na kterém stojí GGUF.

---

# MLX-MoE engine, fáze 2: předčítání podle routeru další vrstvy

- **Výsledek fáze 1** (Qwen3-30B-A3B-Instruct-2507 MLX 4bit DWQ, 6 expertů, cache 3 GB = 25 slotů/vrstvu):
  odpovědi v pořádku, 558 tokenů za ~121 s = **4,6 tok/s** (GGUF 4,6–5,5). Zásah slotů 84,5 %, 115 MB/token
  čteno ve výpočtu za 51 s z 121 s (1,26 GB/s – krátká čtení bez page cache). Bez čtení by výpočet dal
  ~125 ms/token → ~8 tok/s. Kontext jen ~2 300 tokenů – strop paměti 5 GB nestačí na 3 GB cache.
- **Předčítání:** MoE blok vrstvy L spočítá v tomtéž vyhodnocení i odhad expertů vrstvy L+1 (router L+1
  nad normovaným reziduálním proudem vrstvy L, jako `RouterPredictor` u GGUF) a jejich čtení spustí na
  pozadí do slotů L+1, zatímco GPU počítá experty vrstvy L. `ensure` vrstvy L+1 na rozběhnuté čtení počká
  (DispatchGroup po vrstvách). Předčítání nevyhazuje experty použité v posledním tokenu vrstvy.
  Obsazení slotů je teď pod zámkem.
- Log: po odpovědi „prefill … · generování … tok/s“, u MoE z úložiště i předčtení experti, kolik z nich
  se použilo a kolik výpočet čekal. Volba „Předčítat podle odhadu“ (výchozí zapnuto), cache i 2 560 MB.

---

# MLX-MoE engine, fáze 1: experti z úložiště do slotů v paměti GPU

- Nastavení MLX (u MoE modelu): „Experty z úložiště (experiment)“ + „Cache expertů“ (2–4 GB, výchozí 3 GB).
- `MLXExpertStore`: z hlaviček safetensors najde tenzory `switch_mlp` (gate/up/down × weight/scales/biases),
  pro každou MoE vrstvu alokuje pole slotů `[sloty, …]` (sloty = cache / (vrstvy × velikost experta)).
  Chybějící expert se čte `pread` s `F_NOCACHE` přímo do paměti slotu (sdílená paměť CPU/GPU), paralelně
  po tenzorech. Vyhazuje se LRU. Statistiky (zásah slotů, MB/token, doba čtení) do Logu enginu po odpovědi.
- `StreamedQwen3MoEModel`: kopie Qwen3-MoE z mlx-swift-lm, MoE blok vlastní – počká na výběr routeru
  (`eval`), doplní experty do slotů, `gatherQuantizedMM` nad sloty. Při prefillu, kdy dávka vybere víc
  expertů než slotů, se počítá po skupinách. Experti se z vah vynechají v `sanitize` (líné načítání
  safetensors je pak vůbec nepřečte). Registruje se místo `qwen3_moe` v `LLMTypeRegistry`; bez zapnutého
  streamování vrací původní `Qwen3MoEModel`.
- Strop paměti počítá u streamovaného modelu hustou část + cache expertů, ne celý adresář.
- Podmínka pro fázi 2: odpovědi dávají smysl a ≥ 4 tok/s.

---

# Srovnání: Flash-iOS na stejném iPhonu

- Flash-iOS (vlastní Metal engine, Qwen3.5-35B-A3B ve formátu Flash-MoE): ~3,9 tok/s, odpovědi slabé,
  model se zacyklí a píše nesmysly. AiChat (llama.cpp, experti z flash, odhad z routeru k): 4,6–5,2 tok/s.
  Vlastní engine nad Metalem se tedy nedělá – současný přístup vychází nejlépe.

---

# MLX: architektura spark2_5 (Spark-X2.5-4B)

- mlx-swift-lm 3.31.4 `spark2_5` nezná („Unsupported model type“). `MLXSpark25.swift` je port Python
  implementace z mlx-lm (PR #1891): sliding/full attention (okno 512), sloučená `q_k_v_proj`, sigmoid
  brána výstupu po hlavách (`g_proj`, nekvantovaná), částečné RoPE (full: 25 % dimenzí, θ 5M; sliding:
  plné, θ 10k), GELU MLP, sdílené embeddingy. Registruje se do `LLMTypeRegistry` před načtením modelu
  (chat i trénink LoRA).

---

# Test: MoE z flash přes MLX (rozhodnutí před přepisem)

- Parametry › Rychlost úložiště, u GGUF MoE: „Test: MoE z flash přes MLX“ (`MLXMoEProbe`). Napodobí
  generování na GPU přes MLX s rozměry vybraného modelu (z metadat GGUF): husté váhy jsou nulové 4bitové
  matice správné velikosti, experti se opravdu čtou ze souboru podle posledního záznamu expertů.
- Tři běhy po 24 tokenech (+4 na zahřátí): GPU bez čekání, GPU s čekáním na router v každé vrstvě
  a celý průchod se čtením expertů přes paralelní pread a kopií do MLX polí. Výsledek: cena čekání
  na vrstvu, doba čtení a kopie na token a strop tok/s bez předčítání i s ideálním předčítáním.
  Rozhodnutí: nad ~6 tok/s má přepis smysl (GGUF teď 4,6–5,2).
- **Výsledek** (iPhone, Qwen3-30B-A3B, 6 expertů, záznam z 23. 9.): GPU bez čekání 37 ms/token, s čekáním
  na router 155 ms (2,44 ms na vrstvu), čtení 224 ms (784 MB přes pread, 3,42 GB/s), kopie do MLX 25 ms.
  Strop 2,9 tok/s bez předčítání, 4,5 tok/s s ideálním předčítáním – pod GGUF. Druhý běh hned po generování
  v GGUF (teplá page cache, čerstvý záznam, zásah cache 95 %): čtení 174 ms (4,40 GB/s – většinou jen kopie
  z page cache), čekání 158 ms, strop 3,5 / 5,5 tok/s; GGUF ve stejné chvíli 4,40 tok/s se zapnutým záznamem.
  I s nulovým čtením zůstává čekání + kopie ~180 ms → nejvýš ~5,5–6 tok/s. **Přepis se nedělá.**
- **Rozbor čekání** (26. 9.): holé eval 0,72 ms, s top-k a čtením indexů 0,83 ms, skutečná vrstva po vrstvě
  +2,3 ms proti běhu bez čekání. Se zkompilovanou vrstvou (`compile`) 147 ms/token místo 155 – příprava
  grafu na CPU to tedy není. Zbytek je chování GPU při krátkých úsecích práce s čekáním mezi nimi
  (takt, plánování), to aplikace neovlivní. Podlaha ~150 ms/token → i bez čtení nejvýš ~6,5 tok/s,
  reálně 5,5–6. GGUF ve stejný den 5,48 tok/s. **MLX-MoE engine se nedělá.**
  Brzdí čekání na GPU v každé vrstvě (118 ms z tokenu) a to, že MLX musí vybrané experty pokaždé
  zkopírovat, i když leží v page cache – llama.cpp je díky mmapu používá přímo.

---

# GGUF MoE v RAM: počet aktivních expertů i bez streamování

- „Aktivních expertů“ je teď vidět u každého GGUF MoE, i s vypnutým „Experty MoE z úložiště“ (model
  celý v RAM, výpočet na Metalu). Dřív se přepis `expert_used_count` uplatnil jen při streamování.
  Na GPU se neušetří čtení z flash, ale průchod vahami MoE vrstev. Log: „MoE v RAM: 6 z 128 expertů…“.
- Hustý GGUF (třída GGUF) experty nemá, tam volba není.

---

# MLX: počet aktivních expertů u MoE modelů

- Nastavení je uložené zvlášť pro každý typ modelu (GGUF MoE, GGUF, MLX), takže „Aktivních expertů“
  z GGUF MoE na MLX nepůsobí. MLX má teď vlastní krokovač (Parametry › Délka, jen u MoE modelu –
  pozná se podle `num_experts_per_tok` / `top_k_experts` v config.json).
- mlx-swift-lm bere počet expertů z config.json a jinak ho přepsat nejde. Model se proto při sníženém
  počtu načte ze stínové složky v Caches: upravený config.json + odkazy na váhy a tokenizér
  (nic se nekopíruje). Změna počtu model znovu načte. RAM se neušetří (MLX drží všechny experty
  v paměti), zrychlí se výpočet MoE vrstev. Log: „MoE: 6 z 8 expertů na token (sníženo)“.

---

# MoE: čtení odhadu přes paralelní pread (z Flash-iOS) a větší adresní prostor

- **Čtení odhadu** (Parametry › Výkon, pod „Předčítat podle odhadu“): `F_RDADVISE` (výchozí, beze změny)
  nebo `pread ×1 / ×2 / ×4`. S pread se odhadnutí experti opravdu přečtou do 1MB pomocného bufferu
  v N vláknech po kouscích zarovnaných na stránky (min. 256 kB) – stejně jako „fanout“ ve Flash-iOS.
  pread a mmap sdílejí na iOS jednu cache souboru, takže výpočet stránky najde v paměti. Čtení běží
  na pozadí jako dosud; jakmile výpočet vrstvu předběhne, zbylé kousky se přeskočí (počítá se do
  „výpočet předběhl“). Doba v řádku „podle odhadu“ je u pread skutečná doba čtení, u F_RDADVISE jen
  doba ohlášení.
- **Měření** (Qwen3-30B-A3B, 6 expertů, 3 vlákna, odhad k, stejný dotaz, 666 tokenů):
  F_RDADVISE 4,76 tok/s · pread ×1 2,97 · pread ×2 4,40 · pread ×4 4,07. pread je pomalejší ve všech
  variantách. Čtení nestíhá (výpočet předběhl 34–66 % vrstev), pak se stránky už nenamapují předem
  a výpadky „jen mapování“ vyskočí z 0,6 na 3,5–4,5 milionu. Vlákna čtení navíc kopírují data do
  bufferu a berou jádra výpočtu. Flash-iOS z toho těží, protože pread u něj čte rovnou do bufferu,
  se kterým počítá GPU; tady by to byla jen druhá kopie vedle mmapu llama.cpp. Výchozí zůstává F_RDADVISE.
- **Entitlement `extended-virtual-addressing`** (AIChat i Sideload): llama.cpp mapuje celý GGUF;
  u modelů kolem 22 GB (Qwen3.6-35B-A3B Q4_K_M) se mapování nemusí vejít do výchozího adresního prostoru.
  Paměť nezabírá. Kdyby ho podpis nebo sideload nástroj odmítl, stačí klíč z `.entitlements` odebrat.

---

# MoE: oprava zdvojeného odhadu u Qwen3.6 a první měření REAP

- **Oprava:** u Qwen3.6 dělá MoE ze vstupu `attn_post_norm-N` přetvarovaný pohled „attn_post_norm-N
  (reshaped)“ s `ne[1] = 1` i při prefillu. Kontrola prefixu ho brala jako další vstup, takže se odhad
  počítal dvakrát na vrstvu (log ukazoval 2× víc ohlášených expertů, než kolik výpočet použil) a při
  prefillu se odhadovalo z dat prvního tokenu. Teď se bere jen přesné jméno uzlu a 2D tvar s jedním tokenem.
- **REAP-48 v2** (Qwen3.6-35B-A3B, 133 expertů/vrstvu, 9,4 GB, 6 expertů, 3 vlákna, odhad k):
  5,08–5,45 tok/s bez přemýšlení, 47 MB/token z flash ve výpočtu. Qwen3-30B-A3B: 5,17 tok/s, 128 MB/token.
  Čte se o 60 % méně, ale rychlost je skoro stejná, protože teď brzdí výpočet, ne flash: experti jsou
  v IQ3_S/IQ4_XS (na CPU iPhonu pomalejší jádra než Q4_K), přebalí se jen 71 matic místo 193, hustá
  část má 1,78 GB místo 1,02 GB (sdílený expert a attention v Q5–Q8 počítané u každého tokenu)
  a slovník má 248 tisíc tokenů místo 152 tisíc.
- První odpověď po načtení (2,08 tok/s) byla se studenou page cache a s rozptylem telefonu. Qwen3-30B
  se stejným nastavením dal jednou 5,17 a jindy 3,87 tok/s.

---

# MoE: odhad expertů i pro Qwen3.5/3.6 MoE (Qwen3.6-35B-A3B)

llama.cpp u architektury `qwen35moe` (a `qwen3next`) nemá `ffn_norm`. Norma před MoE je uložená jako
`blk.N.post_attention_norm` a v grafu je vidět jen její výstup `attn_post_norm-N`; uzel `ffn_inp` tu
není. Odhad expertů se proto dřív vypnul („router nejde načíst“).

- `GGUFLayout` pro tyto architektury vezme `post_attention_norm` jako normu před MoE a nastaví
  `moeInputNode = "attn_post_norm"` a `moeInputNormalized = true`. U ostatních architektur zůstává
  `ffn_norm` a `ffn_inp`. `post_attention_norm` jinde znamená něco jiného (např. u Gemmy normu výstupu
  attention), proto jen pro vyjmenované architektury.
- `RouterPredictor.predict(…, normalizedBy:)`: normovaný vstup `x/rms(x) ⊙ w_L` se vydělí `w_L`
  a zbyde `x/rms(x)`. Kladné měřítko pořadí expertů nemění, takže odhad je stejný jako ze surového `x`.
  Router L+1 má složenou svou normu jako dřív. Složky s nulovou vahou normy vypadnou.
- `ExpertPrefetcher` si o uzel říká podle `moeInputNode`.

Neověřeno na iPhonu. Po načtení Qwen3.6 by v logu mělo být „odhad expertů: routery 40 vrstev načteny“.
Přesnost ukáže záznam (se záznamem a bez předčítání podle odhadu).

---

# MoE: výchozí předčítání podle odhadu = k

Srovnávací běhy z iPhonu (6 expertů, bez záznamu, mapování stránek vypnuté, stejný dotaz, 748 tokenů):

| nastavení                    | tok/s | ms/token | ohlášeno odhadem na token |
|------------------------------|-------|----------|---------------------------|
| k, 4 vlákna                  | 4,31  | 232      | 786 MB                    |
| k + dvě vrstvy, 4 vlákna     | 3,91  | 256      | 894 MB                    |
| **k, 3 vlákna, bez záznamu (11:52)** | **5,17** | **194** | 767 MB     |

- **Dvě vrstvy dopředu jsou o 9 % pomalejší než k.** Víc zbytečného čtení (+14 % ohlášených dat) a víc práce
  na pozadí sebere víc, než delší náskok dá. Stejně dopadla varianta k+2. Volba zůstává pro pokusy.
- **4 vlákna jsou pomalejší než 3** (4,31 proti 5,17 tok/s, ověřeno během bez záznamu). Na iPhonu s 2 výkonnými a 4 úspornými jádry
  si čtvrté vlákno výpočtu konkuruje s frontami na pozadí. Nechat 3.
- **Výchozí `prefetchAhead` = k** (i v předvolbě GGUF MoE). Bez záznamu 5,17 tok/s proti 4,32 bez odhadu
  (6 expertů, 3 vlákna), tedy +20 %. Předčítání ve vlákně výpočtu zabere 22 ms z 194 ms na token,
  zbytek je výpočet a výpadky stránek.

Doporučené nastavení pro Qwen3-30B-A3B na iPhonu s 8 GB: 3 vlákna, přebalení husté části zapnuté,
GPU prefill vypnutý, předčítat podle odhadu k, prefill po celých vrstvách vypnutý, záznam vypnutý.

---

# MoE: předčítání o dvě vrstvy dopředu

Záznam v4 z iPhonu (6 expertů, bez předčítání podle odhadu, 666 tokenů, page cache 78 %):

| odhad          | trefí výpadky | čtení navíc | náskok             |
|----------------|---------------|-------------|--------------------|
| router L+1 (k) | 78,2 %        | 27,8 %      | 1 vrstva           |
| router L+2 (k) | 71,6 %        | 41,2 %      | 2 vrstvy           |
| L+1 ∪ L+2 (k)  | 84,3 %        | 52,3 %      | většinou 2 vrstvy  |

- Nová volba **„k, dvě vrstvy dopředu“** (`prefetchAhead = 3`). U `ffn_inp-L` se ohlásí k expertů vrstvy L+2
  podle jejího routeru a o vrstvu později (u `ffn_inp-L+1`) už jen experti, které odhad L+1 přidá navíc.
  Úloha na pozadí má u L+2 o vrstvu delší lhůtu.
- Otázka pro měření: vyplatí se o 5 % výpadků víc a delší náskok za dvojnásobné zbytečné čtení?
  Varianta k+2 (víc zbytečného čtení, stejný náskok) byla pomalejší než k, takže výsledek není jistý.

Swift je nepřeložený.

---

# MoE: měření odhadu o dvě vrstvy dopředu

Srovnávací běhy z iPhonu (Qwen3-30B-A3B, 6 expertů, stejný dotaz, 666 tokenů, se záznamem):

| mapovat stránky předem | odhad | tok/s | bez měření | připraveno včas |
|------------------------|-------|-------|------------|-----------------|
| ano                    | vyp   | 4,12  | 4,23       | 78,5 %          |
| ano                    | k     | 4,48  | 4,74       | 94,4 %          |
| ne                     | vyp   | 4,20  | 4,32       | 79,0 %          |
| ne                     | k     | 4,48  | 4,72       | 94,9 %          |

- Předčítání podle odhadu (k) zrychlí generování o 9–12 %. Předmapování stránek teď nemá vliv.
- S předmapováním výpočet předběhl úlohu na pozadí v 7 329 z 31 968 vrstev (23 %), takže jedna
  vrstva náskoku na dočtení často nestačí.

Proto se se zapnutým záznamem u `ffn_inp-L` odhaduje i vrstva L+2 (router L+2 má složenou vlastní
normu, vstup je stejný). Odhad jde do **záznamu v4** (`predicted2`, příznak bit 2) a simulace ho
vyhodnotí v řádcích „router L+2“ (k, k+2, 2k) a „router L+1 ∪ L+2“. Podle odhadu L+2 se zatím nečte.
Bez záznamu se L+2 nepočítá. Záznamy v1–v3 se dál čtou.

Swift je nepřeložený. Python nástroj je ověřený na syntetickém záznamu v4 i na starších záznamech.

---

# MoE: předčítání podle odhadu na pozadí

Log z iPhonu (Qwen3-30B-A3B, **6 z 8 expertů**, KV f16, kontext 32k, repack zapnutý, záznam zapnutý,
666 tokenů):

| odhad | tok/s | bez měření | připraveno včas | čekání v předčítání | ohlášení odhadu |
|-------|-------|------------|-----------------|---------------------|-----------------|
| k     | 4,39  | 4,55       | 95,1 %          | 67 ms/tok           | 34 ms/tok       |
| k+2   | 3,85  | 3,99       | 97,4 %          | 59 ms/tok           | 57 ms/tok       |

- **Odhad funguje.** Podíl vybraných expertů, kteří v okamžiku výpočtu ležel celý v paměti, vyskočil
  z ~73 % (bez odhadu, k = 8) na 95 %. k+2 přidá jen 2,3 procentního bodu, ale čte víc a je pomalejší,
  proto doporučuju k.
- **Ohlášení odhadu brzdilo výpočet.** `F_RDADVISE` přímo v callbacku stálo 34 ms na token (k+2: 57 ms),
  výpočet na něj čekal. Teď běží na sériové frontě na pozadí.
- **Mapování stránek odhadnutých expertů také na pozadí** (druhá fronta, aby čekání na flash nezdrželo
  ohlášení další vrstvy). V cestě výpočtu zbývalo ~60 ms na token mapování (~10 000 výpadků „jen
  mapování“ na token). Úloha se přeruší, jakmile výpočet vrstvu předběhne; log to ukazuje jako
  „výpočet předběhl N×“. `unload()` před uvolněním modelu počká, až úlohy doběhnou.
- **Prefill: celá vrstva nepomáhá, nech ji vypnutou.** Sekvenční `pread` jde jen ~1,5–1,8 GB/s, ne
  3,7 GB/s, takže prefill 52 tokenů trval 12,3–12,9 s místo 7,0–8,2 s.
- Chybí srovnávací běh se 6 experty bez odhadu. Dřívější čísla jsou s 8 experty a s každým tokenem
  měřeným, takže se srovnávat nedají.

Swift je nepřeložený.

---

# MoE: předčítání podle odhadu z routeru, levnější měření, oprava mapování po GPU prefillu

Podle tří záznamů v3 a logu z iPhonu (Qwen3-30B-A3B, k = 8, 650–840 tokenů na odpověď):

- **Odhad z routeru L+1 funguje.** S k experty trefí 81 % expertů, kteří v cache chyběli, za ~24 %
  zbytečného čtení; k+2 trefí 90 % za 56–59 %. Ve všech třech záznamech vyšlo totéž.
- **Předčítat podle odhadu** (`prefetchAhead`, Parametry › Výkon: vypnuto / k / k+2, výchozí vypnuto).
  Při generování se u `ffn_inp-L` odhadnou experti vrstvy L+1 a jejich rozsahy se hned ohlásí přes
  `F_RDADVISE`, bez čekání a bez dotyku stránek. Čtení tak běží souběžně s MoE vrstvy L a attention
  vrstvy L+1. Funguje i bez záznamu. Routery se načtou, když je potřebuje záznam nebo tahle volba.
  Log: „podle odhadu ohlášeno N expertů, X MB za Y ms“ a v řádku generování „· podle odhadu k“.
- **Měření rezidence jen na každém 8. tokenu.** Měřit každý token stálo 36–82 ms na token, tedy 10–18 %
  doby generování, a s odhadem se měřilo ~18 expertů na vrstvu místo 8. Záznam tak zkresloval
  rychlost, kterou měl měřit. Log u zásahu cache uvádí velikost vzorku.
- **Oprava: mapování stránek po GPU prefillu.** První uzel `MUL_MAT_ID` na GPU (prefill s op_offload)
  natrvalo vypnul zjišťování adresy mmapu, takže se při generování stránky předem nemapovaly po celou
  dobu načtení modelu. V logu je to vidět na krátkém předčítání: 71–122 ms na token s GPU prefillem
  proti 187–198 ms bez něj. Teď se GPU uzel přeskočí a adresa se vezme z uzlu generování na CPU.

Co z logu vyšlo pro nastavení (dlouhé odpovědi, tok/s po odečtení času měření):

| čas   | repack | kontext | GPU prefill | tok/s | bez měření | zásah cache |
|-------|--------|---------|-------------|-------|------------|-------------|
| 22:08 | ne     | 16k     | ne          | 2,17  | 2,64       | 74,6 %      |
| 23:30 | ano    | 16k     | ne          | 2,80  | 3,38       | 73,2 %      |

- **Přebalení husté části nechat zapnuté.** Stojí ~1 GB, ale page cache z něj dostala jen ~1,4 procentního
  bodu zásahu (simulace slibovala víc, jenže iOS uvolněnou RAM cache expertů nepřidělil), kdežto
  rychlejší jádra daly +28 % tok/s.
- **GPU prefill u krátkých promptů nezapínat.** Prefill 52 tokenů trval s ním 9,8–10,5 s, bez něj
  7,0–8,2 s, a RAM appky při něm vyskočila na 5,5–6,5 GB.
- Prefill: celá vrstva v těchto bězích zapnutá nebyla, její přínos zatím změřený není.

Swift je nepřeložený.

---

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
