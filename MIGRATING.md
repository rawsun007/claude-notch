# Coming from Vibe Notch

Vibe Notch (Claude Island) solved a real problem and a lot of people, including
me, used it. It has not shipped a commit since April 2026, and a number of the
things people asked for there are things ClaudeNotch does. This page is an
honest map of which ones, and which ones it still does not.

## Migrating

```bash
git clone https://github.com/rawsun007/claude-notch
cd claude-notch
tools/migrate-from-vibe-notch.sh --dry-run   # see exactly what would change
tools/migrate-from-vibe-notch.sh             # do it
```

You have to remove the old hooks rather than just add new ones. Both apps hook
the same Claude Code events, so with both wired up every permission prompt gets
answered twice and whichever app replies first wins.

The script only removes hook entries whose command mentions
`claude-island-state.py`. Hooks belonging to other tools are left alone, even
when they sit in the same event. Your `settings.json` is backed up first and the
old hook script is moved aside rather than deleted, so you can put it all back
by hand.

Then quit Vibe Notch. If you would rather do it yourself, delete the
`claude-island-state.py` entries from `~/.claude/settings.json` and run
`./install.sh`.

## What is already fixed

| Open there | Here |
|---|---|
| [#98](https://github.com/farouqaldori/vibe-notch/issues/98) notch stuck on "Processing" after a background Bash | Fixed. A turn that has ended is an absorbing state, so any hook arriving late for that turn is dropped instead of flipping the display back. `TurnGate.swift` |
| [#58](https://github.com/farouqaldori/vibe-notch/issues/58) move the UI to the menu bar instead of the island | Macs without a notch, including external displays, get a floating pill in the menu bar band. v0.8.7 |
| [#19](https://github.com/farouqaldori/vibe-notch/issues/19) choose which screen the UI appears on | You do not have to choose. It renders on every display at once and hover-expand follows your cursor between them. v0.8.7 and v0.8.8 |
| [#42](https://github.com/farouqaldori/vibe-notch/issues/42) macOS 15.2 support | Runs on macOS 13 and later. |
| [#57](https://github.com/farouqaldori/vibe-notch/issues/57) tool output not shown | Edit and Write requests show a red and green diff inside the card, before you approve it. |
| [#50](https://github.com/farouqaldori/vibe-notch/issues/50) sound when Claude needs you | Alert sounds, and optionally a different sound per tool category so you can tell a Bash prompt from an edit without looking. |
| [#82](https://github.com/farouqaldori/vibe-notch/issues/82) show more detail about a running task | The notch shows the active tool and its target while Claude works, plus a progress bar through its task list. |
| [#47](https://github.com/farouqaldori/vibe-notch/issues/47) crashes without `gettext` | No such dependency. |
| [#31](https://github.com/farouqaldori/vibe-notch/issues/31) build fails on a hardcoded `DEVELOPMENT_TEAM` | There is no Xcode project. `./build.sh` builds it with SwiftPM and no team ID. |
| [#3](https://github.com/farouqaldori/vibe-notch/issues/3) a toggle to disable auto-updates | There is no auto-update to disable. It checks GitHub Releases only when you ask it to. |
| [#94](https://github.com/farouqaldori/vibe-notch/issues/94) language settings | Fixed. Nine languages, picked from **Settings → General → Language**, applied immediately with no restart. Some of the longer settings explanations still fall back to English. |

## What is not

Being straight about it, because finding out after you switch is worse.

| Open there | Here |
|---|---|
| [#65](https://github.com/farouqaldori/vibe-notch/issues/65) Factory Droid | Not supported. Claude Code, Codex and Grok are. |
| [#6](https://github.com/farouqaldori/vibe-notch/issues/6) opencode | Not supported. |
| [#100](https://github.com/farouqaldori/vibe-notch/issues/100), [#41](https://github.com/farouqaldori/vibe-notch/issues/41) set the width of the island | Cards size themselves to their content, and there is no manual width control. |
| [#7](https://github.com/farouqaldori/vibe-notch/issues/7) ship the hook as a plugin so nothing touches `~/.claude` | Hooks still go in `~/.claude/settings.json`. The install is backed up and reversible with `uninstall-hooks.sh`, but it is not a plugin. |
| [#8](https://github.com/farouqaldori/vibe-notch/issues/8) slash command output | Not surfaced. |

## Differences worth knowing before you switch

**No analytics.** Vibe Notch sends anonymous usage events to Mixpanel.
ClaudeNotch has no network calls except an explicit check for updates when you
click the button. Nothing about your sessions leaves the machine.

**Touch ID on destructive commands.** `rm -rf`, `sudo` and force pushes are
flagged and need Touch ID or a deliberate press and hold, so nothing
irreversible goes through on a reflex Enter.

**Cost and context.** Each session shows how full the context window is and a
running cost estimate, with optional per-session and per-day spending caps.

**It works with VoiceOver.** Cards are announced as they appear and every
control is reachable without a mouse. v0.9.0

**Not notarized.** Install with Homebrew (`brew install --cask
rawsun007/tap/claudenotch`) and it launches with no Gatekeeper prompt. The DMG
needs one trip through System Settings the first time.

## If you would rather not switch

The pieces are standalone and liberally commented, so lift what is useful.
`TurnGate.swift` is the fix for the late-hook race in #98. `PetRig.swift` and
`PetEngine.swift` are the pet, split into pure logic and rendering, if you are
maintaining one of the character forks.
