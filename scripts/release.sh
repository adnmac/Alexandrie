#!/bin/zsh
# Publie une version sur GitHub : scripts/release.sh 0.3.0
# Construit l'app signée avec le certificat stable, la zippe, crée l'étiquette vX.Y.Z et la version GitHub.
# L'app installée la propose ensuite avec « Installer et relancer ».
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"

VERSION="${1:-$(cat VERSION)}"
TAG="v$VERSION"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version attendue : X.Y.Z (reçu « $VERSION »)"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Des modifications ne sont pas committées."; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "La publication se fait depuis main."; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "L'étiquette $TAG existe déjà."; exit 1; }

if [[ "$(cat VERSION)" != "$VERSION" ]]; then
  echo "$VERSION" > VERSION
  git commit -q -m "chore: version $VERSION" VERSION
fi

scripts/bundle.sh
APP="$ROOT/build/Alexandrie.app"
# Une app ad hoc ne peut pas être vérifiée par « Installer et relancer » : on refuse de la publier.
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "L'app n'est pas signée avec le certificat stable : publication annulée."
  exit 1
fi
codesign --verify --deep --strict "$APP"

ZIP="$ROOT/build/Alexandrie-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
NOTES="$(git log ${PREVIOUS:+$PREVIOUS..}HEAD --pretty='- %s' | grep -v '^- chore: version' || true)"

git tag -a "$TAG" -m "Alexandrie $VERSION"
git push -q origin main "$TAG"
# Le code est privé : la version publiée va dans le dépôt public des versions, que l'app consulte.
gh release create "$TAG" "$ZIP" --repo adnmac/Alexandrie-versions --title "Alexandrie $VERSION" --notes "${NOTES:-Version $VERSION}"
echo "✅ Alexandrie $VERSION publiée"
