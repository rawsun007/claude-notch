"""Notice that a different ClaudeNotch was installed underneath the running one.

`apt install ./claudenotch_<new>.deb` (or install.sh) replaces the files on
disk, but the process started from the old ones keeps running the old code,
and a fresh launch only finds "already running". So upgrading looked like it
did nothing until the old version was uninstalled. The running app now reads
the installed version every few seconds and restarts into it when it changes,
and quits when the package is removed.
"""

from __future__ import annotations

import os
import re

from . import __version__

_VERSION = re.compile(r"""^__version__\s*=\s*["']([^"']+)["']""", re.MULTILINE)
PACKAGE_INIT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "__init__.py")

RESTART, QUIT = "restart", "quit"


def installed_version(path: str = PACKAGE_INIT) -> str | None:
    """The version of the files on disk now, or None when they are gone."""
    try:
        with open(path, encoding="utf-8") as f:
            m = _VERSION.search(f.read())
    except OSError:
        return None
    return m.group(1) if m else None


def decide(running: str, installed: str | None, missing_checks: int) -> str | None:
    """What to do about what is on disk.

    A package manager briefly leaves the file missing mid-upgrade, so "gone"
    only means uninstalled after it has been missing for several checks in a
    row; a changed version means restart, in either direction, since a
    downgrade the user chose is still the version they want running.
    """
    if installed is None:
        return QUIT if missing_checks >= 3 else None
    if installed != running:
        return RESTART
    return None


def parse(version: str) -> tuple[int, ...]:
    """'0.43.1' -> (0, 43, 1); anything unparsable sorts lowest."""
    try:
        return tuple(int(p) for p in version.split("."))
    except ValueError:
        return (0,)


def running_version() -> str:
    return __version__
