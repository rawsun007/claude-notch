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

- **Opening it:** like the Mac app, ClaudeNotch is always a keystroke
  away. **Ctrl+Alt+,** opens Settings from any app (the Mac's
  Option-Command-Comma), **Ctrl+Alt+N** opens the compose card (the Mac's
  Option-Command-N) and **Ctrl+Alt+H** its history; change any of them
  in Settings > General. The tray icon's menu has Open the Notch,
  Settings, Pause and Quit. In Start, search for ClaudeNotch or
  ClaudeNotch Settings; right-click either (or ClaudeNotch pinned to the
  taskbar) for Open the Notch, Settings, Usage and History. Starting
  ClaudeNotch again while it runs opens its Settings, as reopening a Mac
  app does.
- **From the tray:** Start Claude in Folder…, Resume Last Session (it
  names the project) and Copy Today's Standup, as in the Mac's menu bar,
  and Update available when a newer ClaudeNotch is out. Drop a folder (or
  a file) on the notch to start Claude there.
- **Send to Claude:** Ctrl+Alt+N (or Send to Claude in the tray) opens a
  box to type Claude a message. Ctrl+Enter types it into the terminal you
  were in; pick a project instead to start Claude there with it. Reply on
  a done card answers that session. The bubble beside Deny denies with a
  reason, which Claude sees. ClaudeNotch only ever types into a terminal
  window (never an editor), and only when it is in front.
- **Claude's last reply:** the expand button on the open notch (or a
  session in its list) shows the reply in full, with headings, lists and
  code, and Copy.
- **Question cards:** the shrink button at the top right puts a question
  away without answering it; Claude keeps waiting, and the notch grows a
  small purple tab on its left. Click the tab to bring it back.
- **History:** the clock on the open notch, Ctrl+Alt+H, the tray or the
  jump list opens the history drawer: past sessions (Resume reopens one),
  spend per project with the last seven days, and every card you answered,
  with a search and Allowed / Denied / Risky / Q&A filters. Esc closes it.
- **While Claude works:** the open notch shows the running command with a
  clock (orange past a minute) and the task list's progress. A card Claude
  Code stopped waiting for says "Too late to answer here" instead of
  vanishing. After you allow the same command three times, the card says
  "allowed 3 times" beside Always Allow.
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

Tray icon > Settings, right-click the notch, or a `claudenotch://settings`
link (`claudenotch://settings/usage` opens a page). Laid out like the Mac
app's: a sidebar with search, and these pages:

- **General:** launch at login, the hello at start, **Auto-Approve** (what
  it answers for you, and what it does with destructive commands: show the
  card, confirm with Windows Hello, or approve them too, which asks for
  Windows Hello or your Windows password first), and setup health for the
  hooks and the status line.
- **Notch:** keep it open, open on hover, show it when idle, hide it over
  fullscreen apps, and where it sits.
- **Session:** Auto-approve for 15 minutes to an hour, and snooze
  finished-turn and notification cards.
- **Alerts:** finished-turn and notification cards, plan-limit warnings at
  80 % and 95 %, and Windows notifications.
- **Budget:** session and daily spending caps, and a hard stop that holds
  requests on the card once a cap is reached.
- **Plan:** your 5-hour and weekly limits, with time to reset.
- **Usage:** estimated cost for 7 days and 4 weeks, an activity heatmap,
  all-time counters, top tools and projects, tokens and cost today, in the
  last 5 hours and this week, cache savings, and the model mix. Costs are
  estimates at public API prices, not your subscription bill.
- **History:** every session with its summary, turns, model, branch and
  cost; search, export (CSV or JSON) and clear.
- **Privacy:** hide the notch from screen capture (on by default), require
  Windows Hello for destructive commands, and skip that confirmation
  (asks for Windows Hello or your password).
- **Pet:** Pet Mode, the mascot living in the closed notch (it naps,
  strolls, drops down on a rope, keeps Claude company, celebrates and
  flinches; click the notch to boop it). It also shows up on cards: wary
  on a destructive command, dancing when a task finishes, fretting near a
  plan limit. A Play button for each thing it does.
- **Sounds:** mute, the alert sound or a sound per kind of tool, and a
  sound per event, under the Mac's names (Funk, Glass, Pop, Tink,
  Submarine...). The app ships its own sounds by those names; to hear the
  real macOS ones, put your copies (.aiff or .wav, named as on the Mac) in
  `%APPDATA%\ClaudeNotch\Sounds` and they are used instead.
- **Skills:** your Claude Code skills (personal, claude.ai, projects,
  plugins) with what each costs in every turn; set each to On, Name only,
  Only when I type it, or Off, or move it to the trash and restore it.
- **Rules**, **About**, and **Developer** (show any card on demand).

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
