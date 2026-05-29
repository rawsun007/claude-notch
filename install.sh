#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d "ClaudeNotch.app" ]; then
    echo "→ ClaudeNotch.app not found, building first…"
    ./build.sh
fi

# 1. Install the .app
echo "→ Copying ClaudeNotch.app to /Applications"
if [ -d "/Applications/ClaudeNotch.app" ]; then
    rm -rf "/Applications/ClaudeNotch.app"
fi
cp -R ClaudeNotch.app /Applications/

# 2. Install hook scripts to a stable, absolute path so settings.json can reference them.
# Remove first: on APFS, cp clones and refuses to overwrite a byte-identical file
# ("are identical"), which under set -e would abort the install.
HOOK_DIR="$HOME/.claudenotch/bin"
mkdir -p "$HOOK_DIR"
rm -f "$HOOK_DIR"/*.sh
cp bin/*.sh "$HOOK_DIR/"
chmod +x "$HOOK_DIR"/*.sh
echo "→ Installed hook scripts to $HOOK_DIR"

# 3. Wire hooks into ~/.claude/settings.json (idempotent, with backup)
"$HOOK_DIR/install-hooks.sh"

# 4. Relaunch. `open` alone just re-activates an already-running instance, so a
# reinstall would keep the OLD binary in memory and the update would silently
# not take effect. Kill any running copy first, then launch the fresh one.
killall ClaudeNotch 2>/dev/null || true
# Give the old process a moment to release the menu-bar item + event port.
sleep 1
open /Applications/ClaudeNotch.app

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
