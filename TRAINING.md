# Trénink LoRA adaptéru na zařízení

Doplněk k AIChat. Lokální MLX model se dá doladit LoRA adaptérem z vlastních dat,
kde opravené odpovědi vytvoří Claude nebo Gemini jako „učitel“.

## Jak to použít

1. **Nastavení › Trénink (LoRA)** – obrazovka pracuje vždy s modelem, který je vybraný jako lokální.
2. **Sesbírat z historie** – vybereš odpovědi lokálního modelu z chatů, učitel je ohodnotí
   (0–10) a napíše, jak měly vypadat. Jeden požadavek na API za odpověď.
3. **Procházet vzorky** – co nechceš trénovat, odškrtneš nebo smažeš.
4. **Spustit trénink** – potřeba aspoň 8 schválených vzorků. Appka musí zůstat v popředí.
5. **Používat adaptér** – přepínač v sekci Adaptér. Projeví se při příštím načtení modelu.

## Co přibylo

| Soubor | Co dělá |
|---|---|
| `Models/TrainingSample.swift` | SwiftData model vzorku + `Sendable` kopie pro actor |
| `Services/AdapterStore.swift` | Cesty k adaptérům (`Documents/Adapters/<model>/`) a přepínač použití |
| `Services/TeacherCapture.swift` | Instrukce pro učitele a čtení jeho JSON odpovědi |
| `Services/TrainingDataset.swift` | Převod vzorků na texty pro `LoRATrain` přes chat šablonu |
| `Services/LoRATrainer.swift` | Vlastní trénink (actor), průběh pro UI, ukládání adaptéru |
| `Views/TrainingView.swift` | Obrazovka Trénink, seznam vzorků, sběr učitelem |
| `Services/HuggingFaceDataset.swift` | Čtení datasetů z HF přes Dataset Viewer API, mapování sloupců, JSONL |
| `Views/DatasetImportView.swift` | Obrazovka pro import datasetu |

Změněné soubory: `AIChatApp.swift` (schéma SwiftData), `SettingsView.swift` (odkaz),
`MLXProvider.swift` (načtení adaptéru při generování), `project.pbxproj`
(přibyly produkty `MLXNN` a `MLXOptimizers` z `mlx-swift` – bez nich se to nepřeloží).

Trénink jede přes `LoRATrain` z `mlx-swift-lm`, který už v projektu je. U kvantovaného
modelu vzniknou `QLoRALinear` vrstvy, takže 4bitový základ zůstává a v paměti přibudou
jen LoRA váhy.

## Import datasetů

Vedle sběru učitelem jdou vzorky načíst hotové – tlačítkem **Načíst dataset**:

- **Z Hugging Face.** Čte se přes `datasets-server.huggingface.co`, endpointy `/splits`
  a `/rows`. Nestahuje se celý dataset, jen tolik řádků, kolik nastavíš (strop 100 na
  požadavek, stránkuje se). Parquet soubory by znamenaly vlastní parser, tahle cesta ho
  nepotřebuje. Gated datasety fungují s tokenem z Nastavení › Stahování.
- **Ze souboru.** JSONL (jeden objekt na řádek) i klasické JSON pole, ve kterém se šíří
  většina alpaca datasetů. Tvary `instruction`/`input`/`output`, `prompt`/`response`,
  `question`/`answer` a `messages`. Kódování UTF-8, se záložním čtením Windows-1250.

  Přípona `.jsonl` nemá v systému registrovaný typ, takže ho výběr souborů někdy nenabídne.
  Proto je vedle výběru i seznam souborů nahraných do složky aplikace v Souborech – tam
  soubor jen přetáhneš a načteš ho odsud.

Sloupce se odhadnou podle názvů (`instruction`, `output`, `messages`, ShareGPT `from`/`value`)
a dají se přepsat ručně; pod výběrem se ukazuje první složená dvojice, aby bylo vidět,
jestli mapování sedí. Filtr „jen česky vypadající“ počítá podíl znaků s diakritikou –
odchytí nepřeložené řádky ve strojově přeložených datasetech, ale slovenštinu od češtiny
nepozná.

Zadání, která už v datasetu jsou, se přeskočí, takže opakovaný import nevytvoří duplicity.

### Výběr řádků z Hugging Face

