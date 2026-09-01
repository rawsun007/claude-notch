#!/bin/bash
# Cut a new ClaudeNotch release.
#
#   ./tools/release.sh 0.2.5
#
# What it does:
#   1. Bumps CFBundleShortVersionString (and CFBundleVersion) in build.sh
#   2. Builds the branded DMG (tools/build-dmg.sh)
#   3. Computes the DMG sha256 and updates Casks/claudenotch.rb
#   4. Commits the bump + cask and pushes
#   5. If GITHUB_TOKEN is set, creates the GitHub release and uploads the DMG;
#      otherwise prints the manual upload steps.
#
# After it finishes: add a matching entry to the website changelog
# (app/changelog/releases.ts), rebuild the site, and push docs/.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="rawsun007/claude-notch"
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: ./tools/release.sh <version>   e.g. ./tools/release.sh 0.2.5"
    exit 1
fi

echo "→ Releasing v$VERSION"

# 0. Refuse to publish a build that cannot be notarized.
#
# Until the Developer ID existed, this script skipped notarization when the
# credentials were absent and said so in one line, so a release still worked on
# a machine with no Apple account. Now that every published release is notarized
# that leniency is a trap: the DMG builds, the tag pushes, the cask updates, and
# the artifact people download is one Gatekeeper blocks, which reads to them as
# ClaudeNotch having been compromised. Worse, it would train users to click past
# the warning again after we spent this work removing it.
#
# Escape hatch, deliberately awkward to type, for the case where an unsigned
# artifact is genuinely wanted (reproducing an old build, testing this script):
#   CLAUDENOTCH_ALLOW_UNNOTARIZED=1 ./tools/release.sh <version>
if [ -z "${CLAUDENOTCH_NOTARY_PROFILE:-}" ] && [ -z "${CLAUDENOTCH_ALLOW_UNNOTARIZED:-}" ]; then
    cat >&2 <<'TXT'
CLAUDENOTCH_NOTARY_PROFILE is not set, so this release could not be notarized.

Every published release is notarized, so shipping one that is not would put a
Gatekeeper warning in front of every download, on an app whose whole job is
gating what an agent may run.

  export CLAUDENOTCH_NOTARY_PROFILE=claudenotch

See SIGNING.md if the profile is not on this machine yet. To build an
unnotarized artifact on purpose:

  CLAUDENOTCH_ALLOW_UNNOTARIZED=1 ./tools/release.sh <version>
TXT
    exit 1
fi

# 1. Bump versions in build.sh.
OLD_SHORT=$(grep -oE 'CFBundleShortVersionString</key><string>[^<]*' build.sh | sed 's/.*>//')
OLD_BUILD=$(grep -oE 'CFBundleVersion</key><string>[0-9]*' build.sh | sed 's/.*>//')
NEW_BUILD=$(( ${OLD_BUILD:-0} + 1 ))
sed -i '' "s#CFBundleShortVersionString</key><string>${OLD_SHORT}</string>#CFBundleShortVersionString</key><string>${VERSION}</string>#" build.sh
sed -i '' "s#CFBundleVersion</key><string>${OLD_BUILD}</string>#CFBundleVersion</key><string>${NEW_BUILD}</string>#" build.sh
# The Xcode project carries the same two numbers, because Xcode reads
# Info.plist and project.yml rather than build.sh's heredoc. Left alone they
# drift, and a build made from Xcode then reports a version that never existed.
# build.sh stays the source of truth; these follow it.
# Info.plist is deliberately NOT touched. It holds $(MARKETING_VERSION) and
# $(CURRENT_PROJECT_VERSION), which Xcode substitutes at build time from
# project.yml. Writing literals into it would replace those variables with a
# number that then never changes again, which is the opposite of keeping the
# two in step.
if [ -f project.yml ]; then
    sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" project.yml
    sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" project.yml
fi
git add -A project.yml 2>/dev/null || true

echo "  version ${OLD_SHORT} → ${VERSION} (build ${OLD_BUILD} → ${NEW_BUILD})"

# 2. Build the DMG (this also rebuilds the .app).
./tools/build-dmg.sh >/dev/null
DMG="dist/ClaudeNotch.dmg"
[ -f "$DMG" ] || { echo "DMG build failed"; exit 1; }

