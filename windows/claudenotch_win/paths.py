"""Where things live on Windows, and how the shared core is found.

- settings, rules, hook token: %APPDATA%\\ClaudeNotch (roams with the profile)
- log: %LOCALAPPDATA%\\ClaudeNotch\\claudenotch.log (machine-local)
- the app: %LOCALAPPDATA%\\Programs\\ClaudeNotch (per-user install, D6)
"""

from __future__ import annotations

import os
import sys

APP_NAME = "ClaudeNotch"
AUMID = "Rawsun.ClaudeNotch"     # AppUserModelID; the installer's Start Menu shortcut carries it too


def _here() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def ensure_core_importable() -> None:
    """Put the shared core (`linux/claudenotch`) on sys.path when running from
    a checkout. In a PyInstaller build the core is bundled as a normal
    package, so the import already works and nothing is added."""
    try:
        import claudenotch  # noqa: F401
        return
    except ImportError:
        pass
    checkout_core = os.path.normpath(os.path.join(_here(), "..", "..", "linux"))
    if os.path.isdir(os.path.join(checkout_core, "claudenotch")) and checkout_core not in sys.path:
        sys.path.insert(0, checkout_core)


def appdata() -> str:
    return os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")


def localappdata() -> str:
    return os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")


def config_dir() -> str:
    return os.path.join(appdata(), APP_NAME)


def log_dir() -> str:
    return os.path.join(localappdata(), APP_NAME)


def log_path() -> str:
    return os.path.join(log_dir(), "claudenotch.log")


def install_dir() -> str:
    return os.path.join(localappdata(), "Programs", APP_NAME)


def frozen() -> bool:
    """True inside the PyInstaller build."""
    return bool(getattr(sys, "frozen", False))


def executable_command(*args: str) -> str:
    """The command line that starts this copy of the app, for the Run key.
    The built app is one .exe; from a checkout it is pythonw -m."""
    if frozen():
        parts = [sys.executable, *args]
    else:
        exe = sys.executable
        pyw = os.path.join(os.path.dirname(exe), "pythonw.exe")
        if os.path.exists(pyw):
            exe = pyw
        parts = [exe, "-m", "claudenotch_win", *args]
    return " ".join(f'"{p}"' if " " in p or not p else p for p in parts)


def resource(name: str) -> str:
    """A file shipped with the app (icons). PyInstaller unpacks data next to
    the exe under _internal; a checkout keeps them in windows/resources."""
    base = getattr(sys, "_MEIPASS", None) or os.path.normpath(os.path.join(_here(), ".."))
    return os.path.join(base, "resources", name)