Kolekce poskládané z více zdrojů bývají seřazené podle zdroje – třeba
`ctu-aic/cs_instruction_tuning_collection` má na začátku 50 tisíc řádků přeložené Alpacy
a nativní otázky z jazykové poradny ÚJČ až kolem řádku 90 000. Proto sekce **Výběr řádků**:

- **Po sobě / Začít od řádku** – čte se od zadaného řádku dál.
- **Náhodně** – bloky po 20 řádcích z náhodných míst celého splitu (nebo výběru s filtrem),
  uvnitř bloku se řádky zamíchají. Jeden požadavek na blok, takže import trvá déle.
- **Filtr** – sloupce s malým počtem hodnot podle endpointu `/statistics` (typicky `origin`),
  hodnoty se nabízí i s počty řádků. Filtr se vyhodnocuje v aplikaci: endpoint `/filter`
  u tohohle datasetu vracel 500 nebo nestihl odpovědět. Místo toho se čtením po jednom řádku
  najde úsek, kde hodnota leží (sonda každých `počet / 2` řádků, pak binárně oba okraje, zhruba
  45 požadavků), a import čte jen z něj. Když řádky pohromadě nejsou, filtruje se až při čtení
  a import se zastaví po 300 požadavcích.
  Statistiky nemají všechny datasety; když chybí, filtr se prostě nenabídne.

## Rozhodnutí, která stojí za vysvětlení

**Trenér si model načítá vlastní, ne ten z `MLXEngine`.** Trénink model mění na místě
a drží k němu gradienty. Sdílet ho s chatem by znamenalo buď poškozené sezení, nebo dvě
kopie vah v paměti. Před startem se proto oba chatovací enginy uvolní.

**Výchozí dávka je 1, ne 4.** `LoRABatchIterator` zarovnává vzorky v dávce na ten nejdelší,
takže jeden dlouhý vzorek nafoukne celou dávku. Na telefonu je to největší zdroj překvapení.

**Šablona se aplikuje jen na prompt, odpověď se připojí za ni.** Kdyby šablona dostala
celou konverzaci, přidala by za odpověď ještě prázdnou hlavičku asistenta
(`add_generation_prompt`) a model by se učil na tvaru, který při generování nikdy neuvidí.

**Kontrola paměti běží i během tréninku.** Po každém kroku se čte `os_proc_available_memory()`
a pod `MemoryBudget.reserve` se trénink ukončí – lepší než jetsam uprostřed běhu.

**Adaptér je součástí identity načteného modelu.** `loadedPath` v `MLXEngine` obsahuje i cestu
k adaptéru, takže zapnutí nebo vypnutí vynutí nové načtení.

## Co jsem neudělal a proč

- **Ztráta se počítá i z promptu.** `LoRATrain.loss` maskuje jen podle délky vzorku, hranici
  mezi zadáním a odpovědí nezná, a `LoRABatchIterator` je v balíčku `internal`. Maskovat
  jen odpověď by znamenalo napsat si vlastní dávkování a vlastní trénovací smyčku. Na
  doladění stylu to nevadí, na učení faktů by vadilo víc.
- **Navázání na přerušený běh chybí.** Checkpoint obsahuje jen váhy adaptéru. Novější
  `mlx-swift-lm` má v `LoRATrain.Parameters` pole `completedIterations`, ale ve verzi
  3.31.4, na které je projekt, ještě není — zastavený trénink se dá jen spustit znovu.
- **Vzorek nese jen poslední dotaz a odpověď**, ne celou konverzaci ani přílohy.
- **`fuse` se nikde nepoužívá** – u kvantovaného základu bych to nechal být.
- **Vyhodnocení „před a po“ v UI chybí.** Validační ztráta je v sekci Adaptér, ale porovnání
  odpovědí se zapnutým a vypnutým adaptérem na vlastních dotazech je pořád na tobě. Je to
  jediný způsob, jak poznat, že sis model nezhoršil.

## Které modely natrénovat nejdou

**Qwen3.5 a Qwen3.8 ne.** Jejich dekodér obsahuje `Qwen35SparseMoeBlock` se `SwitchGLU`
(směs expertů) a na části vrstev `Qwen35GatedDeltaNet` (lineární pozornost). Přes obojí
projde dopředný průchod – proto chat funguje bez potíží – ale zpětný ne: experty se
u kvantovaného modelu počítají přes `gather_qmm`, ke kterému MLX nemá definovaný gradient.
Výsledkem je výjimka z C++ vrstvy, kterou Swift neodchytí, takže proces prostě skončí
bez chybové hlášky.

