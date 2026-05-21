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
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "→ Ad-hoc code signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo
echo "✓ Built $APP"
echo
echo "  Run:     open $APP"
echo "  Install: ./install.sh   (copies to /Applications, wires Claude Code hooks)"
