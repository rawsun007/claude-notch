"""Local crash reports, the Mac's CrashReporter: an uncaught error in any
thread is written to %LOCALAPPDATA%\\ClaudeNotch\\Crashes as a text file
(version, time, traceback), and a hard crash's stack goes to fatal.txt
through faulthandler. The newest ten are kept. Nothing leaves the PC;
Settings > About opens the folder.
"""

from __future__ import annotations

import datetime as _dt
import faulthandler
import os
import platform
import sys
import threading
import traceback

from . import __version__, paths

MAX_REPORTS = 10
_fatal = None


def folder() -> str:
    return os.path.join(paths.log_dir(), "Crashes")


def is_report(name: str) -> bool:
    return name.startswith("crash-") and name.endswith(".txt")


def report_text(exc_type, exc, tb, thread: str = "main", now: _dt.datetime | None = None) -> str:
    """Pure: what a report says."""
    now = now or _dt.datetime.now()
    head = [f"ClaudeNotch {__version__} crash report", f"Time: {now.isoformat(timespec='seconds')}",
            f"Windows: {platform.platform()}", f"Python: {sys.version.split()[0]}", f"Thread: {thread}", ""]
    return "\n".join(head) + "".join(traceback.format_exception(exc_type, exc, tb))


def write(exc_type, exc, tb, thread: str = "main") -> str | None:
    try:
        os.makedirs(folder(), exist_ok=True)
        now = _dt.datetime.now()
        path = os.path.join(folder(), f"crash-{now:%Y%m%d-%H%M%S-%f}.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(report_text(exc_type, exc, tb, thread, now))
        prune()
        return path
    except OSError:
        return None


def prune(keep: int = MAX_REPORTS) -> None:
    try:
        names = sorted((n for n in os.listdir(folder()) if is_report(n)), reverse=True)
    except OSError:
        return
    for n in names[keep:]:
        try:
            os.remove(os.path.join(folder(), n))
        except OSError:
            pass


def install() -> None:
    """Catch what would otherwise vanish: the windowed exe has no console."""
    global _fatal
    previous = sys.excepthook

    def hook(t, e, tb):
        write(t, e, tb, "main")
        if previous is not None and previous is not sys.__excepthook__:
            previous(t, e, tb)
        elif sys.stderr is not None:
            sys.__excepthook__(t, e, tb)

    sys.excepthook = hook

    def thread_hook(args):
        if args.exc_type is SystemExit:
            return
        write(args.exc_type, args.exc_value, args.exc_traceback, getattr(args.thread, "name", "thread"))

    threading.excepthook = thread_hook
    try:
        os.makedirs(folder(), exist_ok=True)
        _fatal = open(os.path.join(folder(), "fatal.txt"), "a", encoding="utf-8")
        faulthandler.enable(_fatal)
    except OSError:
        pass
