#!/bin/bash
# Claude Code PermissionRequest hook: surface permission dialogs that DON'T go
# through PreToolUse (e.g. TodoWrite, ExitPlanMode / "proceed with plan") in the
# notch so they can be answered without switching to the terminal.
#
# Fail-safe by construction: on any error or an "ask"/unknown decision we emit
# nothing and exit 0, so Claude Code's own prompt still runs. We never block
# Claude from getting an answer.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
# notch_log writes to the user's own 0700 directory. It used to be a fixed
# name in /tmp, which any other local user could pre-create as a symlink.
. "$DIR/claudenotch-common.sh"
# Overridable so tools/test-blocking-hooks.sh can point this at a server it
# controls, with a timeout short enough to test. Nothing else sets them.
HOST="${CLAUDENOTCH_HOST:-127.0.0.1}"
PORT="${CLAUDENOTCH_PORT:-53127}"
WAIT="${CLAUDENOTCH_TIMEOUT:-290}"

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // "?"' 2>/dev/null)
notch_log "permreq hook fired: tool=$tool"

# Pass through (Claude's own prompt) when we can't reach the notch or lack jq.
pass_through() {
    notch_log "  → pass through (${1:-native prompt})"
    exit 0
}

command -v jq >/dev/null 2>&1 || pass_through "jq missing"

# Same rule as the PreToolUse hook: a payload we cannot read cannot be shown on
# a card, so an answer to that card is not an answer about anything. Here it
# would have approved a plan or a todo list nobody saw.
printf '%s' "$input" | jq -e . >/dev/null 2>&1 || pass_through "payload is not JSON"
nc -z "$HOST" "$PORT" 2>/dev/null || pass_through "notch not running"

# Reuse the blocking permission card. The PermissionRequest payload carries the
# same tool_name / tool_input the card needs, so /permission renders it as-is.
response=$(printf '%s' "$input" | curl -s --max-time "$WAIT" -X POST \
    -H 'Content-Type: application/json' \
        -H "$NOTCH_AUTH" \
    --data-binary @- \
    http://$HOST:$PORT/permission || true)

[ -n "$response" ] || pass_through "empty response from notch"

decision=$(printf '%s' "$response" | jq -r '.decision // "ask"' 2>/dev/null)
case "$decision" in
    allow|deny)
        notch_log "  → emit $decision (PermissionRequest)"
        printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s"}}}\n' "$decision"
        exit 0 ;;
    *)
        # "ask", timeout, or anything unexpected → let Claude prompt normally.
        pass_through "decision=$decision" ;;
esac
