#!/bin/bash
# Claude Code PreCompact hook: tell ClaudeNotch context is being compacted so
# the notch can show a transient "compacting" cue. Fire-and-forget.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

notch_forward compact compact '{
    cwd:             (.cwd // ""),
    session_id:      (.session_id // ""),
    transcript_path: (.transcript_path // "")
}'
