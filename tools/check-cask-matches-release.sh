#!/bin/bash
# Answer one question: can a user actually install and update right now?
#
#   tools/check-cask-matches-release.sh            # the latest release
#   tools/check-cask-matches-release.sh 0.34.0     # a specific version
#
# The Homebrew cask carries a sha256 for the DMG it points at. Two things
# publish that DMG, tools/release.sh and the release workflow, and the workflow
# uploads with --clobber, so the published bytes can change after the cask was
# written. When they disagree:
#
#   - `brew install --cask` fails on a checksum mismatch;
#   - claudenotch-update.sh refuses the download, which is the integrity check
#     doing its job and still leaves Update Now dead for everyone.
#
# Neither failure is visible from this repo. Nothing here builds or publishes,
# so this is safe to run at any time, and it is the check to run after any
# release, any workflow re-run, and before believing an install works.
set -uo pipefail
cd "$(dirname "$0")/.."

REPO="rawsun007/claude-notch"
# Through the API, not raw.githubusercontent.com. That is a CDN and serves a
# stale copy of the cask for minutes after the tap is updated, so a check run
# right after a release, which is the only time anybody runs it, reports a
# mismatch that does not exist. This script raising a false alarm is nearly as
# bad as it missing a real one: both teach you to ignore the answer.
CASK_URL="https://api.github.com/repos/rawsun007/homebrew-tap/contents/Casks/claudenotch.rb"

VERSION="${1:-}"
FAIL=0
note() { printf '  %s\n' "$1"; }
bad()  { FAIL=1; printf '  FAIL  %s\n' "$1"; }
ok()   { printf '  ok    %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo
echo "Checking the published release against the Homebrew cask"
echo

# --- the cask
CASK=$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github.raw" "$CASK_URL") \
    || { echo "  could not fetch the cask from the tap" >&2; exit 1; }
CASK_VERSION=$(printf '%s\n' "$CASK" | sed -n 's/^  version "\(.*\)"$/\1/p' | head -1)
CASK_SHA=$(printf '%s\n' "$CASK" | sed -n 's/^  sha256 "\([a-f0-9]\{64\}\)"$/\1/p' | head -1)
[ -n "$CASK_VERSION" ] && [ -n "$CASK_SHA" ] \
    || { echo "  could not parse version/sha256 out of the cask" >&2; exit 1; }
note "cask: v${CASK_VERSION}, sha256 ${CASK_SHA}"

# --- which release to compare against
if [ -z "$VERSION" ]; then
    # The cask is the thing users install, so its version is what we check by
    # default. Asking GitHub for "latest" instead would hide the failure this
    # script exists for: a cask left behind on an older version entirely.
    VERSION="$CASK_VERSION"
    LATEST=$(curl -fsSL --max-time 30 "https://api.github.com/repos/${REPO}/releases/latest" \
             | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    LATEST=${LATEST#v}
    if [ -n "$LATEST" ] && [ "$LATEST" != "$CASK_VERSION" ]; then
        bad "the cask serves v${CASK_VERSION} but the latest release is v${LATEST}"
        note "      Homebrew users are stuck on the older version. Fix with:"
        note "      ./tools/sync-cask-to-release.sh ${LATEST}"
    else
        ok "the cask is on the latest release (v${CASK_VERSION})"
    fi
fi

# --- the published artifact
URL="https://github.com/${REPO}/releases/download/v${VERSION}/ClaudeNotch.dmg"
curl -fsSL --max-time 300 -o "$TMP/ClaudeNotch.dmg" "$URL" \
    || { bad "could not download $URL"; echo; echo "1 or more checks failed"; exit 1; }
DMG_SHA=$(shasum -a 256 "$TMP/ClaudeNotch.dmg" | cut -d' ' -f1)
note "published v${VERSION}: sha256 ${DMG_SHA}"

if [ "$DMG_SHA" = "$CASK_SHA" ]; then
    ok "the cask checksum matches the published DMG"
else
    bad "checksum mismatch: brew install and Update Now are both broken"
    note "      cask      ${CASK_SHA}"
    note "      published ${DMG_SHA}"
    note "      Fix with: ./tools/sync-cask-to-release.sh ${VERSION}"
fi

# --- and that the artifact users get is one we would stand behind
ASSESS=$(spctl -a -vvv -t install "$TMP/ClaudeNotch.dmg" 2>&1 || true)
if printf '%s\n' "$ASSESS" | grep -q 'source=Notarized Developer ID'; then
    ok "the published DMG is notarized"
else
    bad "the published DMG is not notarized: $(printf '%s\n' "$ASSESS" | tail -1)"
fi
if xcrun stapler validate "$TMP/ClaudeNotch.dmg" >/dev/null 2>&1; then
    ok "the published DMG has a stapled ticket"
else
    bad "the published DMG has no stapled ticket"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "Installing and updating both work."
else
    echo "Something users depend on is broken. See above."
fi
exit "$FAIL"
