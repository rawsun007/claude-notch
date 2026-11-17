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
import signal
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
        return 0

    if _is_running():
        print("ClaudeNotch is already running.", file=sys.stderr)
        return 1

    if not args.no_install:
        try:
            hooks.install()
        except hooks.UnreadableSettings as e:
            print(f"ClaudeNotch: {e}. Fix it, then run claudenotch --install-hooks.", file=sys.stderr)

    from .server import HookServer
    from .state import AppState

    state = AppState()
    try:
        server = HookServer(state)
    except OSError as e:
        print(f"ClaudeNotch: cannot listen on 127.0.0.1:{hooks.PORT}: {e}", file=sys.stderr)
        return 1
    server.start()

    if args.headless:
        print(f"ClaudeNotch {__version__} listening on 127.0.0.1:{hooks.PORT} (headless)", flush=True)
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
        print("ClaudeNotch: no display. Run it from a desktop session, or use --headless.", file=sys.stderr)
        return 1
    NotchWindow(state)
    DesktopNotifier(state)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, Gtk.main_quit)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, Gtk.main_quit)
    print(f"ClaudeNotch {__version__} listening on 127.0.0.1:{hooks.PORT}", flush=True)
    Gtk.main()
    server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
