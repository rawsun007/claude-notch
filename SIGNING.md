# Signing and notarization

Everything a release needs from Apple, where it lives, and what to do when it
stops working. Written down because the parts that break here break years apart,
long after anybody remembers how they were set up.

Published releases are signed with **Developer ID Application: Alfastack
Solution Private Limited (PS8FJ3MQB2)** under the hardened runtime, notarized by
Apple, and stapled. Users verify that with `spctl -a -vvv
/Applications/ClaudeNotch.app`, documented in [SECURITY.md](SECURITY.md).

## What has to exist

| Thing | Where it lives | Used by |
| --- | --- | --- |
| Developer ID Application certificate + private key | login keychain on the release machine, pinned by SHA-1 in `build.sh` | `build.sh` |
| The same certificate as a base64 `.p12` | GitHub secret `DEVELOPER_ID_P12` (+ `DEVELOPER_ID_P12_PASSWORD`) | `.github/workflows/release.yml` |
| notarytool credentials | keychain profile `claudenotch` on the release machine | `tools/release.sh`, `tools/build-dmg.sh` |
| The same credentials as three values | GitHub secrets `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | `.github/workflows/release.yml` |

Two switches drive the local path:

```sh
export CLAUDENOTCH_SIGN_ID="Developer ID Application: Alfastack Solution Private Limited (PS8FJ3MQB2)"
export CLAUDENOTCH_NOTARY_PROFILE=claudenotch
```

`CLAUDENOTCH_SIGN_ID` is optional locally: `build.sh` pins a certificate hash as
its default and only falls back if that hash is not in the keychain.
`CLAUDENOTCH_NOTARY_PROFILE` is not optional. `tools/release.sh` refuses to run
without it, because a published release Gatekeeper blocks is worse than no
release.

## Why the certificate is pinned by hash

This team has four Developer ID Application certificates, identical in every
visible respect:

```
82915A39E2103536D4C1D072B650363E9E24A6F1   expires 30 Aug 2031
B5AFFF4A05663A91CD9D52E7BCAE29D220DBF5B8   expires 30 Aug 2031
8FC67355234285AE6DF8A22D25258E6026C7542E   expires 30 Aug 2031
D1977844AE12568324248A02C78DC7C4A2440AB3   expires 30 Aug 2031  ← pinned in build.sh
```

`codesign` given the name picks whichever it finds first. That is harmless until
one is revoked or expires, at which point releases get signed by a certificate
nobody chose and the failure shows up as user reports, not as a build error. The
hash names exactly one. `security find-identity -v -p codesigning` lists them.

Note what pinning does **not** do: all four belong to team `PS8FJ3MQB2`, so the
designated requirement users verify (`certificate leaf[subject.OU] =
PS8FJ3MQB2`) is satisfied by any of them. Swapping certificates within the team
does not break anyone's install or their TCC grants.

## Storing the notarytool profile

Once per machine. Needs an app-specific password from appleid.apple.com, not the
Apple account password:

```sh
xcrun notarytool store-credentials claudenotch \
    --apple-id <apple-id-email> \
    --team-id PS8FJ3MQB2 \
    --password <app-specific-password>
```

It goes into the login keychain. It is not in this repo, not in a dotfile, and
does not sync, so a new machine needs this run again.

## Rotation

### The certificate expires (next: 30 August 2031)

Signatures already published keep validating: `build.sh` signs with
`--timestamp`, so a signature outlives the certificate that made it. Old
releases keep installing. What breaks is signing anything new.

1. Create a new Developer ID Application certificate in the Apple Developer
   account and download it into the release machine's keychain.
2. `security find-identity -v -p codesigning` for its SHA-1 hash.
3. Update `DEV_ID` in `build.sh` to that hash. One line.
4. Export it as a `.p12` and update the `DEVELOPER_ID_P12` and
   `DEVELOPER_ID_P12_PASSWORD` GitHub secrets.
5. `./build.sh && ./tools/verify-notarized-build.sh` before cutting a release.

As long as the new certificate is in team `PS8FJ3MQB2`, users notice nothing.

### The app-specific password is revoked or lost

Notarization starts failing with an authentication error; signing still works,
so the symptom is a release that builds and then refuses to publish. Generate a
new app-specific password and re-run `store-credentials` with the same profile
name, plus update `APPLE_APP_PASSWORD` in the GitHub secrets.

### The team identifier changes

The expensive one, so it is worth knowing the cost before agreeing to it. The
team identifier is in the designated requirement, so a change means:

- every user's Accessibility and Input Monitoring grant resets, because TCC keys
  on the signature;
- the self-updater's team check fails against the installed copy, so people are
  told the download is signed by someone else and refuse it. That is the check
  working correctly, and it will still block them. `bin/claudenotch-update.sh`
  reads the team from the installed app rather than hardcoding it, which stops a
  field copy going stale, but it cannot approve a genuine team change on its
  own;
- the verification commands in SECURITY.md and the README name the old team.

Do not do this quietly. It needs a release note, and a plan for people whose
updater refuses the new build.

## Release machine setup, from nothing

```sh
# 1. Certificate: download from the Apple Developer account, double-click to
#    add it to the login keychain, then confirm it is usable for signing.
security find-identity -v -p codesigning | grep PS8FJ3MQB2

# 2. Notarization credentials.
xcrun notarytool store-credentials claudenotch \
    --apple-id <apple-id-email> --team-id PS8FJ3MQB2 --password <app-specific-password>
export CLAUDENOTCH_NOTARY_PROFILE=claudenotch

# 3. Prove it end to end before trusting it with a version number.
./build.sh
./tools/verify-notarized-build.sh ClaudeNotch.app
```

Step 3 on a locally built bundle will fail the notarization checks, which is
correct: `build.sh` signs but does not notarize. Run it against
`/Applications/ClaudeNotch.app` after a real release to see all fifteen pass.

## What is verified, and what a person still has to check

`tools/verify-notarized-build.sh` asserts fifteen static properties of a bundle
and runs in `tools/release.sh` and in CI, which refuse to publish if it fails.

Two behaviours it cannot assert, because TCC keys on the signing identity rather
than the version, so they need checking once per identity rather than per
release:

1. **Accessibility and Input Monitoring.** Grant both, press `Opt-Cmd-N`, type a
   message into a live session. `CGEvent` path.
2. **Resume in terminal.** Resume a session from the menu bar and confirm a
   terminal window opens and runs the command. `NSWorkspace.open` on a
   `.command` file.

### About the apple-events entitlement

`ClaudeNotch.entitlements` requests
`com.apple.security.automation.apple-events`, and the commit that added it said
the first notarized build would otherwise have shipped with
`TerminalAutomator` unable to drive Terminal.

On re-reading the code, no path in the app currently sends an Apple Event.
`TerminalAutomator` synthesizes keystrokes with `CGEvent` and opens terminals
with `NSWorkspace.open`; `AppleScriptSupport` receives Apple Events rather than
sending them, which is `NSAppleScriptEnabled`, a different mechanism. So the
entitlement is precautionary rather than load-bearing today.

It stays, and `verify-notarized-build.sh` keeps asserting it. Removing an
entitlement that nothing currently needs looks free and costs nothing until the
day a code path does send an event, at which point it fails silently under the
hardened runtime with no error and no dialog, which is a bug that could take a
long time to find. `NSAppleEventsUsageDescription` stays for the same reason: if
a prompt ever does appear, it should say why.
