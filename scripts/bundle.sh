#!/bin/zsh
# Construit build/Alexandrie.app (release). Signé avec le certificat « Alexandrie Dev » s'il existe
# (identité stable : macOS garde les autorisations d'une version à l'autre), sinon ad hoc.
# Autre certificat : ALEXANDRIE_SIGN_IDENTITY="Nom du certificat" scripts/bundle.sh
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
swift build -c release "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release --show-bin-path "${SWIFT_FLAGS[@]}")/Alexandrie"
APP="$ROOT/build/Alexandrie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Alexandrie"
# Icône : Assets.car (Liquid Glass, macOS 26+) et AppIcon.icns (macOS 14-15), compilés par scripts/make-icon.sh.
for f in Assets.car AppIcon.icns; do [[ -f "$ROOT/Resources/$f" ]] && cp "$ROOT/Resources/$f" "$APP/Contents/Resources/"; done
# Commit compilé : l'app le compare à GitHub pour signaler les mises à jour.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Alexandrie</string>
  <key>CFBundleDisplayName</key><string>Alexandrie</string>
  <key>CFBundleIdentifier</key><string>be.adnmac.alexandrie</string>
  <key>CFBundleExecutable</key><string>Alexandrie</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>AlexandrieCommit</key><string>${COMMIT}</string>
</dict>
</plist>
PLIST
IDENTITY="${ALEXANDRIE_SIGN_IDENTITY:-Alexandrie Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "🔏 signé avec « $IDENTITY »"
else
  codesign --force --sign - "$APP"
  echo "⚠️  certificat « $IDENTITY » introuvable : signature ad hoc (macOS peut redemander ses autorisations à chaque version)"
fi
echo "✅ $APP"
