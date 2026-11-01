#!/bin/zsh
# Compile Alexandrie (debug par défaut ; « release » en argument).
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
swift build -c "${1:-debug}" "${SWIFT_FLAGS[@]}"
