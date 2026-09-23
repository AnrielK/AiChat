# AI Chat – iOS 26 (SwiftUI, Liquid Glass)

Chatovací appka, která umí čtyři zdroje odpovědí:

| Zdroj | Kde běží | Co je potřeba |
|---|---|---|
| **Lokální model – GGUF** | offline v iPhonu (llama.cpp + Metal) | soubor `.gguf` – stáhnout v appce nebo připojit z disku |
| **Lokální model – MLX** | offline v iPhonu (Apple MLX, GPU) | složka z `mlx-community` – stáhnout v appce nebo připojit z disku |
| **Apple Intelligence** | offline v iPhonu (FoundationModels) | zařízení s Apple Intelligence |
| **Claude** | cloud Anthropic | API klíč |
| **Gemini** | cloud Google | API klíč |

## Ovládání
- **Vpravo nahoře** – obsazení kontextu: kroužek a „zbývá / okno“ v tokenech (např. `5,9k / 8,2k`). Plný oblouk je obsazeno, světlejší kolik přidá rozepsaná zpráva s přílohami; od 70 % oranžová, od 90 % červená. Klepnutím podrobnosti (poslední odpověď vs. max, vynechané zprávy, zkrácení pamětí) a pod nimi živé využití paměti appky – zabráno (phys_footprint), volné do limitu (`os_proc_available_memory`), z toho MLX (aktivní + cache), RAM zařízení – obnovované každou sekundu, s tlačítkem pro uvolnění lokálního modelu z paměti. Počty jsou přesné – llama.cpp a MLX z tokenizéru, Claude a Gemini z `usage` v odpovědi; okno cloudových modelů se načte z Models API (`max_input_tokens` / `inputTokenLimit`). Apple Intelligence počty neprozradí, tam jde o odhad.
- **Vlevo nahoře** – v otevřené konverzaci šipka zpět na úvodní obrazovku (= nový chat)
- **Titulek** – klepnutím rychle přepneš poskytovatele (podtitulek ukazuje aktivní model)
- **Dole** – plovoucí Liquid Glass lišta: Historie · pole pro zprávu · Nastavení. Když začneš psát, boční tlačítka se „vlijí“ do pole zprávy.
- **Přílohy** – tlačítko **+** v poli zprávy přidá fotky nebo soubory (víc najednou). Štítky nad polem jdou odebrat, u odeslané zprávy otevřou náhled (Quick Look).
- **Čas u zprávy** – pod každou bublinou je čas odeslání (u starších zpráv i datum, u včerejších „včera“). U odpovědi navíc běží během generování stopky a po dokončení zůstane celková doba, u modelů, které hlásí tokeny, i rychlost (např. `14:32 · 12,4 s · 18,3 tok/s`).
- **Přemýšlení (reasoning)** – ikonka mozku v poli zprávy (nebo menu titulku) ho zapne/vypne pro právě aktivní model. Nastavení se pamatuje **pro každý model zvlášť**. Přemýšlení se v odpovědi zobrazí sbalené nad textem.
- **Nastavení** – výběr zdroje, správa lokálních modelů (stažení / import / smazání), parametry generování, API klíče s načtením seznamu modelů z účtu a testem spojení
- **Stáhnout model** (Nastavení › Modely v zařízení) – přepínač MLX / GGUF, doporučené modely pro iPhone a hledání na Hugging Face (řazené podle stažení). Detail modelu ukáže velikost a porovná ji s RAM telefonu; u GGUF se vybírá kvantizace.

## Spuštění
1. Otevři `AIChat.xcodeproj` v **Xcode 26**.
2. Xcode sám stáhne balíčky: `Packages/LlamaCpp` (předkompilovaný llama.cpp, ~87 MB), `mlx-swift-lm` a `swift-transformers`. Při prvním buildu potvrď **Trust & Enable** u maker `MLXHuggingFaceMacros`.
3. Nainstaluj Metal toolchain (MLX z něj kompiluje shadery): `xcodebuild -downloadComponent MetalToolchain`.
4. V *Signing & Capabilities* vyber svůj tým, případně změň bundle ID (`cz.jiri.aichat`).
5. Build na **skutečný iPhone** (iOS 26).

### Nepodepsaná IPA (sideload)
```bash
./make-ipa.sh          # Release
./make-ipa.sh Debug
```
Výsledek `AIChat.ipa` podepíše až Sideloadly / AltStore / LiveContainer. Entitlement pro vyšší limit paměti přidá jen placený účet, s bezplatným Apple ID počítej s modely do ~2 GB.

### GitHub Actions

