#!/bin/bash
# Tests for the fire-and-forget hook forwarders in bin/.
#
# These run on every hook Claude Code fires, and they had no tests at all. The
# rule they must obey is the one that matters most: a problem in here must never
# become Claude's problem. So as well as checking each one posts the right
# payload to the right endpoint, this checks they still exit 0 when the app is
# not listening, when jq is missing, and when the shared file they source is not
# there at all.
#
# CLAUDENOTCH_HOST/PORT point them at a server this script controls, so nothing
# is posted into a running app.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin"
PASS=0
FAIL=0
PORT=53129

ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq is required for these tests"; exit 1; }

CAPTURE=$(mktemp -d)
# `wait` after the kill so bash does not print its own "Terminated" line.
trap 'kill "${SRV:-0}" 2>/dev/null; wait "${SRV:-0}" 2>/dev/null; rm -rf "$CAPTURE"' EXIT

# A server that records the path and body of whatever is posted to it.
cat > "$CAPTURE/server.py" <<'PY'
import http.server, os, json
OUT = os.environ["CAPTURE"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(os.path.join(OUT, "requests.jsonl"), "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY

CAPTURE="$CAPTURE" PORT="$PORT" python3 "$CAPTURE/server.py" &
SRV=$!
for _ in $(seq 1 40); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.1
done

run() {   # run <script> <payload>
    printf '%s' "$2" | CLAUDENOTCH_HOST=127.0.0.1 CLAUDENOTCH_PORT="$PORT" "$BIN/$1"
}
last_path() { tail -1 "$CAPTURE/requests.jsonl" 2>/dev/null | jq -r '.path'; }
last_body() { tail -1 "$CAPTURE/requests.jsonl" 2>/dev/null | jq -r '.body'; }
field()     { last_body | jq -r "$1"; }

echo "hook forwarders"

# --- each forwarder hits its own endpoint and reshapes the payload
run claudenotch-prompt.sh '{"prompt":"hello there","cwd":"/tmp/proj","session_id":"s1","transcript_path":"/t.jsonl"}'
check "prompt posts to /prompt"        "$(last_path)"        "/prompt"
check "prompt carries the prompt"      "$(field '.prompt')"  "hello there"
check "prompt carries the session"     "$(field '.session_id')" "s1"

run claudenotch-compact.sh '{"cwd":"/tmp/proj","session_id":"s2","transcript_path":"/t.jsonl"}'
check "compact posts to /compact"      "$(last_path)"        "/compact"
check "compact carries the session"    "$(field '.session_id')" "s2"

run claudenotch-sessionend.sh '{"cwd":"/tmp/proj","session_id":"s3"}'
check "sessionend posts to /sessionend" "$(last_path)"       "/sessionend"

run claudenotch-notify.sh '{"message":"needs you","cwd":"/tmp/proj","session_id":"s4"}'
check "notify posts to /notification"  "$(last_path)"        "/notification"
check "notify carries the message"     "$(field '.message')" "needs you"
check "notify labels the source"       "$(field '.source')"  "Claude Code"

run claudenotch-stop.sh '{"cwd":"/tmp/my-project","session_id":"s5","transcript_path":"/t.jsonl"}'
check "stop posts to /stop"            "$(last_path)"        "/stop"
check "stop titles the card"           "$(field '.title')"   "Claude finished"
check "stop uses the folder name"      "$(field '.detail')"  "my-project"

run claudenotch-task.sh '{"hook_event_name":"TaskCompleted","task_id":7,"task_subject":"Ship it","cwd":"/tmp/p","session_id":"s6"}'
check "task posts to /task"            "$(last_path)"        "/task"
check "task stringifies a numeric id"  "$(field '.task_id')" "7"
check "task finds the subject"         "$(field '.subject')" "Ship it"

# --- posttool is the one that posts twice
: > "$CAPTURE/requests.jsonl"
run claudenotch-posttool.sh '{"tool_name":"Edit","tool_input":{"file_path":"/a.swift"},"cwd":"/tmp/p","session_id":"s7"}'
check "posttool sends two requests"    "$(wc -l < "$CAPTURE/requests.jsonl" | tr -d ' ')" "2"
check "posttool reports the activity"  "$(head -1 "$CAPTURE/requests.jsonl" | jq -r '.path')" "/activity"
check "posttool then reports thinking" "$(tail -1 "$CAPTURE/requests.jsonl" | jq -r '.path')" "/thinking"
check "posttool carries the tool name" \
      "$(head -1 "$CAPTURE/requests.jsonl" | jq -r '.body | fromjson | .tool_name')" "Edit"

# --- never break Claude, whatever is wrong
OUT=$(printf '{}' | CLAUDENOTCH_HOST=127.0.0.1 CLAUDENOTCH_PORT=1 "$BIN/claudenotch-stop.sh" 2>&1); RC=$?
check "exits 0 when nothing is listening" "$RC" "0"

OUT=$(printf 'not json at all' | CLAUDENOTCH_HOST=127.0.0.1 CLAUDENOTCH_PORT="$PORT" "$BIN/claudenotch-prompt.sh" 2>&1); RC=$?
check "exits 0 on a payload jq cannot read" "$RC" "0"

# jq missing: an empty PATH entry ahead of the real one hides it.
OUT=$(printf '{}' | PATH="$CAPTURE/nojq:$PATH" CLAUDENOTCH_PORT="$PORT" "$BIN/claudenotch-stop.sh" 2>&1); RC=$?
check "exits 0 with an unusual PATH" "$RC" "0"

# The shared file missing, which is what a half-updated install looks like.
LONE=$(mktemp -d)
cp "$BIN/claudenotch-stop.sh" "$LONE/"
OUT=$(printf '{}' | "$LONE/claudenotch-stop.sh" 2>&1); RC=$?
check "exits 0 without the shared file" "$RC" "0"
check "and says nothing on stderr"      "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"
rm -rf "$LONE"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
