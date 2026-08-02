#!/bin/bash
# Release asset download counts, i.e. roughly how many people installed.
#
#   ./tools/download-stats.sh            # per release + total
#   ./tools/download-stats.sh --snapshot # also record today's total
#   ./tools/download-stats.sh --since    # change since the last snapshot
#
# GitHub only exposes a running total per asset, never a time series, so the
# only way to see growth is to write down the number periodically. --snapshot
# appends to tools/download-history.tsv (one line per day, committed) and
# --since diffs today against the newest line already in that file.
#
# Homebrew installs count here too: brew downloads the DMG from the release.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="rawsun007/claude-notch"
HISTORY="tools/download-history.tsv"

command -v gh >/dev/null 2>&1 || { echo "needs the gh CLI: brew install gh"; exit 1; }

# --paginate, because the release list is already past one page.
REPORT=$(gh api --paginate "repos/${REPO}/releases?per_page=100" --jq '.[]' \
    | python3 "$(dirname "$0")/download_stats.py")
TOTAL=$(printf '%s' "$REPORT" | tail -1)

printf '%s\n\n' "ClaudeNotch downloads (${REPO})"
printf '%s\n' "$REPORT" | sed '$d'
printf '\n  %-10s %6s\n' "TOTAL" "$TOTAL"

TODAY=$(date -u +%Y-%m-%d)

if [ "${1:-}" = "--snapshot" ]; then
    [ -f "$HISTORY" ] || printf 'date\ttotal\n' > "$HISTORY"
    # One row per day: re-running on the same day replaces that day's number.
    grep -v "^${TODAY}	" "$HISTORY" > "${HISTORY}.tmp" || true
    mv "${HISTORY}.tmp" "$HISTORY"
    printf '%s\t%s\n' "$TODAY" "$TOTAL" >> "$HISTORY"
    echo
    echo "  snapshot recorded in ${HISTORY}"
fi

if [ "${1:-}" = "--since" ]; then
    if [ ! -f "$HISTORY" ]; then
        echo
        echo "  no history yet — run --snapshot once to start the series"
        exit 0
    fi
    PREV=$(grep -v "^date	" "$HISTORY" | grep -v "^${TODAY}	" | tail -1)
    if [ -z "$PREV" ]; then
        echo
        echo "  only today in the history — run --snapshot again tomorrow"
        exit 0
    fi
    PREV_DATE=${PREV%%	*}
    PREV_TOTAL=${PREV##*	}
    DAYS=$(( ( $(date -u -j -f %Y-%m-%d "$TODAY" +%s) - $(date -u -j -f %Y-%m-%d "$PREV_DATE" +%s) ) / 86400 ))
    echo
    printf '  +%s since %s (%s day(s), %.1f/day)\n' \
        "$(( TOTAL - PREV_TOTAL ))" "$PREV_DATE" "$DAYS" \
        "$(python3 -c "print(($TOTAL - $PREV_TOTAL) / max($DAYS, 1))")"
fi
