# Weekend plan: ClaudeNotch on Windows, and Ubuntu hardened

Goal: ship **ClaudeNotch for Windows** on **Monday**, and use the same weekend
to test the Linux edition on a real Ubuntu machine and close its gaps.

The research is already done and written down here, so Saturday is for
setting up and proving the risky parts, and Sunday is only for writing code.

## Read in this order

| File | What it is |
|---|---|
| [DECISIONS.md](DECISIONS.md) | The calls to make on Saturday morning, each with a recommendation. |
| [WINDOWS.md](WINDOWS.md) | How the Windows app is built: stack, architecture, every Windows-specific piece, packaging, signing. |
| [WINDOWS-DANGER-RULES.md](WINDOWS-DANGER-RULES.md) | The danger rules for PowerShell, cmd and Windows paths, ready to turn into code and tests. |
| [LINUX.md](LINUX.md) | The Ubuntu test pass on real hardware, and the parity backlog. |
| [SETUP.md](SETUP.md) | Getting the borrowed Windows and Ubuntu machines ready, and leaving them clean. |
| [SUNDAY-TASKS.md](SUNDAY-TASKS.md) | The coding work as ordered tickets, each with files and a "done when". |
| [CLAUDE-PROMPTS.md](CLAUDE-PROMPTS.md) | Prompts to paste into Claude Code on each machine. |
| [LAUNCH.md](LAUNCH.md) | Monday: release, website, winget, announcement. |

## The shape of it in one paragraph

The Linux edition already speaks the same hook protocol as the Mac app, and
it does it with Claude Code's **HTTP hooks**: settings.json points each event
at `http://127.0.0.1:53127`, no shell script involved. That matters most on
Windows, where command hooks run through Git Bash or PowerShell and have a
long history of breaking; HTTP hooks skip all of that. The Linux edition's
core (protocol, danger rules, redaction, hook installer, server, state) is
plain Python with no GTK in it, so the Windows app reuses it as is and only
adds a Windows UI (Qt, via PySide6), Windows paths, Windows danger rules,
a tray icon, start-at-login, and an installer. That is a weekend of work;
a native rewrite (C#/WinUI, or Tauri) is not.

## Timeline

**Saturday: set up, decide, de-risk**

1. Morning: go through [DECISIONS.md](DECISIONS.md) together and lock each one.
2. Set up both machines ([SETUP.md](SETUP.md)).
3. Windows: run the existing core on Windows (task W0, W1) and prove the two
   risky bits with throwaway spikes: the always-on-top pill that does not
   steal focus (W2), and an HTTP hook from a real `claude` session reaching
   the app (W1). If either fails, we know on Saturday, not Sunday night.
4. Ubuntu: run the full test pass in [LINUX.md](LINUX.md) and file what breaks.
5. Order the code-signing certificate if we decide to sign (it takes days to
   verify identity; see DECISIONS.md D4).

**Sunday: code**

Work straight down [SUNDAY-TASKS.md](SUNDAY-TASKS.md). Windows first, Linux
fixes in between while builds run. Cut a release candidate by Sunday night
and submit the winget manifest (review takes one to a few days).

**Monday: launch**

[LAUNCH.md](LAUNCH.md).

## Ground rules (same as the Mac repo)

- No em dashes anywhere user-visible.
- Commits authored as `rawsun007`, one change per commit, pushed as we go,
  each ending with the Co-Authored-By line.
- Never write "click More info, then Run anyway" or any other SmartScreen
  bypass into user-visible text. Same rule as Gatekeeper on the Mac.
- A wire-format or danger-rule change lands on every platform, not just one.