Workflow `.github/workflows/build.yml` postaví nepodepsanou IPA na runneru `macos-26`. Spouští se jen ručně (*Actions › Build IPA › Run workflow*) a tagem `v*` – push na `main` ani pull request build nespouští. Při ručním spuštění se volí konfigurace (Release / Debug) a varianta llama.cpp: *automaticky* (zkompilovaná s BLAS ON, když existuje, jinak oficiální), *originální b10894*, nebo zkompilovaná `armv8.6-a+dotprod+i8mm` s `GGML_BLAS=ON` / `OFF`. Když vybraná zkompilovaná varianta neexistuje, build hned skončí s chybou. Použitá varianta je v souhrnu běhu i v appce (*Nastavení › llama.cpp*).

1. Vybere nejnovější stabilní Xcode 26 a v případě potřeby doinstaluje Metal toolchain.
2. Obnoví cache Swift balíčků v `.build/SourcePackages`.
3. Spustí `./make-ipa.sh`, tedy **stejný build jako lokálně**, včetně kontrol arm64, `llama.framework` a Metal shaderů.
4. Nahraje `AIChat.ipa` jako artefakt (30 dní) a vedle něj `build.log` a `Package.resolved`.

V *Summary* běhu je velikost IPA, verze Xcode a použité verze balíčků. Když build selže, najdeš tam chyby kompilátoru a neúspěšné kontroly skriptu (řádky s `✕`).

Po pushnutí tagu (`git tag v1.0.0 && git push origin v1.0.0`) se `AIChat.ipa` přiloží i ke GitHub Release.

Balíčky mají v projektu rozsah „do další major verze“, takže bez `Package.resolved` si CI může stáhnout novější verzi, než jakou máš lokálně. Po prvním úspěšném buildu proto stáhni `Package.resolved` z artefaktu a commitni ho do `AIChat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`.

### Simulátor
Oficiální XCFramework llama.cpp (build b10894) obsahuje jen slice `ios-arm64` a `macos` – **pro simulátor se nepřeloží**. Když chceš ladit UI v simulátoru, odeber v *Frameworks, Libraries…* položku `llama` (a klidně i MLX balíčky – MLX v simulátoru stejně nemá GPU). Kód je obalený `#if canImport(llama)` / `#if canImport(MLXLLM)`, takže se appka přeloží dál, jen lokální modely vrátí chybu. Claude, Gemini i Apple Intelligence fungují.

### Paměť
Limit paměti appky (kolik smí zabrat, než ji iOS ukončí) zvedá entitlement `com.apple.developer.kernel.increased-memory-limit`.

- **Build z Xcode** ho bere z `AIChat.entitlements`. Pokud ho tvůj účet při podpisu odmítne, smaž ho odtud a používej menší modely.
- **Nepodepsaná IPA** (`make-ipa.sh`, CI) je ad-hoc podepsaná s entitlementem `increased-memory-limit` ze `Sideload.entitlements`. SideStore / AltStore si ho z podpisu přečtou a při instalaci o něj požádají. Dřív byla IPA úplně bez podpisu, takže nástroj neměl podle čeho o limit požádat.
- **JIT (StikDebug) není potřeba** – MLX ani llama.cpp ho nepotřebují a naměřený limit je stejný s ním i bez něj. Entitlement `increased-debugging-memory-limit` proto v projektu není.

Skutečný limit, zabranou paměť a RAM zařízení ukáže **Nastavení › Parametry generování › Paměť** (a živě i ukazatel kontextu v chatu). Podle limitu appky – ne podle RAM zařízení – se řídí i doporučení velikosti modelu při stahování. Na iPhonu s 8 GB RAM bývá bez entitlementu limit ~3,3 GB, s ním ~6,5 GB; to stačí na 4B model v Q4 s kontextem 32k, nebo na 8B model s kratším kontextem. Nabídka délky kontextu proto sahá do 128k a max. délka odpovědi do 16k – co se skutečně vejde, appka stejně dopočítá sama.

**Paměť a délka kontextu.** KV cache roste s kontextem (Gemma 3 4B ≈ 150 kB na token u vrstev s plnou pozorností), takže dlouhý text s velkým kontextem dřív appku shodil. Oba enginy teď před každou odpovědí změří volnou paměť (`os_proc_available_memory`), spočítají paměť na token z parametrů modelu (GGUF metadata / `config.json`, se zohledněním sliding-window a lineárních vrstev) a nastavený kontext případně zkrátí. Parametry generování pak ukážou, na kolik tokenů paměť stačila. MLX má navíc omezenou cache bufferů (32 MB) a `maxKVSize` jako pojistku.

