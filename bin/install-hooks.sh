#!/bin/bash
# Merge ClaudeNotch hooks into ~/.claude/settings.json (idempotent, backed up).
#
# Always copies the hook scripts to ~/.claudenotch/bin/ first, so settings.json
# points at a no-spaces path (otherwise /bin/sh splits the command on spaces).
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claudenotch/bin"

mkdir -p "$INSTALL_DIR"
for s in claudenotch-permission.sh claudenotch-notify.sh claudenotch-stop.sh claudenotch-posttool.sh claudenotch-prompt.sh; do
    src="$SCRIPT_DIR/$s"
    [ -f "$src" ] || { echo "Missing source script: $src"; exit 1; }
    cp "$src" "$INSTALL_DIR/$s"
    chmod +x "$INSTALL_DIR/$s"
done
echo "→ Hook scripts copied to $INSTALL_DIR"

# Sanity-check the install path has no spaces (settings.json command is run
# as a literal shell command — unquoted paths with spaces break it).
case "$INSTALL_DIR" in
    *" "*) echo "WARNING: \$HOME contains spaces ($INSTALL_DIR). The wired command will be quoted." ;;
esac

PERM="$INSTALL_DIR/claudenotch-permission.sh"
NOTIFY="$INSTALL_DIR/claudenotch-notify.sh"
STOP="$INSTALL_DIR/claudenotch-stop.sh"
POST="$INSTALL_DIR/claudenotch-posttool.sh"
PROMPT="$INSTALL_DIR/claudenotch-prompt.sh"

# Quote each path for shell safety, just in case ~ contains spaces.
quote() { printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"; }
PERM_Q=$(quote "$PERM")
NOTIFY_Q=$(quote "$NOTIFY")
STOP_Q=$(quote "$STOP")
POST_Q=$(quote "$POST")
PROMPT_Q=$(quote "$PROMPT")

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch.$TS"
cp "$SETTINGS" "$BACKUP"

jq \
    --arg perm   "$PERM_Q" \
    --arg notify "$NOTIFY_Q" \
    --arg stop   "$STOP_Q" \
    --arg post   "$POST_Q" \
    --arg prompt "$PROMPT_Q" \
    '
    .hooks = (.hooks // {}) |
    .hooks.PreToolUse = [
        { "matcher": ".*",
          "hooks":   [{ "type": "command", "command": $perm }] }
    ] |
    .hooks.PostToolUse = [
        { "matcher": ".*",
          "hooks":   [{ "type": "command", "command": $post }] }
    ] |
    .hooks.UserPromptSubmit = [
        { "hooks": [{ "type": "command", "command": $prompt }] }
    ] |
    .hooks.Notification = [
        { "hooks": [{ "type": "command", "command": $notify }] }
    ] |
    .hooks.Stop = [
        { "hooks": [{ "type": "command", "command": $stop }] }
    ]
    ' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Wired ClaudeNotch hooks into $SETTINGS"
echo "  (backup: $BACKUP)"
echo
echo "  Matcher: .* (all tools — hook script filters which ones show the notch)"
echo "  Interactive tools shown in notch: Bash, Write, Edit, MultiEdit, WebFetch, WebSearch, NotebookEdit, Task"
echo "  Everything else (Read, Grep, Glob, TodoWrite…) falls through to Claude Code."
