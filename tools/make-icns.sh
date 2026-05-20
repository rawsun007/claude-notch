#!/bin/bash
# Build assets/AppIcon.icns from assets/icon-1024.png (master).
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="assets/icon-1024.png"
[ -f "$MASTER" ] || { echo "missing $MASTER — run: swift tools/make-icon.swift $MASTER"; exit 1; }

ICONSET="assets/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# name=size pairs for the standard macOS iconset.
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024

iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
rm -rf "$ICONSET"
echo "✓ wrote assets/AppIcon.icns"
