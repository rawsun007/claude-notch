#!/bin/bash
# Claude Code Stop hook: the turn finished, so the notch can show the
# "Claude finished" card. Fire-and-forget.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

notch_forward stop stop '{
    title:           "Claude finished",
    detail:          ((.cwd // "") | split("/") | last // ""),
    cwd:             (.cwd // ""),
    session_id:      (.session_id // ""),
    transcript_path: (.transcript_path // ""),
    source:          "Claude Code"
}' 3
