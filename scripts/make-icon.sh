#!/bin/zsh
# Compile Icon/AppIcon.icon (fichier Icon Composer) avec actool :
#   Resources/Assets.car    icône Liquid Glass (clair, sombre, teinté, transparent), macOS 26 et plus
#   Resources/AppIcon.icns  icône plate pour macOS 14 et 15 et les vues du Finder qui lisent le .icns
# Les deux fichiers sont versionnés : bundle.sh et la CI n'ont pas besoin de Xcode.
# Il faut Xcode (pas seulement les Command Line Tools) et sa licence acceptée.
set -euo pipefail
ROOT="${0:A:h:h}"
icon="$ROOT/Icon/AppIcon.icon"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$ROOT/Resources"
# actool échoue sur un calque manquant : il sert aussi de validateur. Le dossier doit s'appeler
# AppIcon.icon (comme --app-icon), sinon actool n'écrit rien et sort quand même avec 0.
xcrun actool "$icon" --compile "$work" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$work/partial.plist" \
  --output-format human-readable-text --errors --warnings >"$work/log" 2>&1 || { cat "$work/log"; exit 1; }
[[ -f "$work/Assets.car" && -f "$work/AppIcon.icns" ]] || { cat "$work/log"; echo "actool n'a écrit aucune icône"; exit 1; }
cp "$work/Assets.car" "$work/AppIcon.icns" "$ROOT/Resources/"
echo "écrit Resources/Assets.car et Resources/AppIcon.icns"
