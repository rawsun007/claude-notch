#!/usr/bin/env bash
# Run a script inside headless GNOME Shell (Ubuntu 24.04's desktop).
#   linux/test-env/gnome/run.sh test-env/gnome/some-script.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
docker build -q -t claudenotch-gnome-test test-env/gnome >/dev/null 2>&1
docker run --rm --user root -w /home/tester/app -v "$PWD:/home/tester/app" claudenotch-gnome-test bash -c \
  "mkdir -p /run/dbus && dbus-daemon --system --fork && (python3 test-env/gnome/fake-logind.py &) && sleep 0.5 && su tester -c 'cd /home/tester/app && test-env/gnome/shell.sh $1'"
