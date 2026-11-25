"""Play a notch sound by name, without blocking (winsound, SND_ASYNC).

Where a name is looked up, in order:
1. %APPDATA%\\ClaudeNotch\\Sounds\\<name>.wav: the user's own copy, for
   instance the macOS sound of that name if they have it;
2. the sounds that ship with the app, under the Mac's names (resources/sounds;
   where they come from is in SOURCE.md there);
3. Windows' sounds in C:\\Windows\\Media, for older settings that named one.

A name is a bare word: it can never point outside those folders. A missing
sound plays nothing, never the default beep.
"""

from __future__ import annotations

import os
import struct
import sys

from . import aiffwav, paths

MEDIA = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Media")


def user_dir() -> str:
    return os.path.join(paths.config_dir(), "Sounds")


def _from_aiff(name: str) -> str | None:
    """The user's <name>.aiff as a WAV, converted on first use and again
    whenever the AIFF changes."""
    for ext in (".aiff", ".aif"):
        src = os.path.join(user_dir(), name + ext)
        if not os.path.isfile(src):
            continue
        out = os.path.join(user_dir(), ".converted", name + ".wav")
        try:
            if not os.path.isfile(out) or os.path.getmtime(out) < os.path.getmtime(src):
                with open(src, "rb") as f:
                    wav = aiffwav.to_wav(f.read(aiffwav.MAX_BYTES + 1))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                tmp = out + ".tmp"
                with open(tmp, "wb") as f:
                    f.write(wav)
                os.replace(tmp, out)
            return out
        except (OSError, ValueError, struct.error):
            return None
    return None


def path(name: str) -> str | None:
    if not name or os.sep in name or "/" in name or ".." in name or ":" in name:
        return None
    mine = os.path.join(user_dir(), name + ".wav")
    if os.path.isfile(mine):
        return mine
    converted = _from_aiff(name)
    if converted:
        return converted
    for folder in (paths.resource("sounds"), MEDIA):
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
