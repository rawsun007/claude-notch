# Security

ClaudeNotch decides which commands an AI agent may run on your Mac. That makes
it a security tool whether or not it is described as one, so this page says
what it defends against, what it does not, and how to tell us when it is wrong.

## Reporting a vulnerability

**Please do not open a public issue for a security bug.**

Use GitHub's private reporting:
[Report a vulnerability](https://github.com/rawsun007/claude-notch/security/advisories/new).
It goes to the maintainer and nobody else, and it gives us somewhere to discuss
a fix before it is public.

If that form is unavailable to you, message the maintainer on
[LinkedIn](https://www.linkedin.com/in/roshan-ramani-0510102b2) asking for a
private channel. Do not put the details in the first message.

What helps, roughly in order:

- what an attacker gets out of it, and what they need first (local account?
  a page the user visits? a repository the user opens?)
- the smallest input that shows it: a payload posted to the loopback port, a
  command string, a file path
- the version, from **Settings → About**, and your macOS version

You will get an acknowledgement within **3 days** and an assessment within
**10 days**. Fixes ship in the next release; something exploitable without
local access ships as soon as it is ready.

There is no bounty. This is one person's side project. Credit in the changelog
and the advisory if you want it.

## Supported versions

Only the latest release. There are no maintenance branches, so a fix means an
upgrade. Homebrew users get it with `brew upgrade --cask rawsun007/tap/claudenotch`.

| Version | Supported |
| --- | --- |
| latest release | yes |
| anything older | no |

## What the app assumes

Worth stating plainly, because a report is only a bug if it crosses one of
these lines.

**Trusted.** Your user account, the Claude Code and Codex binaries, and the
contents of your own `~/.claude` and `~/.codex`. Anything able to write there
can already run code as you, with or without this app.

**Untrusted.** Everything that arrives over a hook: `tool_input`, `cwd`,
`transcript_path`, session ids, model names, status-line JSON, PR URLs. Also
transcript file contents, git branch names, and anything a web page can cause
your browser to fetch. All of it is data and never instruction.

**Out of scope.** Another account on the machine that has already achieved code
execution as you. A malicious Claude Code build. Anything requiring physical
access to an unlocked Mac.

## The boundaries, and where they are enforced

| Boundary | Where |
| --- | --- |
| HTTP parsing of raw socket bytes | `EventServer.parseRequest` |
| Rejecting browser-originated requests | `EventServer.isLocalHookRequest` |
| Confining transcript reads to agent directories | `EventServer.isAllowedTranscriptPath` |
| Classifying a command or path as destructive | `ToolPreviewParser.dangerReasons` |
| Restricting a payload URL to http(s) | `AppState.sanitizedWebURL` |
| Validating a project name from a URL or script | `NotchURL.isSafeProjectName` |

Each of those is a pure function with tests, deliberately, so its behaviour can
be checked without running the app.

Other properties the code holds to, worth knowing if you are reading it:

- The listener binds loopback only and every hook must be a POST.
- Collections fed by payloads are capped, so no payload can grow memory without
  bound: sessions 12, queues 64, learned context windows 64, activity history
  500, archived sessions 200, recent projects 8. A single request is capped at
  1 MB.
- Files the app writes are owner-only: `~/.claudenotch` and `~/.claudenotch/bin`
  are 0700, `state.json` and the logs are 0600, and the diagnostic log is off
  unless you turn it on.
- Nothing leaves the machine except the GitHub Releases version check, which
  sends no information about you.
- A URL or an AppleScript command can only ask for a project by *name*, which is
  resolved against sessions already on disk. Neither can hand the app a path.

## Known limits

Say these back to us only if you can get past them in a way we have not
described here.

**The destructive-command check is a denylist.** It recognises patterns:
`rm -rf`, `sudo`, `curl | sh`, writes to `~/.ssh` or a LaunchAgent, scripts
inside `sh -c` and `python3 -c`, and a few dozen more. A denylist never
finishes. Something novel enough will not be flagged, which means it can be
approved by an always-allow rule or by Auto-Approve without a hold-to-confirm.
Treat the warning as a good catch, never as a guarantee. If you want a hard
stop, leave Auto-Approve off and do not create tool-wide allow rules.

**Auto-Approve is exactly what it says.** Turning it on means commands run
without you seeing them. Destructive ones still stop, as far as the check above
can tell.

**A tool-wide allow rule approves every future call of that tool.** The Rules
page marks them amber for this reason.

**The app is signed but not notarized.** macOS Gatekeeper will refuse the first
launch and you have to allow it by hand. That is a real weakness in how the app
is distributed and we would rather not have it; notarization needs a paid Apple
Developer account. Verify the DMG against the checksum published in the
[Homebrew cask](https://github.com/rawsun007/homebrew-tap/blob/main/Casks/claudenotch.rb),
or install through Homebrew, which checks it for you.

**Any local process can post to the loopback port.** That is inherent: it is how
the hooks reach the app. A process running as you could inject a fake session or
a fake notification card. It could also just run the command itself, so this
buys an attacker nothing, but it does mean a card is not proof of provenance.

**Touch ID confirms a person, not a command.** It gates approving a destructive
action. It does not verify that the command shown is the command Claude Code
will run; that comes from the hook payload.

## Verifying a build

```sh
shasum -a 256 ClaudeNotch.dmg
```

Compare against `sha256` in the
[cask](https://github.com/rawsun007/homebrew-tap/blob/main/Casks/claudenotch.rb),
published by the same script that built the DMG. This catches a corrupted or
truncated download. It is not protection against a compromised GitHub account,
since both the DMG and the checksum come from there.

Or build it yourself: `./build.sh`, no dependencies beyond a Swift toolchain.
`Package.swift` pulls in nothing, so there is no package supply chain here.

## Enabling notarization

The build is wired for it; what is missing is a paid Apple Developer account.
With one, two environment variables switch the whole path on:

```sh
export CLAUDENOTCH_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
xcrun notarytool store-credentials claudenotch \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
export CLAUDENOTCH_NOTARY_PROFILE=claudenotch

./tools/release.sh <version>
```

`build.sh` then signs the app with the hardened runtime and a timestamp,
`tools/build-dmg.sh` signs, notarizes and staples the disk image, and refuses
to finish if Gatekeeper still rejects the result. The instructions inside the
DMG change to match, because shipping Gatekeeper-bypass steps to someone who
does not need them teaches them to bypass Gatekeeper for anything calling
itself ClaudeNotch.

Without those variables everything behaves exactly as it does today.
