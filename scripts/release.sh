#!/bin/zsh
# Publie une version sur GitHub : scripts/release.sh 0.3.0
# Construit l'app signée avec le certificat stable, en fait une image disque (.dmg : l'app et un lien vers
# Applications) et une archive .zip (lue par les versions déjà installées, qui ne connaissent que le .zip),
# crée l'étiquette vX.Y.Z et la version GitHub. L'app installée la propose avec « Installer et relancer ».
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

DMG="$ROOT/build/Alexandrie-$VERSION.dmg"
STAGE="$ROOT/build/dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Alexandrie.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Alexandrie $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
hdiutil verify -quiet "$DMG"

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
NOTES="$(git log ${PREVIOUS:+$PREVIOUS..}HEAD --pretty='- %s' | grep -v '^- chore: version' || true)"

git tag -a "$TAG" -m "Alexandrie $VERSION"
git push -q origin main "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "Alexandrie $VERSION" --notes "${NOTES:-Version $VERSION}"
echo "✅ Alexandrie $VERSION publiée"
