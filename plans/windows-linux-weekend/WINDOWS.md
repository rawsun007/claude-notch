# ClaudeNotch for Windows: how it is built

Assumes the recommendations in [DECISIONS.md](DECISIONS.md): Python +
PySide6, reusing the Linux core, per-user Inno Setup installer, winget.

## 1. How Claude Code talks to us on Windows

Nothing new on the wire. Claude Code reads `%USERPROFILE%\.claude\settings.json`
(or `CLAUDE_CONFIG_DIR`), and for each event we register an **HTTP hook**:

```json
{ "type": "http", "url": "http://127.0.0.1:53127/hook?t=<token>", "timeout": 290 }
```

`linux/claudenotch/hooks.py` already writes exactly this. Why it matters:

- HTTP hooks have no shell step. Claude Code's docs give the `shell` option
  to command hooks only; command hooks on Windows run through Git Bash, or
  PowerShell when Git Bash is missing, and the issue tracker is full of
  Windows hook breakage around that (hooks run under bash while the model is
  told PowerShell, `pwsh` missing, `.cmd` shims not spawnable). We sidestep
  all of it.
- Response rules (from the hooks docs): 2xx with a JSON body is parsed like a
  command hook's stdout; 2xx with an empty body is "no opinion"; non-2xx,
  connection refused and timeout are non-blocking errors. So if the app is
  not running, Claude Code just asks in its terminal. Same as Linux and Mac.
- The default `http` timeout is 600 s; we set 290 s, just over our 285 s
  decision window, as on the other platforms.

**Check on Saturday (task W1):** a real `claude` session on the Windows
machine, with our hooks installed, reaches the server and a PreToolUse
answer of `allow` / `deny` is obeyed. Test once in PowerShell and once in
Windows Terminal with Git Bash, since the hook should not care which.

**Firewall:** we bind `127.0.0.1` only. Loopback listeners do not trigger the
Windows Defender Firewall prompt; binding `0.0.0.0` would. Keep it loopback.

## 2. Code layout

```
linux/claudenotch/        shared core (already exists), imported by Windows
  protocol.py danger.py redact.py hooks.py server.py state.py settings.py
windows/
  claudenotch_win/
    __init__.py
    __main__.py           entry: python -m claudenotch_win
    app.py                CLI flags, single instance, startup (mirrors linux app.py)
    paths.py              %APPDATA% / %LOCALAPPDATA% locations
    overlay.py            the pill and cards (QWidget), replaces linux ui.py
    tray.py               QSystemTrayIcon + menu
    settings_window.py    Qt settings window, same pages as Linux
    notify.py             toasts via the tray icon (v1), windows-toasts later
    autostart.py          HKCU Run key
    fullscreen.py         is a fullscreen app in front? (SHQueryUserNotificationState)
    winutil.py            ctypes helpers: WS_EX_NOACTIVATE, DPI, work area
  tests/                  pytest, run on windows-latest in CI
  packaging/
    claudenotch.spec      PyInstaller spec
    installer.iss         Inno Setup script
    build.ps1             spec + iss in one go, writes dist\
    winget/               manifest templates
  README.md
```

### Changes to the shared core (small, all behind `sys.platform`)

| File | Change |
|---|---|
| `state.py` `config_dir()` | Windows: `%APPDATA%\ClaudeNotch`. |
| `settings.py` | Uses `config_dir()`, so follows. |
| `hooks.py` `token_path()` | Windows: `%APPDATA%\ClaudeNotch\hook-token`. Keep `~/.claudenotch` on Linux. `os.chmod(0o600)` is a no-op on Windows; files under the user profile are already ACL'd to that user, which is the protection we want. Note it in a comment, do not add icacls. |
| `hooks.py` writes | `os.replace` fails on Windows if another process holds the target open (an editor with settings.json open is fine; antivirus scanning it briefly is not). Retry `os.replace` a few times over ~500 ms on `PermissionError`. |
| `danger.py` | Add the Windows rules from [WINDOWS-DANGER-RULES.md](WINDOWS-DANGER-RULES.md), and route the `PowerShell` tool to them. Path rules learn `C:\...` and `%VAR%` forms. Linux rules unchanged. |
| `server.py` | `server_version` from the platform. Nothing else. |
| `__init__.py` | Version stays the single source for both. |

Everything the Linux `app.py` does with `/proc` and signals (finding and
killing old copies) is Linux-only and stays there. Windows does it with a
named mutex and the `/control/quit` endpoint (section 6).

## 3. The overlay (overlay.py)

One `QWidget`, frameless, translucent, always on top, never in the taskbar,
never stealing focus from the terminal.

```python
flags = (Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
         | Qt.WindowDoesNotAcceptFocus)
w.setWindowFlags(flags)
w.setAttribute(Qt.WA_TranslucentBackground)
w.setAttribute(Qt.WA_ShowWithoutActivating)
```

Then, after `show()`, set the native extended style, because Qt's flags alone
are known to still activate the window on Windows in some cases (first show
is fine, re-show or resize takes focus):

