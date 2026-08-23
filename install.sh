#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Always rebuild. This used to build only when ClaudeNotch.app was missing,
# which meant editing a source file and running install.sh silently installed
# whatever bundle happened to be lying around from the last build.sh. The
# symptom is the worst kind: the app launches, looks fine, and is missing the
# change you just made. build.sh is incremental, so this costs a second when
# nothing changed. Pass --no-build to skip it deliberately.

# What is in the source tree right now, as one hash.
#
# Replacing the installed bundle is not free: macOS validates a newly written
# app the first time it runs, and for this unnotarized one that measured 38
# seconds during which Claude Code cannot reach it and prints a connection
# error for every hook. Re-running this script after changing nothing used to
# pay that in full, because the build is not reproducible: relinking and
# re-signing produce a different binary every time, so comparing binaries can
# never say "same build".
#
# The sources can say it. The hash is stamped inside the installed bundle, and
# an install that would not change anything stops here instead.
source_fingerprint() {
    find Sources Resources bin tools -type f \
         \( -name '*.swift' -o -name '*.sh' -o -name '*.strings' -o -name '*.json' -o -name '*.py' \) \
         2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}
#
# The stamp lives beside the app's other state, NOT inside the bundle.
#
# It used to live in Contents/Resources/.source-stamp, which broke the code
# signature of every install: the file was added after signing, so the seal no
# longer matched and `codesign --verify` reported "a sealed resource is missing
# or invalid". That is worse than being unsigned. It also defeated the whole
# point of the check, because an invalid seal is exactly what makes macOS
# re-validate the bundle on launch, which is the 38 seconds described below.
STAMP_PATH="$HOME/.claudenotch/source-stamp"
SRC_HASH=$(source_fingerprint)

# Repair an install made by the version that stamped inside the bundle. Left in
# place it keeps that install's signature broken forever, since nothing else
# ever removes it.
LEGACY_STAMP="/Applications/ClaudeNotch.app/Contents/Resources/.source-stamp"
if [ -f "$LEGACY_STAMP" ]; then
    rm -f "$LEGACY_STAMP" 2>/dev/null || true
    # The bundle it was in is now unstamped, so fall through to a real install
    # rather than trusting a stamp written by the broken scheme.
    rm -f "$STAMP_PATH" 2>/dev/null || true
fi

if [ "${1:-}" != "--force" ] \
   && [ -f "$STAMP_PATH" ] \
   && [ "$(cat "$STAMP_PATH" 2>/dev/null)" = "$SRC_HASH" ] \
   && [ -d "/Applications/ClaudeNotch.app" ] \
   && pgrep -x ClaudeNotch >/dev/null 2>&1; then
    echo "✓ /Applications is already running this source tree, nothing to do."
    echo "  (./install.sh --force reinstalls anyway)"
    exit 0
fi

if [ "${1:-}" != "--no-build" ]; then
    ./build.sh
fi

# 1. Install the .app
#
# Two things this used to get wrong, both measurable.
#
# It deleted /Applications/ClaudeNotch.app while that app was still running, so
# for the rest of the script the running process was executing from a deleted
# bundle with no resources behind it. And it replaced the bundle even when
# nothing had changed, which costs a restart every time: macOS validates a
# freshly written app on its first launch, and for this unnotarized bundle that
# measured 38 seconds, during which Claude Code cannot reach the app and prints
# a connection error for every hook it fires.
#
# So: skip the swap entirely when the binary is identical, and when it is not,
# stage beside the old one and swap after quitting.
APP="/Applications/ClaudeNotch.app"
NEW_BIN="ClaudeNotch.app/Contents/MacOS/ClaudeNotch"
OLD_BIN="$APP/Contents/MacOS/ClaudeNotch"
NEEDS_SWAP=1
if [ -f "$OLD_BIN" ] \
   && [ "$(shasum -a 256 "$NEW_BIN" | cut -d' ' -f1)" = "$(shasum -a 256 "$OLD_BIN" | cut -d' ' -f1)" ]; then
    NEEDS_SWAP=0
    echo "→ /Applications copy is already this build, leaving it running"
fi

if [ "$NEEDS_SWAP" = "1" ]; then
    echo "→ Staging ClaudeNotch.app next to the installed copy"
    rm -rf "$APP.incoming"
    cp -R ClaudeNotch.app "$APP.incoming"
fi

