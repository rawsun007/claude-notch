#!/bin/bash
# Build a distributable ClaudeNotch.dmg:
#   • ClaudeNotch.app  (drag this to Applications)
#   • an Applications symlink (drop target)
#   • README.txt with first-launch Gatekeeper instructions
#
# Upload the resulting dist/ClaudeNotch.dmg to Google Drive and share it.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Build the .app fresh (icons + hooks bundled).
./build.sh

APP="ClaudeNotch.app"
[ -d "$APP" ] || { echo "build failed — no $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
VOL="ClaudeNotch $VERSION"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"

# 2. Stage contents.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'TXT'
ClaudeNotch — first launch (one time)
=====================================

1. Drag  ClaudeNotch.app  onto the  Applications  folder (in this window).

2. Open Applications and double-click ClaudeNotch.
   macOS will block it the first time because the app is not notarized
   through Apple's paid Developer program. Click "Done" on the warning.

3. Open  System Settings -> Privacy & Security , scroll to the Security
   section, and click "Open Anyway" next to ClaudeNotch.
   Click "Open" in the confirmation dialog that follows.

   (On macOS Sonoma and earlier, right-click ClaudeNotch -> "Open" still
    works as a faster bypass.)

4. The Setup window appears. Grant Accessibility + Input Monitoring,
   click "Install" to wire up the Claude Code hooks, and you are done.

Then start Claude Code in any terminal and your permission prompts,
questions, and notifications show up in the notch instead of the terminal.

Tip:  press  Opt-Cmd-N  anywhere to type a message straight to Claude.

Skip this warning entirely: install with Homebrew instead.
   brew tap rawsun007/claudenotch https://github.com/rawsun007/claude-notch
   brew install --cask claudenotch
ClaudeNotch is ad-hoc signed (no Developer ID), a tier macOS treats more
leniently than an unnotarized Developer ID app, so the Homebrew install
launches with no Gatekeeper prompt.
TXT

# Brand the disk image with our icon (instead of the generic .dmg icon).
if [ -f assets/AppIcon.icns ]; then
    cp assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"
fi

# 3. Build the DMG. Use a read/write image first so we can flag the custom
#    volume icon, then convert to a compressed read-only image.
mkdir -p dist
DMG="dist/ClaudeNotch.dmg"
RW="$(mktemp -d)/rw.dmg"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null

# Mount, set the custom-icon flag on the volume root, unmount.
MNT="$(mktemp -d)"
hdiutil attach "$RW" -nobrowse -mountpoint "$MNT" >/dev/null
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MNT" 2>/dev/null || true
fi
hdiutil detach "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true

hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW"; rmdir "$(dirname "$RW")" 2>/dev/null || true

# Set the .dmg FILE's Finder icon (what you see in Downloads) to our logo.
if [ -f assets/icon-1024.png ]; then
    /usr/bin/swift - "$DMG" assets/icon-1024.png <<'SWIFT' 2>/dev/null || true
import AppKit
let a = CommandLine.arguments
if a.count >= 3, let img = NSImage(contentsOfFile: a[2]) {
    NSWorkspace.shared.setIcon(img, forFile: a[1], options: [])
}
SWIFT
fi

rm -rf "$(dirname "$STAGE")"
SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ Built $DMG ($SIZE)"
echo
echo "  Next: upload $DMG to Google Drive → Share → 'Anyone with the link'."
echo "  Recipients: open the DMG, drag the app to Applications, right-click → Open."
