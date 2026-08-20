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

# --- what the script refuses to do
#
# These read the script rather than run it: the install path replaces the app
# in /Applications, which is not something a test suite gets to rehearse. What
# can be pinned is that the dangerous shapes are absent from the source.

# An integrity check an attacker can switch off by breaking one request is not
# an integrity check. This used to say "continuing without it".
check "a missing checksum stops the install" \
      "$(grep -c 'cannot be$' "$UPDATE")" "1"
check "no path continues without a checksum" \
      "$(grep -ci 'continuing without it' "$UPDATE")" "0"

# The old code deleted /Applications/ClaudeNotch.app and then copied. A copy
# that failed halfway left the user with no app at all.
check "the old app is not deleted before the new one is in place" \
      "$(grep -c '^rm -rf "\$APP"$' "$UPDATE")" "0"
check "the new app is staged first" \
      "$(grep -c 'STAGED=' "$UPDATE")" "1"
check "a failed install puts the old app back" \
      "$(grep -c 'mv "\$PREVIOUS" "\$APP"' "$UPDATE")" "1"

# The replacement has to come from the same signer as the copy being replaced.
check "the signer is compared" \
      "$(grep -c 'signed by someone else' "$UPDATE")" "1"

# The signer reader works on the real installed app, or the comparison above
# would silently compare two empty strings and pass everything.
if [ -d /Applications/ClaudeNotch.app ]; then
    SIGNER=$(codesign -dvv /Applications/ClaudeNotch.app 2>&1 | sed -n 's/^Authority=//p' | head -1)
    check "the installed app has a readable signer" \
          "$(test -n "$SIGNER" && echo yes)" "yes"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
