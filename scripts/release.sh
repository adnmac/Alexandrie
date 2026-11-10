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
APP="$ROOT/build/Foluna.app"
# Une app ad hoc ne peut pas être vérifiée par « Installer et relancer » : on refuse de la publier.
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "L'app n'est pas signée avec le certificat stable : publication annulée."
  exit 1
fi
codesign --verify --deep --strict "$APP"

ZIP="$ROOT/build/Foluna-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

DMG="$ROOT/build/Foluna-$VERSION.dmg"
STAGE="$ROOT/build/dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Foluna.app"
ln -s /Applications "$STAGE/Applications"
# La 0.6.0 installée ne cherche que « Alexandrie.app » dans l'image : un lien vers Foluna.app lui suffit
# (ditto suit le lien et copie l'app). hdiutil -srcfolder perd le drapeau « caché » : on le pose sur
# l'image montée en écriture, puis on la compresse.
ln -s Foluna.app "$STAGE/Alexandrie.app"
RW="$ROOT/build/dmg-rw.dmg"
MNT="$ROOT/build/dmg-mnt"
rm -rf "$RW" "$MNT"
hdiutil create -quiet -volname "Foluna $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$RW"
chflags -h hidden "$MNT/Alexandrie.app"
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -o "$DMG"
rm -rf "$STAGE" "$RW" "$MNT"
hdiutil verify -quiet "$DMG"

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
NOTES="$(git log ${PREVIOUS:+$PREVIOUS..}HEAD --pretty='- %s' | grep -v '^- chore: version' || true)"

git tag -a "$TAG" -m "Foluna $VERSION"
git push -q origin main "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "Foluna $VERSION" --notes "${NOTES:-Version $VERSION}"
echo "✅ Foluna $VERSION publiée"
