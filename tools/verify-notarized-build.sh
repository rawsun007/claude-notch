#!/bin/bash
# Assert that a ClaudeNotch bundle is actually distributable.
#
#   tools/verify-notarized-build.sh [path/to/ClaudeNotch.app]
#
# Defaults to ./ClaudeNotch.app, then /Applications/ClaudeNotch.app.
#
# Why this exists as a script and not a paragraph in a README: signing and
# notarizing an app can succeed while leaving it broken in ways nothing reports.
# The hardened runtime is required for notarization and silently changes what
# the process may do at runtime; a bundle can be signed, notarized and stapled
# and still be missing its entitlements, its usage strings, or the resources
# build.sh is supposed to have copied in. Each check below is one way a release
# has been able to look fine and not be.
#
# Read-only. Nothing here modifies the bundle.
set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
    if [ -d "ClaudeNotch.app" ]; then APP="ClaudeNotch.app"
    elif [ -d "/Applications/ClaudeNotch.app" ]; then APP="/Applications/ClaudeNotch.app"
    else
        echo "No bundle to check. Pass a path, or run ./build.sh first." >&2
        exit 2
    fi
fi
[ -d "$APP" ] || { echo "Not a bundle: $APP" >&2; exit 2; }

PASS=0
FAIL=0
WARN=0

# Two report levels on purpose. A missing signature is a release blocker; a
# missing localization is not, and conflating them means the blockers stop being
# read.
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
warn() { WARN=$((WARN + 1)); printf '  warn  %s\n' "$1"; }

# `codesign -dvvv` writes everything to stderr, and running it once per check
# would be a dozen invocations of a tool that can disagree with itself if the
# bundle changes underneath. Capture once.
INFO=$(codesign -dvvv --entitlements :- "$APP" 2>&1)
field() { printf '%s\n' "$INFO" | sed -n "s/^$1=//p" | head -1; }

echo
echo "Verifying $APP"
echo

# --- identity
AUTHORITY=$(printf '%s\n' "$INFO" | sed -n 's/^Authority=//p' | head -1)
TEAM=$(field TeamIdentifier)
IDENT=$(field Identifier)

case "$AUTHORITY" in
    "Developer ID Application:"*)
        ok "signed with a Developer ID ($AUTHORITY)" ;;
    "")
        bad "not signed at all" ;;
    *)
        bad "not Developer ID signed: $AUTHORITY" \
            "an ad-hoc or self-signed build is a development build, not a release" ;;
esac

if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
    ok "team identifier present ($TEAM)"
else
    bad "no team identifier" "Gatekeeper and TCC both key on this"
fi

[ "$IDENT" = "com.claudenotch.app" ] \
    && ok "bundle identifier is com.claudenotch.app" \
    || bad "unexpected bundle identifier: ${IDENT:-none}" \
           "TCC grants are keyed to it, so a change silently resets every permission"

# --- hardened runtime
# Required for notarization. Also the reason the entitlements check below
# matters: under it, an entitlement that is absent is a capability that is gone.
if printf '%s\n' "$INFO" | grep -q 'flags=.*runtime'; then
    ok "hardened runtime enabled"
else
    bad "hardened runtime not enabled" "notarization will reject this bundle"
fi

# --- secure timestamp
# Without --timestamp the signature stops validating when the certificate
# expires, which turns every old release into a broken download years later.
if printf '%s\n' "$INFO" | grep -q '^Timestamp='; then
    ok "signed with a secure timestamp ($(field Timestamp))"
else
    bad "no secure timestamp" "the signature dies with the certificate"
fi

# --- entitlements
# The one that matters here is apple-events. Under the hardened runtime a
# process may not send Apple Events without it, and the failure mode is silence:
# no error, no dialog, the automation simply does nothing.
if printf '%s\n' "$INFO" | grep -q 'com.apple.security.automation.apple-events'; then
    ok "apple-events entitlement present"
else
    bad "apple-events entitlement missing" \
        "signed with --options runtime but without --entitlements; Apple Events will fail silently"
fi

