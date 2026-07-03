#!/usr/bin/env bash
# Builds the Neev Remote web app and packages it as:
#   dist/NeevRemote-web.zip   (static site — unzip and serve with any web server)
#
# Runs on any OS with Flutter installed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="dist"
mkdir -p "$OUT"

echo "==> flutter build web --release"
flutter build web --release

echo "==> zip"
rm -f "$OUT/NeevRemote-web.zip"
( cd build/web && zip -qr "../../$OUT/NeevRemote-web.zip" . )

echo "==> done:"
ls -lh "$OUT/NeevRemote-web.zip"