```python
GWL_EXSTYLE, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST = -20, 0x08000000, 0x80, 0x8
hwnd = int(w.winId())
style = user32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
user32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW)
```

The catch with `WS_EX_NOACTIVATE`: the window still gets mouse clicks
(buttons work) but not keyboard focus. The Linux card supports Enter = Allow,
Esc = Deny. On Windows v1, do it like this:

- Clicks work without focus (the common case).
- Keyboard shortcuts work when the user clicks the card first: on mouse press,
  drop `WS_EX_NOACTIVATE`, `activateWindow()`; when the card closes, put the
  style back and do not restore focus ourselves (Windows returns it to the
  terminal).
- Optional v1.1: a global hotkey (`RegisterHotKey`) for Allow/Deny of the
  front card, off by default.

**Placement:** primary screen's `availableGeometry()` (excludes the taskbar),
centred horizontally, `y = top`. Recompute on `screenAdded`, `screenRemoved`,
`primaryScreenChanged`, `geometryChanged` (docking, resolution change).

**DPI:** Qt 6 is per-monitor DPI aware by default. Size everything in device
independent pixels and let Qt scale. Test at 100 %, 125 %, 150 % (most
Windows laptops ship at 125 % or 150 %).

**Look:** black pill, same sizes as Linux (`linux/claudenotch/layout.py`),
Segoe UI Variable for text (Windows 11) with Segoe UI fallback, Cascadia Mono
for commands. Rounded corners painted ourselves (`QPainterPath`) since the
window is frameless.

**Hover:** `enterEvent` / `leaveEvent` grow the pill into the session list,
like Linux `_on_enter` / `_on_leave`. Collapse after a short delay to avoid
flicker.

**Threading:** the HTTP server answers each hook on its own thread (shared
`server.py`). State listeners fire on that thread. In Qt, marshal to the GUI
thread with a `QObject` signal (`Signal()` emitted from the listener,
connected with the default queued connection), the Qt equivalent of the
Linux `GLib.idle_add`.

### Fullscreen

A topmost pill over a fullscreen game or a presentation is a bug report. Poll
`SHQueryUserNotificationState` every 2 s (cheap): when it returns
`QUNS_BUSY`, `QUNS_RUNNING_D3D_FULL_SCREEN` or `QUNS_PRESENTATION_MODE`,
hide the idle pill. A card that needs an answer still shows (the user would
rather see it than have Claude Code wait 285 s), and it also goes to a toast.

## 4. Tray (tray.py)

Windows has no menu bar; the tray is where people look for a background app.
`QSystemTrayIcon` with:

- Left click: show the session list (same as hovering the pill).
- Menu: Settings..., Pause ClaudeNotch (hooks answer "no opinion" while
  paused), Show the pill (toggle), Quit.
- Icon: the ClaudeNotch mark, 16/20/24/32 px in one `.ico`, light and dark
  variants following the taskbar theme
  (`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme`).
