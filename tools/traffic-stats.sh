#!/bin/bash
# Views, uniques and how many of them ended up downloading.
#
#   ./tools/traffic-stats.sh             # last 14 days + today's conversion
#   ./tools/traffic-stats.sh --snapshot  # also record today's numbers
#   ./tools/traffic-stats.sh --history   # the recorded series
#
# GitHub keeps traffic for 14 days and then forgets it, so the only way to have
# a year of it is to write it down. --snapshot appends to
# tools/traffic-history.tsv (one row per day, committed).
#
# Downloads come from the release assets, the same number download-stats.sh
# prints, so the two series can be read against each other: views say how many
# people arrived, downloads say how many of them wanted it enough to install.
#
# Needs push access to the repo (traffic is not public).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="rawsun007/claude-notch"
HISTORY="tools/traffic-history.tsv"
TODAY=$(date -u +%Y-%m-%d)

command -v gh >/dev/null 2>&1 || { echo "needs the gh CLI: brew install gh"; exit 1; }

if [ "${1:-}" = "--history" ]; then
    [ -f "$HISTORY" ] || { echo "no history yet, run --snapshot first"; exit 0; }
    column -t -s "$(printf '\t')" "$HISTORY"
    exit 0
fi

VIEWS_JSON=$(gh api "repos/${REPO}/traffic/views")
CLONES_JSON=$(gh api "repos/${REPO}/traffic/clones")
DOWNLOADS=$(gh api --paginate "repos/${REPO}/releases?per_page=100" --jq '.[]' \
    | python3 "$(dirname "$0")/download_stats.py" | tail -1)
STARS=$(gh api "repos/${REPO}" --jq '.stargazers_count')

read -r VIEWS UNIQUES <<EOF
$(printf '%s' "$VIEWS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["uniques"])')
EOF
read -r CLONES CLONE_UNIQUES <<EOF
$(printf '%s' "$CLONES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["uniques"])')
EOF

printf '%s\n\n' "ClaudeNotch traffic (${REPO}, last 14 days)"
printf '  %-22s %6s\n' "views" "$VIEWS"
printf '  %-22s %6s\n' "unique visitors" "$UNIQUES"
printf '  %-22s %6s\n' "clones" "$CLONES"
printf '  %-22s %6s\n' "unique cloners" "$CLONE_UNIQUES"
printf '  %-22s %6s\n' "stars (total)" "$STARS"
printf '  %-22s %6s\n' "downloads (total)" "$DOWNLOADS"

# Clones are mostly CI: every push checks the repo out on a runner, and this
# repo pushes many times a day. Said out loud so the number is not read as
# demand.
printf '\n  note: clones count CI checkouts, so they are not visitors\n'

echo
echo "  top referrers"
gh api "repos/${REPO}/traffic/popular/referrers" \
    --jq '.[] | "    \(.referrer)  \(.count) views, \(.uniques) unique"' | head -6

if [ "${1:-}" = "--snapshot" ]; then
    [ -f "$HISTORY" ] || printf 'date\tviews\tuniques\tstars\tdownloads\n' > "$HISTORY"
    grep -v "^${TODAY}	" "$HISTORY" > "${HISTORY}.tmp" || true
    mv "${HISTORY}.tmp" "$HISTORY"
    printf '%s\t%s\t%s\t%s\t%s\n' "$TODAY" "$VIEWS" "$UNIQUES" "$STARS" "$DOWNLOADS" >> "$HISTORY"
    echo
    echo "  recorded in ${HISTORY}"

    # Conversion needs two readings, not one: downloads is a running total, so
    # what matters is how many arrived and how many installed BETWEEN snapshots.
    PREV=$(grep -v "^date	" "$HISTORY" | grep -v "^${TODAY}	" | tail -1)
    if [ -n "$PREV" ]; then
        python3 - "$PREV" "$TODAY" "$UNIQUES" "$DOWNLOADS" <<'PY'
import sys
prev = sys.argv[1].split("\t")
today, uniques, downloads = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
gained = downloads - int(prev[4])
print()
print(f"  since {prev[0]}: +{gained} downloads, {uniques} unique visitors in the trailing 14 days")
if uniques:
    print(f"  roughly {gained / uniques * 100:.0f} downloads per 100 visitors")
print("  (visitors is a 14-day window, downloads is the gap between snapshots,")
print("   so treat this as a trend line and not a conversion rate)")
PY
    fi
fi
