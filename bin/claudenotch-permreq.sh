#!/bin/bash
# Claude Code PermissionRequest hook: surface permission dialogs that DON'T go
# through PreToolUse (e.g. TodoWrite, ExitPlanMode / "proceed with plan") in the
# notch so they can be answered without switching to the terminal.
#
# Fail-safe by construction: on any error or an "ask"/unknown decision we emit
# nothing and exit 0, so Claude Code's own prompt still runs. We never block
# Claude from getting an answer.
set -u
LOG=/tmp/claudenotch-hook.log

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // "?"' 2>/dev/null)
echo "[$(date '+%H:%M:%S')] permreq hook fired: tool=$tool" >> "$LOG"

# Temporary: capture raw payloads to confirm the PermissionRequest schema
# (tool_name / tool_input) across tools like TodoWrite and ExitPlanMode.
# Remove once the schema is confirmed.
printf '%s\n' "$input" >> /tmp/claudenotch-permreq-raw.log

# Pass through (Claude's own prompt) when we can't reach the notch or lack jq.
pass_through() {
    echo "[$(date '+%H:%M:%S')]   → pass through (${1:-native prompt})" >> "$LOG"
    exit 0
}

command -v jq >/dev/null 2>&1 || pass_through "jq missing"
nc -z 127.0.0.1 53127 2>/dev/null || pass_through "notch not running"

# Reuse the blocking permission card. The PermissionRequest payload carries the
# same tool_name / tool_input the card needs, so /permission renders it as-is.
response=$(printf '%s' "$input" | curl -s --max-time 290 -X POST \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    http://127.0.0.1:53127/permission || true)

[ -n "$response" ] || pass_through "empty response from notch"

decision=$(printf '%s' "$response" | jq -r '.decision // "ask"' 2>/dev/null)
case "$decision" in
    allow|deny)
        echo "[$(date '+%H:%M:%S')]   → emit $decision (PermissionRequest)" >> "$LOG"
        printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s"}}}\n' "$decision"
        exit 0 ;;
    *)
        # "ask", timeout, or anything unexpected → let Claude prompt normally.
        pass_through "decision=$decision" ;;
esac
