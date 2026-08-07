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

# The log used to be /tmp/claudenotch-hook.log. /tmp is mode 1777 and the name
# was fixed, so any other local user could pre-create it as a symlink and every
# hook after that would append through it as you: ~/.zshrc, ~/.claude/settings.json,
# anything you own. macOS has no equivalent of Linux's protected_symlinks, so
# the append follows the link. On top of that the file listed your working
# directories, tool names and session ids for everyone on the machine to read.
#
# It lives under the user's own 0700 directory now, 0600, and rotates at 512 KB
# so it cannot fill the disk. Same home and same reasoning as Swift's DebugLog,
# which was moved out of /tmp for exactly this.
NOTCH_LOG_DIR="${CLAUDENOTCH_LOG_DIR:-${HOME:-}/.claudenotch/logs}"
NOTCH_LOG="$NOTCH_LOG_DIR/hook.log"
NOTCH_LOG_MAX=524288
# Overridable so the test harness can point the forwarders at a server it
# controls instead of posting real events into a running app.
NOTCH_HOST="${CLAUDENOTCH_HOST:-127.0.0.1}"
NOTCH_PORT="${CLAUDENOTCH_PORT:-53127}"

notch_log() {
    [ -n "${HOME:-}" ] || return 0
    # A symlink at the log path is either an attack or a mistake. Either way,
    # never append through it.
    if [ -L "$NOTCH_LOG" ]; then return 0; fi
    if [ ! -d "$NOTCH_LOG_DIR" ]; then
        mkdir -p "$NOTCH_LOG_DIR" 2>/dev/null || return 0
        chmod 700 "$NOTCH_LOG_DIR" 2>/dev/null || true
    fi
    if [ ! -e "$NOTCH_LOG" ]; then
        # umask, not a chmod afterwards: the file must never exist readable,
        # not even for the instant between the two calls.
        (umask 177; : >> "$NOTCH_LOG") 2>/dev/null || return 0
    else
        local size
        size=$(stat -f%z "$NOTCH_LOG" 2>/dev/null || printf '0')
        if [ "$size" -gt "$NOTCH_LOG_MAX" ] 2>/dev/null; then
            mv -f "$NOTCH_LOG" "$NOTCH_LOG.1" 2>/dev/null || true
            (umask 177; : >> "$NOTCH_LOG") 2>/dev/null || return 0
        fi
    fi
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
