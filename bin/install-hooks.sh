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

# 0700, and applied whether or not mkdir created it: everything in here is
# executed (Claude Code runs the forwarders, the status line evals the inner
# command sidecar), so nobody else on the machine gets to write into it. Matches
# the mode the app itself installs with.
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR" "$HOME/.claudenotch" 2>/dev/null || true
# claudenotch-common.sh first: every forwarder sources it, and one that
# cannot find it exits 0 and silently stops reporting.
for s in claudenotch-common.sh claudenotch-hook.sh \
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
    chmod 700 "$dst"
done
echo "→ Hook scripts copied to $INSTALL_DIR"

# Sanity-check the install path has no spaces (settings.json command is run
# as a literal shell command — unquoted paths with spaces break it).
case "$INSTALL_DIR" in
    *" "*) echo "WARNING: \$HOME contains spaces ($INSTALL_DIR). The wired command will be quoted." ;;
esac

# Shared secret with the app. Created here when the app has not already made
# one, so the fallback path installs a URL the app will accept.
TOKEN_FILE="$HOME/.claudenotch/hook-token"
if [ ! -s "$TOKEN_FILE" ]; then
    mkdir -p "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32 > "$TOKEN_FILE" 2>/dev/null || true
    fi
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
fi
NOTCH_URL="http://127.0.0.1:53127/hook"
if [ -s "$TOKEN_FILE" ]; then
    NOTCH_URL="http://127.0.0.1:53127/hook?t=$(tr -d '\r\n' < "$TOKEN_FILE")"
fi

# Let the app do the merge when it is on disk.
#
# The hooks used to be merged into settings.json by two programs: the app, in
# Swift, and the jq below, in shell. Two implementations of one merge drift,
# and they already had. A fix to the backup rules landed in the Swift copy and
# did nothing, because the shell copy is the one that runs during setup.
#
# So the app is asked first, and the jq path below is the fallback for the one
# case it cannot cover: a machine where the app is not installed yet.
# Set CLAUDENOTCH_FORCE_JQ_MERGE=1 to take the fallback deliberately. The
# conformance test runs both paths against the same settings file and compares
# them, which is the only thing that keeps the fallback honest.
for candidate in ${CLAUDENOTCH_FORCE_JQ_MERGE:+} "/Applications/ClaudeNotch.app" \
                 "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/ClaudeNotch.app"; do
    [ -n "${CLAUDENOTCH_FORCE_JQ_MERGE:-}" ] && break
    BIN="$candidate/Contents/MacOS/ClaudeNotch"
    if [ -x "$BIN" ] && "$BIN" --install-hooks >/dev/null 2>&1; then
        echo "→ Hooks merged into ~/.claude/settings.json (by ClaudeNotch)"
        exit 0
    fi
done
echo "→ ClaudeNotch.app not available, merging with jq"

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Back up what we are about to replace, keep the newest few, and keep them to
# ourselves. This runs on every setup, and settings.json can hold env values and
# tokens, so an unpruned pile of world-readable copies accumulates in ~/.claude
# and stays there. Mirrors HookInstaller.backUp in the app, which does the same
# thing when the app installs the hooks itself.
BACKUPS_KEPT=5
TS=$(date +%s)
BACKUP="$SETTINGS.before-claudenotch.$TS"
cp "$SETTINGS" "$BACKUP"
# Every one of them, not only the one just written: an install that predates
# this left world-readable copies behind, and they hold the same secrets.
chmod 600 "$SETTINGS".before-claudenotch.* 2>/dev/null || true
# The timestamp is in the name, so sorting the names sorts by age. Newest
# first, then skip the ones we are keeping: `head -n -N` would read better but
# a negative count is a GNU extension and macOS ships BSD head, where it is an
# error and the whole pipeline quietly deletes nothing.
ls -1 "$SETTINGS".before-claudenotch.* 2>/dev/null \
    | sort -r \
    | tail -n "+$((BACKUPS_KEPT + 1))" \
    | while IFS= read -r old_backup; do rm -f "$old_backup"; done

