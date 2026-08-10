#!/bin/bash
# claudenotch-statusline.sh — installed as Claude Code's `statusLine.command`.
#
# Claude Code feeds the status line command a rich JSON on stdin that includes
# the AUTHORITATIVE context-window usage and the real 5-hour / weekly plan-limit
# usage — the only local source of those numbers. This script:
#   1. forwards them to the ClaudeNotch app (fire-and-forget), then
#   2. re-emits the user's PREVIOUS status line so their terminal is unchanged
#      (or prints a compact default line if they had none).
#
# It must never fail the status line: everything is guarded and it always exits 0.
set -u
input=$(cat)
DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) Forward usage to the notch. Skip instantly if jq is missing or the app is
#    down so the status line never stalls.
if command -v jq >/dev/null 2>&1 && nc -z 127.0.0.1 53127 2>/dev/null; then
    printf '%s' "$input" | jq -c '{
        cwd:           (.workspace.current_dir // .cwd // ""),
        session_id:    (.session_id // ""),
        model:         (.model.id // .model.display_name // ""),
        session_name:  (.session_name // ""),
        worktree:      (.workspace.git_worktree // .worktree.name // ""),
        pr_number:     (.pr.number // null),
        pr_url:        (.pr.url // ""),
        pr_state:      (.pr.review_state // ""),
        effort:        (.effort.level // ""),
        cost_usd:      (.cost.total_cost_usd // null),
        lines_added:   (.cost.total_lines_added // null),
        lines_removed: (.cost.total_lines_removed // null),
        context_pct:   (.context_window.used_percentage // null),
        context_window: (.context_window.context_window_size // null),
        context_tokens: (.context_window.total_input_tokens // null),
        five_hour_pct: (.rate_limits.five_hour.used_percentage // null),
        seven_day_pct: (.rate_limits.seven_day.used_percentage // null),
        five_hour_resets_at: (.rate_limits.five_hour.resets_at // null),
        seven_day_resets_at: (.rate_limits.seven_day.resets_at // null)
    }' 2>/dev/null | curl -s --max-time 1 -X POST \
        -H 'Content-Type: application/json' --data-binary @- \
        http://127.0.0.1:53127/statusline >/dev/null 2>&1 || true
fi

# 2) Re-emit the user's previous status line, preserving their display. The
#    installer wrote the original command here; if it's empty we had nothing to
#    chain to, so print a compact default so the row isn't blank.
INNER="$DIR/statusline-inner.cmd"
if [ -s "$INNER" ]; then
    printf '%s' "$input" | eval "$(cat "$INNER")"
elif command -v jq >/dev/null 2>&1; then
    dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')
    model=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // ""')
    ctx=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
    line="${model}  ${dir/#$HOME/\~}"
    [ -n "$ctx" ] && line="$line  ctx ${ctx}%"
    printf '%s' "$line"
fi
exit 0
