#!/bin/bash
# Remove ClaudeNotch hooks from ~/.claude/settings.json (backed up).
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "No $SETTINGS — nothing to do."; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch-uninstall.$TS"
cp "$SETTINGS" "$BACKUP"
# Same rules the install path already follows, and for the same reason: this
# copy holds whatever settings.json held, including the hook token and any env
# values, and an unpruned pile of them accumulates in ~/.claude forever. The
# install script hardened this; the uninstall script never did, so it was
# leaving world-readable copies behind on the way out.
chmod 600 "$SETTINGS".before-claudenotch-uninstall.* 2>/dev/null || true
ls -1 "$SETTINGS".before-claudenotch-uninstall.* 2>/dev/null \
    | sort -r \
    | tail -n +6 \
    | while IFS= read -r old_backup; do rm -f "$old_backup"; done

# Restore the user's original statusLine (captured at install time). If there
# was none, drop our forwarder entry entirely.
INNER="$HOME/.claudenotch/bin/statusline-inner.cmd"
PRIOR_STATUSLINE=""
[ -f "$INNER" ] && PRIOR_STATUSLINE=$(cat "$INNER")

jq --arg prior "$PRIOR_STATUSLINE" '
def ours:
    ((.command // "") | (contains("claudenotch") or contains(".claudenotch")))
    or ((.url // "") | contains("127.0.0.1:53127")) ;
def strip_event(arr):
    (arr // []) | map(select(((.hooks // []) | any(ours)) | not)) ;

# Restore (or remove) our statusLine forwarder first.
( if ((.statusLine.command // "") | contains("claudenotch-statusline.sh")) then
    ( if ($prior | length) > 0
      then .statusLine = {type: "command", command: $prior}
      else del(.statusLine) end )
  else . end ) |

.hooks = (.hooks // {}) |
# Every event, not a list of them: the app registers new events as Claude Code
# adds them, and a hard-coded list here left those, and every HTTP entry the
# app writes (url 127.0.0.1:53127), behind after an uninstall.
.hooks |= with_entries(.value = strip_event(.value)) |
.hooks |= with_entries(select((.value | length) > 0)) |
( if (.hooks | length) == 0 then del(.hooks) else . end )
' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Removed ClaudeNotch hooks from $SETTINGS"
echo "  (backup: $BACKUP)"
