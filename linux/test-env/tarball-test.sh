#!/usr/bin/env bash
# Install the tarball with its install.sh as a normal user on a distro
# without dpkg, then run the desktop e2e against the installed command.
#   linux/test-env/tarball-test.sh [fedora:41|archlinux|...]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${1:-fedora:41}"
TAR="$(ls -t dist/claudenotch-*-linux.tar.gz | head -1)"
docker run --rm -v "$PWD:/src:ro" -e TAR="$TAR" "$IMAGE" bash -c '
  set -e
  if command -v dnf >/dev/null; then
    dnf install -y -q python3-gobject gtk3 xorg-x11-server-Xvfb openbox xdotool ImageMagick xdpyinfo xsetroot curl dejavu-sans-fonts procps-ng util-linux tar gzip >/dev/null
  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm --quiet python-gobject gtk3 xorg-server-xvfb openbox xdotool imagemagick xorg-xdpyinfo xorg-xsetroot curl ttf-dejavu procps-ng >/dev/null
  fi
  useradd -m tester
  su tester -c "cd ~ && tar xzf /src/$TAR && ./claudenotch-*-linux/install.sh && ~/.local/bin/claudenotch --version"
  cp -r /src/test-env /tmp/te && chown -R tester /tmp/te
  su tester -c "APP=/tmp/te/.. OUT=/tmp/te/out LAUNCHER=/home/tester/.local/bin/claudenotch bash /tmp/te/e2e.sh"
  su tester -c "cd ~ && ./claudenotch-*-linux/install.sh --uninstall >/dev/null; test ! -e ~/.local/bin/claudenotch && echo \"PASS  install.sh --uninstall removes the app\""
'
