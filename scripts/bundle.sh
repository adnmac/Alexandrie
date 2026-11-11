#!/bin/zsh
# Construit build/Foluna.app (release ; l'exécutable et le code gardent le nom d'origine, Foluna). Signé avec un certificat Apple Development s'il existe,
# sinon « Alexandrie Dev » (identité stable : macOS garde les autorisations d'une version à l'autre), sinon ad hoc.
# Autre certificat : FOLUNA_SIGN_IDENTITY="Nom du certificat" scripts/bundle.sh
# Copie ensuite l'app dans ~/Applications (FOLUNA_INSTALL=0 pour s'en passer).
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
# Valeurs constantes des types App Intents (Metadata.appintents, plus bas), comme Xcode les demande.
PROTOCOLS="$ROOT/scripts/appintents-protocols.json"
CONST_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS")
swift build -c release "${SWIFT_FLAGS[@]}" "${CONST_FLAGS[@]}"
BIN="$(swift build -c release --show-bin-path "${SWIFT_FLAGS[@]}" "${CONST_FLAGS[@]}")/Foluna"
APP="$ROOT/build/Foluna.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Foluna"
# Icône : Assets.car (Liquid Glass, macOS 26+) et AppIcon.icns (macOS 14-15), compilés par scripts/make-icon.sh.
for f in Assets.car AppIcon.icns; do [[ -f "$ROOT/Resources/$f" ]] && cp "$ROOT/Resources/$f" "$APP/Contents/Resources/"; done
# Action Raccourcis « Envoyer à la Kindle » (App Intents) : Raccourcis ne la voit que si le bundle contient
# Metadata.appintents, que Xcode produit d'habitude. On lance le même outil sur les valeurs constantes que
# le compilateur écrit pendant la build release. Sans Xcode : l'app marche, sans l'action Raccourcis.
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
INTENTS_TOOL="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
CONSTS="$ROOT/.build/out/Intermediates.noindex/Foluna.build/Release/Foluna-p.build/Objects-normal/arm64/Foluna-primary.swiftconstvalues"
# La build release passe toujours CONST_FLAGS : chaque recompilation réécrit ces valeurs.
if [[ -x "$INTENTS_TOOL" && -f "$CONSTS" ]]; then
  WORK=$(mktemp -d)
  find "$ROOT/Sources/Foluna" -name '*.swift' > "$WORK/sources.txt"
  echo "$CONSTS" > "$WORK/consts.txt"
  "$INTENTS_TOOL" --output "$APP/Contents/Resources" \
    --toolchain-dir "$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain" --module-name Foluna \
    --sdk-root "$(DEVELOPER_DIR=$XCODE_DEV xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(DEVELOPER_DIR=$XCODE_DEV xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
    --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/consts.txt" --quiet-warnings 2>/dev/null
  rm -rf "$WORK"
fi
if [[ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
  echo "🧩 action Raccourcis « Envoyer à la liseuse »"
else
  echo "⚠️  pas de Metadata.appintents (Xcode absent ?) : l'action Raccourcis ne sera pas proposée"
fi
# Traductions de l'interface (Resources/Localizable.xcstrings) et des autorisations (InfoPlist.xcstrings).
scripts/l10n.sh compile "$APP/Contents/Resources"
LOCALIZATIONS=""
for l in $(scripts/l10n.sh languages); do LOCALIZATIONS+="<string>$l</string>"; done
# Commit compilé : l'app le compare à GitHub pour signaler les mises à jour.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Foluna</string>
  <key>CFBundleDisplayName</key><string>Foluna</string>
  <key>CFBundleIdentifier</key><string>be.adnmac.alexandrie</string>
  <key>CFBundleExecutable</key><string>Foluna</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>FolunaCommit</key><string>${COMMIT}</string>
  <!-- Adresse qui reçoit les rapports de plantage que l'utilisateur choisit d'envoyer (info@foluna.app par défaut ; vide : Finder seulement). -->
  <key>FolunaSupportEmail</key><string>${FOLUNA_SUPPORT_EMAIL:-info@foluna.app}</string>
  <!-- Explications des autorisations demandées par macOS (audit, § 3). -->
  <key>NSRemovableVolumesUsageDescription</key><string>Foluna envoie vos livres à votre liseuse et lit ses notes et surlignages quand elle est branchée.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Foluna lit les livres de votre bibliothèque rangés dans Documents, sans les modifier.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Foluna lit les livres de votre bibliothèque rangés sur le Bureau, sans les modifier.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Foluna lit les livres de votre bibliothèque rangés dans Téléchargements, sans les modifier.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Foluna lit les livres de votre bibliothèque rangés sur un volume réseau, sans les modifier.</string>
</dict>
</plist>
PLIST
# Signature : un certificat Apple Development (gratuit, créé par Xcode > Réglages > Comptes) en priorité.
# Raccourcis n'exécute l'action que si la signature porte un team ID : « Alexandrie Dev » n'en a pas
# (linkd refuse alors la connexion de l'app, voir docs/FIXLOG.md).
APPLE_DEV="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: /{print $2; exit}')"
IDENTITY="${FOLUNA_SIGN_IDENTITY:-${APPLE_DEV:-Alexandrie Dev}}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "🔏 signé avec « $IDENTITY »"
  [[ "$IDENTITY" == "Apple Development: "* ]] || echo "⚠️  signature sans team ID : l'action Raccourcis apparaît mais ne s'exécute pas"
else
  codesign --force --sign - "$APP"
  echo "⚠️  certificat « $IDENTITY » introuvable : signature ad hoc (macOS peut redemander ses autorisations à chaque version)"
fi
echo "✅ $APP"
# Copie dans ~/Applications : Raccourcis et le Finder trouvent une seule Foluna, toujours à jour.
# Une ancienne copie nommée Alexandrie.app est retirée.
# La copie de build/ est retirée de LaunchServices. FOLUNA_INSTALL=0 garde seulement build/.
if [[ "${FOLUNA_INSTALL:-1}" != 0 ]]; then
  DEST="$HOME/Applications/Foluna.app"
  LEGACY="$HOME/Applications/Alexandrie.app"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  if pgrep -f "$DEST/Contents/MacOS/" >/dev/null || pgrep -f "$LEGACY/Contents/MacOS/" >/dev/null; then
    echo "⚠️  Foluna est ouverte : quittez-la puis relancez scripts/bundle.sh pour mettre à jour $DEST"
  else
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    if [[ -d "$LEGACY" ]]; then
      "$LSREGISTER" -u "$LEGACY" 2>/dev/null || true
      rm -rf "$LEGACY"
      echo "🧹 ancienne copie $LEGACY retirée"
    fi
    ditto "$APP" "$DEST"
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    "$LSREGISTER" -f "$DEST"
    echo "📦 installé dans $DEST"
  fi
fi
