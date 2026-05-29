#!/bin/bash
# Remove ClaudeNotch hooks from ~/.claude/settings.json (backed up).
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "No $SETTINGS — nothing to do."; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch-uninstall.$TS"
cp "$SETTINGS" "$BACKUP"

jq '
def strip_event(arr):
    (arr // []) | map(
        select(
            ((.hooks // []) | map(.command // "") | join(" ")
              | (contains("claudenotch") or contains(".claudenotch")) | not)
        )
    ) ;

.hooks = (.hooks // {}) |
.hooks.PreToolUse       = strip_event(.hooks.PreToolUse) |
.hooks.PostToolUse      = strip_event(.hooks.PostToolUse) |
.hooks.UserPromptSubmit = strip_event(.hooks.UserPromptSubmit) |
.hooks.Notification     = strip_event(.hooks.Notification) |
.hooks.Stop             = strip_event(.hooks.Stop) |
.hooks.SessionEnd       = strip_event(.hooks.SessionEnd) |
( if (.hooks.PreToolUse       | length) == 0 then del(.hooks.PreToolUse)       else . end ) |
( if (.hooks.PostToolUse      | length) == 0 then del(.hooks.PostToolUse)      else . end ) |
( if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end ) |
( if (.hooks.Notification     | length) == 0 then del(.hooks.Notification)     else . end ) |
( if (.hooks.Stop             | length) == 0 then del(.hooks.Stop)             else . end ) |
( if (.hooks.SessionEnd       | length) == 0 then del(.hooks.SessionEnd)       else . end ) |
( if (.hooks | length) == 0 then del(.hooks) else . end )
' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Removed ClaudeNotch hooks from $SETTINGS"
echo "  (backup: $BACKUP)"
