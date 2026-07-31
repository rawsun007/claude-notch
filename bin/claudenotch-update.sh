#!/bin/bash
# Update ClaudeNotch in place.
#
# Homebrew users already have `brew upgrade --cask claudenotch`. Everyone who
# installed from the DMG had to download it, mount it, drag it over the running
# copy and relaunch, by hand, every release. This does that.
#
#   claudenotch-update.sh            # update if there is something newer
#   claudenotch-update.sh --check    # say what is available, change nothing
#
# Installed to ~/.claudenotch/bin alongside the hook scripts, so it is on disk
# for anyone who ran setup, including people who never cloned the repo.
set -euo pipefail

REPO="rawsun007/claude-notch"
# Fully qualified. A bare "claudenotch" is ambiguous the moment the token also
# exists in another tap, and brew refuses rather than guessing.
BREW_CASK="rawsun007/tap/claudenotch"
CASK_URL="https://raw.githubusercontent.com/rawsun007/homebrew-tap/main/Casks/claudenotch.rb"
APP="/Applications/ClaudeNotch.app"
DMG_URL="https://github.com/${REPO}/releases/latest/download/ClaudeNotch.dmg"

CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --check)   CHECK_ONLY=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required."

# --- what is installed
if [ ! -d "$APP" ]; then
    die "ClaudeNotch is not in /Applications. Install it first: $DMG_URL"
fi
CURRENT=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
[ -n "$CURRENT" ] || die "Could not read the installed version from $APP."

# --- what is published
TAG=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$TAG" ] || die "Could not reach GitHub to ask what the latest release is."
LATEST=${TAG#v}

# Sort -V puts them in version order; if the newest is the one we already have,
# there is nothing to do. Handles 0.10.2 vs 0.9.0, which a string compare does not.
newest() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }
if [ "$CURRENT" = "$LATEST" ] || [ "$(newest "$CURRENT" "$LATEST")" = "$CURRENT" ]; then
    say "ClaudeNotch v${CURRENT} is up to date."
    exit 0
fi

say "ClaudeNotch v${LATEST} is available. You have v${CURRENT}."
[ "$CHECK_ONLY" -eq 1 ] && exit 0

# --- do not fight Homebrew
# Replacing a cask-installed app by hand leaves brew believing the old version
# is still there, and the next `brew upgrade` will happily put it back.
#
# Match against the list of installed casks rather than asking brew about the
# name. `brew list --cask claudenotch` fails outright when the token exists in
# more than one tap, and a failure there reads as "not installed by Homebrew",
# which is how this guard was walked straight past on a machine that had a
# leftover local tap. Listing what is installed cannot be ambiguous.
if command -v brew >/dev/null 2>&1 \
   && brew list --cask 2>/dev/null | grep -qx "claudenotch"; then
    say ""
    say "This copy was installed with Homebrew. Update it the same way:"
    say "    brew upgrade --cask ${BREW_CASK}"
    exit 0
fi

TMP=$(mktemp -d)
MOUNT="$TMP/mnt"
# Always try to detach before deleting, without first asking whether anything is
# mounted: /var is a symlink to /private/var, so the mount table lists a path
# that does not match the one we passed in, and a check against it never fires.
# A detach on a path that was never mounted fails harmlessly.
#
# The exit status is captured and restored because a failure in here would
# otherwise become the script's, reporting a successful update as a failure.
cleanup() {
    local rc=$?
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 \
        || hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true
    rm -rf "$TMP" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT

say "→ Downloading v${LATEST}"
curl -fsSL --max-time 300 -o "$TMP/ClaudeNotch.dmg" "$DMG_URL" \
    || die "Download failed."

# --- verify what we downloaded
# The cask in the tap carries the checksum for this release, published by the
# same release script that built the DMG. This is not protection against a
# compromised GitHub, since both come from there. It catches the realistic
# failure: a truncated or corrupted download being dragged over your app.
EXPECTED=$(curl -fsSL --max-time 20 "$CASK_URL" 2>/dev/null \
           | sed -n 's/.*sha256[[:space:]]*"\([a-f0-9]\{64\}\)".*/\1/p' | head -1)
ACTUAL=$(shasum -a 256 "$TMP/ClaudeNotch.dmg" | awk '{print $1}')
if [ -n "$EXPECTED" ]; then
    [ "$EXPECTED" = "$ACTUAL" ] || die "Checksum mismatch, refusing to install.
  expected $EXPECTED
  got      $ACTUAL"
    say "→ Checksum verified"
else
    say "→ Could not fetch the published checksum, continuing without it"
fi

say "→ Mounting"
# Mount at a path we picked. Reading the mount point back out of hdiutil's
# output does not survive -quiet, which prints nothing, and the tab-separated
# columns it prints otherwise are not worth parsing.
mkdir -p "$MOUNT"
hdiutil attach "$TMP/ClaudeNotch.dmg" -nobrowse -quiet -mountpoint "$MOUNT" \
    || die "Could not mount the disk image."
[ -d "$MOUNT/ClaudeNotch.app" ] \
    || die "The disk image did not contain ClaudeNotch.app."

# --- replace
# Quit first: copying over a running bundle leaves the old code mapped and the
# relaunch below would start a half-replaced app.
if pgrep -x ClaudeNotch >/dev/null 2>&1; then
    say "→ Quitting ClaudeNotch"
    osascript -e 'quit app "ClaudeNotch"' >/dev/null 2>&1 || pkill -x ClaudeNotch || true
    for _ in $(seq 1 20); do
        pgrep -x ClaudeNotch >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

say "→ Installing to /Applications"
rm -rf "$APP"
cp -R "$MOUNT/ClaudeNotch.app" "$APP" || die "Could not copy into /Applications."

say "→ Relaunching"
open -a "$APP"

say ""
say "✓ Updated to v${LATEST}. Release notes: https://rawsun007.github.io/claude-notch/changelog/"
