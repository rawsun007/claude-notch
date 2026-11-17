#!/usr/bin/env bash
# Build dist/claudenotch_<version>_all.deb. Needs dpkg-deb (any Debian or
# Ubuntu, or the test-env image). The package is pure Python, so one .deb
# serves every architecture.
#
#   /usr/bin/claudenotch                  launcher
#   /usr/lib/claudenotch/claudenotch/     the package
#   /usr/share/applications/              menu entry
#   /etc/xdg/autostart/                   starts at login (users can turn it off
#                                         in their session's startup settings)
#   /usr/share/icons/hicolor/256x256/apps/
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(python3 -c 'import claudenotch; print(claudenotch.__version__)')"
ROOT="$(mktemp -d)"
PKG="$ROOT/claudenotch_${VERSION}_all"
trap 'rm -rf "$ROOT"' EXIT

install -d "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/lib/claudenotch/claudenotch" \
  "$PKG/usr/share/applications" "$PKG/etc/xdg/autostart" \
  "$PKG/usr/share/icons/hicolor/256x256/apps" "$PKG/usr/share/doc/claudenotch"
install -m 0755 bin/claudenotch "$PKG/usr/bin/claudenotch"
install -m 0644 claudenotch/*.py "$PKG/usr/lib/claudenotch/claudenotch/"
install -m 0644 packaging/claudenotch.desktop "$PKG/usr/share/applications/claudenotch.desktop"
install -m 0644 packaging/claudenotch.desktop "$PKG/etc/xdg/autostart/claudenotch.desktop"
install -m 0644 packaging/claudenotch.png "$PKG/usr/share/icons/hicolor/256x256/apps/claudenotch.png"
install -m 0644 README.md "$PKG/usr/share/doc/claudenotch/README.md"

SIZE="$(du -sk "$PKG/usr" "$PKG/etc" | awk '{s+=$1} END {print s}')"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: claudenotch
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: all
Depends: python3 (>= 3.10), python3-gi, gir1.2-gtk-3.0
Recommends: libnotify-bin, curl
Suggests: gir1.2-gtklayershell-0.1
Installed-Size: ${SIZE}
Maintainer: ClaudeNotch <noreply@github.com>
Homepage: https://github.com/rawsun007/claude-notch
Description: Claude Code permission prompts at the top of your screen
 A small card at the top centre of the screen that shows Claude Code's
 permission requests and questions, so they can be answered without
 switching to the terminal. Talks to Claude Code through its hooks on
 127.0.0.1 only, and warns before dangerous commands.
CONTROL

# The hooks live in each user's own settings, which a root maintainer script
# must not edit, so removal is `claudenotch --uninstall-hooks` (see README).
cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
POSTINST
chmod 0755 "$PKG/DEBIAN/postinst"

mkdir -p dist
dpkg-deb --root-owner-group --build "$PKG" "dist/claudenotch_${VERSION}_all.deb" >/dev/null
echo "dist/claudenotch_${VERSION}_all.deb"