# 2. Install hook scripts to a stable, absolute path so settings.json can reference them.
# Remove first: on APFS, cp clones and refuses to overwrite a byte-identical file
# ("are identical"), which under set -e would abort the install.
HOOK_DIR="$HOME/.claudenotch/bin"
# 0700: everything in here is executed, and the directory also holds the
# statusline-inner.cmd sidecar the status line evals on every redraw.
mkdir -p "$HOOK_DIR"
chmod 700 "$HOOK_DIR" "$HOME/.claudenotch" 2>/dev/null || true
# Only the scripts we ship, by name: a blanket `rm *.sh` also deleted files the
# app itself writes there (the Codex forwarder), leaving ~/.codex/hooks.json
# pointing at a missing command, i.e. "hook exited with code 127" on every
# Codex event until the integration was toggled off and on again.
for f in bin/*.sh; do
    rm -f "$HOOK_DIR/$(basename "$f")"
done
cp bin/*.sh "$HOOK_DIR/"
chmod 700 "$HOOK_DIR"/*.sh
echo "→ Installed hook scripts to $HOOK_DIR"

# 3. Swap the bundle and relaunch, if there is a new one.
#
# The old copy keeps serving hooks until the last possible moment, and the swap
# itself is two renames rather than an 18MB copy.
if [ "$NEEDS_SWAP" = "1" ]; then
    if pgrep -x ClaudeNotch >/dev/null 2>&1; then
        echo "→ Quitting the running copy"
        osascript -e 'quit app "ClaudeNotch"' >/dev/null 2>&1 || killall ClaudeNotch 2>/dev/null || true
        for _ in $(seq 1 40); do
            pgrep -x ClaudeNotch >/dev/null 2>&1 || break
            sleep 0.25
        done
        # It had ten seconds to save its state and go.
        pkill -9 -x ClaudeNotch 2>/dev/null || true
    fi

    rm -rf "$APP.previous"
    [ -d "$APP" ] && mv "$APP" "$APP.previous"
    if ! mv "$APP.incoming" "$APP"; then
        # Never leave the machine with no app: put the old one back.
        [ -d "$APP.previous" ] && mv "$APP.previous" "$APP"
        rm -rf "$APP.incoming"
        echo "Could not install the new app; the previous version is still in place." >&2
        exit 1
    fi
    rm -rf "$APP.previous"
    # Stamp what went in, so the next run can tell whether it would change
    # anything before paying for a restart. Outside the bundle: writing into a
    # signed app after signing it invalidates the seal, which is the cost this
    # check exists to avoid.
    mkdir -p "$(dirname "$STAMP_PATH")" 2>/dev/null || true
    chmod 700 "$(dirname "$STAMP_PATH")" 2>/dev/null || true
    printf '%s' "$SRC_HASH" > "$STAMP_PATH" 2>/dev/null || true
    echo "→ Installed to $APP"
    open "$APP"
fi

# 4. Wire hooks into ~/.claude/settings.json (idempotent, with backup).
#    After the swap, so the merge is done by the build that was just installed.
"$HOOK_DIR/install-hooks.sh"

# 5. Say when it is actually answering again.
#
# macOS validates a newly written bundle the first time it runs, and for an
# unnotarized app that takes long enough that Claude Code reports a connection
# error for every hook fired in the meantime. Waiting here turns a silent gap
# into a visible one, and gives the number rather than leaving it a mystery.
if [ "$NEEDS_SWAP" = "1" ]; then
    printf '→ Waiting for it to start answering'
    START=$(date +%s)
    for _ in $(seq 1 120); do
        if curl -s -m 1 -X POST http://127.0.0.1:53127/ping -d '{}' >/dev/null 2>&1; then
            echo " ($(( $(date +%s) - START ))s)"
            break
        fi
        printf '.'
        sleep 1
    done
fi

cat <<EOF

✓ ClaudeNotch installed and launched.

  Look for the bell in your menu bar.

  Test now without leaving the shell:
    curl -s -X POST http://127.0.0.1:53127/notification \\
      -H 'Content-Type: application/json' \\
      -d '{"message":"Hello from curl"}'

  Wire test through Claude Code:
    Start a new session in any project and ask Claude to run a shell command.
    The notch should expand with Allow / Deny / Always allow buttons.

  Uninstall hooks: $HOOK_DIR/uninstall-hooks.sh
EOF
