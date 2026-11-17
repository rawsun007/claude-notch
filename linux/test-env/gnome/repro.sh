# Inside GNOME Shell: start ClaudeNotch the way the app menu does and
# screenshot the idle pill, a permission card, and the stderr it printed.
set -u
OUT=/home/tester/app/test-env/out-gnome
mkdir -p "$OUT"
export HOME="$(mktemp -d)"
shell_eval() { gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval "$1" >/dev/null; }
shell_eval 'Main.overview.hide(); Main.messageTray._bannerBin.hide();'
sleep 1
${LAUNCHER:-/home/tester/app/bin/claudenotch} > "$OUT/app.log" 2>&1 &
sleep 4
gshot "$OUT/01-idle.png"
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
  -d '{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/home/tester/webapp","tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  "http://127.0.0.1:53127/hook?t=$(cat $HOME/.claudenotch/hook-token)" > /dev/null &
sleep 2
gshot "$OUT/02-card.png"
echo "--- app log"; cat "$OUT/app.log"
echo "--- windows"; xwininfo -root -tree 2>/dev/null | grep -i claude
