#!/usr/bin/env bash
# Install ClaudeNotch for the current user, on any Linux distribution.
# No root needed: everything goes under ~/.local and ~/.config.
#
#   ./install.sh              install (or upgrade) and start it
#   ./install.sh --uninstall  remove the hooks from Claude Code, then the app
#
# Needs Python 3.10+ with PyGObject and GTK 3:
#   Debian/Ubuntu: sudo apt install python3-gi gir1.2-gtk-3.0
#   Fedora:        sudo dnf install python3-gobject gtk3
#   Arch:          sudo pacman -S python-gobject gtk3
#   openSUSE:      sudo zypper install python3-gobject-Gdk typelib-1_0-Gtk-3_0
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOME/.local/lib/claudenotch"
BIN="$HOME/.local/bin"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

if [ "${1:-}" = "--uninstall" ]; then
  pkill -u "$(id -u)" -f "$BIN/claudenotch( |$)|$LIB/" 2>/dev/null || true
  [ -x "$BIN/claudenotch" ] && "$BIN/claudenotch" --uninstall-hooks || true
  rm -rf "$LIB" "$BIN/claudenotch" "$APPS/claudenotch.desktop" "$ICONS/claudenotch.png" "$AUTOSTART/claudenotch.desktop"
  echo "ClaudeNotch removed. Your always-allow rules are kept in ~/.config/claudenotch; delete that folder to forget them."
  exit 0
fi

if ! python3 -c 'import sys; assert sys.version_info >= (3, 10); import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null; then
  echo "ClaudeNotch needs Python 3.10+ with PyGObject and GTK 3. Install them first:" >&2
  sed -n 's/^#   /  /p' "$0" | grep -E 'apt|dnf|pacman|zypper' >&2
  exit 1
fi

mkdir -p "$LIB" "$BIN" "$APPS" "$ICONS" "$AUTOSTART"
rm -rf "$LIB/claudenotch"
cp -r "$HERE/claudenotch" "$LIB/claudenotch"
install -m 0755 "$HERE/bin/claudenotch" "$LIB/claudenotch-launcher"
# The launcher looks for the package beside ../lib/claudenotch, so link it
# from ~/.local/bin rather than copying.
ln -sf "$LIB/claudenotch-launcher" "$BIN/claudenotch"
install -m 0644 "$HERE/claudenotch.png" "$ICONS/claudenotch.png"
sed "s|^Exec=claudenotch|Exec=$BIN/claudenotch|" "$HERE/claudenotch.desktop" > "$APPS/claudenotch.desktop"
cp "$APPS/claudenotch.desktop" "$AUTOSTART/claudenotch.desktop"

"$BIN/claudenotch" --install-hooks
echo "Installed to $LIB. It starts at login; starting it now."
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH; add it to run 'claudenotch' by name." ;; esac
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && ! "$BIN/claudenotch" --status | grep -q 'app:   running'; then
  nohup "$BIN/claudenotch" >/dev/null 2>&1 &
fi
