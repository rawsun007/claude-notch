# Assertions on real GNOME Shell (Ubuntu's desktop). Run via
#   linux/test-env/gnome/run.sh test-env/gnome/check.sh
set -u
OUT=/home/tester/app/test-env/out-gnome; mkdir -p "$OUT"
export HOME="$(mktemp -d)"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
shell_eval() { gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval "$1"; }
shell_eval 'Main.overview.hide();' >/dev/null
sleep 1

BAR=$(shell_eval 'Main.panel.height' | sed -E "s/.*'([0-9]+)'.*/\1/")
[ -n "$BAR" ] && [ "$BAR" -gt 0 ] && ok "GNOME top bar is ${BAR}px" || bad "could not read the top bar height ($BAR)"

/home/tester/app/bin/claudenotch </dev/null >/dev/null 2>&1 &
sleep 7   # past the greeting
win_y() { xwininfo -root -tree | awk '/"ClaudeNotch": \("claudenotch"/ {print $0}' | sed -E 's/.*\+[0-9]+\+([0-9]+)  \+.*/\1/' | head -1; }
Y=$(win_y)
gshot "$OUT/check-idle.png"
[ -n "$Y" ] && [ "$Y" -ge "${BAR:-1}" ] && ok "idle pill at y=$Y, below the top bar" || bad "idle pill at y=$Y, behind the ${BAR}px top bar"

TOKEN=$(cat "$HOME/.claudenotch/hook-token")
curl -s --max-time 20 -X POST -H 'Content-Type: application/json' \
  -d '{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/home/tester/webapp","tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  "http://127.0.0.1:53127/hook?t=$TOKEN" > /tmp/r.json &
CURL=$!
sleep 2
Y=$(win_y); gshot "$OUT/check-card.png"
[ -n "$Y" ] && [ "$Y" -ge "${BAR:-1}" ] && ok "permission card at y=$Y, fully visible" || bad "permission card at y=$Y, under the top bar"
kill $CURL 2>/dev/null

/home/tester/app/bin/claudenotch </dev/null >/dev/null 2>&1
sleep 0.8; gshot "$OUT/check-second-launch.png"
grep -q "already running" "$HOME/.cache/claudenotch/claudenotch.log" && ok "a second launch is answered by the running app" || bad "second launch left no trace"
grep -q "listening" "$HOME/.cache/claudenotch/claudenotch.log" && ok "menu launch logs to ~/.cache/claudenotch" || bad "no log from a menu launch"
pkill -f bin/claudenotch; sleep 1

unset XAUTHORITY
/home/tester/app/bin/claudenotch </dev/null >/dev/null 2>&1 &
sleep 4
curl -s http://127.0.0.1:53127/ping >/dev/null && ok "starts on Wayland when XWayland refuses it" || bad "did not start without XWayland"

echo; echo "$pass passed, $fail failed (GNOME Shell). Screenshots in $OUT"
[ "$fail" -eq 0 ]
