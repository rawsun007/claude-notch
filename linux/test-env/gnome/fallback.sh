# XWayland refusing the app (no Xauthority) must not stop it: it should come
# up on native Wayland instead.
set -u
export HOME="$(mktemp -d)"; unset XAUTHORITY
/home/tester/app/bin/claudenotch > /tmp/app.log 2>&1 &
sleep 4
curl -s http://127.0.0.1:53127/ping >/dev/null && grep -q listening /tmp/app.log && echo "PASS  starts on Wayland when X11 is refused" || { echo "FAIL  did not start:"; cat /tmp/app.log; }
