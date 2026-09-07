#!/bin/bash
# Build the app and actually restart it, then PROVE the running process is the
# one just built.
#
#   tools/run-dev-build.sh            # universal build
#   tools/run-dev-build.sh --fast     # native arch only, for iterating
#
# Why this exists, written down because the failure was expensive and silent:
#
# A test build was left running for four hours while six commits were built into
# the bundle on disk and none of them reached the process on screen. Every
# rebuild "worked". The person testing reported bugs that had already been
# fixed, and the fixes were re-litigated against a stale binary.
#
# Two things went wrong and this closes both.
#
#   1. The restart used `osascript -e 'quit app "ClaudeNotch"' || pkill`. That
#      quit has been seen returning success without quitting, and because it
#      exited 0 the `||` meant pkill never ran. `open` on an app that is already
#      running just brings it to the front rather than launching the new copy.
#      So: SIGTERM, unconditionally, and wait for the process to actually be
#      gone before launching.
#
#   2. The check afterwards was `pgrep`, which answers "something is running",
#      not "the thing I just built is running". Those are different questions
#      and only the second one matters. So: compare the process start time
#      against the binary's build time and refuse to claim success if the
#      process is older.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="ClaudeNotch.app"
BIN="$APP/Contents/MacOS/ClaudeNotch"

BUILD_ENV=()
for arg in "$@"; do
    case "$arg" in
        --fast) BUILD_ENV=(CLAUDENOTCH_SKIP_UNIVERSAL=1) ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "→ Building"
if ! env "${BUILD_ENV[@]}" ./build.sh >/dev/null; then
    echo "build failed" >&2
    exit 1
fi
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

# --- stop whatever is running, and make sure it is stopped
if pgrep -x ClaudeNotch >/dev/null 2>&1; then
    echo "→ Stopping the running copy"
    pkill -x ClaudeNotch
    for _ in $(seq 1 20); do
        pgrep -x ClaudeNotch >/dev/null 2>&1 || break
        sleep 0.25
    done
    if pgrep -x ClaudeNotch >/dev/null 2>&1; then
        echo "  it ignored SIGTERM, forcing"
        pkill -9 -x ClaudeNotch
        sleep 1
    fi
    if pgrep -x ClaudeNotch >/dev/null 2>&1; then
        echo "could not stop the running copy, refusing to pretend otherwise" >&2
        exit 1
    fi
fi

echo "→ Launching"
open "./$APP" || { echo "open failed" >&2; exit 1; }

# --- prove it
for _ in $(seq 1 20); do
    pgrep -x ClaudeNotch >/dev/null 2>&1 && break
    sleep 0.25
done
PID=$(pgrep -x ClaudeNotch | head -1)
[ -n "$PID" ] || { echo "nothing started" >&2; exit 1; }

python3 - "$PID" "$BIN" <<'PY'
import datetime, subprocess, sys
pid, binary = sys.argv[1], sys.argv[2]
fmt = "%a %b %d %H:%M:%S %Y"
started = subprocess.check_output(["ps", "-o", "lstart=", "-p", pid]).decode()
built = subprocess.check_output(
    ["stat", "-f", "%Sm", "-t", "%a %b %e %H:%M:%S %Y", binary]).decode()
s = datetime.datetime.strptime(" ".join(started.split()), fmt)
b = datetime.datetime.strptime(" ".join(built.split()), fmt)
path = subprocess.check_output(["ps", "-o", "comm=", "-p", pid]).decode().strip()
print(f"  pid {pid}")
print(f"  started {s}")
print(f"  binary  {b}")
print(f"  path    {path}")
# Both timestamps have one-second resolution and the launch follows the build
# immediately, so they routinely land in the same second. Only a process that
# predates the binary by more than that is actually a stale one, and the case
# this guards against is stale by hours.
if (b - s).total_seconds() > 1:
    print("\nFAIL: the running process is OLDER than the binary. It is not this build.")
    raise SystemExit(1)
print("\n✓ Running the build that was just made.")
PY
