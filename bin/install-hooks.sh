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
         claudenotch-task.sh claudenotch-permreq.sh claudenotch-compact.sh \
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

# Non-destructive merge (mirrors the in-app HookInstaller): keep whatever hooks
# the user already has at each event, drop any prior ClaudeNotch entry so a
# re-run doesn't duplicate it, then append ours. Previously this assigned each
# event to ONLY our entry, which wiped out the user's existing hooks.
jq --arg hook "$HOOK_Q" '
    def add_hook(arr; with_matcher):
        ((arr // []) | map(select(
            ((.hooks // []) | map(.command // "") | join(" ")
              | contains("claudenotch-hook.sh") | not)
        )))
        + [ if with_matcher
            then { "matcher": ".*", "hooks": [{ "type": "command", "command": $hook }] }
            else { "hooks": [{ "type": "command", "command": $hook }] }
            end ];
    .hooks = (.hooks // {}) |
    .hooks.PreToolUse        = add_hook(.hooks.PreToolUse;        true)  |
    .hooks.PermissionRequest = add_hook(.hooks.PermissionRequest; true)  |
    .hooks.PostToolUse       = add_hook(.hooks.PostToolUse;       true)  |
    .hooks.UserPromptSubmit  = add_hook(.hooks.UserPromptSubmit;  false) |
    .hooks.Notification      = add_hook(.hooks.Notification;      false) |
    .hooks.Stop              = add_hook(.hooks.Stop;              false) |
    .hooks.SessionEnd        = add_hook(.hooks.SessionEnd;        true)  |
    .hooks.TaskCreated       = add_hook(.hooks.TaskCreated;       false) |
    .hooks.TaskCompleted     = add_hook(.hooks.TaskCompleted;     false) |
    .hooks.PreCompact        = add_hook(.hooks.PreCompact;        false)
' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Wired ClaudeNotch hooks (single-dispatcher) into $SETTINGS"
echo "  (backup: $BACKUP)"
echo
echo "  Trust prompt: Claude Code will ask 'trust this hook?' ONCE per project."
echo "  Click 'Yes, and don't ask again for ... commands in /path/to/project'."
echo
echo "  Uninstall: $INSTALL_DIR/uninstall-hooks.sh"
