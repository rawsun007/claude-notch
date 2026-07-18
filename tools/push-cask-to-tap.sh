#!/bin/bash
# Push the generated cask (dist/claudenotch.rb) to rawsun007/homebrew-tap so
# `brew install --cask rawsun007/tap/claudenotch` serves the new version. That
# tap is the ONLY place the cask lives — the main repo no longer ships a Casks/
# dir (which would be a second, conflicting tap). release.sh generates
# dist/claudenotch.rb, then calls this.
set -euo pipefail
cd "$(dirname "$0")/.."

TAP_REPO="rawsun007/homebrew-tap"
DEST="Casks/claudenotch.rb"
SRC="dist/claudenotch.rb"
VERSION=$(grep -m1 'version' "$SRC" | sed 's/[^0-9.]*//g')

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "⚠ gh not available/authed — update the tap manually:"
    echo "  copy ${SRC} to https://github.com/${TAP_REPO}/${DEST}"
    exit 1
fi

# The contents API needs the current blob sha to update an existing file.
SHA=$(gh api "repos/${TAP_REPO}/contents/${DEST}" --jq '.sha' 2>/dev/null || echo "")

ARGS=(-f message="Update claudenotch cask to v${VERSION}"
      -f content="$(base64 -i "$SRC")")
[ -n "$SHA" ] && ARGS+=(-f sha="$SHA")

gh api -X PUT "repos/${TAP_REPO}/contents/${DEST}" "${ARGS[@]}" --jq '.commit.sha' >/dev/null
echo "✓ Tap updated to v${VERSION} — brew install --cask rawsun007/tap/claudenotch"
