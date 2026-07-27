#!/bin/bash
# Move a Vibe Notch / Claude Island install over to ClaudeNotch.
#
# Both apps hook the same Claude Code events. Leaving both wired up means every
# permission prompt is answered twice, and whichever app replies first wins, so
# the migration has to REMOVE the old hooks rather than just add ours alongside.
#
# Vibe Notch wires `<python> ~/.claude/hooks/claude-island-state.py` into each
# event in ~/.claude/settings.json. That command string is the signature this
# looks for, so a hand-rolled install in a different directory is still matched.
#
# Nothing is deleted. settings.json is backed up first and the old hook script
# is moved aside, so the whole thing can be put back by hand.
#
#   tools/migrate-from-vibe-notch.sh --dry-run   # show what would change
#   tools/migrate-from-vibe-notch.sh             # migrate, then install ours
#   tools/migrate-from-vibe-notch.sh --no-install # unwire only, install later
set -euo pipefail

SIGNATURE="claude-island-state.py"
DRY_RUN=0
INSTALL=1

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=1 ;;
        --no-install) INSTALL=0 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }

SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="$HOME/.claude/hooks/$SIGNATURE"

if [ ! -f "$SETTINGS" ]; then
    echo "No ~/.claude/settings.json found. Nothing to migrate."
    exit 0
fi

# Refuse to touch a file we cannot parse. Without this the first jq fails, set -e
# aborts mid-run with a raw parse error, and the user is left guessing whether
# their settings were half-rewritten. They are not, but say so plainly.
if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "~/.claude/settings.json is not valid JSON, so nothing was changed." >&2
    echo "Fix or restore it first, then run this again." >&2
    exit 1
fi

# Count the hook entries that belong to the old app, across every event.
count_theirs() {
    jq --arg sig "$SIGNATURE" '
        [ (.hooks // {})[]?                     # each event
          | .[]?                                # each matcher group
          | (.hooks // [])[]?                   # each hook entry
          | select((.command // "") | contains($sig)) ]
        | length
    ' "$SETTINGS"
}

FOUND=$(count_theirs)

if [ "$FOUND" -eq 0 ] && [ ! -f "$HOOK_SCRIPT" ]; then
    echo "No Vibe Notch install detected. Nothing to migrate."
    [ "$INSTALL" -eq 1 ] && echo "Run ./install.sh to set up ClaudeNotch."
    exit 0
fi

echo "→ Found $FOUND Vibe Notch hook entries in ~/.claude/settings.json"
[ -f "$HOOK_SCRIPT" ] && echo "→ Found its hook script at ~/.claude/hooks/$SIGNATURE"

# Strip their entries, then drop any matcher group and any event left empty, so
# settings.json comes out the way it looked before they were ever added rather
# than littered with empty scaffolding.
STRIPPED=$(jq --arg sig "$SIGNATURE" '
    if .hooks then
        .hooks |= (
            map_values(
                map(.hooks |= map(select(((.command // "") | contains($sig)) | not)))
                | map(select((.hooks | length) > 0))
            )
            | map_values(select(length > 0))
        )
        | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
' "$SETTINGS")

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--- would write to $SETTINGS ---"
    printf '%s\n' "$STRIPPED"
    [ -f "$HOOK_SCRIPT" ] && echo "--- would move $HOOK_SCRIPT aside ---"
    [ "$INSTALL" -eq 1 ] && echo "--- would then run install-hooks.sh ---"
    echo
    echo "Dry run, nothing changed."
    exit 0
fi

TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch-migration.$TS"
cp "$SETTINGS" "$BACKUP"
printf '%s\n' "$STRIPPED" > "$SETTINGS"
echo "→ Removed their hooks (backup: $(basename "$BACKUP"))"

if [ -f "$HOOK_SCRIPT" ]; then
    mv "$HOOK_SCRIPT" "$HOOK_SCRIPT.disabled.$TS"
    echo "→ Moved their hook script aside (not deleted)"
fi

if [ "$INSTALL" -eq 1 ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    for candidate in "$SCRIPT_DIR/../bin/install-hooks.sh" "$HOME/.claudenotch/bin/install-hooks.sh"; do
        if [ -x "$candidate" ]; then
            echo "→ Installing ClaudeNotch hooks"
            "$candidate"
            break
        fi
    done
fi

echo
echo "✓ Migrated. Quit Vibe Notch so the two apps stop competing for the same events."
