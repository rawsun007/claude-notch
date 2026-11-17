#!/usr/bin/env bash
# Runs inside the container for purge-test.sh. $DEB, $CLEANUP from the caller.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null; apt-get install -y -qq xvfb curl procps python3 >/dev/null 2>&1
apt-mark manual python3 >/dev/null   # a desktop always has it; autoremove must not take it here
apt-get install -y -qq "/src/$DEB" >/dev/null 2>&1
useradd -m bro; Xvfb :7 >/dev/null 2>&1 & sleep 1
mkdir -p /home/bro/.claude
cat > /home/bro/.claude/settings.json <<'JSON'
{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "my-own.sh"}]}]}}
JSON
chown -R bro:bro /home/bro/.claude
su bro -c "cd ~ && DISPLAY=:7 setsid claudenotch </dev/null >/dev/null 2>&1 &"; sleep 4
hooks() { grep -o 53127 /home/bro/.claude/settings.json | wc -l; }
data()  { ls -d /home/bro/.claudenotch /home/bro/.config/claudenotch /home/bro/.cache/claudenotch 2>/dev/null | wc -l; }
ping()  { curl -s --max-time 2 http://127.0.0.1:53127/ping; }
echo "before purge: hooks=$(hooks) ping=$(ping)"
apt-get purge -y -qq claudenotch >/dev/null 2>&1; apt-get autoremove -y -qq >/dev/null 2>&1; sleep 2
P=$(ping); echo "after purge:  hooks=$(hooks) running=${P:+yes} data=$(data)"
[ "$CLEANUP" = 1 ] && su bro -c "bash /src/packaging/remove-leftovers.sh"
P=$(ping); H=$(hooks); D=$(data)
echo "final:        hooks=$H running=${P:+yes} data=$D"
grep -q my-own.sh /home/bro/.claude/settings.json && grep -q opus /home/bro/.claude/settings.json && K=yes || K=no
if [ -z "$P" ] && [ "$H" = 0 ] && [ "$D" = 0 ] && [ "$K" = yes ]; then
  echo "PASS  nothing left running, no hooks, no data, the user's own settings kept"
else
  echo "FAIL  running=${P:+yes} hooks=$H data=$D own-settings-kept=$K"; exit 1
fi
