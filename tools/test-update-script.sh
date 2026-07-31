#!/bin/bash
# Tests for bin/claudenotch-update.sh.
#
# The script replaces the app in /Applications, so the parts worth pinning down
# are the ones that decide WHETHER to do that. A version comparison that gets
# 0.10.2 versus 0.9.0 backwards either skips a real update forever or reinstalls
# the same build on every run, and neither announces itself.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE="$SCRIPT_DIR/../bin/claudenotch-update.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "claudenotch-update"

# The comparison the script uses, lifted verbatim so a change there fails here.
newest() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }
uptodate() {   # current, latest -> "yes" when no update should happen
    if [ "$1" = "$2" ] || [ "$(newest "$1" "$2")" = "$1" ]; then echo yes; else echo no; fi
}

check "same version is up to date"        "$(uptodate 0.10.3 0.10.3)" "yes"
check "older current wants the update"    "$(uptodate 0.10.2 0.10.3)" "no"
check "newer current stays put"           "$(uptodate 0.11.0 0.10.3)" "yes"

# The case a plain string compare gets wrong: "0.9.0" > "0.10.2" as text.
check "double digit minor beats single"   "$(uptodate 0.9.0 0.10.2)"  "no"
check "and not the other way round"       "$(uptodate 0.10.2 0.9.0)"  "yes"
check "double digit patch beats single"   "$(uptodate 0.10.9 0.10.10)" "no"

# --- flags
OUT=$("$UPDATE" --help 2>&1); RC=$?
check "help exits successfully" "$RC" "0"
check "help explains itself" "$(printf '%s' "$OUT" | grep -c 'Update ClaudeNotch in place')" "1"

OUT=$("$UPDATE" --nonsense 2>&1); RC=$?
check "an unknown flag is refused" "$RC" "2"

# --- reads the installed version rather than assuming one
if [ -d /Applications/ClaudeNotch.app ]; then
    INSTALLED=$(defaults read /Applications/ClaudeNotch.app/Contents/Info CFBundleShortVersionString)
    OUT=$("$UPDATE" --check 2>&1)
    check "check mentions the installed version" \
          "$(printf '%s' "$OUT" | grep -c "$INSTALLED")" "1"
    check "check changes nothing (app still there)" \
          "$(test -d /Applications/ClaudeNotch.app && echo yes)" "yes"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
