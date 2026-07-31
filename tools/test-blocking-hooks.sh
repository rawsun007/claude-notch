#!/bin/bash
# Tests for the two BLOCKING hooks: bin/claudenotch-permission.sh (PreToolUse)
# and bin/claudenotch-permreq.sh (PermissionRequest).
#
# These are the dangerous ones. Claude Code waits on their stdout before it may
# run a tool, so a hang here hangs the session, and malformed stdout can be read
# as a decision the user never made. The rules they must obey:
#
#   1. always exit 0
#   2. always finish, even when the server accepts the connection and then
#      never answers
#   3. emit either nothing or one valid JSON object, never half of one
#   4. never turn an unknown or missing decision into allow
#
# CLAUDENOTCH_HOST/PORT/TIMEOUT point them at a server this script controls, so
# nothing is asked of a running app.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin"
PERM="$BIN/claudenotch-permission.sh"
PERMREQ="$BIN/claudenotch-permreq.sh"
PASS=0
FAIL=0
PORT=53131

ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq is required for these tests"; exit 1; }

WORK=$(mktemp -d)
trap 'kill "${SRV:-0}" 2>/dev/null; wait "${SRV:-0}" 2>/dev/null; rm -rf "$WORK"' EXIT

# A server that replies with whatever is in reply.json, and records what it was
# asked. If reply.json holds the string "HANG" it accepts the connection and
# never answers, which is the case that can hang a session.
cat > "$WORK/server.py" <<'PY'
import http.server, os, json, time
OUT = os.environ["WORK"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(os.path.join(OUT, "requests.jsonl"), "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        reply = open(os.path.join(OUT, "reply.json")).read()
        if reply.strip() == "HANG":
            time.sleep(30)
            return
        data = reply.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY

echo '{}' > "$WORK/reply.json"
WORK="$WORK" PORT="$PORT" python3 "$WORK/server.py" &
SRV=$!
for _ in $(seq 1 40); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.1
done

reply() { printf '%s' "$1" > "$WORK/reply.json"; }
requests() { : > "$WORK/requests.jsonl"; }

# run <script> <payload> [extra env assignments...]
run() {
    local script="$1" payload="$2"; shift 2
    printf '%s' "$payload" | env CLAUDENOTCH_HOST=127.0.0.1 CLAUDENOTCH_PORT="$PORT" \
        CLAUDENOTCH_TIMEOUT=3 "$@" "$script"
}

BASH_TOOL='{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp/p","session_id":"s1"}'

# Every case asserts the exit status too, so a script that stops emitting JSON
# and starts failing cannot pass by accident.
emitted() { OUT=$(run "$@"); RC=$?; }

echo "PreToolUse hook (claudenotch-permission.sh)"

reply '{"decision":"allow"}'
requests
emitted "$PERM" "$BASH_TOOL"
check "allow: exits 0"            "$RC" "0"
check "allow: decision is allow"  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "allow"
check "allow: names the event"    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "PreToolUse"
check "allow: asks /permission"   "$(head -1 "$WORK/requests.jsonl" | jq -r '.path')" "/permission"
# The follow-up POST that turns the card into "running" is backgrounded, so give
# it a moment. It must not be what the decision waits on.
sleep 1
check "allow: also marks it running" \
      "$(grep -c '"/pretool"' "$WORK/requests.jsonl" | tr -d ' ')" "1"

reply '{"decision":"deny","reason":"not that folder"}'
emitted "$PERM" "$BASH_TOOL"
check "deny: exits 0"             "$RC" "0"
check "deny: decision is deny"    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
check "deny: carries the reason"  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "not that folder"

# A reason is cut to 200 characters. Cutting by bytes would split a multibyte
# character and produce invalid UTF-8, which used to drop the reason entirely.
LONG_CJK=$(python3 -c 'print("設定"*200)')
reply "$(jq -nc --arg r "$LONG_CJK" '{decision:"deny",reason:$r}')"
emitted "$PERM" "$BASH_TOOL"
check "long CJK reason: still valid JSON" \
      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
check "long CJK reason: cut to 200 characters" \
      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | python3 -c 'import sys;print(len(sys.stdin.read().rstrip("\n")))')" "200"

# Anything that is not allow/deny/ask must become ask. Never allow.
for d in '"maybe"' '""' 'null' '"ALLOW"' '"allow "'; do
    reply "{\"decision\":$d}"
    emitted "$PERM" "$BASH_TOOL"
    got=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')
    check "decision $d falls back to ask" "$got" "ask"
done

reply '{"decision":"allow"}'
requests
emitted "$PERM" '{"tool_name":"Grep","tool_input":{"pattern":"x"},"cwd":"/tmp/p"}'
check "safe-listed tool asks"     "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "ask"
check "safe-listed tool is not sent to the notch" \
      "$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')" "0"

requests
emitted "$PERM" 'not json at all'
check "unreadable payload: exits 0" "$RC" "0"
check "unreadable payload: asks"    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "ask"
check "unreadable payload: not forwarded" "$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')" "0"

reply 'this is not json'
emitted "$PERM" "$BASH_TOOL"
check "unreadable reply: asks"      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "ask"

# Nothing listening: the common case, since the app is often not running.
OUT=$(printf '%s' "$BASH_TOOL" | CLAUDENOTCH_HOST=127.0.0.1 CLAUDENOTCH_PORT=1 "$PERM"); RC=$?
check "notch not running: exits 0"  "$RC" "0"
check "notch not running: asks"     "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "ask"

# jq missing. It is used before the check that it exists, so this is worth
# proving rather than reading.
OUT=$(printf '%s' "$BASH_TOOL" | PATH="$WORK/nojq" CLAUDENOTCH_HOST=127.0.0.1 \
      CLAUDENOTCH_PORT="$PORT" CLAUDENOTCH_TIMEOUT=3 "$PERM" 2>/dev/null); RC=$?
check "without jq: exits 0"         "$RC" "0"
check "without jq: asks"            "$(printf '%s' "$OUT" | grep -c '"ask"' | tr -d ' ')" "1"

# The one that hangs a session: connection accepted, no reply.
reply 'HANG'
START=$(date +%s)
emitted "$PERM" "$BASH_TOOL"
ELAPSED=$(( $(date +%s) - START ))
check "server never answers: exits 0" "$RC" "0"
check "server never answers: asks"    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "ask"
if [ "$ELAPSED" -le 8 ]; then ok "server never answers: gives up on its timeout"
else bad "server never answers: took ${ELAPSED}s, timeout was 3s"; fi

echo
echo "AskUserQuestion pipeline"

Q='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","header":"Pick"}]},"cwd":"/tmp/p"}'

reply '{"mode":"allow"}'
requests
emitted "$PERM" "$Q"
check "question: goes to /question"  "$(head -1 "$WORK/requests.jsonl" | jq -r '.path')" "/question"
check "question allowed: allow"      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "allow"

reply '{"mode":"deny","answers":[{"header":"Pick","picked":["Second one"]}]}'
emitted "$PERM" "$Q"
check "question answered: deny with the answer" \
      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
check "question answered: quotes the pick" \
      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -c 'Pick: Second one' | tr -d ' ')" "1"

