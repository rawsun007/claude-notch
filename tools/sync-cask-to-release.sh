#!/bin/bash
# Point the Homebrew cask at the DMG that is actually published, and verify it
# before doing so.
#
#   tools/sync-cask-to-release.sh 0.34.0
#
# Why this is not just "shasum the file we built":
#
# Two things publish a DMG for a tag. tools/release.sh uploads the one it built
# locally, and .github/workflows/release.yml builds its own from the tag commit
# and uploads it with --clobber. Whichever lands last is what users download,
# and the cask carries a sha256 that has to match THAT file, not the one that
# happened to be on the release machine. Before the CI signing secrets existed
# the workflow died at its first step and the question never came up; now it
# runs, wins the race, and a cask generated from the local build points at a
# checksum nobody can download. The symptom is `brew install` failing on a
# checksum mismatch, and the self-updater correctly refusing to install, which
# together mean nobody can update.
#
# So the checksum comes from the published asset, after the workflow that might
# replace it has finished. Re-runnable: it is also the fix if a cask has already
# gone out wrong.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="rawsun007/claude-notch"
VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: ./tools/sync-cask-to-release.sh <version>   e.g. 0.34.0" >&2
    exit 2
fi
TAG="v${VERSION}"

command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
    || { echo "gh is required and must be logged in." >&2; exit 2; }

# 1. Wait out any Release workflow run for this tag.
#
# Only runs of the release workflow matter here; CI and the Pages deploy do not
# touch the asset. A run that fails is reported rather than waited on forever:
# the local upload is then what is published, which is still a valid artifact.
#
# The tag is created by the release moments before this runs, and GitHub takes a
# few seconds to queue the workflow for it, so asking once is a race this lost
# on the first release that used it: no run was found, the cask was written, and
# the workflow started twelve seconds later to replace the asset underneath it.
# Poll for one to appear instead. The wait is bounded because most tags never
# start a run at all, and waiting the full window on every release would add a
# minute of nothing to each one.
find_run() {
    gh run list --workflow=release.yml --limit 20 \
        --json databaseId,headBranch,status,conclusion \
        --jq "[.[] | select(.headBranch == \"$TAG\")] | first" 2>/dev/null || echo ""
}
RUN=$(find_run)
if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
    echo "→ No release workflow run for $TAG yet, watching for one to start"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        RUN=$(find_run)
        if [ -n "$RUN" ] && [ "$RUN" != "null" ]; then break; fi
    done
fi

if [ -n "$RUN" ] && [ "$RUN" != "null" ]; then
    RUN_ID=$(printf '%s' "$RUN" | python3 -c 'import sys,json; print(json.load(sys.stdin)["databaseId"])')
    echo "→ Release workflow run $RUN_ID exists for $TAG, waiting for it"
    # --exit-status makes a failed run a nonzero exit; we want to keep going and
    # say so, because a failed CI build leaves the local upload in place.
    gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1 || true
    CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq .conclusion)
    echo "  workflow conclusion: $CONCLUSION"
    if [ "$CONCLUSION" != "success" ]; then
        echo "  (not a blocker: the DMG uploaded by tools/release.sh is still"
        echo "   what the release serves, and that is what gets checksummed)"
    fi
else
    echo "→ No release workflow run for $TAG, nothing else is going to replace"
    echo "  the asset. Run this again if one appears later."
fi

# 2. Download what the release actually serves, through the same URL the cask
#    will point at, rather than trusting a local file to be the same bytes.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/${REPO}/releases/download/${TAG}/ClaudeNotch.dmg"
echo "→ Downloading $URL"
curl -fsSL --max-time 300 -o "$TMP/ClaudeNotch.dmg" "$URL" \
    || { echo "could not download the published DMG" >&2; exit 1; }

# 3. Verify it before pointing users at it. A cask is an instruction to install
#    something; publishing one for an artifact nobody checked is how a broken
#    release becomes an installed release.
echo "→ Verifying the published DMG"
ASSESS=$(spctl -a -vvv -t install "$TMP/ClaudeNotch.dmg" 2>&1 || true)
printf '%s\n' "$ASSESS" | sed 's/^/  /'
printf '%s\n' "$ASSESS" | grep -q 'source=Notarized Developer ID' \
    || { echo "the published DMG is not notarized, refusing to publish a cask for it" >&2; exit 1; }
xcrun stapler validate "$TMP/ClaudeNotch.dmg" >/dev/null 2>&1 \
    || { echo "the published DMG has no stapled ticket, refusing to publish a cask for it" >&2; exit 1; }

# The app inside, not only the wrapper. build-dmg.sh has shipped a notarized
# image around an unsigned one before; it can equally ship one around an app
# missing its entitlements, which nothing outside verify-notarized-build.sh
# looks at.
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$TMP/ClaudeNotch.dmg" -nobrowse -quiet -mountpoint "$MOUNT"
STATUS=0
./tools/verify-notarized-build.sh "$MOUNT/ClaudeNotch.app" >"$TMP/verify.log" 2>&1 || STATUS=1
hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true
if [ "$STATUS" -ne 0 ]; then
    echo "the app inside the published DMG failed verification:" >&2
    sed 's/^/  /' "$TMP/verify.log" >&2
    exit 1
fi
grep -E '^[0-9]+ passed' "$TMP/verify.log" | sed 's/^/  /'

# 4. Generate and push the cask.
SHA=$(shasum -a 256 "$TMP/ClaudeNotch.dmg" | cut -d' ' -f1)
mkdir -p dist
sed -e "s/__VERSION__/${VERSION}/" -e "s/__SHA__/${SHA}/" \
    tools/claudenotch.rb.tmpl > dist/claudenotch.rb
echo "→ Cask: version ${VERSION}, sha256 ${SHA}"
./tools/push-cask-to-tap.sh
