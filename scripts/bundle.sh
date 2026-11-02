#!/bin/zsh
# Construit build/Alexandrie.app (release, signature ad hoc).
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
swift build -c release "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release --show-bin-path "${SWIFT_FLAGS[@]}")/Alexandrie"
APP="$ROOT/build/Alexandrie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Alexandrie"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# Commit compilé : l'app le compare à GitHub pour signaler les mises à jour.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>AlexandrieCommit</key><string>${COMMIT}</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "✅ $APP"
