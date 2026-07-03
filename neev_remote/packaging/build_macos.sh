#!/usr/bin/env bash
# Builds Neev Remote for macOS and produces:
#   dist/NeevRemote-macos.zip   (portable .app, just unzip & run)
#   dist/NeevRemote-macos.dmg   (drag-to-Applications disk image)
#   dist/NeevRemote-macos.pkg   (installer package -> /Applications)
#
# Run on macOS with full Xcode + CocoaPods installed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Neev Remote"
OUT="dist"
mkdir -p "$OUT"

echo "==> flutter build macos --release"
RELAY_DEFINE=""
[ -n "${RELAY_URL:-}" ] && RELAY_DEFINE="--dart-define=RELAY_URL=$RELAY_URL"
flutter build macos --release $RELAY_DEFINE

APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP_PATH" ] || { echo "build .app not found"; exit 1; }

echo "==> portable zip"
rm -f "$OUT/NeevRemote-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUT/NeevRemote-macos.zip"

echo "==> dmg"
rm -f "$OUT/NeevRemote-macos.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO \
  "$OUT/NeevRemote-macos.dmg"
rm -rf "$STAGE"

echo "==> pkg installer"
rm -f "$OUT/NeevRemote-macos.pkg"
pkgbuild --install-location /Applications \
  --identifier com.neev.neev_remote \
  --version 1.0.0 \
  --component "$APP_PATH" \
  "$OUT/NeevRemote-macos.pkg"

echo "==> done:"
ls -lh "$OUT"/NeevRemote-macos.*
