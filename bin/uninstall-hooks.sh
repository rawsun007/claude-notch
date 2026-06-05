#!/bin/bash
# Remove ClaudeNotch hooks from ~/.claude/settings.json (backed up).
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "No $SETTINGS — nothing to do."; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch-uninstall.$TS"
cp "$SETTINGS" "$BACKUP"

# Restore the user's original statusLine (captured at install time). If there
# was none, drop our forwarder entry entirely.
INNER="$HOME/.claudenotch/bin/statusline-inner.cmd"
PRIOR_STATUSLINE=""
[ -f "$INNER" ] && PRIOR_STATUSLINE=$(cat "$INNER")

jq --arg prior "$PRIOR_STATUSLINE" '
def strip_event(arr):
    (arr // []) | map(
        select(
            ((.hooks // []) | map(.command // "") | join(" ")
              | (contains("claudenotch") or contains(".claudenotch")) | not)
        )
    ) ;

# Restore (or remove) our statusLine forwarder first.
( if ((.statusLine.command // "") | contains("claudenotch-statusline.sh")) then
    ( if ($prior | length) > 0
      then .statusLine = {type: "command", command: $prior}
      else del(.statusLine) end )
  else . end ) |

.hooks = (.hooks // {}) |
.hooks.PreToolUse       = strip_event(.hooks.PreToolUse) |
.hooks.PermissionRequest = strip_event(.hooks.PermissionRequest) |
.hooks.PostToolUse      = strip_event(.hooks.PostToolUse) |
.hooks.UserPromptSubmit = strip_event(.hooks.UserPromptSubmit) |
.hooks.Notification     = strip_event(.hooks.Notification) |
.hooks.Stop             = strip_event(.hooks.Stop) |
.hooks.SessionEnd       = strip_event(.hooks.SessionEnd) |
.hooks.TaskCreated      = strip_event(.hooks.TaskCreated) |
.hooks.TaskCompleted    = strip_event(.hooks.TaskCompleted) |
.hooks.PreCompact       = strip_event(.hooks.PreCompact) |
( if (.hooks.PreToolUse       | length) == 0 then del(.hooks.PreToolUse)       else . end ) |
( if (.hooks.PermissionRequest | length) == 0 then del(.hooks.PermissionRequest) else . end ) |
( if (.hooks.PostToolUse      | length) == 0 then del(.hooks.PostToolUse)      else . end ) |
( if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end ) |
( if (.hooks.Notification     | length) == 0 then del(.hooks.Notification)     else . end ) |
( if (.hooks.Stop             | length) == 0 then del(.hooks.Stop)             else . end ) |
( if (.hooks.SessionEnd       | length) == 0 then del(.hooks.SessionEnd)       else . end ) |
( if (.hooks.TaskCreated      | length) == 0 then del(.hooks.TaskCreated)      else . end ) |
( if (.hooks.TaskCompleted    | length) == 0 then del(.hooks.TaskCompleted)    else . end ) |
( if (.hooks.PreCompact       | length) == 0 then del(.hooks.PreCompact)       else . end ) |
( if (.hooks | length) == 0 then del(.hooks) else . end )
' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Removed ClaudeNotch hooks from $SETTINGS"
echo "  (backup: $BACKUP)"
