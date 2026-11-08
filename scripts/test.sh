#!/bin/zsh
# Lance les tests. Pour les tests sur de vrais livres :
#   ALEXANDRIE_FIXTURES=/chemin/vers/livres scripts/test.sh
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
# Traductions complètes dans toutes les langues (catalogue Resources/Localizable.xcstrings).
scripts/l10n.sh check
swift test "${SWIFT_FLAGS[@]}" "$@"
