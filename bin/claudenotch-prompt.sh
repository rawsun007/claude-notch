#!/bin/bash
# Claude Code UserPromptSubmit hook: fire-and-forget the user's latest prompt
# to ClaudeNotch so the notch can show "you just asked: ..." while Claude works.
set -u
LOG=/tmp/claudenotch-hook.log
input=$(cat)
echo "[$(date '+%H:%M:%S')] prompt hook fired" >> "$LOG"
nc -z 127.0.0.1 53127 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -c '{
    prompt: (.prompt // ""),
    cwd:    (.cwd    // "")
}' | curl -s --max-time 2 -X POST \
       -H 'Content-Type: application/json' \
       --data-binary @- \
       http://127.0.0.1:53127/prompt >/dev/null || true
exit 0
