#!/usr/bin/env bash
# Builds Neev Remote for Linux (x64) and produces:
#   dist/NeevRemote-linux-x64.tar.gz  (portable bundle, extract & run ./neev_remote)
#
# Requires the Flutter Linux desktop toolchain plus X11/XTest dev headers:
#   sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
#                    libx11-dev libxtst-dev
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="dist"
mkdir -p "$OUT"

echo "==> flutter build linux --release"
RELAY_DEFINE=""
[ -n "${RELAY_URL:-}" ] && RELAY_DEFINE="--dart-define=RELAY_URL=$RELAY_URL"
flutter build linux --release $RELAY_DEFINE

BUNDLE="build/linux/x64/release/bundle"
[ -d "$BUNDLE" ] || { echo "bundle not found at $BUNDLE"; exit 1; }

echo "==> portable tar.gz"
rm -f "$OUT/NeevRemote-linux-x64.tar.gz"
tar -czf "$OUT/NeevRemote-linux-x64.tar.gz" -C "$BUNDLE" .

echo "==> done:"
ls -lh "$OUT/NeevRemote-linux-x64.tar.gz"
echo "Run with: tar -xzf NeevRemote-linux-x64.tar.gz && ./neev_remote"
