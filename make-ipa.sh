#!/usr/bin/env bash
#
# Postaví nepodepsanou IPA AI Chatu pro fyzické zařízení.
#
#   ./make-ipa.sh            # Release
#   ./make-ipa.sh Debug      # Debug
#
# Výsledek: AIChat-<verze>-b<číslo>.ipa v kořeni projektu. Podpis řeší až sideload
# (Sideloadly / AltStore / LiveContainer) — tenhle skript nic nepodepisuje,
# takže nepotřebuje účet ani certifikát.
#
# Pozor:
# - Jen pro zařízení. XCFramework llama.cpp nemá slice pro simulátor
#   a MLX potřebuje skutečnou GPU.
# - IPA je jen ad-hoc podepsaná s entitlementy ze Sideload.entitlements
#   (rozšířený limit paměti). SideStore / AltStore si je z podpisu přečtou a při
#   instalaci o ně požádají. Jestli limit opravdu platí, ukáže appka v
#   Nastavení › Parametry generování › Paměť.
# - Síť je potřeba ke stažení modelů z huggingface.co a pro Claude / Gemini.
#   Lokální model i Apple Intelligence běží offline.
# - Modely (jednotky GB), konverzace i API klíče (Klíčenka) jsou vázané na
#   bundle ID. Přeinstalace s jiným bundle ID = prázdná aplikace, modely se
#   stahují znovu a klíče je potřeba vložit znovu.
# - První build stahuje Swift balíčky (mlx-swift-lm, mlx-swift, swift-transformers,
#   llama.cpp XCFramework ~90 MB) do .build/SourcePackages, další už jsou rychlé.

set -euo pipefail

CONFIGURATION="${1:-Release}"
PROJECT="AIChat.xcodeproj"
SCHEME="AIChat"
DERIVED_DATA=".build/DerivedData"
PACKAGES=".build/SourcePackages"

cd "$(dirname "$0")"

