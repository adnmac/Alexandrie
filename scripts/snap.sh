#!/bin/zsh
# Captures de chaque page en clair et en sombre, avec les livres d'exemple, sur un dossier de test neuf.
#   scripts/snap.sh                                   toutes les pages et les réglages
#   ALEXANDRIE_SNAPSHOT_PAGES=tous,reglages scripts/snap.sh
#   scripts/snap.sh -gridMode NO                      en liste (arguments passés à l'app)
# Le binaire debug est emballé dans un bundle de test (be.adnmac.alexandrie.snapshot, langue fr) :
# ses réglages (UserDefaults) ne sont pas ceux de l'app installée.
# Il faut l'autorisation Enregistrement de l'écran pour le terminal (ou Claude) qui lance ce script.
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build --show-bin-path "${SWIFT_FLAGS[@]}")/Alexandrie"
STORE=/tmp/alexandrie-snap
SHOTS="${ALEXANDRIE_SNAPSHOT:-/tmp/alexandrie-shots}"
APP=/tmp/alexandrie-snap.app
BUNDLE_ID=be.adnmac.alexandrie.snapshot
rm -rf "$STORE" "$SHOTS" "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Alexandrie"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Alexandrie</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Alexandrie</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string></array>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Après un plantage, macOS proposerait de rouvrir les fenêtres et bloquerait le lancement suivant.
rm -rf ~/Library/Saved\ Application\ State/$BUNDLE_ID.savedState
ALEXANDRIE_STORE="$STORE" ALEXANDRIE_SEED=1 ALEXANDRIE_SNAPSHOT="$SHOTS" "$APP/Contents/MacOS/Alexandrie" -gridMode YES "$@"