# 2b. Notarize, when there is a credential profile to do it with.
#
# Without this the download is stamped "Apple could not verify this app is free
# of malware", every new user has to right-click-Open past it, and macOS holds
# a first-launch assessment on the bundle. Skipped entirely when
# CLAUDENOTCH_NOTARY_PROFILE is unset, so a release still works on a machine
# with no Apple credentials rather than failing at the last step.
#
# Both the app and the DMG are stapled. Stapling only the DMG leaves the app
# needing a network round trip on first launch, which fails offline; stapling
# only the app leaves the DMG itself flagged on download.
if [ -n "${CLAUDENOTCH_NOTARY_PROFILE:-}" ]; then
    echo "→ Notarizing (profile: ${CLAUDENOTCH_NOTARY_PROFILE})"
    APP_ZIP="dist/ClaudeNotch-notarize.zip"
    rm -f "$APP_ZIP"
    # ditto, not zip: it preserves the bundle's symlinks and extended
    # attributes, and a zip of a .app that loses them fails notarization.
    /usr/bin/ditto -c -k --keepParent ClaudeNotch.app "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" \
        --keychain-profile "$CLAUDENOTCH_NOTARY_PROFILE" --wait \
        || { echo "notarization of the app failed"; exit 1; }
    xcrun stapler staple ClaudeNotch.app \
        || { echo "could not staple the app"; exit 1; }
    rm -f "$APP_ZIP"

    # Repackage so the DMG carries the stapled app. Explicitly WITHOUT
    # rebuilding: build.sh would produce a fresh bundle and the ticket just
    # attached would be gone, which is a mistake that leaves a DMG looking
    # notarized while the app inside is not.
    CLAUDENOTCH_SKIP_BUILD=1 ./tools/build-dmg.sh >/dev/null
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$CLAUDENOTCH_NOTARY_PROFILE" --wait \
        || { echo "notarization of the DMG failed"; exit 1; }
    xcrun stapler staple "$DMG" || { echo "could not staple the DMG"; exit 1; }

    # Say what Gatekeeper will say, rather than assuming it worked, and stop if
    # it says no. This was already fatal, but only by accident: spctl exits
    # nonzero and `set -o pipefail` took the script down with no explanation of
    # what had failed or what state the tree was left in. Cutting v0.34.0 hit
    # exactly that, and the last line of output was "source=no usable signature"
    # with no indication that the release had stopped.
    if ! spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /'; then
        echo
        echo "Gatekeeper rejects $DMG, so this release stops here. Nothing was"
        echo "committed, tagged or published."
        echo
        echo "'no usable signature' means the disk image itself was not signed,"
        echo "even though the app inside it was and Apple notarized it. Check the"
        echo "signing identity build.sh pins is in this keychain."
        exit 1
    fi

    # And check the app, not only the disk image. A notarized DMG says nothing
    # about whether the bundle inside carries its entitlements, its usage
    # strings, or the resources build.sh is meant to have copied in, and each of
    # those fails silently at runtime rather than here.
    ./tools/verify-notarized-build.sh ClaudeNotch.app \
        || { echo "the signed app failed verification, not publishing"; exit 1; }
    echo "✓ Notarized and stapled"
else
    # Only reachable with CLAUDENOTCH_ALLOW_UNNOTARIZED set, since the guard at
    # the top of this script exits otherwise.
    echo "  ⚠ NOT NOTARIZED (CLAUDENOTCH_ALLOW_UNNOTARIZED). Gatekeeper will"
    echo "    block this DMG for every user. Do not publish it as a release."
fi

# 3. sha256 + generate the Homebrew cask into dist/ (NOT the repo root — the
#    cask is served only from rawsun007/homebrew-tap now, so the main repo no
#    longer carries a Casks/ dir that would make it a second, conflicting tap).
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
mkdir -p dist
sed -e "s/__VERSION__/${VERSION}/" -e "s/__SHA__/${SHA}/" \
    tools/claudenotch.rb.tmpl > dist/claudenotch.rb
echo "  cask generated: version ${VERSION}, sha256 ${SHA:0:12}…"

# 4. Commit the bump and push so the tag points at this commit.
git add build.sh
git commit -m "Release v${VERSION}" >/dev/null

# Resolve a token for the GitHub API: prefer an explicit env var, else the
# gh CLI's stored login, so nothing has to be pasted on each release.
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
    TOKEN=$(gh auth token 2>/dev/null || true)
fi

