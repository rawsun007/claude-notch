# Decisions for Saturday morning

Each one has a recommendation. Lock them before anyone writes code; most of
Sunday's tickets depend on D1 and D2.

## D1. What the Windows app is built with

| Option | Weekend? | Notes |
|---|---|---|
| **Python + PySide6 (Qt), reusing the Linux core** | Yes | ~2,000 lines of tested core already exist. Only the UI and the OS glue are new. |
| C# / WinUI 3 or WPF, native rewrite | No | Best feel on Windows, but the protocol, danger rules, redaction, installer merge and state all get rewritten and re-tested. Two weeks, not two days. |
| Tauri (Rust + web UI) | No | Same rewrite cost, plus a new language for the core. |
| GTK on Windows (run the Linux app as is) | No | GTK on Windows needs MSYS2, ships badly, looks foreign. |

**Recommendation: Python + PySide6.** Qt does frameless, always-on-top,
transparent windows, a real tray icon and Windows toasts out of the box, and
PyInstaller turns it into a normal `.exe`. A native rewrite can come later,
once Windows users exist and we know what they want.

## D2. Where the shared code lives

**Recommendation: the Windows app imports the existing `linux/claudenotch`
package for the pure modules** (`protocol`, `danger`, `redact`, `hooks`,
`server`, `state`, `settings`), and adds a new `windows/` folder for only the
Windows parts. The pure modules get small `sys.platform == "win32"` branches
for paths. One copy of the core, and Linux CI keeps testing it.

Not this weekend: renaming `linux/` to something shared (`core/`) and moving
the GTK parts out. Worth doing after launch, but it touches the .deb and
tarball build scripts and the Docker tests, which is risk we do not need on
launch weekend.

## D3. Where the pill sits on Windows

Windows laptops have no notch, and the top centre of the screen is where a
maximized window's title bar and Windows 11's Snap Layouts flyout live.

| Option | |
|---|---|
| **Top centre, like Linux** (recommended default) | Same product, same screenshots, same muscle memory. A slim pill (about 180x26 px) covers little of a title bar. |
| Bottom right, above the tray | The "Windows" place for notifications, but then it is a toast app, not ClaudeNotch. |

**Recommendation: top centre by default, with a Settings choice for
top-centre / bottom-right.** The setting is cheap since the card layout is
the same; only `_place()` changes. Also hide the pill while a fullscreen app
or game is in front (see WINDOWS.md, "Fullscreen").

## D4. Code signing

An unsigned `.exe` downloaded in a browser gets the SmartScreen "Windows
protected your PC" screen. What we know:

- **Azure Artifact Signing** (formerly Trusted Signing), ~$9.99/month, is
  the cheapest, but individual developers must be in the **USA or Canada**.
  Not available to us as individuals in India.
- **SignPath Foundation** (free for open source) needs an OSI-approved
  license. ClaudeNotch is **PolyForm Noncommercial**, which is not OSI, so
  this is out unless the license changes.
- **Certum** (Poland) sells to individuals anywhere. Standard Code Signing
  in the cloud (SimplySign, no USB token) is roughly EUR 100 to 110 a year;
  their "Open Source" variant is cheaper (from EUR 69) but is meant for open
  source projects, so check whether they accept a noncommercial license
  before buying. Identity verification takes a few working days. Since
  February 27, 2026 certificates last at most 459 days.
- Even a valid certificate starts with no SmartScreen reputation: the first
  downloads can still warn until the file and certificate build history.
  Microsoft no longer promises instant reputation for any certificate type.

**Recommendation:**
1. Launch Monday **unsigned, through winget and the GitHub release**. winget
   is the path we point people at; it is the normal way to install
   developer tools on Windows, and the people we are building for are
   developers already living in a terminal.
2. On Saturday, **order a Certum cloud certificate** so it can be verified
   during the week, and sign from the first update after launch.
3. Never tell users how to click past SmartScreen. The website and README
   say "install with winget" and offer the download as an alternative.

