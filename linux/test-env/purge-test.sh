#!/usr/bin/env bash
# What `sudo apt purge claudenotch && sudo apt autoremove` leaves behind.
#   CLEANUP=1 (default): then run packaging/remove-leftovers.sh as the user
#   CLEANUP=0: the package alone must leave nothing (0.44.0 and later)
#   linux/test-env/purge-test.sh [deb]   default: the released 0.43.1
set -euo pipefail
cd "$(dirname "$0")/.."
DEB="${1:-dist/old/claudenotch_0.43.1_all.deb}"
docker run --rm --user root --cap-add SYS_PTRACE -v "$PWD:/src:ro" -e DEB="$DEB" -e CLEANUP="${CLEANUP:-1}" \
  ubuntu:24.04 bash /src/test-env/purge-inner.sh
