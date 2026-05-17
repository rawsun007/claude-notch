# ClaudeNotch

> Tested live: this very line was added by Claude Code through the ClaudeNotch
> permission flow — the notch expanded with the file path and "Allow" was
> clicked from the notch instead of switching back to the IDE.

A Dynamic-Island-style overlay for AI coding agents. Sits at the top of your
screen and turns invisible agent events into ambient UI you can't miss.

- **Permission requests** expand the notch with **Allow / Always allow / Deny**
  buttons that actually drive Claude Code's hook system — clicking *Allow*
  unblocks the tool call without you switching apps.
- **Notifications** ("Claude is waiting for input") show a sticky orange card
  with an **Open IDE** button that brings the previously-frontmost app back.
- **Task completions** show a green card that stays put until you click *Done*.
- **Tool use** shows a quiet blue thinking pulse.

It's a SwiftUI menu-bar app that exposes a localhost HTTP server on
`127.0.0.1:53127`. Three shell scripts wire it to Claude Code via the standard
`PreToolUse` / `Notification` / `Stop` hooks.

---

## Install (60 seconds)

Requires macOS 13+, Swift 5.9+ (Xcode CLT — `xcode-select --install`), and `jq`
(`brew install jq`).

```bash
cd "/Users/roshanramani/claude mac app"
./build.sh        # produces ClaudeNotch.app (ad-hoc signed)
./install.sh      # copies to /Applications, wires Claude Code hooks, launches
```

A bell icon appears in your menu bar. The app is permission-only and shows no
Dock icon (`LSUIElement`).

To launch at login: click the menu-bar bell → *Launch at login*.

---

## Test it

### Without Claude Code

Menu-bar bell → *Demo: tool permission (blocking)* — should expand the notch.
Clicking *Allow* / *Deny* logs the decision to Console.

Or from a shell:

```bash
# Sticky orange notification
curl -s -X POST http://127.0.0.1:53127/notification \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello from curl","cwd":"'"$PWD"'"}'

# Sticky green completion
curl -s -X POST http://127.0.0.1:53127/stop \
  -H 'Content-Type: application/json' \
  -d '{"title":"Tests passed","detail":"42 passing"}'

# Blocking permission — terminal hangs until you click in the notch
curl -s -X POST http://127.0.0.1:53127/permission \
  -H 'Content-Type: application/json' \
  -d '{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"cwd":"'"$PWD"'"}'
# → {"decision":"allow"}  (or deny/ask, based on your click)
```

### With Claude Code

After `./install.sh`:

1. Open a Claude Code session in any project.
2. Ask Claude to run a shell command, write a file, or edit something.
3. The notch should expand at the top of your screen with the command shown
   and three buttons. Whatever you click is what Claude Code does next —
   you never have to switch back to the IDE for the prompt.

Tools matched: `Bash`, `Write`, `Edit`, `MultiEdit`. Other tools (Read, Grep,
Glob, etc.) keep using Claude Code's normal permission flow so you're not
pestered for every read.

If ClaudeNotch isn't running, the hook silently falls back to `ask` —
Claude Code shows its own prompt as if the hook wasn't there.

---

## How the blocking permission works

```
Claude Code  ── PreToolUse hook fires ─▶  claudenotch-permission.sh
                                                  │
                                                  ▼
                                            POST /permission
                                                  │  (curl --max-time 290)
                                                  ▼
                                          ClaudeNotch (Swift)
                                                  │
                                            shows notch card
                                                  │
                                            user clicks Allow
                                                  │
                                                  ▼
                                          {"decision":"allow"}
                                                  │
                                                  ▼
                              hook prints JSON to Claude Code stdout:
                              { "hookSpecificOutput":
                                { "permissionDecision":"allow" } }
                                                  │
                                                  ▼
                                       Claude Code runs the tool
```

The connection is held open server-side using a `DispatchSemaphore`. Timeout
is 285 s (just under the 290 s curl timeout, which is just under Claude
Code's hook timeout). On any failure path — server not running, jq missing,
timeout — the hook returns `ask`, which falls through to Claude Code's own
prompt. No way to deadlock Claude.

---

## Endpoints

| Endpoint              | Method | Behavior |
| --------------------- | ------ | -------- |
| `POST /permission`    | block  | Holds the connection open. Body: `{tool_name, tool_input, cwd}`. Responds with `{"decision":"allow"\|"deny"\|"ask"}` when user clicks. |
| `POST /notification`  | async  | Sticky orange card with *Open IDE* / *Dismiss*. |
| `POST /stop`          | async  | Sticky green completion. |
| `POST /pretool`       | async  | Brief blue thinking pulse (auto-fades ~8 s). |
| `POST /ping`          | async  | Liveness probe. |

---

## Always-allow

Click *Always allow Bash* on a permission card → that tool auto-approves for
the rest of the session (no notch shown, hook returns `allow` immediately).

Clear via menu-bar bell → *Always-allowed: …* (click to reset). Not persisted
across restarts — by design, in case you ever say *always allow* to `rm -rf`.

---

## Multi-screen

The notch follows the screen your mouse is on, recomputed on each state
change. If you've moved to a different display since the last event, the next
one appears where you're actually looking.

---

## Layout

```
Sources/ClaudeNotch/
  main.swift                  — bootstrap as a .accessory app (no Dock)
  AppDelegate.swift           — wires window, menu bar, HTTP server
  AppState.swift              — @MainActor state + frontmost-app tracker
  NotchView.swift             — SwiftUI: idle / thinking / permission / completed
  NotchWindowController.swift — borderless NSPanel, follows current screen
  MenuBarController.swift     — NSStatusItem, login-item toggle, allowlist
  EventServer.swift           — NWListener HTTP/1.1, blocking permission handler

bin/
  claudenotch-permission.sh   — PreToolUse hook (blocking)
  claudenotch-notify.sh       — Notification hook (fire-and-forget)
  claudenotch-stop.sh         — Stop hook (fire-and-forget)
  install-hooks.sh            — jq-merges hooks into ~/.claude/settings.json
  uninstall-hooks.sh          — removes them, idempotent
build.sh                      — produces ClaudeNotch.app
install.sh                    — copies to /Applications + runs install-hooks.sh
```

---

## Uninstall

```bash
~/.claudenotch/bin/uninstall-hooks.sh   # remove from ~/.claude/settings.json
rm -rf /Applications/ClaudeNotch.app ~/.claudenotch
```

---

## Known limits

- *Always-allow* is session-scoped only (intentional).
- No global keyboard shortcuts for Allow/Deny — the notch is a non-activating
  panel and can't reliably capture keys without Accessibility permissions.
  Click-only for now.
- Hook scripts require `jq` and `nc` (both preinstalled on macOS, except `jq`
  which needs `brew install jq`).
