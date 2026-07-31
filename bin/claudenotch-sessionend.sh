#!/bin/bash
# Claude Code SessionEnd hook: let ClaudeNotch retire the session so it stops
# showing as live. Fire-and-forget.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

notch_forward sessionend sessionend '{
    cwd:             (.cwd        // ""),
    session_id:      (.session_id // "")
}'