- Windows 11 hides new tray icons in the overflow by default. The first-run
  greeting says so in one line ("Drag the ClaudeNotch icon onto the taskbar to
  keep it in view"). Nothing more; we cannot pin it ourselves.

## 5. Notifications (notify.py)

v1: `QSystemTrayIcon.showMessage()`. It produces a real Windows toast with
our icon and no extra dependency. Off by default, as on Linux; Settings >
Notifications turns on "every card" or "dangerous calls only". Clicking the
toast brings up the card.

v1.1: actionable toasts (Allow / Deny buttons on the toast) with the
`windows-toasts` package. Needs an AppUserModelID registered by the
installer (Start Menu shortcut with `AppUserModelID` set; Inno Setup supports
`AppUserModelID:` on `[Icons]`). Set that AUMID in v1 already so v1.1 does
not need a reinstall.

## 6. Single instance, upgrade, quit

- **Single instance:** named mutex `Local\ClaudeNotch` (`CreateMutexW`). If it
  already exists, ping `http://127.0.0.1:53127/ping`: same version means
  "show Settings in the running copy" (`/control/settings`) and exit; older
  version means `/control/quit`, wait up to 6 s, then take over. Same logic
  as Linux `_take_over`, minus `/proc`.
- **Upgrade:** Inno Setup `AppMutex=ClaudeNotch` makes the installer notice
  the running app; `CloseApplications=force` plus `RestartApplications=yes`
  uses the Restart Manager to close and relaunch it. Our quit path must answer
  open cards with "no opinion" before exiting, so Claude Code falls back to
  its terminal prompt rather than hanging.
- **Port in use:** if 53127 is taken by something that is not us (`/ping`
  fails or returns junk), show one toast saying so and keep the tray icon up
  with "Not listening" in the menu. Do not pick another port: the hooks in
  settings.json name 53127.

## 7. Start at login (autostart.py)

`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `ClaudeNotch`,
data `"<install dir>\ClaudeNotch.exe" --background`. Read and write with
`winreg`. Settings > General toggles it. Note that Windows lets users turn a
Run entry off in Task Manager > Startup apps; that sets a flag under
`...\Explorer\StartupApproved\Run`. Read it so our toggle shows the truth.

## 8. Settings window (settings_window.py)

Same pages and wording as Linux (`linux/claudenotch/settings_window.py`):
General, Notifications, Claude Code, Always allow, About. A plain
`QWidget` with a left list and a stacked right side. Windows 11 look:
Segoe UI Variable, 8 px radius, Mica not needed. Follows the system light/dark
setting (`QStyleHints.colorScheme()` in Qt 6.5+).

## 9. Packaging

**PyInstaller** (`--onedir`, not `--onefile`: onefile unpacks to %TEMP% on
every launch, starts slowly and trips antivirus heuristics far more often).
`--windowed` so no console flashes. Exclude unused Qt modules (WebEngine, QML,
Multimedia, 3D) to keep the install around 60 to 80 MB.

**Inno Setup** script (`installer.iss`), key lines:

```ini
[Setup]
AppId={{<fixed GUID, never change it>}
AppName=ClaudeNotch
AppVersion=0.45.0
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\ClaudeNotch
DisableProgramGroupPage=yes
AppMutex=ClaudeNotch
CloseApplications=force
RestartApplications=yes
OutputBaseFilename=ClaudeNotch-0.45.0-windows-x64-setup
UninstallDisplayIcon={app}\ClaudeNotch.exe

[Icons]
Name: "{userprograms}\ClaudeNotch"; Filename: "{app}\ClaudeNotch.exe"; AppUserModelID: "Rawsun.ClaudeNotch"

[Run]
Filename: "{app}\ClaudeNotch.exe"; Parameters: "--install-hooks --first-run"; Flags: nowait postinstall

[UninstallRun]
Filename: "{app}\ClaudeNotch.exe"; Parameters: "--uninstall-hooks --quit-running"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveHooks"
```

The `[UninstallRun]` line is the lesson from the Linux purge bug: removing
the app must also stop the running copy and take our hooks out of
settings.json, or Claude Code keeps calling a server that is gone (harmless,
since a refused connection is a non-blocking error, but untidy and it slows
every tool call by the connect attempt).

Silent install for winget: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.

**Architectures:** x64 build only. Windows on ARM (Snapdragon laptops) runs
x64 apps under emulation; fine for v1. Native arm64 is a later item
(PySide6 publishes arm64 wheels, PyInstaller supports it).

**CI:** `.github/workflows/windows.yml` on `windows-latest`, triggered by
`windows-v*` tags and PRs touching `windows/**` or `linux/claudenotch/**`.
Steps: setup-python 3.12, `pip install -r windows/requirements.txt`,
`pytest windows/tests linux/tests` (the core tests must pass on Windows too),
`build.ps1`, upload `dist\*.exe` to the release. Add `windows/**` to the
`paths-ignore` of `ci.yml`, as `linux/**` already is.

## 10. Signing (when the certificate arrives)

Certum SimplySign gives a cloud key used through their desktop client, which
exposes it as a normal certificate to `signtool`. Sign three things, in this
order: the PyInstaller `ClaudeNotch.exe`, then let Inno Setup sign its
uninstaller and the setup `.exe` (`SignTool=` directive). Timestamp every
signature (`/tr http://time.certum.pl /td sha256`), or signatures die with
the certificate. CI signing with a cloud HSM needs their CI option; until
then, sign locally on release day.

## 11. Windows test checklist (before calling it done)

- [ ] Fresh Windows 11, per-user install, no admin prompt.
- [ ] Windows 10 22H2 too (still a large share of developer machines).
- [ ] Hooks land in `%USERPROFILE%\.claude\settings.json`, user's own hooks
      kept, backup written.
- [ ] `claude` in PowerShell, Windows Terminal, and Git Bash: permission
      card appears, Allow and Deny are obeyed.
- [ ] AskUserQuestion card answers reach Claude Code.
- [ ] ExitPlanMode plan approval works.
- [ ] Dangerous PowerShell command shows reasons, needs two clicks, no
      Always allow.
- [ ] Card not answered in 285 s goes back to the terminal.
- [ ] Pill does not steal focus while typing in the terminal (type a long
      line while a card appears: no characters lost).
- [ ] 125 % and 150 % scaling, two monitors, primary switched, laptop
      docked and undocked.
- [ ] Fullscreen video / game: idle pill hidden.
- [ ] Start at login on and off; Task Manager's Startup apps toggle agrees.
- [ ] Install the next version over the running one: app restarts on the new
      version, no uninstall needed.
- [ ] Uninstall: app stops, hooks gone from settings.json, nothing left in
      `%LOCALAPPDATA%\Programs\ClaudeNotch`; `%APPDATA%\ClaudeNotch` kept
      (settings and always-allow rules) unless the user ticks "remove my
      settings".
- [ ] App not running: Claude Code works normally, prompts in the terminal.
- [ ] Defender does not flag the build (submit a false positive to
      Microsoft if it does, and say so in the README).
