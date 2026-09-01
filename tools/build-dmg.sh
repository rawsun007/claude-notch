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
#
# Skipped when CLAUDENOTCH_SKIP_BUILD is set, which the release script does on
# its second pass: by then the app has been notarized and stapled, and
# rebuilding would replace the bundle and throw the ticket away.
if [ -z "${CLAUDENOTCH_SKIP_BUILD:-}" ]; then
    ./build.sh
fi

APP="ClaudeNotch.app"
[ -d "$APP" ] || { echo "build failed — no $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
VOL="ClaudeNotch $VERSION"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"

# 2. Stage contents.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The instructions differ entirely depending on whether this build is
# notarized, and shipping the Gatekeeper-bypass steps to someone who does not
# need them teaches them to bypass Gatekeeper for anything calling itself
# ClaudeNotch. So the README is written to match the build.
if [ -n "${CLAUDENOTCH_SIGN_ID:-}" ] && [ -n "${CLAUDENOTCH_NOTARY_PROFILE:-}" ]; then
cat > "$STAGE/README.txt" <<'TXT'
ClaudeNotch — first launch
==========================

1. Drag  ClaudeNotch.app  onto the  Applications  folder (in this window).

2. Open Applications and double-click ClaudeNotch. It opens straight away:
   this build is signed with a Developer ID and notarized by Apple.

3. The Setup window appears. Grant Accessibility + Input Monitoring,
   click "Install" to wire up the Claude Code hooks, and you are done.

Then start Claude Code in any terminal and your permission prompts,
questions, and notifications show up in the notch instead of the terminal.

Updating from an older version?
   Use  Update Now  inside the app (menu-bar bell, or Settings > About).
   It downloads, verifies the checksum, replaces and relaunches for you.
   Your settings and history are kept: they live in ~/.claudenotch, not in
   the app.

Tip:  press  Opt-Cmd-N  anywhere to type a message straight to Claude.

Prefer Homebrew?
   brew tap rawsun007/claudenotch https://github.com/rawsun007/claude-notch
   brew install --cask claudenotch
TXT
else
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

Updating from an older version?
   Quit the running ClaudeNotch first (menu-bar bell -> Quit), otherwise
   macOS will not let the new copy replace the one that is still open.
   Then drag the new ClaudeNotch.app onto Applications and click "Replace".
   Your settings and history are kept (they live in ~/.claudenotch, not in
   the app). Steps 2-3 above are one-time; you will not see them again.

Tip:  press  Opt-Cmd-N  anywhere to type a message straight to Claude.

Skip this warning entirely: install with Homebrew instead.
   brew tap rawsun007/claudenotch https://github.com/rawsun007/claude-notch
   brew install --cask claudenotch
ClaudeNotch is ad-hoc signed (no Developer ID), a tier macOS treats more
leniently than an unnotarized Developer ID app, so the Homebrew install
launches with no Gatekeeper prompt.
TXT
fi

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

# Sign the disk image.
#
# Unconditionally, whenever an identity is available, and NOT as part of the
# notarization block below. It used to be the first line inside that block, and
# that coupling produced the same broken artifact twice in one release:
#
#   - Locally, the block is gated on CLAUDENOTCH_NOTARY_PROFILE, and the signing
#     identity was read from CLAUDENOTCH_SIGN_ID alone while build.sh had grown
#     a pinned default. A run with only the notary profile set signed the app
#     and left the image around it bare.
#   - In CI, the identity is set but CLAUDENOTCH_NOTARY_PROFILE never is: the
#     workflow notarizes in its own steps, because it needs --keychain to reach
#     the throwaway keychain it imported the certificate into. So the whole
#     block was skipped and the image went unsigned again.
#
# Both callers notarize themselves. Neither signs the image itself. So signing
# belongs here, on its own, with no second condition attached to it. The failure
# it caused is silent in a nasty way: Apple notarizes an unsigned image without
# complaint, because the app inside is what it inspects, and stapler attaches
# the ticket regardless, so every step reports success and only
# `spctl -t install` says "rejected: no usable signature".
#
# The identity default is read out of build.sh rather than copied, because a
# second copy of the hash is a second thing to update when the certificate
# rotates.
DMG_SIGN_ID="${CLAUDENOTCH_SIGN_ID:-$(sed -n 's/^DEV_ID="\${CLAUDENOTCH_SIGN_ID:-\([0-9A-F]*\)}".*$/\1/p' build.sh)}"
if [ -n "$DMG_SIGN_ID" ] \
   && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$DMG_SIGN_ID"; then
    echo "  (signing identity $DMG_SIGN_ID not in this keychain)"
    DMG_SIGN_ID=""
fi

if [ -n "$DMG_SIGN_ID" ]; then
    echo "→ Signing the disk image"
    codesign --force --timestamp --sign "$DMG_SIGN_ID" "$DMG"
    # Assert it took. codesign can succeed and leave an image that carries no
    # usable signature, and every later step reports success anyway.
    codesign --verify --strict "$DMG" \
        || { echo "the disk image did not end up signed, refusing to continue"; exit 1; }
fi

# Notarize and staple, when there are credentials to do it with.
#
# Without this the DMG is signed but not notarized, so Gatekeeper refuses the
# first launch and every new user has to right-click Open, or run xattr, on a
# tool whose whole job is deciding what an AI may run on their Mac. That is an
# expensive first impression and it is the single biggest install-time drop.
#
# Needs a notarytool keychain profile in CLAUDENOTCH_NOTARY_PROFILE, stored once
# with xcrun notarytool store-credentials, or this block is skipped. The release
# workflow leaves it unset on purpose and does this itself.
#
# Stapling matters: it puts the ticket inside the DMG so a first launch works
# with no network. Without it, someone offline sees the refusal anyway.
if [ -n "$DMG_SIGN_ID" ] && [ -n "${CLAUDENOTCH_NOTARY_PROFILE:-}" ]; then
    echo "→ Notarizing (this waits on Apple, usually a minute or two)"
    if xcrun notarytool submit "$DMG" \
           --keychain-profile "$CLAUDENOTCH_NOTARY_PROFILE" --wait; then
        xcrun stapler staple "$DMG"
        echo "→ Stapled"
        # Say it worked rather than assuming: a stapled-but-rejected DMG is the
        # one failure that would otherwise ship silently and greet every user.
        if spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q accepted; then
            echo "✓ Gatekeeper accepts the disk image"
        else
            echo "⚠ Gatekeeper still rejects it. Do not ship this build."
            spctl -a -t open --context context:primary-signature -vv "$DMG" || true
            exit 1
        fi
    else
        echo "⚠ Notarization failed. Check: xcrun notarytool log <id> --keychain-profile $CLAUDENOTCH_NOTARY_PROFILE"
        exit 1
    fi
elif [ -n "$DMG_SIGN_ID" ]; then
    echo "→ Signed, not notarized (CLAUDENOTCH_NOTARY_PROFILE unset). Expected"
    echo "  in CI, which notarizes in its own step."
else
    echo "→ Neither signed nor notarized: the signing identity build.sh pins is"
    echo "  not in this keychain. Development build only."
fi

# Everything below this line touches the finished image, so the signature is
# checked again at the end rather than assumed to have survived.

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

# Last word on the artifact, after the Finder icon has been written into it.
# Setting the icon goes through NSWorkspace and is not expected to disturb the
# signature, and this says so rather than trusting it: the cost of being wrong
# is a release nobody can install, and the check is one process.
if [ -n "$DMG_SIGN_ID" ]; then
    codesign --verify --strict "$DMG" \
        || { echo "the disk image's signature did not survive packaging"; exit 1; }
    echo "→ Disk image signature verified"
fi

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ Built $DMG ($SIZE)"
echo
echo "  Next: publish it with tools/release.sh, which notarizes, verifies and"
echo "  points the Homebrew cask at the published file."
