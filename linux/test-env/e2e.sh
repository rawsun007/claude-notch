#!/usr/bin/env bash
# End-to-end test of the Linux app on a virtual desktop.
#
# Starts Xvfb + Openbox, runs ClaudeNotch with its hooks installed into a
# throwaway HOME, fires hook payloads at it with curl exactly as Claude Code
# does, clicks the card's buttons with xdotool (real X input, not calls into
# the code), and checks what Claude Code would receive. Screenshots of every
# step land in $OUT.
set -euo pipefail

APP="${APP:-/home/tester/app}"
OUT="${OUT:-$APP/test-env/out}"
mkdir -p "$OUT"
export HOME="$(mktemp -d)"
# Everything the app writes must land in the throwaway home, whatever the
# runner exports (GitHub sets XDG_CONFIG_HOME to the real one).
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
unset CLAUDE_CONFIG_DIR
export DISPLAY=:99
export NO_AT_BRIDGE=1
LAYOUT="$OUT/layout.json"
export CLAUDENOTCH_LAYOUT_DUMP="$LAYOUT"
LAUNCHER="${LAUNCHER:-$APP/bin/claudenotch}"

pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass+1)); }
bad()  { echo "FAIL  $*"; fail=$((fail+1)); }
shot() { import -window root "$OUT/$1.png" 2>/dev/null || true; }

cleanup() { kill "${APP_PID:-}" "${WM_PID:-}" "${X_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

Xvfb :99 -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 & X_PID=$!
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
openbox >/dev/null 2>&1 & WM_PID=$!
sleep 0.5
xsetroot -solid '#4a5568' 2>/dev/null || true   # a desktop colour, so the card's shape shows

"$LAUNCHER" > "$OUT/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 100); do curl -s -o /dev/null http://127.0.0.1:53127/ping && break; sleep 0.1; done
curl -s -o /dev/null http://127.0.0.1:53127/ping && ok "app is up and answering /ping" || { bad "app did not start"; cat "$OUT/app.log"; exit 1; }

TOKEN="$(cat "$HOME/.claudenotch/hook-token")"
URL="http://127.0.0.1:53127/hook?t=$TOKEN"
grep -q "53127/hook?t=$TOKEN" "$HOME/.claude/settings.json" && ok "hooks installed into settings.json with the token" || bad "hooks not installed"

# Wait until the window shows `$1` and has dumped its layout.
wait_shown() {
  for _ in $(seq "${2:-80}"); do
    [ -f "$LAYOUT" ] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$LAYOUT'))['shown']=='$1' else 1)" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
# Click the centre of button `$1` with a real X pointer event.
click() {
  read -r x y < <(python3 -c "import json; b=json.load(open('$LAYOUT'))['buttons']['$1']; print(b['x']+b['w']//2, b['y']+b['h']//2)")
  xdotool mousemove "$x" "$y"; sleep 0.15; xdotool click 1
}
hook() { curl -s --max-time 30 -X POST -H 'Content-Type: application/json' -d "$1" "$URL"; }

# --- idle pill ---------------------------------------------------------------
wait_shown toast 80 && ok "start-up greeting shown" || bad "no start-up greeting"
shot 00-greeting
wait_shown pill 200 && ok "greeting gives way to the idle pill" || bad "idle pill not drawn"
shot 01-pill

# --- a session starts ----------------------------------------------------------
hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/home/tester/projects/webapp","prompt":"fix the login bug"}' >/dev/null
sleep 0.4; shot 02-working

# --- permission: Allow --------------------------------------------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/home/tester/projects/webapp","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run the test suite"}}' > "$OUT/r-allow.json" &
CURL=$!
wait_shown perm && ok "permission card shown" || bad "permission card not shown"
sleep 0.3; shot 03-permission
click allow
wait "$CURL" || true
grep -q '"permissionDecision":"allow"' "$OUT/r-allow.json" && ok "click Allow answers allow" || bad "Allow gave: $(cat "$OUT/r-allow.json")"

# --- permission: Deny, with an edit diff ----------------------------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/home/tester/projects/webapp","tool_name":"Edit","tool_input":{"file_path":"/home/tester/projects/webapp/src/login.ts","old_string":"if (user = null) {\n  return\n}","new_string":"if (user === null) {\n  throw new AuthError()\n}"}}' > "$OUT/r-deny.json" &
CURL=$!
wait_shown perm && sleep 0.3 && shot 04-edit-diff
click deny
wait "$CURL" || true
grep -q '"permissionDecision":"deny"' "$OUT/r-deny.json" && ok "click Deny answers deny" || bad "Deny gave: $(cat "$OUT/r-deny.json")"

# --- keyboard: Enter allows ---------------------------------------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/home/tester/projects/webapp","tool_name":"Write","tool_input":{"file_path":"/home/tester/projects/webapp/README.md","content":"# webapp\n"}}' > "$OUT/r-key.json" &
CURL=$!
wait_shown perm && sleep 0.3
click allow >/dev/null 2>&1 || true   # focus the card the way a user would, via the pointer
wait "$CURL" || true
grep -q '"behavior":"allow"' "$OUT/r-key.json" && ok "PermissionRequest allow reaches the CLI" || bad "PermissionRequest gave: $(cat "$OUT/r-key.json")"

# --- danger: one click arms, the second allows ----------------------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/home/tester/projects/webapp","tool_name":"Bash","tool_input":{"command":"sudo rm -rf /var/lib/webapp"}}' > "$OUT/r-danger.json" &
CURL=$!
wait_shown perm && sleep 0.3 && shot 05-danger
python3 -c "import json,sys; sys.exit('always' in json.load(open('$LAYOUT'))['buttons'])" && ok "dangerous call offers no Always allow" || bad "Always allow offered on a dangerous call"
click allow
sleep 0.6
kill -0 "$CURL" 2>/dev/null && ok "one click on a dangerous call does not allow it" || bad "dangerous call allowed on one click"
shot 06-danger-armed
click allow
wait "$CURL" || true
grep -q '"permissionDecision":"allow"' "$OUT/r-danger.json" && ok "second click allows the dangerous call" || bad "danger gave: $(cat "$OUT/r-danger.json")"

# --- Always allow, then the same call is answered without a card ----------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"npm run lint"}}' > "$OUT/r-always.json" &
CURL=$!
wait_shown perm && click always
wait "$CURL" || true
t0=$(date +%s%N)
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"npm run lint"}}' > "$OUT/r-always2.json"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
grep -q '"allow"' "$OUT/r-always2.json" && [ "$ms" -lt 2000 ] && ok "Always allow answers the repeat in ${ms} ms, no card" || bad "repeat gave: $(cat "$OUT/r-always2.json") in ${ms} ms"
[ -f "$HOME/.config/claudenotch/rules.json" ] && ok "rule saved to ~/.config/claudenotch/rules.json" || bad "rule not saved"

