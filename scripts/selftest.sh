#!/bin/zsh
# Self-test de l'app sur un dossier de données vide dans /tmp (jamais les vraies données).
# Compile en debug, puis lance le binaire avec --selftest : PASS/FAIL par étape, code de sortie 0 si tout passe.
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build --show-bin-path "${SWIFT_FLAGS[@]}")/Alexandrie"
STORE="${ALEXANDRIE_STORE:-/tmp/alexandrie-selftest}"
[[ "$STORE" == /tmp/* || "$STORE" == /private/tmp/* ]] || { echo "ALEXANDRIE_STORE doit être dans /tmp"; exit 2; }
rm -rf "$STORE"
# Après un plantage, macOS proposerait de rouvrir les fenêtres et bloquerait le lancement suivant.
rm -rf ~/Library/Saved\ Application\ State/be.adnmac.alexandrie.savedState
ALEXANDRIE_STORE="$STORE" "$BIN" --selftest
