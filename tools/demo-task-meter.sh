#!/bin/bash
# Demo / smoke-test for the per-session task progress meter.
#
# Drives a realistic task list through ClaudeNotch's /task endpoint so the
# notch animates a session row's meter from 0/5 up to 5/5. Use it to:
#   • record the demo GIF (run this, screen-record the notch), or
#   • quickly verify the meter end-to-end without a real Claude session.
#
# The notch only shows session rows while it's OPEN, so either turn on
# "Persistent notch display" (menu-bar bell) or hover the notch while this runs.
#
# Usage: tools/demo-task-meter.sh [project_name] [step_seconds] [hold_seconds]
set -u

PORT=53127
HOST=127.0.0.1
PROJECT="${1:-auth-service}"
STEP="${2:-1.2}"
HOLD="${3:-8}"   # seconds to leave the finished meter up before cleaning up
CWD="$HOME/Demos/$PROJECT"
SESSION="demo-$(date +%s)"

post() {  # post <event> <task_id> [subject]
    curl -s --max-time 2 -X POST "http://$HOST:$PORT/task" \
        -H 'Content-Type: application/json' \
        -d "{\"event\":\"$1\",\"task_id\":\"$2\",\"task_subject\":\"${3:-}\",\"session_id\":\"$SESSION\",\"cwd\":\"$CWD\"}" \
        >/dev/null
}

# Remove the demo's fake session from the notch so it doesn't linger as a
# phantom (it has no real Claude session behind it). Runs on any exit.
cleanup() {
    curl -s --max-time 2 -X POST "http://$HOST:$PORT/sessionend" \
        -H 'Content-Type: application/json' \
        -d "{\"session_id\":\"$SESSION\",\"cwd\":\"$CWD\"}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! nc -z "$HOST" "$PORT" 2>/dev/null; then
    echo "ClaudeNotch isn't listening on $HOST:$PORT — launch the app first." >&2
    exit 1
fi

echo "→ Driving task meter for '$PROJECT' (session $SESSION)"
echo "  Open the notch (hover, or enable Persistent notch display) to watch."

SUBJECTS=(
    "Add token rotation"
    "Wire refresh endpoint"
    "Migrate session store"
    "Backfill expiry column"
    "Update integration tests"
)
N=${#SUBJECTS[@]}

# Create the whole batch first → meter shows 0/N.
for i in $(seq 0 $((N - 1))); do
    post TaskCreated "t$i" "${SUBJECTS[$i]}"
    echo "  created  $((i + 1))/$N  ${SUBJECTS[$i]}"
    sleep "$STEP"
done

sleep "$STEP"

# Complete them one at a time → meter climbs to N/N and turns green.
for i in $(seq 0 $((N - 1))); do
    post TaskCompleted "t$i"
    echo "  done     $((i + 1))/$N  ${SUBJECTS[$i]}"
    sleep "$STEP"
done

echo "✓ Finished: meter should read $N/$N (green). Holding ${HOLD}s, then cleaning up the demo session."
sleep "$HOLD"
# cleanup() runs on EXIT (trap) and removes the phantom session.
