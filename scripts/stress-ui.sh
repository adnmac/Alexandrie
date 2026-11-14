#!/bin/zsh
# Interface sur une grosse bibliothèque : ouvre l'app (bundle de test) sur une copie du store indexé
# par scripts/stress.sh, visite les pages, la liste, une fiche et la recherche, note les blocages du
# thread principal, écrit /tmp/foluna-stress/interface-<n>.md et quitte.
#   scripts/stress.sh 10000 && scripts/stress-ui.sh 10000
#   FOLUNA_STRESS_UI_FRESH=1 scripts/stress-ui.sh 10000    # première indexation, fenêtre ouverte (index vide)
#   FOLUNA_STRESS_UI_GRID=NO scripts/stress-ui.sh 10000    # ouvre en liste plutôt qu'en grille
#   FOLUNA_STRESS_UI_MANUAL=1 scripts/stress-ui.sh 10000   # sans visite automatique : à vous de cliquer,
#                                                          # les blocages > 250 ms s'écrivent dans le terminal
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"

N="${1:?usage : scripts/stress-ui.sh <nombre de livres>}"
OUT=/tmp/foluna-stress
SOURCE="$OUT/store-$N"
STORE="$OUT/ui-$N"
[[ -f "$SOURCE/library.json" ]] || { echo "Pas de store indexé dans $SOURCE : lancer d'abord scripts/stress.sh $N" >&2; exit 1; }

swift build -c release "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release "${SWIFT_FLAGS[@]}" --show-bin-path)/Foluna"
APP=/tmp/foluna-stress-ui.app
BUNDLE_ID=be.adnmac.alexandrie.snapshot
rm -rf "$STORE" "$APP"
cp -R "$SOURCE" "$STORE"
# Première indexation, fenêtre ouverte : on garde la liste des dossiers, pas l'index ni ce qui en découle.
if [[ -n "$FOLUNA_STRESS_UI_FRESH" ]]; then
  rm -rf "$STORE/library.json" "$STORE/Covers" "$STORE/Sauvegardes" "$STORE/Texte" "$STORE/Recherche"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Foluna"
for f in Assets.car AppIcon.icns; do [[ -f Resources/$f ]] && cp Resources/$f "$APP/Contents/Resources/"; done
scripts/l10n.sh compile "$APP/Contents/Resources" >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Foluna</string>
  <key>CFBundleShortVersionString</key><string>$(cat VERSION)</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Foluna</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
rm -rf ~/Library/Saved\ Application\ State/$BUNDLE_ID.savedState
# Présentation au lancement, par le réglage du bundle de test (un argument -gridMode l'emporterait sur tout
# changement fait dans l'app) : grille par défaut, liste avec FOLUNA_STRESS_UI_GRID=NO.
defaults write "$BUNDLE_ID" gridMode -bool "${FOLUNA_STRESS_UI_GRID:-YES}"
UI_DIR="$OUT"; [[ -n "$FOLUNA_STRESS_UI_MANUAL" ]] && UI_DIR=""
FOLUNA_STORE="$STORE" FOLUNA_HANGLOG=1 FOLUNA_STRESS_UI="$UI_DIR" "$APP/Contents/MacOS/Foluna" -AppleLanguages "(fr)"
