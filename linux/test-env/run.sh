#!/usr/bin/env bash
# Run the Linux test suite and the desktop e2e test in Docker, from any OS.
#   linux/test-env/run.sh          unit tests + e2e, screenshots in linux/test-env/out
#   linux/test-env/run.sh shell    a shell in the test box
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t claudenotch-linux-test test-env >/dev/null
if [ "${1:-}" = "shell" ]; then
  exec docker run --rm -it -v "$PWD:/home/tester/app" claudenotch-linux-test bash
fi
docker run --rm -v "$PWD:/home/tester/app" claudenotch-linux-test bash -c '
  set -e
  echo "== unit and integration tests"; python3 -m unittest discover -s tests
  echo "== desktop e2e"; test-env/e2e.sh'
