#!/bin/bash
# Do the two hook installers still agree on what they install?
#
# The hooks are merged into settings.json by the app (HookInstaller, in Swift)
# and, on a machine where the app is not on disk yet, by jq inside
# install-hooks.sh. One job, two implementations, and they drifted: the shell
# copy was ten events behind the app when this test was written, so anyone who
# set up before installing the app got a hook set from months earlier.
#
# Comparing the two lists is what keeps them together. Running both and diffing
# the output would be better, and is not possible: an app bundle resolves its
# home directory through the password database rather than $HOME, so the app
# cannot be pointed at a temporary settings file.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "hook-merge conformance"

# event<space>matched, sorted, from each source.
swift_events() {
    grep -o 'appendHook(to: "[A-Za-z]*", in: &hooks, matcher: [^)]*)' Sources/ClaudeNotch/HookInstaller.swift \
        | sed 's/appendHook(to: "\([A-Za-z]*\)".*matcher: \(.*\))/\1 \2/' \
        | sed 's/ ".*"$/ true/; s/ nil$/ false/' \
        | sort
}
shell_events() {
    # The generated jq lines are column-aligned, so spaces can appear either
    # side of the semicolon.
    grep -oE '\.hooks\.[A-Za-z]+ *= *add_hook\(\.hooks\.[A-Za-z]+ *; *(true|false)\)' bin/install-hooks.sh \
        | sed -E 's/\.hooks\.([A-Za-z]+) *= *add_hook\(.*; *(true|false)\)/\1 \2/' \
        | sort
}

SWIFT=$(swift_events)
SHELL_=$(shell_events)

[ -n "$SWIFT" ]  && ok "read the app's event list ($(printf '%s\n' "$SWIFT" | wc -l | tr -d ' ') events)" \
                 || bad "could not read the app's event list"
[ -n "$SHELL_" ] && ok "read the fallback's event list ($(printf '%s\n' "$SHELL_" | wc -l | tr -d ' ') events)" \
                 || bad "could not read the fallback's event list"

if [ "$SWIFT" = "$SHELL_" ]; then
    ok "both installers register the same events, with the same matchers"
else
    bad "the two installers disagree"
    echo "      only in the app:"
    comm -23 <(printf '%s\n' "$SWIFT") <(printf '%s\n' "$SHELL_") | sed 's/^/        /'
    echo "      only in the fallback:"
    comm -13 <(printf '%s\n' "$SWIFT") <(printf '%s\n' "$SHELL_") | sed 's/^/        /'
fi

# And the fallback is only reached when the app cannot do it.
grep -q -- "--install-hooks" bin/install-hooks.sh \
    && ok "setup asks the app to merge when it can" \
    || bad "setup no longer delegates to the app"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