# iOS 26 SDK (Liquid Glass, FoundationModels) je jen v Xcode 26+.
XCODE_MAJOR="$(xcodebuild -version | awk 'NR==1 { split($2, v, "."); print v[1] }')"
if [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
  echo "✕ potřeba Xcode 26 nebo novější (máš: $(xcodebuild -version | head -1))" >&2
  exit 1
fi

# MLX kompiluje Metal shadery a od Xcode 26 je Metal toolchain samostatná komponenta.
# (llama.cpp má shadery předkompilované, ten by ho nepotřeboval.)
if ! xcrun metal -v >/dev/null 2>&1; then
  echo "✕ chybí Metal toolchain, nainstaluj ho (~700 MB):" >&2
  echo "    xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

# --- verze -------------------------------------------------------------------
# Číslo buildu je počet commitů: roste monotónně, je stejné na Macu i na CI a dvě
# IPA se stejným číslem jsou opravdu stejný kód. Marketingová verze se bere
# z posledního tagu v*. Nic se nezapisuje do project.pbxproj – hodnoty se předávají
# xcodebuildu jako build settings, takže po buildu není strom změněný a nevznikají
# konflikty při merge.
if git -C . rev-parse --git-dir >/dev/null 2>&1; then
  BUILD_NUMBER="$(git rev-list --count HEAD)"
  GIT_COMMIT="$(git rev-parse --short=7 HEAD)"
  # Plus na konci = stavělo se z rozpracovaných změn, commit tedy nestačí
  # k tomu, aby šel build zreprodukovat.
  git diff --quiet HEAD -- 2>/dev/null || GIT_COMMIT="${GIT_COMMIT}+"
  MARKETING_VERSION="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
  MARKETING_VERSION="${MARKETING_VERSION#v}"
  # Mělký checkout (actions/checkout bez fetch-depth: 0) hlásí jediný commit.
  if [ "$BUILD_NUMBER" = "1" ] && [ -f .git/shallow ]; then
    echo "⚠︎ mělký klon – číslo buildu bude 1; do checkoutu přidej fetch-depth: 0" >&2
  fi
else
  # Bez gitu (stažený ZIP) aspoň časové razítko, ať se dvě IPA rozliší.
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  GIT_COMMIT=""
  MARKETING_VERSION=""
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

VERSION_SETTINGS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
[ -n "$MARKETING_VERSION" ] && VERSION_SETTINGS+=(MARKETING_VERSION="$MARKETING_VERSION")
echo "▸ verze ${MARKETING_VERSION:-(z projektu)} ($BUILD_NUMBER)${GIT_COMMIT:+ · commit $GIT_COMMIT}"

# Varianta llama.cpp do Nastavení › Verze. Na CI ji předá krok „Vybrat llama.cpp“
# (LLAMA_BUILD), lokálně se pozná podle toho, co Package.swift použije.
if [ -z "${LLAMA_BUILD:-}" ]; then
  if [ -d Packages/LlamaCpp/llama.xcframework ]; then
    LLAMA_BUILD="vlastní XCFramework (Packages/LlamaCpp/llama.xcframework)"
  else
    LLAMA_BUILD="$(grep -oE 'download/b[0-9]+' Packages/LlamaCpp/Package.swift | head -1 | cut -d/ -f2) (oficiální)"
  fi
fi
echo "▸ llama.cpp $LLAMA_BUILD"

echo "▸ build $SCHEME ($CONFIGURATION, iphoneos)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  "${VERSION_SETTINGS[@]}" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/$SCHEME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "✕ .app nenalezena v $APP_PATH" >&2
  exit 1
fi

# Ověření, že to opravdu není simulátorový build — ten by na telefonu nenaběhl.
if ! lipo -archs "$APP_PATH/$SCHEME" | grep -q arm64; then
  echo "✕ binárka není arm64 — zkontroluj -sdk iphoneos" >&2
  exit 1
fi

# llama.cpp je dynamický framework. Když v bundlu chybí, aplikace spadne
# hned při startu na dyld chybě, ještě než se cokoli zobrazí.
LLAMA_BINARY="$APP_PATH/Frameworks/llama.framework/llama"
if [ ! -f "$LLAMA_BINARY" ]; then
  echo "✕ v bundlu chybí Frameworks/llama.framework — aplikace by po spuštění spadla" >&2
  exit 1
fi
if ! lipo -archs "$LLAMA_BINARY" | grep -q arm64; then
  echo "✕ llama.framework není arm64" >&2
  exit 1
fi

# MLX načítá zkompilované shadery (default.metallib) z resource bundlu balíčku.
if [ -z "$(find "$APP_PATH" -name '*.metallib' -print -quit)" ]; then
  echo "⚠︎ v bundlu není žádný .metallib — MLX modely nepůjdou načíst (GGUF přes llama.cpp ano)" >&2
fi

# Bez vygenerovaného Info.plist klíče se složka Models neukáže v aplikaci Soubory.
if ! /usr/libexec/PlistBuddy -c "Print :UIFileSharingEnabled" "$APP_PATH/Info.plist" 2>/dev/null | grep -q true; then
  echo "⚠︎ v Info.plist chybí UIFileSharingEnabled — import modelů přes Soubory/Finder nepůjde" >&2
fi

# Nepodepsaná binárka nenese žádné entitlementy, takže sideload nástroj nemá podle čeho
# požádat o rozšířený limit paměti – appka pak dostane jen základní a u delšího textu
# ji iOS ukončí. Ad-hoc podpis je do IPA vloží; SideStore / AltStore si je přečtou
# a při instalaci appku podepíšou znovu, už pro tvůj účet.
# Commit a čas do Info.plist. Musí to být před podpisem – po něm by změna plistu
# podpis rozbila. Xcode tyhle klíče negeneruje, takže v buildu z Xcode chybí
# a appka je prostě neukáže.
plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP_PATH/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$APP_PATH/Info.plist"
}
[ -n "$GIT_COMMIT" ] && plist_set GitCommit "$GIT_COMMIT"
plist_set BuildDate "$BUILD_DATE"
# plutil místo PlistBuddy – hodnota obsahuje mezery a „·“.
plutil -replace LlamaBuild -string "$LLAMA_BUILD" "$APP_PATH/Info.plist"

ENTITLEMENTS="Sideload.entitlements"
echo "▸ ad-hoc podpis s entitlementy ($ENTITLEMENTS)"
if [ -d "$APP_PATH/Frameworks" ]; then
  find "$APP_PATH/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) \
    -exec codesign --force --sign - --timestamp=none {} \;
fi
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP_PATH"
if ! codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | grep -q "increased-memory-limit"; then
  echo "✕ entitlement increased-memory-limit se do podpisu nedostal" >&2
  exit 1
fi

echo "▸ balím IPA"
# Verze v názvu, ať se dvě IPA ve složce Stažené nepřepíšou a bylo poznat, co je co.
# Bez tagu zůstane jen číslo buildu: AIChat-b247.ipa.
IPA="$SCHEME${MARKETING_VERSION:+-$MARKETING_VERSION}-b$BUILD_NUMBER.ipa"
# Starší IPA ze stejného projektu pryč – jinak by se v kořeni hromadily.
rm -rf Payload "$SCHEME.ipa" "$SCHEME"-*.ipa
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -qry "$IPA" Payload
rm -rf Payload

echo "✓ $IPA  ($(du -h "$IPA" | cut -f1))"
# Na GitHub Actions si název převezmou další kroky, ať ho nemusí skládat znovu.
if [ -n "${GITHUB_ENV:-}" ]; then echo "IPA_NAME=$IPA" >> "$GITHUB_ENV"; fi