# Non-destructive merge (mirrors the in-app HookInstaller): keep whatever hooks
# the user already has at each event, drop any prior ClaudeNotch entry (both
# legacy command hooks and new HTTP hooks) so a re-run doesn't duplicate it,
# then append ours. HTTP hooks POST the event JSON directly to the running app —
# no shell scripts or trust prompts needed.
jq --arg url "$NOTCH_URL" '
    def is_ours(sub):
        (sub.type == "command" and (sub.command // "" | contains("claudenotch-hook.sh")))
        or
        (sub.type == "http" and (sub.url // "" | contains("53127")));

    # 290s: must exceed the apps own 285s decision-wait window (EventServer,
    # matching the 3-minute waiting-on-you nudge), or Claude Code gives up on
    # the HTTP request and falls back to its own terminal prompt while the
    # notch card sits there unable to reply to anything.
    def add_hook(arr; with_matcher):
        ((arr // []) | map(select(
            ((.hooks // []) | map(is_ours(.)) | any | not)
        )))
        + [ if with_matcher
            then { "matcher": ".*", "hooks": [{ "type": "http", "url": $url, "timeout": 290 }] }
            else { "hooks": [{ "type": "http", "url": $url, "timeout": 290 }] }
            end ];
    .hooks = (.hooks // {}) |
    .hooks.PreToolUse         = add_hook(.hooks.PreToolUse        ; true) |
    .hooks.PermissionRequest  = add_hook(.hooks.PermissionRequest ; true) |
    .hooks.PostToolUse        = add_hook(.hooks.PostToolUse       ; true) |
    .hooks.PostToolUseFailure = add_hook(.hooks.PostToolUseFailure; true) |
    .hooks.UserPromptSubmit   = add_hook(.hooks.UserPromptSubmit  ; false) |
    .hooks.Notification       = add_hook(.hooks.Notification      ; false) |
    .hooks.Stop               = add_hook(.hooks.Stop              ; false) |
    .hooks.StopFailure        = add_hook(.hooks.StopFailure       ; false) |
    .hooks.SessionStart       = add_hook(.hooks.SessionStart      ; false) |
    .hooks.SessionEnd         = add_hook(.hooks.SessionEnd        ; true) |
    .hooks.TaskCreated        = add_hook(.hooks.TaskCreated       ; false) |
    .hooks.TaskCompleted      = add_hook(.hooks.TaskCompleted     ; false) |
    .hooks.PreCompact         = add_hook(.hooks.PreCompact        ; false) |
    .hooks.PostCompact        = add_hook(.hooks.PostCompact       ; false) |
    .hooks.Elicitation        = add_hook(.hooks.Elicitation       ; true) |
    .hooks.ElicitationResult  = add_hook(.hooks.ElicitationResult ; true) |
    .hooks.SubagentStart      = add_hook(.hooks.SubagentStart     ; false) |
    .hooks.SubagentStop       = add_hook(.hooks.SubagentStop      ; false) |
    .hooks.TeammateIdle       = add_hook(.hooks.TeammateIdle      ; false) |
    .hooks.WorktreeCreate     = add_hook(.hooks.WorktreeCreate    ; false) |
    .hooks.WorktreeRemove     = add_hook(.hooks.WorktreeRemove    ; false) |
    .hooks.DirectoryAdded     = add_hook(.hooks.DirectoryAdded    ; false) |
    .hooks.CwdChanged         = add_hook(.hooks.CwdChanged        ; false) |
    .hooks.PermissionDenied   = add_hook(.hooks.PermissionDenied  ; true) |
    .hooks.FileChanged        = add_hook(.hooks.FileChanged        ; true)  |
    .hooks.InstructionsLoaded = add_hook(.hooks.InstructionsLoaded ; true)  |
    .hooks.ConfigChange       = add_hook(.hooks.ConfigChange      ; false) |
    .hooks.PostModelSwitch    = add_hook(.hooks.PostModelSwitch   ; true)
' "$SETTINGS" > "$SETTINGS.new"

mv "$SETTINGS.new" "$SETTINGS"
echo "✓ Wired ClaudeNotch HTTP hooks into $SETTINGS"
echo "  (backup: $BACKUP)"
echo
echo "  HTTP hooks post directly to the running app — no trust prompts."
echo "  ClaudeNotch must be running when Claude Code fires hooks."
echo
echo "  Uninstall: $INSTALL_DIR/uninstall-hooks.sh"
