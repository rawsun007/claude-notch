#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "→ swift build -c release"
swift build -c release

BIN=.build/release/ClaudeNotch
[ -f "$BIN" ] || { echo "build failed"; exit 1; }

APP="ClaudeNotch.app"
echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/hooks"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
chmod +x "$APP/Contents/MacOS/ClaudeNotch"

# Bundle hook scripts so the app's in-process installer can self-wire
# Claude Code without the user opening a terminal.
cp bin/*.sh "$APP/Contents/Resources/hooks/"
chmod +x "$APP/Contents/Resources/hooks/"*.sh

# App icon (Finder / Dock / About). Built by tools/make-icns.sh.
if [ -f assets/AppIcon.icns ]; then
    cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Menu-bar template glyph.
if [ -f assets/menubar.png ]; then
    cp assets/menubar.png "$APP/Contents/Resources/menubar.png"
fi
# Claude brand icon used in the idle pill.
if [ -f assets/claude-color.svg ]; then
    cp assets/claude-color.svg "$APP/Contents/Resources/claude-color.svg"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.claudenotch.app</string>
    <key>CFBundleName</key><string>ClaudeNotch</string>
    <key>CFBundleDisplayName</key><string>ClaudeNotch</string>
    <key>CFBundleExecutable</key><string>ClaudeNotch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.2.61</string>
    <key>CFBundleVersion</key><string>64</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity (so TCC permission grants persist
# across rebuilds — see tools/make-signing-cert.sh). Fall back to ad-hoc.
SIGN_ID="ClaudeNotch Code Signing"
# Sign with the stable self-signed identity if present (created by
# tools/make-signing-cert.sh, imported -A so codesign never prompts). This
# keeps the app's designated requirement constant across rebuilds, so macOS
# Accessibility / Input Monitoring grants persist. Falls back to ad-hoc.
if security find-identity 2>/dev/null | grep -q "$SIGN_ID" \
   && codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
    echo "→ Code signed with stable identity ($SIGN_ID) — permissions persist across updates"
else
    echo "→ Ad-hoc code signing (run tools/make-signing-cert.sh once so permissions persist)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo
echo "✓ Built $APP"
echo
echo "  Run:     open $APP"
echo "  Install: ./install.sh   (copies to /Applications, wires Claude Code hooks)"
