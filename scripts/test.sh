#!/bin/zsh
# Lance les tests. Pour les tests sur de vrais livres :
#   ALEXANDRIE_FIXTURES=/chemin/vers/livres scripts/test.sh
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
swift test "${SWIFT_FLAGS[@]}" "$@"
