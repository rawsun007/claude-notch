#!/bin/bash
# Merge ClaudeNotch hooks into ~/.claude/settings.json (idempotent, backed up).
#
# Single-dispatcher mode: all Claude Code hook events point at the same
# command (claudenotch-hook.sh). Claude Code's "do you trust this hook?"
# prompt fires once per command per project, so this is one click total.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claudenotch/bin"

mkdir -p "$INSTALL_DIR"
for s in claudenotch-hook.sh \
         claudenotch-permission.sh claudenotch-notify.sh claudenotch-stop.sh \
         claudenotch-posttool.sh claudenotch-prompt.sh claudenotch-sessionend.sh \
         uninstall-hooks.sh; do
    src="$SCRIPT_DIR/$s"
    dst="$INSTALL_DIR/$s"
    [ -f "$src" ] || { echo "Missing source script: $src"; exit 1; }
    # When invoked from the install dir itself, src == dst — nothing to copy.
    # Otherwise remove first: on APFS, cp clones and refuses to overwrite a
    # byte-identical file ("are identical"), which under set -e would abort.
    if [ "$src" != "$dst" ]; then
        rm -f "$dst"
        cp "$src" "$dst"
    fi
    chmod +x "$dst"
done
echo "→ Hook scripts copied to $INSTALL_DIR"

# Sanity-check the install path has no spaces (settings.json command is run
# as a literal shell command — unquoted paths with spaces break it).
case "$INSTALL_DIR" in
    *" "*) echo "WARNING: \$HOME contains spaces ($INSTALL_DIR). The wired command will be quoted." ;;
esac

HOOK="$INSTALL_DIR/claudenotch-hook.sh"
quote() { printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"; }
HOOK_Q=$(quote "$HOOK")

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch.$TS"
cp "$SETTINGS" "$BACKUP"

jq --arg hook "$HOOK_Q" '
    .hooks = (.hooks // {}) |
    .hooks.PreToolUse = [
        { "matcher": ".*", "hooks": [{ "type": "command", "command": $hook }] }
    ] |
    .hooks.PostToolUse = [
        { "matcher": ".*", "hooks": [{ "type": "command", "command": $hook }] }
    ] |
    .hooks.UserPromptSubmit = [
        { "hooks": [{ "type": "command", "command": $hook }] }
    ] |
    .hooks.Notification = [
        { "hooks": [{ "type": "command", "command": $hook }] }
    ] |
    .hooks.Stop = [
        { "hooks": [{ "type": "command", "command": $hook }] }
    ] |
    .hooks.SessionEnd = [
        { "matcher": ".*", "hooks": [{ "type": "command", "command": $hook }] }
    ]
' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Wired ClaudeNotch hooks (single-dispatcher) into $SETTINGS"
echo "  (backup: $BACKUP)"
echo
echo "  Trust prompt: Claude Code will ask 'trust this hook?' ONCE per project."
echo "  Click 'Yes, and don't ask again for ... commands in /path/to/project'."
echo
echo "  Uninstall: $INSTALL_DIR/uninstall-hooks.sh"
