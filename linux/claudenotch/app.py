"""Entry point: `claudenotch` and its subcommands.

    claudenotch                  run the app (installs the hooks on first run)
    claudenotch --install-hooks  wire Claude Code to the app, then exit
    claudenotch --uninstall-hooks
    claudenotch --status         say whether the hooks are wired and the app is up
    claudenotch --headless       the server only, no window (for tests and servers)
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import urllib.request

from . import __version__, hooks


def _choose_backend() -> None:
    """Prefer a real overlay on Wayland when the compositor offers layer-shell
    (KDE, wlroots); otherwise run through XWayland, where keep-above and
    window placement work. GNOME's Wayland has no layer-shell, so it takes
    the XWayland path."""
    if os.environ.get("GDK_BACKEND") or os.environ.get("XDG_SESSION_TYPE") != "wayland":
        return
    try:
        import gi
        gi.require_version("GtkLayerShell", "0.1")
        from gi.repository import GtkLayerShell  # noqa: F401
        desktop = (os.environ.get("XDG_CURRENT_DESKTOP") or "").lower()
        if "gnome" not in desktop:
            return  # layer-shell available and likely supported: stay on Wayland
    except (ImportError, ValueError):
        pass
    if os.environ.get("DISPLAY"):
        # A list, not just x11: if XWayland refuses us (no Xauthority, or a
        # session started without it) GDK falls through to native Wayland
        # instead of the app quitting with "no display".
        os.environ["GDK_BACKEND"] = "x11,wayland"


def log_path() -> str:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "claudenotch", "claudenotch.log")


def _log_to_file_if_detached() -> None:
    """Started from the app menu or at login there is no terminal, so
    anything printed vanishes. Send it to a log the user can be pointed at."""
    if sys.stderr is not None and sys.stderr.isatty():
        return
    path = log_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path) and os.path.getsize(path) > 512 * 1024:
            os.replace(path, path + ".1")
        f = open(path, "a", buffering=1, encoding="utf-8")
    except OSError:
        return
    sys.stdout = sys.stderr = f
    os.dup2(f.fileno(), 1)
    os.dup2(f.fileno(), 2)


def _tell(message: str, urgent: bool = False) -> None:
    """Say something the user must see: printed, and when there is no
    terminal, also as a desktop notification, since a double-click from the
    app menu has nowhere else to show it."""
    print(f"ClaudeNotch: {message}", file=sys.stderr, flush=True)
    if os.isatty(2) or not shutil.which("notify-send"):
        return
    try:
        subprocess.Popen(["notify-send", "--app-name=ClaudeNotch", "--icon=claudenotch",
                          f"--urgency={'critical' if urgent else 'normal'}", "--", "ClaudeNotch", message],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def _wave_at_running_app() -> bool:
    """Ask the instance that is already running to show itself, so a second
    double-click visibly lands somewhere instead of doing nothing."""
    import json
    token = hooks.expected_token()
    url = f"http://127.0.0.1:{hooks.PORT}/notification" + (f"?t={token}" if token else "")
    body = json.dumps({"hook_event_name": "Notification", "title": "ClaudeNotch is running",
                       "message": "Claude Code prompts will appear here."}).encode()
    try:
        req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=2) as r:
            return r.status == 200
    except OSError:
        return False


class UpgradeWatcher:
    """Restart into a different installed version, quit once uninstalled.

    Waits while a card is on screen: restarting drops the held hook
    connection, and an answer half given should not be thrown away.
    """

    INTERVAL = 3.0

    def __init__(self, state, server, stop_ui=None):
        from . import upgrade
        self.upgrade = upgrade
        self.state, self.server, self.stop_ui = state, server, stop_ui
        self.missing = 0

    def check(self) -> bool:
        installed = self.upgrade.installed_version()
        self.missing = self.missing + 1 if installed is None else 0
        action = self.upgrade.decide(self.upgrade.running_version(), installed, self.missing)
        if action == self.upgrade.QUIT:
            print("ClaudeNotch was uninstalled; quitting.", flush=True)
            self._stop()
            os._exit(0)
        if action == self.upgrade.RESTART:
            perms, questions, _, _ = self.state.snapshot()
            if perms or questions:
                return True   # try again once the card is answered
            print(f"ClaudeNotch {installed} installed over {__version__}; restarting into it.", flush=True)
            self._stop()
            env = dict(os.environ, CLAUDENOTCH_UPDATED_FROM=__version__)
            os.execve(sys.executable, [sys.executable, os.path.abspath(sys.argv[0]), *sys.argv[1:]], env)
        return True

    def _stop(self):
        try:
            self.server.stop()
        except Exception:
            pass


def _is_running() -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{hooks.PORT}/ping", timeout=1) as r:
            return r.status == 200
    except OSError:
        return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="claudenotch", description="Claude Code prompts at the top of your screen.")
    ap.add_argument("--install-hooks", action="store_true")
    ap.add_argument("--uninstall-hooks", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--headless", action="store_true", help="run the hook server without a window")
    ap.add_argument("--no-install", action="store_true", help="do not install the hooks on start")
    ap.add_argument("--version", action="version", version=f"ClaudeNotch for Linux {__version__}")
    args = ap.parse_args(argv)

    if args.install_hooks:
        print(f"Hooks installed in {hooks.install()}")
        return 0
    if args.uninstall_hooks:
        print(f"Hooks removed from {hooks.uninstall()}")
        return 0
    if args.status:
        print(f"hooks: {'installed' if hooks.installed() else 'not installed'} ({hooks.settings_path()})")
        print(f"app:   {'running' if _is_running() else 'not running'} (127.0.0.1:{hooks.PORT})")
        print(f"log:   {log_path()}")
        return 0

    _log_to_file_if_detached()

    if _is_running():
        if _wave_at_running_app():
            print("ClaudeNotch is already running; it says hello at the top of the screen.", flush=True)
            return 0
        _tell("ClaudeNotch is already running. It sits at the top centre of your screen, "
              "just below the top bar.")
        return 0

    if not args.no_install:
        try:
            hooks.install()
        except hooks.UnreadableSettings as e:
            _tell(f"{e}. Fix it, then run claudenotch --install-hooks.", urgent=True)

    from .server import HookServer
    from .state import AppState

    state = AppState()
    try:
        server = HookServer(state)
    except OSError as e:
        _tell(f"cannot listen on 127.0.0.1:{hooks.PORT} ({e.strerror}). Another program is using "
              f"that port; close it and start ClaudeNotch again.", urgent=True)
        return 1
    server.start()

    watcher = UpgradeWatcher(state, server)

    if args.headless:
        print(f"ClaudeNotch {__version__} listening on 127.0.0.1:{hooks.PORT} (headless)", flush=True)
        import threading

        def watch():
            import time
            while True:
                time.sleep(watcher.INTERVAL)
                watcher.check()
        threading.Thread(target=watch, daemon=True, name="upgrade-watch").start()
        signal.sigwait({signal.SIGINT, signal.SIGTERM})
        server.stop()
        return 0

    _choose_backend()
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    from .notify import DesktopNotifier
    from .ui import NotchWindow

    if not Gtk.init_check(sys.argv)[0]:
        _tell("no display to draw on. Start it from your desktop session, or use --headless.", urgent=True)
        return 1
    NotchWindow(state)
    state.greet(updated_from=os.environ.pop("CLAUDENOTCH_UPDATED_FROM", None), version=__version__)
    GLib.timeout_add_seconds(int(watcher.INTERVAL), watcher.check)
    DesktopNotifier(state)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, Gtk.main_quit)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, Gtk.main_quit)
    print(f"ClaudeNotch {__version__} listening on 127.0.0.1:{hooks.PORT}", flush=True)
    Gtk.main()
    server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
