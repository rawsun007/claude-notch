#!/bin/bash
# claudenotch-hook.sh — single entry point for every Claude Code hook.
#
# Claude Code prompts the user to trust each unique hook COMMAND once per
# project. By routing every event through this one script, the user only
# sees the trust prompt ONCE per project instead of 5 times.
#
# This dispatcher just sniffs `hook_event_name` from stdin and hands the
# payload to the right sub-script next to it.
set -u
LOG=/tmp/claudenotch-hook.log

input=$(cat)

# Without jq we can't determine the event. Fail-soft for PreToolUse so we
# never break Claude.
if ! command -v jq >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] dispatcher: jq missing, asking" >> "$LOG"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\n'
    exit 0
fi

event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "[$(date '+%H:%M:%S')] dispatcher: event=$event" >> "$LOG"

case "$event" in
    PreToolUse)
        printf '%s' "$input" | exec "$DIR/claudenotch-permission.sh"
        ;;
    PermissionRequest)
        printf '%s' "$input" | exec "$DIR/claudenotch-permreq.sh"
        ;;
    PostToolUse)
        printf '%s' "$input" | exec "$DIR/claudenotch-posttool.sh"
        ;;
    UserPromptSubmit)
        printf '%s' "$input" | exec "$DIR/claudenotch-prompt.sh"
        ;;
    Notification)
        printf '%s' "$input" | exec "$DIR/claudenotch-notify.sh"
        ;;
    Stop|SubagentStop)
        printf '%s' "$input" | exec "$DIR/claudenotch-stop.sh"
        ;;
    SessionEnd)
        printf '%s' "$input" | exec "$DIR/claudenotch-sessionend.sh"
        ;;
    TaskCreated|TaskCompleted)
        printf '%s' "$input" | exec "$DIR/claudenotch-task.sh"
        ;;
    PreCompact)
        printf '%s' "$input" | exec "$DIR/claudenotch-compact.sh"
        ;;
    *)
        echo "[$(date '+%H:%M:%S')] dispatcher: unknown event=$event" >> "$LOG"
        exit 0
        ;;
esac
