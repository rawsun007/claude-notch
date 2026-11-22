"""Play a notch sound by name, without blocking (winsound, SND_ASYNC).

Where a name is looked up, in order:
1. %APPDATA%\\ClaudeNotch\\Sounds\\<name>.wav: the user's own copy, for
   instance the macOS sound of that name if they have it;
2. the app's own sounds, made under the Mac's names (resources/sounds);
3. Windows' sounds in C:\\Windows\\Media, for older settings that named one.

A name is a bare word: it can never point outside those folders. A missing
sound plays nothing, never the default beep.
"""

from __future__ import annotations

import os
import sys

from . import paths

MEDIA = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Media")


def user_dir() -> str:
    return os.path.join(paths.config_dir(), "Sounds")


def path(name: str) -> str | None:
    if not name or os.sep in name or "/" in name or ".." in name or ":" in name:
        return None
    for folder in (user_dir(), paths.resource("sounds"), MEDIA):
        p = os.path.join(folder, name + ".wav")
        if os.path.isfile(p):
            return p
    return None


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
