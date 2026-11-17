#!/usr/bin/env bash
# Tarball install.sh over a running older copy: the new version must end up
# running with no uninstall. Uses the released 0.43.1 tarball as the old one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/old
[ -f dist/old/claudenotch-0.43.1-linux.tar.gz ] || gh release download v0.43.1 -R rawsun007/claude-notch -p '*.tar.gz' -D dist/old --clobber
docker run --rm -v "$PWD:/src:ro" claudenotch-linux-test bash -c '
  set -u
  export HOME=/home/tester DISPLAY=:5
  cd ~ && cp -r /src /tmp/b && (cd /tmp/b && rm -f dist/*.tar.gz && packaging/build-tarball.sh >/dev/null)
  Xvfb :5 >/dev/null 2>&1 & sleep 1
  tar xzf /src/dist/old/claudenotch-0.43.1-linux.tar.gz && ./claudenotch-0.43.1-linux/install.sh >/dev/null 2>&1
  sleep 3; echo "before: $(curl -s http://127.0.0.1:53127/ping)"
  NEW=$(ls /tmp/b/dist/*.tar.gz); tar xzf "$NEW" && ./claudenotch-0.44.*-linux/install.sh
  for _ in $(seq 40); do curl -s http://127.0.0.1:53127/ping | grep -q "0.44" && break; sleep 0.5; done
  echo "after:  $(curl -s http://127.0.0.1:53127/ping)"
  n=$(pgrep -fc "python3[.0-9]* .*claudenotch( |$)")
  curl -s http://127.0.0.1:53127/ping | grep -q "0.44" && [ "$n" = "1" ] && echo "PASS  install.sh over a running 0.43.1 leaves one 0.44 copy running" || echo "FAIL  $n copies, ping: $(curl -s http://127.0.0.1:53127/ping)"
'
