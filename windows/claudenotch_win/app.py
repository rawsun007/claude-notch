"""Entry point: `ClaudeNotch.exe` (or `python -m claudenotch_win`) and its flags.

    ClaudeNotch                    run the app (installs the hooks on first run)
    ClaudeNotch --install-hooks    wire Claude Code to the app, then exit
    ClaudeNotch --uninstall-hooks  take our hooks out of settings.json, then exit
    ClaudeNotch --status           hooks installed? app running? where is the log?
    ClaudeNotch --settings         open Settings (in the running copy if there is one)
    ClaudeNotch --background       start quietly (start at login): no greeting
    ClaudeNotch --quit-running     ask the running copy to quit (the uninstaller uses this)
    ClaudeNotch --first-run        the installer's last step: hooks, then the welcome card
    ClaudeNotch --headless         the server only, no window (tests, CI)

Mirrors linux/claudenotch/app.py. What Linux does with /proc and signals
(finding and stopping an old copy) is done here with a named mutex and the
/control/quit endpoint.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import urllib.request

from . import __version__, paths

from claudenotch import hooks  # noqa: E402  (paths made it importable)


# --- talking to a running copy ------------------------------------------------------

def running_version() -> str | None:
    """The version of the ClaudeNotch on our port: None when none is, "" when
    something answers that is too old to say (or is not ClaudeNotch)."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{hooks.PORT}/ping", timeout=1) as r:
            body = r.read()
    except OSError:
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return ""
    return str(data.get("version") or "") if isinstance(data, dict) else ""


def control(action: str, timeout: float = 2.0) -> bool:
    """POST /control/<action> to the running copy, with the hook token."""
    token = hooks.expected_token()
    url = f"http://127.0.0.1:{hooks.PORT}/control/{action}" + (f"?t={token}" if token else "")
    try:
        req = urllib.request.Request(url, data=b"{}", method="POST", headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except OSError:
        return False


def quit_running(wait: float = 6.0) -> bool:
    """Ask the running copy to quit and wait for the port to free up."""
    if running_version() is None:
        return True
    control("quit")
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if running_version() is None:
            return True
        time.sleep(0.2)
    return running_version() is None


# --- logging -----------------------------------------------------------------------

def _log_to_file_if_windowed() -> None:
    """The built app has no console (PyInstaller --windowed), so stdout and
    stderr are None and anything printed is lost. Send it to a log the user
    can be pointed at, rotated at 512 KB."""
    if sys.stderr is not None and getattr(sys.stderr, "isatty", lambda: False)():
        return
    path = paths.log_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path) and os.path.getsize(path) > 512 * 1024:
            os.replace(path, path + ".1")
        f = open(path, "a", buffering=1, encoding="utf-8")
    except OSError:
        return
    sys.stdout = sys.stderr = f


def say(message: str) -> None:
    """Print to the console when there is one, and the log otherwise."""
    stream = sys.stdout if sys.stdout is not None else None
    if stream is not None:
        print(message, file=stream, flush=True)


# --- main ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="ClaudeNotch", description="Claude Code prompts at the top of your screen.")
    ap.add_argument("--install-hooks", action="store_true", help="wire Claude Code to ClaudeNotch, then exit")
    ap.add_argument("--uninstall-hooks", action="store_true", help="remove ClaudeNotch's hooks, then exit")
    ap.add_argument("--status", action="store_true", help="say whether the hooks are wired and the app is up")
    ap.add_argument("--settings", action="store_true", help="open the Settings window")
    ap.add_argument("--background", action="store_true", help="start quietly, as at login")
    ap.add_argument("--quit-running", "--quit", dest="quit_running", action="store_true",
                    help="quit the running ClaudeNotch")
    ap.add_argument("--first-run", action="store_true", help="installer's last step: hooks and a welcome")
    ap.add_argument("--headless", action="store_true", help="run the hook server without a window")
    ap.add_argument("--no-install", action="store_true", help="do not install the hooks on start")
    ap.add_argument("--version", action="version", version=f"ClaudeNotch for Windows {__version__}")
    return ap.parse_args(argv)


def _attach_parent_console() -> None:
    """The built exe is a GUI program, so it has no console and print() goes
    nowhere. When it was started from a terminal with a flag like --status,
    attach to that terminal so the answer shows up there."""
    if sys.platform != "win32" or sys.stdout is not None:
        return
    try:
        import ctypes
        if ctypes.windll.kernel32.AttachConsole(-1):      # ATTACH_PARENT_PROCESS
            sys.stdout = open("CONOUT$", "w", encoding="utf-8", buffering=1)
            sys.stderr = sys.stdout
            print()   # the prompt was already drawn; start on a fresh line
    except OSError:
        pass


_CLI_FLAGS = ("--install-hooks", "--uninstall-hooks", "--status", "--quit-running", "--quit", "--version",
              "--help", "-h", "--headless")


def main(argv: list[str] | None = None) -> int:
    raw = sys.argv[1:] if argv is None else argv
    if any(a in _CLI_FLAGS for a in raw):
        _attach_parent_console()
    args = parse_args(argv)

    # Flags that do one thing and exit. --uninstall-hooks with --quit-running
    # is the uninstaller's line: stop the app first, so it cannot rewrite
    # settings.json behind us, then take the hooks out.
    if args.quit_running:
        stopped = quit_running()
        if not args.uninstall_hooks:
            say("ClaudeNotch quit." if stopped else "ClaudeNotch did not quit in time.")
            return 0 if stopped else 1
    if args.uninstall_hooks:
        try:
            say(f"Hooks removed from {hooks.uninstall()}")
        except hooks.UnreadableSettings as e:
            say(str(e))
            return 1
        return 0
    if args.install_hooks and not args.first_run:
        try:
            say(f"Hooks installed in {hooks.install()}")
        except hooks.UnreadableSettings as e:
            say(str(e))
            return 1
        return 0
    if args.status:
        running = running_version()
        say(f"hooks: {'installed' if hooks.installed() else 'not installed'} ({hooks.settings_path()})")
        say(f"app:   {'running ' + running if running else 'not running'} (127.0.0.1:{hooks.PORT})")
        say(f"log:   {paths.log_path()}")
        return 0

    if args.headless:
        return run_headless(args)

    _log_to_file_if_windowed()
    from .qtapp import run
    return run(args)


def run_headless(args: argparse.Namespace) -> int:
    """The server and state, no UI: for CI and for checking hooks by hand."""
    from claudenotch.server import HookServer
    from claudenotch.state import AppState

    if not args.no_install:
        hooks.install()
    state = AppState()
    try:
        server = HookServer(state)
    except OSError as e:
        say(f"ClaudeNotch: cannot listen on 127.0.0.1:{hooks.PORT} ({e.strerror}).")
        return 1
    stop = threading.Event()
    server.controls["quit"] = stop.set
    server.start()
    say(f"ClaudeNotch {__version__} listening on 127.0.0.1:{hooks.PORT} (headless)")
    try:
        while not stop.wait(0.5):
            pass
    except KeyboardInterrupt:
        pass
    server.stop()
    return 0
