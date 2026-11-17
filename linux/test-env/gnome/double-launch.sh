# Launch from the menu twice: the second must say where the app is rather
# than vanish, and the first must leave a log behind.
set -u
OUT=/home/tester/app/test-env/out-gnome; mkdir -p "$OUT"
export HOME="$(mktemp -d)"
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval 'Main.overview.hide(); Main.messageTray._bannerBin.hide();' >/dev/null
sleep 1
/home/tester/app/bin/claudenotch </dev/null >/dev/null 2>&1 &
sleep 4
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval 'Main.messageTray._bannerBin.show();' >/dev/null
/home/tester/app/bin/claudenotch </dev/null >/dev/null 2>&1; echo "second launch exit $?"
sleep 0.8
gshot "$OUT/03-second-launch.png"
grep -q "listening" "$HOME/.cache/claudenotch/claudenotch.log" && echo "PASS  log written to ~/.cache/claudenotch/claudenotch.log" || echo "FAIL  no log"
grep -q "already running" "$HOME/.cache/claudenotch/claudenotch.log" && echo "PASS  second launch logged" || echo "FAIL  second launch not logged"