Aplikace to teď pozná dvakrát: z `config.json` (klíče `num_experts`, `layer_types` a spol.)
ještě před načtením vah, a po načtení podle skutečných modulů modelu. V obou případech
místo pádu přijde hláška a tlačítka jsou vypnutá.

**Trénovat jde hustý model s běžnou pozorností** – Qwen3-4B-4bit, Llama, Gemma bez MoE.
Adaptér je stejně vázaný na konkrétní model, takže se s ním musí i používat.

## Proč to spadne na paměti a co s tím

První pokus o trénink shodil aplikaci ještě před první iterací, přestože ukazatel
hlásil přes 4 GB volných. Příčina není v LoRA vahách ani v aktivacích, ale v logitech.

`LoRATrain.loss` spočítá výstup modelu pro **každou pozici přes celý slovník** a převede
ho na float32. Qwen3 má slovník 151 936 položek, takže při 640 tokenech má jedno takové
pole 371 MB – a vedle sebe leží původní bf16 verze, float32 kopie a mezivýsledky křížové
entropie, které si autodiff drží až do konce zpětného průchodu. Přes gigabajt, který
vznikne během jediného kroku, k tomu 2,4 GB vah. Systém proces ukončí dřív, než se
stihne ohlásit první iterace, takže kontrola paměti mezi kroky nemá šanci zasáhnout.

Z toho plyne, co se s tím dá dělat:

- **Délka vzorku je ten parametr, na kterém všechno visí** – paměť roste přímo úměrně
  s ní. Výchozí hodnota je teď 256 tokenů místo 640, nabídka končí na 512.
- **Odhad špičky** se počítá z `vocab_size` v `config.json` a velikosti safetensorů
  a ukazuje se nad tlačítkem. Když přesáhne volnou paměť, trénink se nespustí a řekne proč.
- **`Memory.memoryLimit`** se nastaví pod jetsam limit, takže MLX při jeho překročení
  počká na rozpracované výpočty místo aby alokoval dál.
- **Zkušební krok** pustí jedinou iteraci nad nejkratším vzorkem a nahlásí skutečnou
  špičku. Když projde, projde i celý běh – špička je u každého kroku stejná.
- **Fáze běhu se ukládá na disk.** Po ukončení systémem nezůstane výjimka ani záznam,
  tohle je jediná stopa, která pád přežije; po startu se ukáže, kde to skončilo.

Co se opravit nedá bez vlastní trénovací smyčky: logity nad celým slovníkem se počítají
uvnitř `LoRATrain.loss` a nejdou dávkovat po částech slovníku.

## Závislost na verzi balíčku

Kód je psaný proti **mlx-swift-lm 3.31.4**, tedy té, kterou má CI vyřešenou. Mezi 3.31.4
a `main` se API liší ve dvou místech, na která jsem narazil při prvním buildu:

- `LoRAConfiguration.LoRAParameters` nemá ve 3.31.4 parametr `dropout` (na `main` ano).
- `LoRATrain.Parameters` nemá ve 3.31.4 `completedIterations`.

Balíčky mají v projektu rozsah „do další major verze“, takže po aktualizaci na novější 3.x
tyhle dva parametry přibudou — nic se tím nerozbije, jen by se dal dropout doplnit.
Commitnutý `Package.resolved` je tady důležitější než obvykle.

## Než to pustíš

Kód jsem nepřeložil lokálně – nemám tu Xcode ani Metal toolchain. První kolo na CI odhalilo
tři chyby (chybějící `import Tokenizers`, který potřebuje makro `#huggingFaceTokenizerLoader`,
`dropout` navíc a přístup k `TrainingRuntime.shared` z actoru bez `await`), všechny jsou opravené.

První běh doporučuju malý: 20 vzorků, 40 iterací, 4 vrstvy, rank 8. Podívej se v Konzoli
na `subsystem:cz.aichat category:lora`, kolik zabere jedna iterace a kdy začne throttling.
Podle toho teprve nastav delší běh.
