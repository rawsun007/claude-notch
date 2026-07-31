# Shared plumbing for the fire-and-forget hook forwarders next to this file.
# Sourced, never executed.
#
# Every one of those scripts was the same twenty lines: read stdin, append a
# line to the log, check the port is open, check jq exists, reshape the payload
# and POST it. Only the log label, the jq filter and the endpoint differed. Nine
# copies of the plumbing meant nine places to fix anything wrong with it, and
# they had already diverged on the curl timeout for no reason anyone recorded.
#
# These run on every hook Claude Code fires, so the rule throughout is that a
# problem here must never become Claude's problem: no failure path exits
# non-zero, and nothing blocks longer than its timeout.

NOTCH_LOG=/tmp/claudenotch-hook.log
# Overridable so the test harness can point the forwarders at a server it
# controls instead of posting real events into a running app.
NOTCH_HOST="${CLAUDENOTCH_HOST:-127.0.0.1}"
NOTCH_PORT="${CLAUDENOTCH_PORT:-53127}"

notch_log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >> "$NOTCH_LOG" 2>/dev/null || true
}

# True when the app is listening and jq is available to reshape the payload.
# Both are ordinary conditions rather than errors: the app is often not running,
# and jq is a recommendation rather than a requirement.
notch_ready() {
    nc -z "$NOTCH_HOST" "$NOTCH_PORT" 2>/dev/null || return 1
    command -v jq >/dev/null 2>&1 || return 1
}

# notch_post <endpoint> <jq-filter> [timeout] , payload on stdin.
notch_post() {
    local endpoint="$1" filter="$2" timeout="${3:-2}"
    jq -c "$filter" 2>/dev/null | curl -s --max-time "$timeout" -X POST \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "http://$NOTCH_HOST:$NOTCH_PORT/$endpoint" >/dev/null 2>&1 || true
}

# notch_forward <label> <endpoint> <jq-filter> [timeout]
# The whole of a one-shot forwarder: read the payload, log it, post it, exit 0.
notch_forward() {
    local label="$1" endpoint="$2" filter="$3" timeout="${4:-2}"
    local input
    input=$(cat)
    notch_log "$label hook fired"
    notch_ready || exit 0
    printf '%s' "$input" | notch_post "$endpoint" "$filter" "$timeout"
    exit 0
}
