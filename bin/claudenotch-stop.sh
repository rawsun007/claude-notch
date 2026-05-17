#!/bin/bash
# Claude Code Stop hook: tell ClaudeNotch a turn finished.
set -u
LOG=/tmp/claudenotch-hook.log
input=$(cat)
echo "[$(date '+%H:%M:%S')] stop hook fired" >> "$LOG"
nc -z 127.0.0.1 53127 2>/dev/null || { echo "[$(date '+%H:%M:%S')]   → skipped (notch down)" >> "$LOG"; exit 0; }
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -c '{
    title:           "Claude finished",
    detail:          ((.cwd // "") | split("/") | last // ""),
    cwd:             (.cwd // ""),
    transcript_path: (.transcript_path // ""),
    source:          "Claude Code"
}' | curl -s --max-time 3 -X POST \
       -H 'Content-Type: application/json' \
       --data-binary @- \
       http://127.0.0.1:53127/stop >/dev/null || true
exit 0