# --- usage strings
# Absent, macOS shows a permission dialog with an empty reason line, which reads
# as an app that will not say why it wants your keyboard.
PLIST="$APP/Contents/Info.plist"
for key in NSAccessibilityUsageDescription NSAppleEventsUsageDescription; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
        ok "$key is set"
    else
        bad "$key missing" "the macOS permission prompt would have a blank reason"
    fi
done

# --- signature integrity
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    ok "signature verifies (deep, strict)"
else
    bad "signature does not verify" "$(codesign --verify --deep --strict "$APP" 2>&1 | head -2)"
fi

# --- designated requirement
# The check a user can run to answer "did this come from you". Worth asserting
# here so it cannot quietly stop holding for a build we published.
if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
    REQ="anchor apple generic and certificate leaf[subject.OU] = ${TEAM}"
    codesign --verify --strict -R "=${REQ}" "$APP" 2>/dev/null \
        && ok "satisfies an Apple-anchored requirement for team $TEAM" \
        || bad "does not satisfy its own team requirement" \
               "the documented verification command would fail for users"
fi

# --- notarization
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    ok "notarization ticket is stapled"
else
    bad "no stapled ticket" \
        "Gatekeeper falls back to a network check, so first launch fails offline"
fi

ASSESS=$(spctl -a -vvv -t exec "$APP" 2>&1)
if printf '%s\n' "$ASSESS" | grep -q 'source=Notarized Developer ID'; then
    ok "Gatekeeper accepts it as a notarized Developer ID app"
elif printf '%s\n' "$ASSESS" | grep -q 'accepted'; then
    bad "accepted, but not as notarized: $(printf '%s\n' "$ASSESS" | sed -n 's/.*source=/source=/p' | head -1)"
else
    bad "Gatekeeper rejects it" "$(printf '%s\n' "$ASSESS" | head -2)"
fi

# --- contents build.sh is meant to have copied in
# Signing is not the only way a release goes out broken. These are cheap and
# have each been wrong at least once.
HOOKS=$(ls "$APP/Contents/Resources/hooks" 2>/dev/null | wc -l | tr -d ' ')
[ "$HOOKS" -ge 15 ] \
    && ok "hook scripts bundled ($HOOKS)" \
    || bad "only $HOOKS hook scripts bundled, expected 15 or more" \
           "setup would install an incomplete set of forwarders"

LPROJ=$(ls -d "$APP"/Contents/Resources/*.lproj 2>/dev/null | wc -l | tr -d ' ')
[ "$LPROJ" -ge 10 ] \
    && ok "localizations bundled ($LPROJ)" \
    || warn "only $LPROJ localizations bundled, expected 10"

/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$PLIST" >/dev/null 2>&1 \
    && ok "claudenotch:// URL scheme registered" \
    || bad "CFBundleURLTypes missing" "claudenotch:// links would do nothing"

echo
echo "$PASS passed, $FAIL failed, $WARN warnings"

# Everything above is static. Two things cannot be asserted from a signature and
# have to be exercised by a person, once per signing identity rather than once
# per release, because that is what TCC keys on.
if [ "$FAIL" -eq 0 ]; then
    cat <<'TXT'

Static checks pass. Two runtime behaviours still need a person, once per
signing identity (that is what TCC remembers, not the version):

  1. Global hotkey and keystroke injection. Grant Accessibility and Input
     Monitoring, then press Opt-Cmd-N and type a message to a live session.
     These go through CGEvent, which needs the TCC grants but not the
     apple-events entitlement.

  2. Resume in terminal. Menu bar -> resume a session, and confirm a
     terminal window opens and the command runs. This goes through
     NSWorkspace.open on a .command file, not Apple Events.

  Note for whoever audits this next: no code path in the app currently sends
  an Apple Event. TerminalAutomator uses CGEvent and NSWorkspace, and
  AppleScriptSupport receives events rather than sending them. The
  apple-events entitlement is therefore precautionary today, and the check
  above stays because removing the entitlement is the kind of change that
  looks free and breaks silently the moment a code path does send one.
TXT
fi

[ "$FAIL" -eq 0 ]
