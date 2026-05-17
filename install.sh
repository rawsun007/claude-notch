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
HOOK_DIR="$HOME/.claudenotch/bin"
mkdir -p "$HOOK_DIR"
cp bin/*.sh "$HOOK_DIR/"
chmod +x "$HOOK_DIR"/*.sh
echo "→ Installed hook scripts to $HOOK_DIR"

# 3. Wire hooks into ~/.claude/settings.json (idempotent, with backup)
"$HOOK_DIR/install-hooks.sh"

# 4. Launch
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