### MoE modely a streamování expertů
MoE modely (Qwen3-30B-A3B, Gemma 4 26B-A4B …) mají v souboru desítky GB, ale na každý token použijí jen malou část vah. Appka to u GGUF využívá stejně jako `--cpu-moe` v llama.cpp:

- **Hustá část** (attention, embeddingy, normy, router) jde na Metal a leží v RAM – u Qwen3-30B-A3B v Q4_K_M zhruba 1–1,5 GB.
- **Routovaní experti** (`blk.N.ffn_{up,gate,down}_exps`) zůstanou přes `tensor_buft_overrides` v obyčejném CPU bufferu nad namapovaným souborem. iOS si je čte z flash, až na ně router sáhne, a page cache funguje jako LRU cache expertů. Stránky jsou clean, takže se do limitu appky nepočítají a při nedostatku paměti je jádro zahodí – model je pomalejší, ale nespadne.
- Kvůli tomu se vypíná **repacking vah** (`use_extra_bufts`), který by experty zkopíroval do nové paměti, a **offload násobení na GPU** při prefillu (`op_offload`), který by celé tenzory expertů vrstvy kopíroval do Metal bufferu. Prefill dlouhých promptů proto běží na CPU.
- Rozpočet kontextu nepočítá s celým souborem, jen s hustou částí + 1,5 GB pracovní sady expertů (`LlamaEngine.expertWorkingSet`).

**Metal a pořadí tenzorů.** Metal sdílí namapovaný soubor jen jako souvislý `MTLBuffer` od prvního po poslední tenzor pro GPU a stránky takového bufferu drží v paměti (residency set, wiring při výpočtu). V běžném GGUF se attention a experti střídají vrstvu po vrstvě, takže by buffer pokryl skoro celý 18GB soubor – model se zasekne a appka spadne. `GGUFLayout` proto měří rozpětí tenzorů pro GPU; když nejsou pohromadě, model poběží celý na CPU nad mmapem. Pro GPU soubor jednou přeuspořádej na počítači:

```
python tools/gguf_moe_reorder.py Qwen_Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf Qwen3-30B-A3B-2507-moe.gguf
```

Skript nepotřebuje žádné balíčky, mění jen pořadí dat a offsety v hlavičce (hustá část na začátek, experti za ni). Výsledek nahraj do appky přes Soubory.

**Předčítání expertů** (`ExpertPrefetcher`). Bez něj si výpočet dotahuje experty přes page faulty mmapu – stránku po stránce, sériově. Appka proto přes `cb_eval` callback nechá scheduler zastavit za uzlem `ffn_moe_topk-N`, přečte, které experty router pro vrstvu vybral, a jejich rozsahy v souboru pošle jádru jako `F_RDADVISE` po 8MB blocích paralelně (když `F_RDADVISE` selže, přes `pread`). Mmap a čtení z deskriptoru sdílí na Darwinu jednu cache, takže `MUL_MAT_ID` pak najde stránky načtené. Dá se vypnout (**Předčítat experty**) kvůli porovnání. Do Konzole se po prefillu a po odpovědi zapíše, kolik expertů a MB se předčetlo a jaký podíl času to zabralo.

