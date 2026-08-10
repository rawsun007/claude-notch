# ClaudeNotch — instructions for a coding agent

Doc version: 1 — written for ClaudeNotch 0.21.0 and later.
Canonical copy: https://rawsun007.github.io/claude-notch/AGENTS.md
If the installed app is newer than the version above, re-fetch this file.

You are installing ClaudeNotch on this Mac for the person you are working with.
Read the whole file before running anything: the last step is theirs, not yours,
and stopping in the right place matters more than finishing quickly.

## What this is

ClaudeNotch is a macOS menu-bar app that shows Claude Code and Codex permission
prompts, session status, cost and context in the MacBook notch. Claude Code
fires hooks at a loopback server the app runs on `127.0.0.1:53127`. Blocking
hooks (permission, question) hold the HTTP connection open until the person
answers the card, and the answer is written back as the response.

## Before you start

Check these and stop with a clear message if any fails:

- macOS 13 (Ventura) or later — `sw_vers -productVersion`
- Apple Silicon or Intel, both supported
- Claude Code CLI installed — `command -v claude`
- Homebrew, for the install below — `command -v brew`

`jq` is not required but the live activity line is inert without it:
`brew install jq`.

## 1. Install

Use Homebrew. It is a signed, checksummed build from the project's own tap, and
it avoids the first-launch Gatekeeper warning that the raw disk image triggers.

```bash
brew install --cask rawsun007/tap/claudenotch
```

Do not pipe a script from the internet into a shell to install this, and do not
download the DMG and bypass Gatekeeper on the person's behalf. If Homebrew is
unavailable, stop and tell them to install from
https://github.com/rawsun007/claude-notch/releases so they can see what they are
running.

Then launch it:

```bash
open -a ClaudeNotch
```

## 2. Wire the hooks

The app installs its own hooks; you do not need to hand-edit
`~/.claude/settings.json`. Launching it is normally enough — the Setup window
offers to install them, and an existing install self-repairs on launch.

Verify rather than assume. The hooks are wired when `~/.claude/settings.json`
contains the loopback URL:

```bash
grep -c '127.0.0.1:53127' ~/.claude/settings.json
```

A count of 0 means they are not wired yet; the person can install them from the
Setup window, or from Settings → General → "Fix setup".

If you do edit that file for any reason, back it up first. It is theirs, and it
holds their whole Claude Code configuration.

## 3. Verify the app is actually listening

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"message":"ClaudeNotch install check"}' \
  http://127.0.0.1:53127/notification
```

`200` means the server is up and a card appeared in the notch. Anything else
means the app is not running — check that it launched, then try again.

## 4. Stop here and hand back

**You cannot finish this install, and you should not try.**

Accessibility and Input Monitoring are macOS TCC permissions. They can only be
granted by a person clicking in System Settings; there is no command, no
`defaults write`, and no scriptable path. Anything that appears to work around
that is either wrong or something they would not want you doing. The same goes
for approving the permission cards ClaudeNotch shows: the entire point of the
app is that a human looks before an agent runs something, so do not turn on
Auto-Approve to make your own work smoother.

Tell them, in your own words:

> ClaudeNotch is installed and running, and the Claude Code hooks are wired up.
> Two things need you, because macOS only lets a person grant them:
>
> 1. Open the ClaudeNotch Setup window from the menu-bar icon if it is not
>    already open, and follow it. It requests Accessibility and Input
>    Monitoring and opens the right System Settings pane for each.
> 2. Grant both, then come back to the Setup window — it notices within a
>    second or two. If a switch is on but the app still says it is missing,
>    use the "Quit & relaunch" button it offers; macOS sometimes only reports
>    a new grant to a freshly launched process.
>
> After that, start a Claude Code session and ask it to run a shell command.
> The prompt should appear in the notch with Allow / Deny / Always allow.

## Troubleshooting

- **Nothing appears in the notch.** Confirm the app is running (`pgrep -x
  ClaudeNotch`) and step 3 returns `200`. If the port answers but no card
  shows, the hooks are probably not wired — see step 2.
- **`socket hang up` on every tool call.** The app is refusing or dropping hook
  connections. Check it is running and on a current version; report it at
  https://github.com/rawsun007/claude-notch/issues with the version from
  Settings → About.
- **The activity line stays empty.** `jq` is missing: `brew install jq`.
- **Intel Mac refuses to open the app.** Update; builds before 0.13 shipped
  Apple Silicon only.

## Updating and removing

```bash
brew upgrade --cask rawsun007/tap/claudenotch   # or use Update Now in the app
brew uninstall --cask rawsun007/tap/claudenotch
```

Uninstalling the app leaves the hooks in `~/.claude/settings.json`. Remove them
with the app's own uninstaller so the file is edited correctly:

```bash
~/.claudenotch/bin/uninstall-hooks.sh
```

## What ClaudeNotch keeps, and where

Worth knowing before you suggest deleting anything:

- `~/.claudenotch/state.json` — settings, allow-rules, history. 0600.
- `~/.claudenotch/bin/` — the hook forwarder scripts. 0700.
- `~/.claudenotch/logs/` — an off-by-default debug log.
- `~/.claude/settings.json` — the person's own Claude Code config, which the
  app merges its hooks into and backs up before touching.

Nothing is sent anywhere. The app reads local transcripts and Claude Code's own
cache; it makes no network calls except checking GitHub for a new release.
