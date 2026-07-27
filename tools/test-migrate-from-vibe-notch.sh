#!/bin/bash
# Golden tests for tools/migrate-from-vibe-notch.sh.
#
# The migration edits the user's real ~/.claude/settings.json, which is a file
# they cannot afford to have mangled: it holds hooks from other tools, and the
# whole point is to remove one app's entries without touching anyone else's.
# Every case here runs against a throwaway HOME.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE="$SCRIPT_DIR/migrate-from-vibe-notch.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# A settings.json with their hooks tangled up with hooks from other tools.
fixture() {
    mkdir -p "$1/.claude/hooks"
    cat > "$1/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/usr/bin/python3 /Users/x/.claude/hooks/claude-island-state.py"},
        {"type": "command", "command": "/Users/x/my-own-audit.sh"}
      ]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "python3 /Users/x/.claude/hooks/claude-island-state.py"}]}
    ],
    "Notification": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/Users/x/notify-me.sh"}]}
    ]
  }
}
EOF
    touch "$1/.claude/hooks/claude-island-state.py"
}

echo "migrate-from-vibe-notch"

# --- their hooks go, everyone else's stay
T=$(mktemp -d); fixture "$T"
HOME="$T" "$MIGRATE" --no-install >/dev/null 2>&1
S="$T/.claude/settings.json"
check "removes every hook of theirs" \
      "$(jq '[.. | objects | select(.command? // "" | contains("claude-island-state")) ] | length' "$S")" "0"
check "keeps another tool's hook in a shared event" \
      "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")" "/Users/x/my-own-audit.sh"
check "keeps an event that was never theirs" \
      "$(jq -r '.hooks.Notification[0].hooks[0].command' "$S")" "/Users/x/notify-me.sh"
check "drops an event left empty" \
      "$(jq 'has("hooks") and (.hooks | has("Stop"))' "$S")" "false"
check "leaves unrelated settings alone" \
      "$(jq -r '.model' "$S")" "opus"
check "moves their script aside instead of deleting it" \
      "$(ls "$T/.claude/hooks/" | grep -c 'claude-island-state.py.disabled')" "1"
check "backs up the original settings" \
      "$(ls "$T/.claude/" | grep -c 'settings.json.before-claudenotch-migration')" "1"
rm -rf "$T"

# --- running it twice must not change anything the second time
T=$(mktemp -d); fixture "$T"
HOME="$T" "$MIGRATE" --no-install >/dev/null 2>&1
FIRST=$(cat "$T/.claude/settings.json")
OUT=$(HOME="$T" "$MIGRATE" --no-install 2>&1)
check "second run reports nothing to do" \
      "$(printf '%s' "$OUT" | grep -c 'No Vibe Notch install detected')" "1"
check "second run leaves the file byte identical" \
      "$(if [ "$FIRST" = "$(cat "$T/.claude/settings.json")" ]; then echo same; else echo changed; fi)" "same"
rm -rf "$T"

# --- dry run must not touch anything
T=$(mktemp -d); fixture "$T"
BEFORE=$(cat "$T/.claude/settings.json")
HOME="$T" "$MIGRATE" --dry-run --no-install >/dev/null 2>&1
check "dry run leaves settings untouched" \
      "$(if [ "$BEFORE" = "$(cat "$T/.claude/settings.json")" ]; then echo same; else echo changed; fi)" "same"
check "dry run leaves their script in place" \
      "$(ls "$T/.claude/hooks/" | grep -c '^claude-island-state.py$')" "1"
rm -rf "$T"

# --- a machine that never had it
T=$(mktemp -d); mkdir -p "$T/.claude"
echo '{"model":"opus"}' > "$T/.claude/settings.json"
OUT=$(HOME="$T" "$MIGRATE" --no-install 2>&1); RC=$?
check "clean machine exits successfully" "$RC" "0"
check "clean machine says there is nothing to migrate" \
      "$(printf '%s' "$OUT" | grep -c 'No Vibe Notch install detected')" "1"
check "clean machine settings untouched" \
      "$(jq -r '.model' "$T/.claude/settings.json")" "opus"
rm -rf "$T"

# --- no settings.json at all
T=$(mktemp -d)
OUT=$(HOME="$T" "$MIGRATE" --no-install 2>&1); RC=$?
check "missing settings.json exits successfully" "$RC" "0"
check "missing settings.json is reported, not crashed on" \
      "$(printf '%s' "$OUT" | grep -c 'Nothing to migrate')" "1"
rm -rf "$T"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
