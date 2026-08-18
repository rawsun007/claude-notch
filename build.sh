#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Universal (arm64 + x86_64). A single-slice build still installs cleanly on the
# wrong Mac through Homebrew and then refuses to launch, which reads as "the app
# is broken" rather than "wrong architecture", so both slices ship every time.
#
# `swift build --arch arm64 --arch x86_64` needs xcbuild, which only full Xcode
# provides; this machine (and anyone on Command Line Tools) has no such thing.
# Two single-arch builds plus lipo gets the same fat binary out of the CLT
# toolchain, since the macOS SDK carries both architectures. Set
# CLAUDENOTCH_SKIP_UNIVERSAL=1 for a native-only build while iterating.
echo "→ swift build -c release (arm64)"
swift build -c release
BIN=.build/release/ClaudeNotch
[ -f "$BIN" ] || { echo "build failed"; exit 1; }

if [ "${CLAUDENOTCH_SKIP_UNIVERSAL:-0}" = "1" ]; then
    echo "  ⚠ CLAUDENOTCH_SKIP_UNIVERSAL=1 — native-only build, do NOT release this"
else
    X86_TRIPLE=x86_64-apple-macosx13.0
    echo "→ swift build -c release (x86_64, cross)"
    swift build -c release --scratch-path .build-x86_64 \
        -Xswiftc -target -Xswiftc "$X86_TRIPLE" \
        -Xcc -target -Xcc "$X86_TRIPLE"

    echo "→ lipo -create"
    mkdir -p .build/universal
    lipo -create -output .build/universal/ClaudeNotch \
        .build/release/ClaudeNotch .build-x86_64/release/ClaudeNotch
    BIN=.build/universal/ClaudeNotch

    # Never ship a single-slice binary by accident.
    ARCHS=$(lipo -archs "$BIN")
    for want in arm64 x86_64; do
        case " $ARCHS " in
            *" $want "*) ;;
            *) echo "build failed: $BIN is missing the $want slice (has: $ARCHS)"; exit 1 ;;
        esac
    done
    echo "  universal binary: $ARCHS"
fi

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

if [ -f assets/spiderman-meme-song.mp3 ]; then
    cp assets/spiderman-meme-song.mp3 "$APP/Contents/Resources/spiderman-meme-song.mp3"
fi
# Pet Mode's mascot is not shipped as an image: the app rebuilds it from the
# 16x16 grid in PetRig.swift so its legs, arms, and eyes can move independently.
# assets/claude-pet.png stays in the repo as the reference artwork.

# Localized strings. macOS picks the .lproj matching the user's language and
# falls back to CFBundleDevelopmentRegion, so an untranslated build reads in
# English. Regenerate the English table with tools/l10n-extract.py.
if [ -d Resources ]; then
    cp -R Resources/*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
fi

# AppleScript dictionary. Info.plist points OSAScriptingDefinition at this, and
# it is what Script Editor and Shortcuts' Run AppleScript action read.
if [ -f Resources/ClaudeNotch.sdef ]; then
    cp Resources/ClaudeNotch.sdef "$APP/Contents/Resources/ClaudeNotch.sdef"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.claudenotch.app</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleName</key><string>ClaudeNotch</string>
    <key>CFBundleDisplayName</key><string>ClaudeNotch</string>
    <key>CFBundleExecutable</key><string>ClaudeNotch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.27.1</string>
    <key>CFBundleVersion</key><string>134</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleScriptEnabled</key><true/>
    <key>OSAScriptingDefinition</key><string>ClaudeNotch.sdef</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.claudenotch.app.url</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key><array><string>claudenotch</string></array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Signing, best available tier first.
#
#   1. Developer ID, when CLAUDENOTCH_SIGN_ID names one. This is the only tier
#      Gatekeeper accepts without the user overriding it by hand, and the only
#      one that can be notarized. Set it and the DMG build will notarize too.
#   2. A stable self-signed identity, so TCC grants (Accessibility, Input
#      Monitoring) survive a rebuild, because the designated requirement stays
#      constant. See tools/make-signing-cert.sh.
#   3. Ad-hoc, which works but re-prompts for permissions on every update.
#
# Only the first clears Gatekeeper. The other two mean every new user meets
# "cannot be opened because Apple cannot check it for malicious software" and
# has to right-click Open, which is a lot to ask of somebody installing a tool
# that gates what an AI may run on their Mac.
DEV_ID="${CLAUDENOTCH_SIGN_ID:-}"
SIGN_ID="ClaudeNotch Code Signing"
if [ -n "$DEV_ID" ]; then
    # --options runtime is required for notarization; --timestamp is required
    # for the ticket to remain valid after the certificate expires.
    codesign --force --deep --options runtime --timestamp \
             --sign "$DEV_ID" "$APP"
    echo "→ Code signed with Developer ID ($DEV_ID), hardened runtime"
elif security find-identity 2>/dev/null | grep -q "$SIGN_ID" \
   && codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
    echo "→ Code signed with stable identity ($SIGN_ID) — permissions persist across updates"
    echo "  (not notarized: set CLAUDENOTCH_SIGN_ID to a Developer ID to clear Gatekeeper)"
else
    echo "→ Ad-hoc code signing (run tools/make-signing-cert.sh once so permissions persist)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo
echo "✓ Built $APP"
echo
echo "  Run:     open $APP"
echo "  Install: ./install.sh   (copies to /Applications, wires Claude Code hooks)"
