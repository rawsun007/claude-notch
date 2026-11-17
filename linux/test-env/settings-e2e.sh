#!/usr/bin/env bash
# Settings window and app control, on the Xvfb desktop with real input.
set -uo pipefail
APP="${APP:-/home/tester/app}"; OUT="${OUT:-$APP/test-env/out}"; mkdir -p "$OUT"
export HOME="$(mktemp -d)" DISPLAY=:98 NO_AT_BRIDGE=1
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_DIRS="$HOME/xdg"
unset CLAUDE_CONFIG_DIR
LAUNCHER="${LAUNCHER:-$APP/bin/claudenotch}"
export CLAUDENOTCH_LAYOUT_DUMP="$OUT/settings-layout.json"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
shot() { import -window root "$OUT/$1.png" 2>/dev/null || true; }
win() { xdotool search --name "^$1\$" 2>/dev/null | head -1; }
cleanup() { pkill -u "$(id -u)" -f 'claudenotch' 2>/dev/null; kill "${WM_PID:-}" "${X_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

Xvfb :98 -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 & X_PID=$!
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
openbox >/dev/null 2>&1 & WM_PID=$!; sleep 0.5; xsetroot -solid '#4a5568'

"$LAUNCHER" </dev/null >/dev/null 2>&1 &
for _ in $(seq 100); do curl -s -o /dev/null http://127.0.0.1:53127/ping && break; sleep 0.1; done
curl -s http://127.0.0.1:53127/ping | grep -q '"version"' && ok "ping reports a version" || bad "no version in ping"

# A second launch opens Settings in the running app.
"$LAUNCHER" </dev/null >/dev/null 2>&1; echo "second launch exit $?"
for _ in $(seq 50); do [ -n "$(win 'ClaudeNotch Settings')" ] && break; sleep 0.1; done
[ -n "$(win 'ClaudeNotch Settings')" ] && ok "second launch opens Settings" || bad "no Settings window"
sleep 0.5; shot settings-general
[ "$(pgrep -u "$(id -u)" -fc 'bin/claudenotch')" = "1" ] && ok "still one copy running" || bad "more than one copy running"

grep -q '"desktop_notifications": false' "$HOME/.config/claudenotch/settings.json" 2>/dev/null \
  && bad "settings written before any change" || ok "no settings file until something changes"

# Close Settings; right-click the notch for the menu.
xdotool windowclose "$(win 'ClaudeNotch Settings')" 2>/dev/null || xdotool windowkill "$(win 'ClaudeNotch Settings')"
sleep 0.5
sleep 4.5   # past the greeting
read -r x y < <(python3 -c "import json; w=json.load(open('$CLAUDENOTCH_LAYOUT_DUMP'))['window']; print(w['x']+w['w']//2, w['y']+w['h']//2)")
xdotool mousemove "$x" "$y"; sleep 0.6
xdotool click 3; sleep 0.6
shot notch-menu
xdotool key Down Return 2>/dev/null; sleep 0.8
[ -n "$(win 'ClaudeNotch Settings')" ] && ok "right-click > Settings opens it" || bad "menu did not open Settings"

# --quit stops it.
"$LAUNCHER" --quit >/dev/null; sleep 1
curl -s -o /dev/null http://127.0.0.1:53127/ping && bad "--quit left it running" || ok "--quit stops the app"

# --settings starts it with Settings open.
"$LAUNCHER" --settings </dev/null >/dev/null 2>&1 &
for _ in $(seq 60); do [ -n "$(win 'ClaudeNotch Settings')" ] && break; sleep 0.1; done
[ -n "$(win 'ClaudeNotch Settings')" ] && ok "--settings starts the app with Settings open" || bad "--settings showed nothing"

echo; echo "$pass passed, $fail failed (settings). Screenshots in $OUT"
[ "$fail" -eq 0 ]
