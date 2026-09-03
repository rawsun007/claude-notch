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
    <key>CFBundleShortVersionString</key><string>0.35.0</string>
    <key>CFBundleVersion</key><string>144</string>
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
    <!-- Shown verbatim in the macOS permission prompts. Without them the
         dialog has an empty reason line, which reads as an app that will not
         say why it wants control of your terminal. -->
    <key>NSAppleEventsUsageDescription</key><string>ClaudeNotch types into your terminal to resume a session, send a message, or run /compact when you ask it to.</string>
    <key>NSAccessibilityUsageDescription</key><string>ClaudeNotch needs Accessibility to type into the terminal window running your agent.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Signing, best available tier first.
#
#   1. Developer ID, when the pinned certificate below (or CLAUDENOTCH_SIGN_ID)
#      is in the keychain. The only tier that can be notarized, and therefore
#      the only tier a release may ship in.
#   2. A stable self-signed identity, so TCC grants (Accessibility, Input
#      Monitoring) survive a rebuild, because the designated requirement stays
#      constant. See tools/make-signing-cert.sh.
#   3. Ad-hoc, which works but re-prompts for permissions on every update.
#
# Tiers 2 and 3 are DEVELOPMENT ONLY, and are now only reachable on a machine
# without the release certificate. They exist so the app builds and runs there,
# not so it can be handed to anyone: both produce a bundle Gatekeeper refuses
# with "cannot be opened because Apple cannot check it for malicious software",
# which is a lot to ask of somebody installing a tool that gates what an AI may
# run on their Mac. tools/release.sh refuses to publish one, and
# tools/verify-notarized-build.sh fails on one.
# The Developer ID to sign with.
#
# Pinned to a SHA-1 hash rather than a name on purpose. This team has several
# "Developer ID Application: Alfastack Solution Private Limited (PS8FJ3MQB2)"
# certificates, identical in every visible respect, so codesign given the name
# picks whichever it finds first. That is fine until one is revoked or expires
# and a release is quietly signed by a certificate nobody meant to use. The
# hash names exactly one.
#
# `security find-identity -v -p codesigning` lists the hashes. Overriding
# CLAUDENOTCH_SIGN_ID still works, for CI, which imports its own copy.
DEV_ID="${CLAUDENOTCH_SIGN_ID:-D1977844AE12568324248A02C78DC7C4A2440AB3}"

# Signing is now the default rather than something to remember: an unsigned
# release is the one outcome this whole exercise existed to prevent. Falls back
# to the previous behaviour if that certificate is not on this machine.
if [ -n "$DEV_ID" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID"; then
    echo "  (Developer ID $DEV_ID not in this keychain, falling back to local signing)"
    DEV_ID=""
fi
SIGN_ID="ClaudeNotch Code Signing"
if [ -n "$DEV_ID" ]; then
    # --options runtime is required for notarization; --timestamp is required
    # for the ticket to remain valid after the certificate expires.
    # --entitlements is not optional here. Hardened runtime is required for
    # notarization, and under it a process may not send AppleEvents to another
    # app without com.apple.security.automation.apple-events. Without this the
    # first notarized build would ship with TerminalAutomator silently unable
    # to drive Terminal, which is how the app resumes and composes sessions.
    codesign --force --deep --options runtime --timestamp \
             --entitlements ClaudeNotch.entitlements \
             --sign "$DEV_ID" "$APP"
    echo "→ Code signed with Developer ID ($DEV_ID), hardened runtime"
elif security find-identity 2>/dev/null | grep -q "$SIGN_ID" \
   && codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
    echo "→ Code signed with stable identity ($SIGN_ID) — permissions persist across updates"
    echo "  DEVELOPMENT BUILD: not notarized, do not distribute this bundle."
else
    echo "→ Ad-hoc code signing (run tools/make-signing-cert.sh once so permissions persist)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "  DEVELOPMENT BUILD: not notarized, do not distribute this bundle."
fi

echo
echo "✓ Built $APP"
echo
echo "  Run:     open $APP"
echo "  Install: ./install.sh   (copies to /Applications, wires Claude Code hooks)"
