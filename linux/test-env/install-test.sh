#!/usr/bin/env bash
# Install the built .deb on a clean Ubuntu with apt (which must pull in GTK
# and PyGObject by itself), then run the desktop e2e against the installed
# /usr/bin/claudenotch instead of the source tree.
#   linux/test-env/install-test.sh [ubuntu:24.04|debian:12|...]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${1:-ubuntu:24.04}"
DEB="$(ls -t dist/claudenotch_*_all.deb | head -1)"
docker run --rm -v "$PWD:/src:ro" -e DEB="$DEB" "$IMAGE" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  echo "== installing $DEB on a clean '"$IMAGE"'"
  apt-get install -y -qq "/src/$DEB" >/dev/null
  claudenotch --version
  test -f /etc/xdg/autostart/claudenotch.desktop && echo "autostart entry installed"
  apt-get install -y -qq --no-install-recommends xvfb openbox xdotool imagemagick x11-utils x11-xserver-utils curl fonts-dejavu-core >/dev/null
  useradd -m tester
  cp -r /src/test-env /tmp/te && chown -R tester /tmp/te
  su tester -c "APP=/tmp/te/.. OUT=/tmp/te/out LAUNCHER=/usr/bin/claudenotch bash /tmp/te/e2e.sh"
'
