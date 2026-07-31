#!/bin/bash
# Claude Code PostToolUse hook: forward "what Claude just did" to ClaudeNotch,
# then signal that it is reasoning again between tool calls. Two posts, so this
# does not use notch_forward. Fire-and-forget, never blocks Claude.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

input=$(cat)
notch_log "posttool hook fired"
notch_ready || exit 0

printf '%s' "$input" | notch_post activity '{
    tool_name:       (.tool_name        // ""),
    tool_input:      (.tool_input       // {}),
    tool_response:   (.tool_response    // null),
    cwd:             (.cwd              // ""),
    session_id:      (.session_id       // ""),
    transcript_path: (.transcript_path  // "")
}'

# Claude is now reasoning between tool calls.
printf '%s' "$input" | notch_post thinking '{
    cwd:        (.cwd        // ""),
    session_id: (.session_id // "")
}'
exit 0
