#!/bin/bash
# Claude Code UserPromptSubmit hook: fire-and-forget the user's latest prompt
# to ClaudeNotch so the notch can show "you just asked: ..." while Claude works.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

notch_forward prompt prompt '{
    prompt:          (.prompt          // ""),
    cwd:             (.cwd             // ""),
    session_id:      (.session_id      // ""),
    transcript_path: (.transcript_path // "")
}'