# Wait for any in-progress GitHub Pages deploy to clear before pushing —
# Pages refuses concurrent deploys, and our push will trigger a fresh one
# even though docs/ didn't change in this commit. Skip silently if no
# token is available or the API check fails.
if [ -n "$TOKEN" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        in_prog=$(curl -s -H "Authorization: token ${TOKEN}" \
            "https://api.github.com/repos/${REPO}/actions/runs?per_page=10&status=in_progress" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for r in d.get('workflow_runs',[]) if 'pages' in r.get('name','').lower()))" 2>/dev/null || echo "0")
        [ "$in_prog" = "0" ] && break
        echo "  waiting for in-progress Pages deploy to finish ($i/12)…"
        sleep 10
    done
fi

git push origin main >/dev/null
echo "  committed + pushed version bump"

# 5. Create the GitHub release + upload the DMG.
BODY="ClaudeNotch v${VERSION}. See the changelog: https://rawsun007.github.io/claude-notch/changelog/"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # Preferred path: gh uses its keychain-stored login — no token needed.
    if gh release create "v${VERSION}" "$DMG" \
        --repo "${REPO}" \
        --title "ClaudeNotch v${VERSION}" \
        --notes "$BODY" >/dev/null 2>&1; then
        echo "✓ Published release v${VERSION} with ClaudeNotch.dmg (via gh)"
    else
        echo "⚠ gh release create failed. Run 'gh auth login', or finish manually at:"
        echo "       https://github.com/${REPO}/releases/new?tag=v${VERSION}"
        echo "     and upload ${DMG} as ClaudeNotch.dmg"
    fi
elif [ -n "$TOKEN" ]; then
    RESP=$(curl -s -X POST \
        -H "Authorization: token ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/releases" \
        -d "{\"tag_name\":\"v${VERSION}\",\"name\":\"ClaudeNotch v${VERSION}\",\"body\":$(printf '%s' "$BODY" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}")
    UPLOAD=$(printf '%s' "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url','').split('{')[0])" 2>/dev/null || echo "")
    if [ -n "$UPLOAD" ]; then
        curl -s -X POST \
            -H "Authorization: token ${TOKEN}" \
            -H "Content-Type: application/octet-stream" \
            --data-binary @"$DMG" \
            "${UPLOAD}?name=ClaudeNotch.dmg" >/dev/null
        echo "✓ Published release v${VERSION} with ClaudeNotch.dmg"
    else
        echo "⚠ Could not create the release via API. Response:"
        printf '%s\n' "$RESP" | head -5
    fi
else
    echo
    echo "No gh login or GITHUB_TOKEN — finish the release manually:"
    echo "  1. Create a release tagged v${VERSION} at:"
    echo "       https://github.com/${REPO}/releases/new?tag=v${VERSION}"
    echo "  2. Upload ${DMG} as an asset named ClaudeNotch.dmg"
    echo "     (the cask expects releases/download/v${VERSION}/ClaudeNotch.dmg)"
fi


# Keep the Homebrew tap serving the new version.
"$(dirname "$0")/push-cask-to-tap.sh" || true

# Reinstall the freshly built .app into /Applications and relaunch, so the
# machine that cut the release is actually running it. build-dmg.sh already
# rebuilt ClaudeNotch.app for this version; without this step the local install
# silently lags the release (e.g. About kept showing the previous version).
if [ -d "ClaudeNotch.app" ]; then
    pkill -x ClaudeNotch 2>/dev/null || true
    sleep 1
    rm -rf /Applications/ClaudeNotch.app
    if cp -R ClaudeNotch.app /Applications/ 2>/dev/null; then
        open /Applications/ClaudeNotch.app || true
        echo "  reinstalled v${VERSION} to /Applications and relaunched"
    else
        echo "  ⚠ could not copy to /Applications — reinstall manually"
    fi
fi

# Nudge to keep the in-app What's new list current. It is a hand-maintained
# constant, so it lags unless updated with each release.
if ! grep -q "whatsNew" Sources/ClaudeNotch/SettingsWindow.swift 2>/dev/null; then
    :
else
    echo "  reminder: update the whatsNew highlights in SettingsWindow.swift for v${VERSION}"
fi

echo
echo "Next: add a v${VERSION} entry to app/changelog/releases.ts on the website,"
echo "then rebuild it and copy out/ into docs/ so the changelog page updates."
