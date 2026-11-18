# Tickets

W = Windows, L = Linux, S = shared core, R = release. Do them in order;
the ones marked **Saturday** de-risk the rest. One commit per ticket at
least, pushed as soon as it passes. "Done when" is the bar, not a wish.

## Saturday (de-risk)

**W0. Core runs on Windows.** Run `pytest linux/tests` on the Windows machine
with `linux/` on `PYTHONPATH`. Fix what fails in the core (paths, file
writes), not by skipping tests.
Done when: all core tests pass on Windows; Linux CI still green.

**W1. A real hook reaches us.** Throwaway script: start
`claudenotch.server.HookServer` with a state that auto-allows, run
`hooks.install()`, start `claude` in PowerShell, ask it to run `dir`.
Done when: the request shows up in our log and an `allow` is obeyed, then
the same with `deny`. Also from Git Bash.

**W2. Pill spike.** Throwaway `spike_pill.py`: frameless, topmost,
`WS_EX_NOACTIVATE` window with one button, top centre.
Done when: typing continuously in Windows Terminal while the pill shows and
hides every 2 s loses no characters; clicking the button works; it sits
right at 100 % and 150 % scaling.

**S0. Order the signing certificate** (if D4 says yes). Not code, but it has
the longest lead time.

## Sunday morning: shared core

**S1. Windows paths.** `state.config_dir()`, `hooks.token_path()` per
WINDOWS.md section 2. Tests for both platforms (monkeypatch `sys.platform`
and env).

**S2. `os.replace` retry** in `hooks.py`, `settings.py`, `state.py` writes.
Test with a mocked `PermissionError` twice then success.

**S3. Windows danger rules.** From WINDOWS-DANGER-RULES.md. `PowerShell`
tool routed. Fires / does-not-fire test per rule.
Done when: `pytest linux/tests/test_danger.py` green on both OSes.

## Sunday: Windows app

**W3. Package skeleton.** `windows/claudenotch_win/` with `__main__.py`,
`app.py` (argparse: `--install-hooks`, `--uninstall-hooks`, `--status`,
`--settings`, `--background`, `--quit-running`, `--first-run`), `paths.py`.
`python -m claudenotch_win --status` prints hooks installed / app running.

**W4. Single instance + control.** Named mutex, `/ping` version check,
`/control/quit` and `/control/settings`, take-over of an older copy.
Done when: launching twice opens Settings in the first copy; launching a
newer build replaces an older running one.

**W5. Overlay: pill + session list.** `overlay.py` from the W2 spike. Pill
summary like Linux `_pill()`/`_summary()`, hover grows to the session list,
collapse on leave. GUI-thread marshalling via a Qt signal.

**W6. Permission card.** Allow / Deny / Always allow, danger reasons with the
two-step confirm and no Always allow, "+N more" for a queue, Enter / Esc when
the card has been clicked (WINDOWS.md section 3). Mirrors Linux
`_permission_card` and `_decide`.
Done when: W1's real `claude` session is answered from the card.

**W7. Question card.** AskUserQuestion: single, multi-select, "Answer in
terminal". Mirrors Linux `_question_card`.

**W8. Toasts for session events** (in the overlay, like Linux `_toast`).

**W9. Tray.** Icon, left click, menu: Settings..., Pause, Show the pill, Quit.
Light/dark icon.

**W10. Settings window.** Pages General / Notifications / Claude Code /
Always allow / About, bound to the shared `settings.Store`.

**W11. Notifications** via `QSystemTrayIcon.showMessage`, off by default,
"every card" / "dangerous only".

**W12. Start at login** (HKCU Run key, respect StartupApproved).

**W13. Fullscreen hide** (SHQueryUserNotificationState).

**W14. First run.** Install hooks, one greeting card that says where the app
lives (top centre and the tray) and how to keep the tray icon visible.

## Sunday afternoon: packaging and CI

**W15. PyInstaller spec** (`--onedir`, `--windowed`, icon, excluded Qt
modules, version info resource so Explorer shows publisher and version).
Done when: `dist\ClaudeNotch\ClaudeNotch.exe` runs on a machine without
Python.

**W16. Inno Setup installer** per WINDOWS.md section 9, including
`[UninstallRun]` hook removal and the AUMID shortcut.
Done when: the whole checklist in WINDOWS.md section 11 passes on the Windows
machine.

**W17. CI.** `.github/workflows/windows.yml`: tests on `windows-latest`, build,
upload installer to `windows-v*` releases. `ci.yml` ignores `windows/**`.

**W18. Windows README** (`windows/README.md`): install (winget first,
download second), use, settings, update, uninstall. Same structure as
`linux/README.md`. No SmartScreen bypass instructions.

**W19. CLAUDE.md**: add a "Windows edition" section to the repo map, like the
Linux one.

## Sunday, in between Windows builds: Linux

**L1..Ln. Fixes from Saturday's test pass**, one issue per commit.

**L-final. Confirm the shared-core changes on Ubuntu**: install a locally
built 0.45.0 `.deb` over 0.44.0 on the real machine, rerun the card checks.

## Sunday night: release candidate

**R1.** Bump `linux/claudenotch/__init__.py` to 0.45.0 (shared version, D5).

**R2.** Tag `windows-v0.45.0-rc1`, let CI build, install the CI artifact (not
a local build) on the Windows machine, run the section 11 checklist again.

**R3.** winget manifest with `wingetcreate new` pointing at the RC's final
URL pattern, ready to submit the moment the real tag is published (see
LAUNCH.md).

**R4.** Leave the borrowed machines clean (SETUP.md).