reply '{"cancelled":true}'
emitted "$PERM" "$Q"
check "question cancelled: asks"     "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "ask"

reply '{"mode":"deny","answers":[]}'
emitted "$PERM" "$Q"
check "question with no answers: still valid JSON" \
      "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"

echo
echo "PermissionRequest hook (claudenotch-permreq.sh)"

reply '{"decision":"allow"}'
requests
emitted "$PERMREQ" '{"tool_name":"ExitPlanMode","tool_input":{"plan":"do it"},"cwd":"/tmp/p"}'
check "allow: exits 0"            "$RC" "0"
check "allow: behavior is allow"  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')" "allow"
check "allow: names the event"    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "PermissionRequest"
check "allow: reuses /permission" "$(head -1 "$WORK/requests.jsonl" | jq -r '.path')" "/permission"

reply '{"decision":"deny"}'
emitted "$PERMREQ" '{"tool_name":"TodoWrite","tool_input":{},"cwd":"/tmp/p"}'
check "deny: behavior is deny"    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')" "deny"

# Anything that is not a decision must produce NO output, which is how this hook
# hands the prompt back to Claude Code. Empty output is the pass-through signal,
# so it is checked exactly rather than loosely.
for r in '{"decision":"ask"}' '{"decision":"weird"}' '{}' 'not json'; do
    reply "$r"
    emitted "$PERMREQ" '{"tool_name":"TodoWrite","tool_input":{},"cwd":"/tmp/p"}'
    check "reply $r: exits 0"       "$RC" "0"
    check "reply $r: emits nothing" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"
done

reply '{"decision":"allow"}'
requests
emitted "$PERMREQ" 'not json at all'
check "unreadable payload: exits 0"       "$RC" "0"
check "unreadable payload: emits nothing" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"
check "unreadable payload: not forwarded" "$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')" "0"

OUT=$(printf '{"tool_name":"TodoWrite"}' | CLAUDENOTCH_HOST=127.0.0.1 CLAUDENOTCH_PORT=1 "$PERMREQ"); RC=$?
check "notch not running: exits 0"   "$RC" "0"
check "notch not running: emits nothing" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"

OUT=$(printf '{"tool_name":"TodoWrite"}' | PATH="$WORK/nojq" CLAUDENOTCH_HOST=127.0.0.1 \
      CLAUDENOTCH_PORT="$PORT" CLAUDENOTCH_TIMEOUT=3 "$PERMREQ" 2>/dev/null); RC=$?
check "without jq: exits 0"          "$RC" "0"
check "without jq: emits nothing"    "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"

reply 'HANG'
START=$(date +%s)
emitted "$PERMREQ" '{"tool_name":"TodoWrite","tool_input":{},"cwd":"/tmp/p"}'
ELAPSED=$(( $(date +%s) - START ))
check "server never answers: exits 0" "$RC" "0"
check "server never answers: emits nothing" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"
if [ "$ELAPSED" -le 8 ]; then ok "server never answers: gives up on its timeout"
else bad "server never answers: took ${ELAPSED}s, timeout was 3s"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
