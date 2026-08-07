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
DIR="$(cd "$(dirname "$0")" && pwd)"
# notch_log writes to the user's own 0700 directory. It used to be a fixed
# name in /tmp, which any other local user could pre-create as a symlink.
. "$DIR/claudenotch-common.sh"

input=$(cat)

# Without jq we can't determine the event. Fail-soft for PreToolUse so we
# never break Claude.
if ! command -v jq >/dev/null 2>&1; then
    notch_log "dispatcher: jq missing, asking"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\n'
    exit 0
fi

event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
notch_log "dispatcher: event=$event"

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
    Stop)
        printf '%s' "$input" | exec "$DIR/claudenotch-stop.sh"
        ;;
    SubagentStart)
        nc -z 127.0.0.1 53127 2>/dev/null || exit 0
        command -v jq >/dev/null 2>&1 || exit 0
        printf '%s' "$input" | jq -c '{
            agent_type:      (.agent_type      // ""),
            session_id:      (.session_id      // ""),
            cwd:             (.cwd             // ""),
            transcript_path: (.transcript_path // "")
        }' | curl -s --max-time 2 -X POST \
               -H 'Content-Type: application/json' \
               --data-binary @- \
               http://127.0.0.1:53127/subagentstart >/dev/null 2>&1 || true
        exit 0
        ;;
    SubagentStop)
        # Parent session is still running — go back to "thinking..." state
        # instead of triggering a "Claude finished" notification for each agent.
        nc -z 127.0.0.1 53127 2>/dev/null || exit 0
        command -v jq >/dev/null 2>&1 || exit 0
        printf '%s' "$input" | jq -c '{
            cwd:        (.cwd        // ""),
            session_id: (.session_id // "")
        }' | curl -s --max-time 2 -X POST \
               -H 'Content-Type: application/json' \
               --data-binary @- \
               http://127.0.0.1:53127/thinking >/dev/null 2>&1 || true
        exit 0
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
        notch_log "dispatcher: unknown event=$event"
        exit 0
        ;;
esac
