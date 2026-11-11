#!/bin/zsh
# Rend Icon/AppIcon.icon comme macOS l'affiche (ictool d'Icon Composer), sur une seule planche :
#   par défaut, sombre, teintée, transparente à 256 pt, puis par défaut à 32 et 16 pt.
# Usage : scripts/icon-review.sh [sortie.png]   (par défaut /tmp/foluna-icon.png)
set -euo pipefail
ROOT="${0:A:h:h}"
out=${1:-/tmp/foluna-icon.png}
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || { echo "ictool introuvable : il faut Xcode 26 ou plus récent."; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
render() { # apparence taille fichier
  "$ictool" "$ROOT/Icon/AppIcon.icon" --export-image --output-file "$work/$3" \
    --platform macOS --rendition "$1" --width "$2" --height "$2" --scale 2 >/dev/null
}
render Default 256 1.png
render Dark 256 2.png
render TintedDark 256 3.png
render ClearLight 256 4.png
render Default 32 5.png
render Default 16 6.png
swift "$ROOT/scripts/icon-sheet.swift" "$out" "$work"/{1,2,3,4,5,6}.png
echo "écrit $out"
