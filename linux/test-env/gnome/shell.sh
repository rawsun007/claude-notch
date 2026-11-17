#!/usr/bin/env bash
# Inside the gnome test image, as the normal user: start a headless GNOME
# Shell (Wayland + XWayland, one 1440x900 virtual monitor) and run the script
# given as $1 inside it, with DISPLAY / WAYLAND_DISPLAY set and `gshot FILE`
# available to screenshot the whole shell, top bar included.
set -euo pipefail
export XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=ubuntu:GNOME
export SCRIPT="$1"
exec dbus-run-session -- bash -c '
  gnome-shell --headless --wayland --virtual-monitor 1440x900 --unsafe-mode > "$XDG_RUNTIME_DIR/shell.log" 2>&1 &
  SHELL_PID=$!
  for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.2; done
  export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0
  gshot() { gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
            --method org.gnome.Shell.Screenshot.Screenshot false false "$1" >/dev/null; }
  export -f gshot
  sleep 4
  export XAUTHORITY="$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -1)"
  kill -0 $SHELL_PID 2>/dev/null || { echo "gnome-shell died:"; tail -40 "$XDG_RUNTIME_DIR/shell.log"; exit 1; }
  bash "$SCRIPT"
  rc=$?
  kill $SHELL_PID 2>/dev/null
  exit $rc
'