## D5. Version numbers and tags

**Recommendation: one version line across Linux and Windows, since they
share the core.** The Windows launch is **0.45.0**, tagged
`windows-v0.45.0`, not marked as the GitHub "latest" release (that stays the
Mac DMG, which the Mac app's updater and the Homebrew cask read). Linux
fixes from the weekend ship as `linux-v0.45.0` the same day.

## D6. Install scope

**Recommendation: per-user install, no admin.** Inno Setup with
`PrivilegesRequired=lowest`, installed to `%LOCALAPPDATA%\Programs\ClaudeNotch`.

- No UAC prompt, works on locked-down work laptops.
- The uninstaller runs as the same user, so it can remove that user's hooks
  from `~/.claude/settings.json`. The Linux `apt purge` bug (app gone, hooks
  still pointing at it) came from the remover not running as the user; a
  per-user install avoids that by construction.
- winget handles per-user installers fine (`Scope: user`).

## D7. What v1 includes (Monday)

Parity with the **Linux** edition, which is the smaller, already-proven
feature set:

- Permission cards (Allow / Deny / Always allow), question cards
  (AskUserQuestion), plan approval (ExitPlanMode via PermissionRequest).
- Danger detection with the Windows rules, two-step confirm, no Always allow.
- Session list on hover, toasts for session events.
- Tray icon with Settings, Pause, Quit.
- Settings window: General, Notifications, Claude Code (hooks), Always
  allow, About.
- Start at login, single instance, upgrade in place, uninstall that cleans
  up hooks.

**After launch (v0.46+), in rough order:** Windows Hello for dangerous calls
(the Touch ID equivalent), actionable toasts (Allow / Deny on the toast
itself), auto-approve (the Mac 0.44 feature), status line (cost and context
meter), Codex CLI support, a native rewrite if it earns one.

## D8. Who does what

Fill in on Saturday.

| Machine | Person | Signed in to Claude as | Owns |
|---|---|---|---|
| Windows | | | Windows app (W-tickets) |
| Ubuntu | | | Linux test pass and L-tickets |
| Mac | | | Website, release notes, reviewing PRs |

## D9. The overlay matches the Mac, still in Qt

The first Windows overlay copied the Linux GTK look, a plain black box.
The bar now is the Mac notch itself, the same down to the numbers.

**Decision: keep PySide6 and the shared core; redraw the overlay with
QPainter.** No spike against WinUI 3 or Tauri was needed, because Qt
already meets every requirement on this PC:

- **The shape:** `QPainterPath` draws NotchShape's quad curves exactly
  (concave ears, round bottom corners), antialiased.
- **The motion:** CardSizeAnimator is a hand-driven curve on the Mac too
  (ease-out-back and cubic, sampled per frame), not a SwiftUI spring, so a
  precise 8 ms QTimer sampling the same functions reproduces it exactly.
  The window only resizes at the start and end of a motion; per frame
  only the clip and the paint change.
- **Per-pixel alpha and click-through:** a translucent top-level Qt window
  on Windows is a layered window, so pixels outside the black shape pass
  clicks to whatever is below (checked with `WindowFromPoint`).
- **Focus:** `WS_EX_NOACTIVATE` keeps the terminal's keyboard, as before.
- **Scaling:** everything is painted in logical pixels, so 125 % and
  150 % render sharp (checked with `QT_SCALE_FACTOR`).

Type: Segoe UI Variable (Display from 14 px, Text below) for SF Pro,
Cascadia Mono for SF Mono, at the Mac's point sizes as DIPs; greyscale
antialiasing, as macOS draws. Icons that carry meaning (warning
triangle, speech bubbles, dollar coin) are drawn in SF Symbols' shapes;
the rest use Segoe Fluent Icons. No Apple fonts or symbols are shipped.

Not matched on purpose: the Mac's notch hides behind a hardware cutout
or the menu bar; Windows has neither, so the closed notch is the Mac's
"no notch" 200 x 28 shape, always visible at the top centre.