**Záznam a simulace cache expertů** (`ExpertTrace`, `ExpertCacheSimulator`). Přepínač **Zaznamenávat experty** v Parametrech › Výkon zapisuje do `Documents/ExpertTraces/*.axtr`, které experty router v každé vrstvě vybral. Zároveň před předčtením změří přes `mincore`, kolik z nich už leželo celých v page cache. Tenhle *skutečný* zásah cache se po každé odpovědi zapíše do Logu enginu („zásah cache expertů 41,2 %“) a hity, které obsloužilo až předčítání, se do něj nepočítají. Princip je z [kimi-k3-in-c](https://github.com/FareedKhan-dev/kimi-k3-in-c): routing na cache nezávisí, takže jeden záznam jde offline přehrát pro libovolnou velikost cache a politiku. **Simulace cache expertů** ukáže pro 0,25–6 GB zásah LRU (≈ page cache iOS), LFU a Belady (strop se znalostí budoucnosti), objem čtení na token, strop povinných výpadků a jak moc se požadavky soustředí na malou skupinu expertů. Na počítači totéž s vlastními velikostmi:

```
python tools/expert_cache_sim.py Qwen3-30B-A3B-Instruct-2507-Q4_K_M-20260922-204512.axtr --sizes 0.5 1 1.5 2 3
```

**Předpověď expertů.** Se zapnutým záznamem appka při generování u uzlu `ffn_inp-L` (vstup MoE vrstvy L) vynásobí skrytý stav routerem vrstvy L+1 (`RouterPredictor`). Routery se načtou ze souboru s už složenou RMSNorm vrstvy L+1 a uloží v F16, u Qwen3 ~25 MB a seřazený odhad uloží do záznamu (formát v2). Simulace pak ukáže, kolik potřebných bajtů by předčítání o vrstvu dopředu trefilo a kolik přečetlo zbytečně: pro odhad z routeru (k, k+2, k+4, 2k expertů), pro „experty z minulého tokenu“ a pro jejich sjednocení. Podle odhadu se zatím nic nečte, výsledek má teprve ukázat, jestli se to vyplatí. Sekce **Prefill** ukazuje, jakou část expertů vrstvy vybere dávka promptu. Nad ~30 % by bylo rychlejší přečíst celou vrstvu sekvenčně (≈3,7 GB/s) než vybrané experty po stránkách (≈1,1 GB/s).

**Předčítat podle odhadu** (Parametry › Výkon: vypnuto / k / k+2, výchozí vypnuto). Při generování se z routeru vrstvy L+1 odhadne, které experty vybere, a jejich čtení se ohlásí přes `F_RDADVISE` o vrstvu dřív. Podle záznamů z iPhonu trefí odhad s k experty 81 % expertů chybějících v cache za ~24 % zbytečného čtení. Tok/s porovnávej se záznamem expertů vypnutým.

**Prefill: celá vrstva** (Parametry › Výkon, výchozí vypnuto). Když dávka promptu vybere aspoň 30/50/70 % expertů vrstvy, přečtou se celé tenzory expertů té vrstvy sekvenčně po 8MB blocích přes page cache. Teprve potom jde běžné předčítání vybraných expertů, které už jen namapuje stránky. Záznam z iPhonu ukázal průměrné pokrytí 40 % i u krátkých dávek (20–52 tokenů) a 74 % vrstev nad 30 %. Log enginu po prefillu vypíše, kolik vrstev se četlo celých a jakou rychlostí.

**Rezidence po expertech (záznam v3).** Horní bit čísla experta v záznamu říká, jestli expert ležel v page cache. Simulace pak u předpovědi ukazuje i sloupec **výpadky**, tedy kolik expertů, kteří v cache opravdu chyběli, by odhad načetl dopředu. To je skutečný přínos předčítání. Druhý sloupec **čtení navíc** říká, kolik by odhad přečetl z flash zbytečně. Experti z minulého tokenu vycházejí u výpadků kolem nuly, protože v cache už leží.

Jak číst výsledek: když je LRU daleko pod Belady, páka je v tom, *co* v RAM držet, ne kolik RAM přidat. LRU menší než pracovní sada jednoho tokenu (u Qwen3-30B-A3B ~1 GB) má zásah 0 %: vrstvy se procházejí stále dokola ve stejném pořadí, takže LRU každého experta vyhodí těsně předtím, než ho další token potřebuje.

**CPU, ne GPU.** Měření na iPhonu s 8 GB (Qwen3-30B-A3B Q4_K_M, druhá odpověď): jen CPU se 4 vlákny 3,3 tok/s, CPU + GPU 1,6–1,9 tok/s. Střídání CPU a GPU ve 48 vrstvách na token stojí víc, než GPU ušetří. Streamované MoE proto běží jen na CPU bez ohledu na GPU vrstvy; GPU jde zapnout pro pokusy (**GPU pro hustou část MoE**), a to jen u přeuspořádaného souboru.

**Přebalení husté části** (**Rychlá jádra pro hustou část**). llama.cpp umí váhy přebalit pro rychlejší ARM jádra (buffer `CPU_REPACK`, i8mm/dotprod), automaticky by ale přebalil i experty – 17 GB do paměti. Appka proto automatický výběr vypíná (`use_extra_bufts = false`) a přes `tensor_buft_overrides` pošle do `CPU_REPACK` jen jednotlivé matice attention a `output.weight`, u kterých repack jádro existuje (podmínky zrcadlí `ggml_repack_get_optimal_repack_type`). Experti zůstanou v mmapu. Stojí zhruba velikost husté části v RAM.

**Optimalizovaný llama.cpp.** Oficiální XCFramework se pro iOS překládá bez `-march`, takže cílí na nejstarší arm64 bez instrukcí dotprod a i8mm – kvantizované násobení (experti i hustá část) jede přes pomalejší obecná NEON jádra a přebalení husté části není k dispozici. Workflow **llama.cpp XCFramework (optimalizovaný)** (`.github/workflows/llama-xcframework.yml`, spouští se ručně) přeloží stejnou verzi s `GGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm` a nahraje ji jako Release `llama-cpu-opt-blas-on`, resp. `llama-cpu-opt-blas-off` (volba *obojí* přeloží obě varianty naráz). Build IPA si vybranou variantu stáhne sám a `Packages/LlamaCpp/Package.swift` použije lokální `llama.xcframework` místo oficiálního. Build vyžaduje Apple A15 a novější (iPhone 13+); na starším iPhonu by appka spadla. Jestli běží optimalizovaná verze, ukáže Log enginu po načtení modelu („llama.cpp CPU: dotprod ano · i8mm ano“).

Zapíná se v **Parametrech › Výkon › Experty MoE z úložiště** (výchozí zapnuto, jen s GPU). Model se pozná podle obsahu souboru (`GGUFLayout`), ne podle názvu. V sekci Paměť je pak vidět, kolik je v RAM a kolik na úložišti; v Konzoli (`subsystem:cz.aichat category:gguf`) se při načtení vypíše totéž.

Při stahování se MoE poznají podle názvu (`…-A3B…`) a místo RAM se u nich hlídá hlavně volné místo – stahování se nespustí, když se soubor nevejde na úložiště.

## Struktura
```
AIChat/
  App/          AIChatApp – vstupní bod, SwiftData kontejner
  Models/       Conversation, ChatMessage (SwiftData), Attachment + AttachmentStore, AIProvider, SettingsStore
  Providers/    ChatProvider (protokol), ClaudeProvider, GeminiProvider,
                AppleIntelligenceProvider, LlamaProvider + LlamaEngine (actor),
                MLXProvider + MLXEngine (actor), ThinkTagParser
  Services/     ChatViewModel, ModelManager (katalog, import, mazání),
                RetrievalPipeline (hledání v podkladech), DocumentIndex (BM25),
                ConversationSearch (fulltext nad historií), SummaryPipeline,
                DownloadManager (stahování na pozadí), HuggingFaceAPI, KeychainHelper,
                AttachmentLoader (text, PDF, OCR), OfficeText (docx/xlsx/pptx),
                CloudLimits (limity modelů a tarifu Claude/Gemini)
  Views/        RootView, ChatBottomBar, ChatView, HistoryView, SettingsView,
                LocalModelsView, ModelDownloadView (+ HFModelDetailView),
                DownloadJobRow, AttachmentViews, LocalModelSettingsView, CloudProviderView
Packages/LlamaCpp   binaryTarget na llama.cpp XCFramework
```
Projekt používá `PBXFileSystemSynchronizedRootGroup` – nový `.swift` soubor stačí zkopírovat do složky `AIChat/`.

## Poznámky
- **Modely** leží v `Documents/Models` (vyloučeno ze zálohy iCloud). Díky `UIFileSharingEnabled` je složka vidět v aplikaci Soubory i ve Finderu – GGUF tam můžeš nahrát i ručně.
- **Limity Claude a Gemini podle tarifu** (`CloudLimits.swift`). Okno a max. délka odpovědi modelu se načtou z Models API (Claude `max_input_tokens` / `max_tokens`, Gemini `inputTokenLimit` / `outputTokenLimit`, jednou za týden). Limity tarifu za minutu Claude posílá v hlavičkách `anthropic-ratelimit-*` každé odpovědi; Gemini je prozradí jen v chybě 429 (`QuotaFailure` s `quotaId` …`-FreeTier` a `quotaValue`).
  - Z toho se před každým požadavkem spočítá plán: max. odpověď nepřesáhne limit modelu, prompt se vejde do okna a (s volbou *Přizpůsobit tarifu*) i do 90 % limitu vstupních tokenů za minutu – větší požadavek by tarif odmítl vždy.
  - Když se nevejde, textové přílohy se zkrátí a nejstarší výměny vynechají. Když 429 přijde kvůli velikosti promptu, požadavek se jednou zopakuje už se zjištěným limitem.
  - **Tarif se dá vybrat ručně** (Nastavení › Claude / Gemini › Tarif): Claude Evaluation / Start / Build / Scale / Custom s limity podle tabulky Anthropic po rodinách modelů (`CloudTiers.swift`), Gemini Free / Tier 1–3. Google limity po modelech už nezveřejňuje (jen v AI Studiu), proto jsou u Gemini orientační a jde zadat přesný „Vlastní limit vstupu“. Platí nižší z hodnoty tarifu a hodnoty zjištěné z API; změna tarifu zjištěné hodnoty vymaže.
  - Odhad znaků na token: Claude 2,0 (Claude 5 má nový tokenizér s ~30 % tokenů navíc), Gemini 2,5.
  - Přehled je v Nastavení › Claude / Gemini › Limity a parametry, ukazatel kontextu v chatu počítá se stejným oknem.
- **Ukládání chatů.** Konverzace se uloží hned po odeslání otázky, rozepsaná odpověď každé 3 s a při odchodu z appky – dřív se ukládalo až po dokončení odpovědi, takže při ukončení appky (paměť, pozadí) chat zmizel. Smazání v Historii vyžaduje klepnutí na tlačítko (bez „full swipe“). Když se databázi nepodaří otevřít, appka to ukáže a původní soubor nechá beze změny.
- **Výběr souborů** (přílohy i vlastní model) jde přes `UIDocumentPickerViewController` místo SwiftUI `.fileImporter` – ten se ve více místech appky navzájem rušil a u MLX importu ztrácel druh modelu. Přílohy se berou jako kopie (funguje i iCloud bez staženého souboru), modely se kopírují koordinovaně přes `NSFileCoordinator`.
- **Klávesnice** ve formulářích Nastavení má tlačítko Hotovo (víceřádkový systémový prompt Return nezavře); v chatu ji schová klepnutí mimo pole nebo tažení dolů.
- **Režimy podle úkolu** (`TaskProfile.swift`). Parametry vzorkování se u lokálních modelů mění podle toho, co po modelu chceš:

  | Režim | Teplota | Top-P | Min-P | Top-K | Opakování |
  |---|---|---|---|---|---|
  | Extrakce dat | 0,20 | 0,90 | 0,05 | 40 | 1,08 |
  | Shrnutí | 0,30 | 0,90 | 0,05 | 40 | 1,05 |
  | Běžný chat | 0,70 | 0,90 | 0,05 | 40 | 1,10 |

  Výchozí je *Automaticky* a vyhodnocuje se **každá zpráva zvlášť, i uprostřed chatu**: „vytáhni / najdi / kolik / částka / faktura“ → extrakce, „shrň / souhrn / stručně / o čem je“ → shrnutí, tvůrčí zadání („vymysli“, „co si myslíš“) → chat, nová příloha nebo **dlouhý vložený text** (od 1 200 znaků) bez zadání → shrnutí. Porovnávají se kmeny slov na začátku slova, ne celé tvary – čeština skloňuje („souhrn“, „shrnutí“, „stručný“ musí zabrat stejně), a prefixové porovnání zabrání falešným shodám („scéna“ vs. „cena“). Navazující dotaz bez klíčových slov v chatu, kde už je příloha nebo dlouhý vložený text, zůstane u režimu předchozí odpovědi (uložen v `ChatMessage.profileRaw`, takže platí i po otevření z historie). Detekce ignoruje diakritiku a rozumí i anglicky. Režim jde zafixovat v Parametrech generování, kde se dá každý z nich i doladit. Co právě platí, ukáže detail ukazatele kontextu v chatu.
- **Zúžené shrnutí.** Když zadání míří na konkrétní věc uvnitř kapitoly („shrň, co Item 1A říká o exportních omezeních“), `SummaryPipeline` kapitolu neprojde celou, ale vybere z ní pasáže k zadání – jednotky sekund místo desítek průchodů. Práh jsou dvě obsahová slova v zadání (slova jako „shrň“, „item“ nebo číslo kapitoly se nepočítají) a dvě nalezené pasáže; jinak se kapitola projde poctivě celá. Zúžení se hlásí ve stavu odpovědi včetně toho, kolik znaků z kapitoly model dostal, a vybrané pasáže jsou pod odpovědí v **Podkladech**.
  - Když se nic netrefí, sáhne se po `QueryExpansion` (viz níže) a hledá se znovu; teprve pak se kapitola projde celá.
- **Dotaz v jiném jazyce než podklad** (`QueryExpansion.swift`). Hledá se na slovech, takže česky položený dotaz nad anglickou výroční zprávou nenajde nic – „závislost“ nepotká „dependence“. Když běžné hledání selže, model dostane úryvek podkladu a dotaz a vypíše nejvýš šest klíčových slov **v jazyce dokumentu**; hledá se s nimi znovu. Čtení odpovědi se utne na prvním řádku (menší modely pod seznam rády přidají vysvětlení), takže je to jeden krátký průchod, ne plná odpověď. Použitá klíčová slova se ukážou ve stavu. U dotazu ve stejném jazyce jako podklad se nic z toho nespustí.
- **Co se u dlouhé přílohy hlásí.** Varování v poli zprávy netvrdí, že model „uvidí jen začátek“ – příloha, která se nevejde do kontextu, se neořízne: v režimu *Shrnutí* se zpracuje po částech, jinak se v ní vyhledají pasáže k dotazu, a varování to podle režimu rozliší. Na konci vícekolového shrnutí přibude do stavu řádek s počtem průchodů a celkovým počtem tokenů: ukazatel kontextu vpravo nahoře ukazuje jen poslední průchod, takže po deseti kolech vypadá skoro prázdný, i když se přečetl celý dokument.
- **Pokyn o chybějících kapitolách** se do promptu posledního kola přidá, jen když uživatel opravdu vyžádal kapitolu, která v dokumentu není. Napevno zapsaná podmínka („když zadání zmiňuje kapitolu, která tu není, uveď to“) je pro 4B model příliš – splnil ji naprázdno a k odpovědi připsal, že nenašel kapitolu, o kterou nikdo nežádal.
- **Délka odpovědi u shrnutí.** Poslední, streamované kolo `SummaryPipeline` má vlastní strop 1 536 tokenů (platí nižší z něj a nastavené *Max. délky odpovědi*). Nastavená hodnota je pro konverzaci, kde delší odpovědi dávají smysl; shrnutí je z principu kratší než podklad a na lokálním modelu je psaní odpovědi při 12–20 tokenech za sekundu často dražší než zpracování celého dokumentu – u kapitoly, která se vejde do jednoho průchodu, dělalo 4 096 tokenů většinu z pěti minut čekání. Stejný strop se bere i jako rezerva při rozhodování, jestli se vůbec dělit.
- **Dělení na kapitoly** (`DocumentSections.swift`) – tři opravy ověřené na 10-K NVDA (1,9 MB HTML → 361 tis. znaků textu): název kapitoly smí mít 120 znaků místo 80 (`Item 7. Management's Discussion and Analysis…` má za číslem 85 a bez toho se celý MD&A připojil k předchozí kapitole), další hlavička se hledá už 40 znaků za předchozí místo 200 (`Item 1C. Cybersecurity` začíná 42 znaků za hlavičkou `Item 1B`) a obsah se rozpoznává jen v první čtvrtině dokumentu (kapitoly části III jsou samé krátké odkazy na proxy statement a jinak by celý dokument vyšel jako obsah). Práh nejkratší kapitoly je 40 znaků, aby přežily i kapitoly, jejichž celý obsah je „None.“. Výsledek: 23 kapitol místo 15, všechny se správným názvem.
- **Hledání v podkladech** (`RetrievalPipeline.swift`). Dotaz do přílohy, která se do kontextu nevejde, se dřív zodpovídal z oříznutého začátku dokumentu. Teď se v příloze hledá a modelu se pošlou jen pasáže k dotazu.
  - Dokument se rozdělí na kapitoly (`DocumentSections`) a ty na kusy; hledá se **BM25 nad kmeny slov** (`DocumentIndex.swift`). Diakritika se ignoruje a slovo se krátí na šest znaků, takže „faktura“, „faktury“ i „fakturu“ je jeden klíč; čísla se nekrátí, ať se nesloučí „2024“ a „2025“. Žádné embeddingy – druhý model by v paměti konkuroval tomu, co odpovídá.
  - **Tabulky** (xlsx, CSV) se dělí po řádcích a popisek listu s hlavičkou se opakují v každém kusu. Sešit se dělí po listech.
  - Modelu jde osnova dokumentu, číslované úryvky a pokyn odpovídat jen z nich a citovat `[2]`. Úryvky se ukládají ke zprávě a v odpovědi jdou rozbalit (**Podklady**) – i po otevření chatu z historie.
  - Když v úryvcích odpověď není, model má napsat jediný řádek `HLEDEJ: klíčová slova`. Pipeline to zachytí ještě před vypsáním, vyhledá znovu a pustí druhé kolo; uživatel vidí jen řádek ve stavu. Úmyslně ne JSON – prefix trefí i 4B model.
  - **Historie chatů** (`ConversationSearch.swift`) se prohledá u dotazů typu „co jsme řešili minulý týden kolem faktury“, a to jen v chatu bez příloh. Slova, kterými se člověk ptá na minulost, se z dotazu vyhodí (jinak by hledal hlavně „minul“ a „tyden“); „včera“, „minulý týden“, „v červnu“ nebo „2025“ zúží dotaz do databáze na dané období. Běží to jako `@ModelActor`, mimo kontext UI.
  - Zapíná se jen u lokálních modelů a Apple Intelligence, v režimech *Extrakce* a *Chat*. *Shrnutí* si bere `SummaryPipeline` (to musí projít celý dokument), cloudové modely mají okno na celý text a nezabalují se vůbec.
- **Parametry lokálního modelu:** systémový prompt, teplota, Top-P, Min-P, Top-K, penalizace opakování, max. délka odpovědi, délka kontextu, GPU vrstvy, vlákna CPU, seed. Systémový prompt, teplota a délka platí i pro Apple Intelligence.
- **Stahování na pozadí:** background `URLSession` – pokračuje i se zavřenou appkou. Úlohy jsou uložené v `Application Support/downloads.json`, rozstahované soubory ve skryté `Models/.downloads/<id>`. Po znovuspuštění `reconcile()` převezme hotové soubory a znovu zařadí, co systém zahodil. Když stahování doběhne se zavřenou appkou, systém ji probudí (`AppDelegate.handleEventsForBackgroundURLSession`) a model se rovnou nainstaluje. Neúspěšné stahování jde zkusit znovu (dotáhne jen chybějící soubory). Mobilní data jsou ve výchozím stavu vypnutá, token Hugging Face je volitelný (jen pro modely s licencí).
- **MLX modely** se stahují soubor po souboru přes Hugging Face API do `Documents/Models/MLX/<org>__<repo>` (config.json, tokenizér, *.jinja, *.safetensors). Nahrát jde i vlastní složku přes Soubory/Finder.
- **Jak se vypíná přemýšlení:**
  - GGUF (llama.cpp): pokud chat šablona modelu zná `<think>`, vloží se na začátek odpovědi prázdný blok přemýšlení (stejně jako `enable_thinking=false` u Qwen 3).
  - MLX: do Jinja šablony se předá `enable_thinking: false`.
  - Claude 5: `thinking: {type: "disabled"}`; Claude 4.6–4.8 bez pole `thinking`; zapnuté = adaptivní přemýšlení se shrnutím. Fable a Mythos přemýšlení vypnout neumí – vypnutím se jen skryje.
  - Gemini 3: `thinkingLevel: minimal` (Pro `low`); Gemini 2.5: `thinkingBudget: 0` (Pro 128).
  - Apple Intelligence přemýšlení nemá, přepínač se u ní neukazuje.
- **Přílohy – co umí:** text a kód v libovolné příponě (UTF-8, UTF-16, Windows-1250, ISO 8859-2), CSV, JSON, RTF, PDF, obrázky a Word/Excel/PowerPoint (docx, xlsx, pptx – vlastní čtečka ZIPu + XMLParser, bez závislostí). Starší .doc/.xls ne. Limit 50 MB na soubor, text se ořízne na 1 mil. znaků.
  - **PDF** se čte po stranách přes PDFKit. Sken bez textové vrstvy projde OCR (Vision, čeština od iOS 18), nejvýš 20 stran.
  - **Obrázky** se uloží jako JPEG s nejdelší stranou 1568 px a projdou OCR.
  - **Claude a Gemini** dostanou obrázky a naskenovaná PDF jako originál (model je vidí), ostatní jako text v bloku `<file name="…">`. Textová PDF jdou jako text – je to několikanásobně levnější.
  - **Lokální modely a Apple Intelligence** dostanou jen text (u obrázků rozpoznaný). Obsah se vejde do kontextu: texty zpráv mají přednost, novější přílohy před staršími, zbytek se zkrátí. llama.cpp po tokenizaci rozpočet doladí podle skutečného počtu tokenů. Když se přílohy nevejdou, pole zprávy na to upozorní – pomůže delší kontext v Parametrech.
  - Metadata a vytažený text jsou ve zprávě (SwiftData, pole `attachmentsData`), originály v `Application Support/Attachments/<id>` (bez zálohy). Smazáním chatu se smažou i ony.
- **Chat šablona** se bere z GGUF souboru (`llama_chat_apply_template`); neznámé šablony spadnou na ChatML. Když se historie nevejde do kontextu, nejstarší výměny se vynechají.
- **API klíče** jsou jen v Klíčence (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- **Teplota u cloudu** jde nastavit jen pro Gemini (ve výchozím stavu vypnutá, Gemini 3 ji doporučuje neměnit). Claude od verze 4.7 teplotu nepřijímá, proto se neposílá.
- **Aktualizace llama.cpp:** v `Packages/LlamaCpp/Package.swift` změň číslo buildu a checksum (`swift package compute-checksum soubor.zip`).
