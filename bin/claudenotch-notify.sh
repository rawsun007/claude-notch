#!/bin/bash
# Claude Code Notification hook: surface "Claude needs your attention" in the
# notch. Fire-and-forget.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

notch_forward notify notification '{
    message:    (.message    // "Claude needs your attention"),
    detail:     (.cwd        // ""),
    cwd:        (.cwd        // ""),
    session_id: (.session_id // ""),
    source:     "Claude Code"
}' 3
