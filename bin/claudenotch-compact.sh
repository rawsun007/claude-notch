#!/bin/bash
# Claude Code PreCompact hook: tell ClaudeNotch context is being compacted so
# the notch can show a transient "compacting" cue. Fire-and-forget.
set -u
LOG=/tmp/claudenotch-hook.log
input=$(cat)
echo "[$(date '+%H:%M:%S')] compact hook fired" >> "$LOG"
nc -z 127.0.0.1 53127 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -c '{
    cwd:             (.cwd // ""),
    session_id:      (.session_id // ""),
    transcript_path: (.transcript_path // "")
}' | curl -s --max-time 2 -X POST \
       -H 'Content-Type: application/json' \
       --data-binary @- \
       http://127.0.0.1:53127/compact >/dev/null || true
exit 0
