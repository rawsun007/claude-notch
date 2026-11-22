# ClaudeNotch for Windows

Claude Code's permission prompts and questions, answered from a card at the
top of your screen instead of the terminal. The same hooks, the same danger
warnings and the same secret redaction as the macOS and Linux apps, plus
rules for PowerShell and cmd.

Windows laptops have no notch, so the app draws the Mac's notch where one
would be: a small black notch hanging from the top centre of your main
display, the same shape, colours, type and motion as the macOS app. Point
at it and it opens into your session; when Claude needs you it grows into
the card. A tray icon holds Settings, Pause and Quit.

Windows 10 (1809 or later) and Windows 11, x64. Windows on Arm runs it
under emulation.

## Install

With winget (recommended):

```powershell
winget install Rawsun.ClaudeNotch
```

Or download `ClaudeNotch-<version>-windows-x64-setup.exe` from the
[releases page](https://github.com/rawsun007/claude-notch/releases)
(Windows releases are tagged `windows-v...`).

The installer is per-user: no administrator rights and no UAC prompt. It
installs to `%LOCALAPPDATA%\Programs\ClaudeNotch`, wires Claude Code to the
app and starts it. Claude Code sessions that were already open read the
hooks when they start, so restart those.

## Use

- **Permission card:** Deny, Always Allow (this exact command, or every
  call of that tool; the same call is then answered without a card), or
  Allow. With several cards waiting, Allow All answers them at once.
  Click the card once and Enter allows, Esc denies.
- **Dangerous calls** (`Remove-Item -Recurse -Force`, `rd /s`, `iwr | iex`,
  `-EncodedCommand`, registry Run keys, scheduled tasks, Defender or the
  firewall turned off, `rm -rf`, `git push --force`, writes into `.ssh`,
  `.claude` or your PowerShell profile, and more) show the reasons in a
  red banner and are allowed only by **Hold to Allow**: press and hold
  the button until it fills. Enter never allows one, and they can never
  be always-allowed.
- **Questions** (AskUserQuestion): pick one or more answers, or type your
  own under "Something else", then Send. Cancel sends Claude Code back to
  asking in its terminal.
- **Done and notifications:** a finished turn shows "Claude finished" and
  a notification shows Claude's message. Both wait until you press Done
  or Dismiss, or Open IDE, which brings back the window you were in when
  the card arrived.
- **Sessions:** point at the notch, or click the tray icon. The open notch
  shows the session's model, effort, git branch, how full its context
  window is and what it has cost so far, read from Claude Code's status
  line.
- Nobody answers within 285 seconds, or ClaudeNotch is not running: Claude
  Code asks in its terminal exactly as it would without the app.

The notch never takes the keyboard from your terminal: a card appearing
while you type does not eat keystrokes. It hides over fullscreen games,
videos and presentations; a card that needs an answer still shows.

## Your status line

To read those numbers, ClaudeNotch sets Claude Code's `statusLine` to a
small PowerShell script in `%APPDATA%\ClaudeNotch`. If you already had a
status line, it is kept and still drawn below your prompt, through Git
Bash; if you had none, you get a short default (model, folder, context).
`ClaudeNotch --uninstall-hooks` (and uninstalling the app) puts your own
status line back.

## Settings

Tray icon > Settings, or right-click the pill.

- **General:** start at login, the hello at start, sessions on hover,
  session updates, show the idle pill, hide it over fullscreen apps, and
  where the pill sits.
- **Notifications:** Windows notifications for every card, or dangerous
  calls only. Off by default, since the card is already on screen.
- **Claude Code:** install, reinstall or remove the hooks. Your own hooks
  in `%USERPROFILE%\.claude\settings.json` are kept, and a backup is
  written next to it before any change.
- **Always allow:** the rules you added, with Remove.
- **About:** version, where the log and settings are.

**Pause** in the tray menu sends every prompt straight back to the terminal
until you un-pause.

## Updating

`winget upgrade Rawsun.ClaudeNotch`, or run a newer setup. The installer
closes the running app and starts the new version; nothing else to do.

## If you don't see it

- **Tray icon missing:** Windows 11 tucks new tray icons under the ^ arrow.
  Drag ClaudeNotch onto the taskbar to keep it in view.
- **No card for a running session:** that session started before the hooks
  were installed. Restart it.
- **"Not listening":** another program uses port 53127. Close it and start
  ClaudeNotch again. Claude Code keeps asking in its terminal meanwhile.
- Check from a terminal:

  ```powershell
  & "$env:LOCALAPPDATA\Programs\ClaudeNotch\ClaudeNotch.exe" --status
  ```

- The log is `%LOCALAPPDATA%\ClaudeNotch\claudenotch.log`.

## Uninstall

Settings > Apps > Installed apps > ClaudeNotch > Uninstall, or
`winget uninstall Rawsun.ClaudeNotch`. Uninstalling stops the app, takes
its hooks out of Claude Code's settings and removes start at login. It asks
whether to also delete your settings and Always allow rules in
`%APPDATA%\ClaudeNotch`.

## Privacy

Everything stays on your machine. The app listens on `127.0.0.1` only (no
firewall prompt, nothing reachable from the network), refuses requests from
web pages, and checks a per-install token. No telemetry.

## Develop

The Windows edition is Python 3.10+ and PySide6 (Qt). Everything that is
not drawing (hook protocol, danger rules, redaction, the settings merge,
the server, state) is the shared core in `linux/claudenotch`, tested on
Linux and Windows CI. `windows/claudenotch_win` adds only the Windows parts.

```powershell
powershell -ExecutionPolicy Bypass -File windows\dev\setup.ps1   # Python, venv, deps, tests
powershell -ExecutionPolicy Bypass -File windows\dev\run.ps1     # run from the checkout
powershell -ExecutionPolicy Bypass -File windows\packaging\build.ps1   # exe + installer in windows\dist
```

| File | What it does |
|---|---|
| `app.py` | CLI flags, headless server |
| `qtapp.py` | startup, single instance, take-over, quit |
| `overlay.py` / `view.py` / `theme.py` | the pill and cards; `view.py` is the pure, tested part |
| `tray.py`, `notify.py` | tray icon and menu, Windows toasts |
| `settings_window.py` | Settings |
| `autostart.py` | HKCU Run key, respecting Task Manager's switch |
| `instance.py` | named mutex `Local\ClaudeNotch` |
| `winutil.py` | ctypes: no-activate window, topmost, fullscreen, theme |
| `packaging/` | PyInstaller spec, Inno Setup script, build.ps1 |

CI: `.github/workflows/windows.yml`. A `windows-v*` tag builds the
installer and publishes a Windows-only release.