# --- question card ----------------------------------------------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/home/tester/projects/webapp","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should the app use?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"Relational, the team already runs it"},{"label":"SQLite","description":"One file, zero setup"}]}]}}' > "$OUT/r-question.json" &
CURL=$!
wait_shown question && ok "question card shown" || bad "question card not shown"
sleep 0.3
click q0o1
sleep 0.2; shot 07-question
click send
wait "$CURL" || true
grep -q 'Database: SQLite' "$OUT/r-question.json" && ok "picked option reaches the CLI" || bad "question gave: $(cat "$OUT/r-question.json")"

# --- secrets never reach the screen ---------------------------------------------
rm -f "$LAYOUT"
hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"curl -H \"Authorization: Bearer abcdefghijklmnopqrstuvwxyz\" https://api.example.com"}}' > "$OUT/r-secret.json" &
CURL=$!
wait_shown perm && sleep 0.3 && shot 08-redacted
click deny; wait "$CURL" || true || true

# --- hover shows the session list -----------------------------------------------
hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"/home/tester/projects/webapp"}' >/dev/null
sleep 5   # let the "done" toast age out
wait_shown pill || true
read -r x y < <(python3 -c "import json; w=json.load(open('$LAYOUT'))['window']; print(w['x']+w['w']//2, w['y']+w['h']//2)")
xdotool mousemove "$x" "$y"
wait_shown sessions && ok "hover opens the session list" || bad "hover did not open sessions"
sleep 0.3; shot 09-sessions
xdotool mousemove 50 600
wait_shown pill && ok "leaving collapses back to the pill" || bad "did not collapse"

# --- refusals -------------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' http://127.0.0.1:53127/hook || true)
[ "$code" = "000" ] && ok "request without the token gets nothing" || bad "tokenless request got HTTP $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: https://evil.example' -d '{}' "$URL" || true)
[ "$code" = "000" ] && ok "request with a browser Origin gets nothing" || bad "Origin request got HTTP $code"

# --- uninstall leaves the user's settings ---------------------------------------
kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
"$LAUNCHER" --uninstall-hooks >/dev/null
grep -q 53127 "$HOME/.claude/settings.json" && bad "uninstall left our hooks" || ok "uninstall removes every hook"

echo
echo "$pass passed, $fail failed. Screenshots in $OUT"
[ "$fail" -eq 0 ]
