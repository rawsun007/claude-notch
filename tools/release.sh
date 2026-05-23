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

# 1. Bump versions in build.sh.
OLD_SHORT=$(grep -oE 'CFBundleShortVersionString</key><string>[^<]*' build.sh | sed 's/.*>//')
OLD_BUILD=$(grep -oE 'CFBundleVersion</key><string>[0-9]*' build.sh | sed 's/.*>//')
NEW_BUILD=$(( ${OLD_BUILD:-0} + 1 ))
sed -i '' "s#CFBundleShortVersionString</key><string>${OLD_SHORT}</string>#CFBundleShortVersionString</key><string>${VERSION}</string>#" build.sh
sed -i '' "s#CFBundleVersion</key><string>${OLD_BUILD}</string>#CFBundleVersion</key><string>${NEW_BUILD}</string>#" build.sh
echo "  version ${OLD_SHORT} → ${VERSION} (build ${OLD_BUILD} → ${NEW_BUILD})"

# 2. Build the DMG (this also rebuilds the .app).
./tools/build-dmg.sh >/dev/null
DMG="dist/ClaudeNotch.dmg"
[ -f "$DMG" ] || { echo "DMG build failed"; exit 1; }

# 3. sha256 + update the Homebrew cask.
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" Casks/claudenotch.rb
sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" Casks/claudenotch.rb
echo "  cask updated: version ${VERSION}, sha256 ${SHA:0:12}…"

# 4. Commit the bump + cask and push so the tag points at this commit.
git add build.sh Casks/claudenotch.rb
git commit -m "Release v${VERSION}" >/dev/null
git push origin main >/dev/null
echo "  committed + pushed version bump"

# 5. Create the GitHub release + upload the DMG (needs a token).
if [ -n "${GITHUB_TOKEN:-}" ]; then
    BODY="ClaudeNotch v${VERSION}. See the changelog: https://rawsun007.github.io/claude-notch/changelog/"
    RESP=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/releases" \
        -d "{\"tag_name\":\"v${VERSION}\",\"name\":\"ClaudeNotch v${VERSION}\",\"body\":$(printf '%s' "$BODY" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}")
    UPLOAD=$(printf '%s' "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url','').split('{')[0])" 2>/dev/null || echo "")
    if [ -n "$UPLOAD" ]; then
        curl -s -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
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
    echo "No GITHUB_TOKEN set — finish the release manually:"
    echo "  1. Create a release tagged v${VERSION} at:"
    echo "       https://github.com/${REPO}/releases/new?tag=v${VERSION}"
    echo "  2. Upload ${DMG} as an asset named ClaudeNotch.dmg"
    echo "     (the cask expects releases/download/v${VERSION}/ClaudeNotch.dmg)"
fi

echo
echo "Next: add a v${VERSION} entry to app/changelog/releases.ts on the website,"
echo "then rebuild it and copy out/ into docs/ so the changelog page updates."
