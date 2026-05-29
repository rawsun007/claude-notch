#!/bin/bash
# Claude Code SessionEnd hook: tell ClaudeNotch the session has ended (Ctrl+C /
# Ctrl+D / exit) so it can drop that session from the notch immediately.
# Fire-and-forget — never blocks Claude.
set -u
LOG=/tmp/claudenotch-hook.log
input=$(cat)
echo "[$(date '+%H:%M:%S')] sessionend hook fired" >> "$LOG"
nc -z 127.0.0.1 53127 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -c '{
    cwd:             (.cwd        // ""),
    session_id:      (.session_id // "")
}' | curl -s --max-time 2 -X POST \
       -H 'Content-Type: application/json' \
       --data-binary @- \
       http://127.0.0.1:53127/sessionend >/dev/null || true
exit 0
