#!/bin/bash
# Claude Code PreToolUse hook: ask ClaudeNotch for permission.
# Always exits 0 with valid JSON. On any error (notch not running, jq missing,
# server timeout) we fall through to "ask" so Claude Code's normal prompt runs.
#
# Every invocation is logged to /tmp/claudenotch-hook.log so you can verify
# the hook is firing:  tail -f /tmp/claudenotch-hook.log

set -u
LOG=/tmp/claudenotch-hook.log

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // "?"' 2>/dev/null)
echo "[$(date '+%H:%M:%S')] permission hook fired: tool=$tool" >> "$LOG"

emit_ask() {
    local why="${1:-fallback}"
    echo "[$(date '+%H:%M:%S')]   → emit ask ($why)" >> "$LOG"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\n'
    exit 0
}

# AskUserQuestion gets its own pipeline — we mirror the question in the notch
# and feed the selected answer back to Claude via the deny reason.
if [ "$tool" = "AskUserQuestion" ]; then
    nc -z 127.0.0.1 53127 2>/dev/null || emit_ask "notch not running (AskUserQuestion)"
    response=$(printf '%s' "$input" | curl -s --max-time 290 -X POST \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        http://127.0.0.1:53127/question || true)
    if [ -z "$response" ] || [ "$(printf '%s' "$response" | jq -r '.cancelled // false' 2>/dev/null)" = "true" ]; then
        echo "[$(date '+%H:%M:%S')]   → AskUserQuestion: cancelled, falling back to terminal" >> "$LOG"
        emit_ask "question cancelled"
    fi

    mode=$(printf '%s' "$response" | jq -r '.mode // "deny"' 2>/dev/null)
    if [ "$mode" = "allow" ]; then
        # Clean path: notch is going to type the answer into the terminal.
        echo "[$(date '+%H:%M:%S')]   → AskUserQuestion: notch will inject keystrokes (allow)" >> "$LOG"
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
        exit 0
    fi

    # Fallback: format answers + deny+reason (red Error: line, but works).
    body=$(printf '%s' "$response" | jq -r '
        def line($q):
            ($q.header // "" | if . == "" then ($q.question // "Question") else . end) as $h
            | (($q.picked // []) | map(select(. != null and . != ""))) as $p
            | if ($p | length) == 0
              then "  - " + $h + ": (no preference)"
              else "  - " + $h + ": " + ($p | join(", "))
              end ;
        ((.answers // []) | map(line(.)) | join("\n")) as $lines
        | (.fallback_reason // "") as $why
        | if ($lines | length) == 0
          then "[ClaudeNotch] user dismissed the question — please ask again in plain text."
          else "[ClaudeNotch — user replied via the notch]\n" + $lines
                + (if $why == "accessibility-not-granted"
                   then "\n\n(Grant ClaudeNotch Accessibility in System Settings to remove this Error: prefix.)"
                   else "" end)
                + "\n\nUse these answers and continue."
          end
        | {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: .}}
    ' 2>/dev/null)

    if [ -z "$body" ]; then
        echo "[$(date '+%H:%M:%S')]   → AskUserQuestion: encode failed, asking" >> "$LOG"
        emit_ask "AskUserQuestion encode failed"
    fi

    echo "[$(date '+%H:%M:%S')]   → AskUserQuestion answered (deny+reason fallback)" >> "$LOG"
    printf '%s\n' "$body"
    exit 0
fi

# Narrow safe-list — these are the truly non-interactive read tools.
# Everything else (including custom MCP tools, ExitPlanMode, SlashCommand)
# routes through the notch so user never has to look at the terminal.
case "$tool" in
    Read|Grep|Glob|LS|TodoWrite|BashOutput|KillShell)
        emit_ask "tool $tool is safe/non-interactive" ;;
    *) ;;
esac

nc -z 127.0.0.1 53127 2>/dev/null || emit_ask "notch not running"

response=$(printf '%s' "$input" | curl -s --max-time 290 -X POST \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    http://127.0.0.1:53127/permission || true)

[ -n "$response" ] || emit_ask "empty response from notch"
command -v jq >/dev/null 2>&1 || emit_ask "jq missing"

decision=$(printf '%s' "$response" | jq -r '.decision // "ask"' 2>/dev/null)
case "$decision" in
    allow|deny|ask) ;;
    *) decision="ask" ;;
esac

reason=$(printf '%s' "$response" | jq -r '.reason // ""' 2>/dev/null | head -c 200)
reason_json=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null || printf '""')

echo "[$(date '+%H:%M:%S')]   → emit $decision" >> "$LOG"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$decision" "$reason_json"
