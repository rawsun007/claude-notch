#!/usr/bin/env bash
# Installing a new .deb over a running ClaudeNotch must leave the new version
# running, with no uninstall and no relaunch by hand.
#
#   0.43.1 (released, no self-update) --apt install--> this build (postinst hands over)
#   this build --apt install--> this build bumped one patch (the app restarts itself)
#   --apt remove--> nothing left running
#
#   linux/test-env/upgrade-test.sh [path/to/old.deb]
set -euo pipefail
cd "$(dirname "$0")/.."
OLD="${1:-dist/old/claudenotch_0.43.1_all.deb}"
[ -f "$OLD" ] || { mkdir -p dist/old; gh release download v0.43.1 -R rawsun007/claude-notch -p '*.deb' -D dist/old --clobber; }
# SYS_PTRACE: root on a real machine can read a process's environment (where
# its DISPLAY is); Docker drops that ability by default.
docker run --rm --user root --cap-add SYS_PTRACE -v "$PWD:/src:ro" -e OLD="$OLD" ubuntu:24.04 bash -c '
  set -uo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq xvfb openbox curl procps dpkg-dev python3 >/dev/null 2>&1
  pass=0; fail=0
  ok()  { echo "PASS  $*"; pass=$((pass+1)); }
  bad() { echo "FAIL  $*"; fail=$((fail+1)); }
  ver() { curl -s --max-time 2 http://127.0.0.1:53127/ping | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(\"version\") or \"0.43.x\")" 2>/dev/null; }
  wait_ver() { for _ in $(seq 60); do [ "$(ver)" = "$1" ] && return 0; sleep 0.5; done; return 1; }

  # Build this tree twice: as is, and one patch higher.
  cp -r /src /build && cd /build && rm -rf dist/*.deb
  NEW=$(python3 -c "import sys; sys.path.insert(0,\".\"); import claudenotch; print(claudenotch.__version__)")
  packaging/build-deb.sh >/dev/null
  NEXT=$(python3 -c "v=\"$NEW\".split(\".\"); v[-1]=str(int(v[-1])+1); print(\".\".join(v))")
  sed -i "s/__version__ = \"$NEW\"/__version__ = \"$NEXT\"/" claudenotch/__init__.py
  packaging/build-deb.sh >/dev/null
  ls dist/*.deb

  apt-get install -y -qq "/src/$OLD" >/dev/null 2>&1
  useradd -m u
  Xvfb :7 -screen 0 1280x800x24 >/dev/null 2>&1 &
  sleep 1
  su u -c "DISPLAY=:7 openbox >/dev/null 2>&1 &"
  su u -c "cd ~ && DISPLAY=:7 setsid claudenotch </dev/null >/dev/null 2>&1 &"
  wait_ver 0.43.x && ok "0.43.1 running in the desktop session" || bad "0.43.1 did not start"
  OLDPID=$(pgrep -u u -f "python3[.0-9]* /usr/bin/claudenotch" | head -1)

  echo "== apt install $NEW over the running 0.43.1"
  apt-get install -y -qq "/build/dist/claudenotch_${NEW}_all.deb" 2>&1 | grep -i "claudenotch:" || true
  wait_ver "$NEW" && ok "$NEW is now the one running, with no relaunch by hand" || bad "still running $(ver) after installing $NEW"
  NEWPID=$(pgrep -u u -f "python3[.0-9]* /usr/bin/claudenotch" | head -1)
  [ -n "$NEWPID" ] && [ "$NEWPID" != "$OLDPID" ] && ok "old process replaced (pid $OLDPID -> $NEWPID)" || bad "process not replaced"
  [ "$(stat -c %U /proc/$NEWPID 2>/dev/null)" = "u" ] && ok "restarted as the user, not root" || bad "restarted as $(stat -c %U /proc/$NEWPID 2>/dev/null)"
  [ "$(pgrep -u u -fc "python3[.0-9]* /usr/bin/claudenotch")" = "1" ] && ok "exactly one copy running" || bad "$(pgrep -u u -fc "python3[.0-9]* /usr/bin/claudenotch") copies running"
  grep -q "updated to\|restarting\|listening" /home/u/.cache/claudenotch/claudenotch.log 2>/dev/null && ok "log written as the user" || bad "no log"
  [ "$(stat -c %U /home/u/.cache/claudenotch/claudenotch.log 2>/dev/null)" = "u" ] && ok "log owned by the user" || bad "log owned by $(stat -c %U /home/u/.cache/claudenotch/claudenotch.log 2>/dev/null)"

  echo "== apt install $NEXT over the running $NEW"
  apt-get install -y -qq "/build/dist/claudenotch_${NEXT}_all.deb" >/dev/null 2>&1
  wait_ver "$NEXT" && ok "$NEXT running within seconds: the app restarted itself" || bad "still running $(ver) after installing $NEXT"
  [ "$(pgrep -u u -fc "python3[.0-9]* /usr/bin/claudenotch")" = "1" ] && ok "still exactly one copy" || bad "copies: $(pgrep -u u -fc "python3[.0-9]* /usr/bin/claudenotch")"
  grep -q "restarting into it" /home/u/.cache/claudenotch/claudenotch.log && ok "it logged the self-restart" || bad "no self-restart in the log"

  echo "== apt remove"
  apt-get remove -y -qq claudenotch >/dev/null 2>&1
  sleep 2
  [ -z "$(ver)" ] && ok "removing the package stops the app" || bad "still running $(ver) after remove"

  echo; echo "$pass passed, $fail failed (upgrade)"
  [ "$fail" -eq 0 ]
'
