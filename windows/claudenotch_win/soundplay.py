"""Play a Windows system sound by name, without blocking: winsound with
SND_ASYNC, from C:\\Windows\\Media. Only names that exist there are played
or offered; anything else is silently skipped (no fallback beep)."""

from __future__ import annotations

import os
import sys

MEDIA = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Media")


def path(name: str) -> str | None:
    if not name or os.sep in name or "/" in name or ".." in name:
        return None
    p = os.path.join(MEDIA, name + ".wav")
    return p if os.path.isfile(p) else None


def available(names) -> list[str]:
    return [n for n in names if path(n)]


def play(name: str | None) -> bool:
    p = path(name) if name else None
    if p is None or sys.platform != "win32":
        return False
    try:
        import winsound
        winsound.PlaySound(p, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
        return True
    except (RuntimeError, OSError):
        return False
