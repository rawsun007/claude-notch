#!/bin/bash
# Claude Code Notification hook: tell ClaudeNotch to show a non-blocking ping.
set -u
LOG=/tmp/claudenotch-hook.log
input=$(cat)
echo "[$(date '+%H:%M:%S')] notify hook fired" >> "$LOG"
nc -z 127.0.0.1 53127 2>/dev/null || { echo "[$(date '+%H:%M:%S')]   → skipped (notch down)" >> "$LOG"; exit 0; }
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -c '{
    message:    (.message    // "Claude needs your attention"),
    detail:     (.cwd        // ""),
    cwd:        (.cwd        // ""),
    session_id: (.session_id // ""),
    source:     "Claude Code"
}' | curl -s --max-time 3 -X POST \
       -H 'Content-Type: application/json' \
       --data-binary @- \
       http://127.0.0.1:53127/notification >/dev/null || true
exit 0
