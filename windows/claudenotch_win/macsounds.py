"""Get the real macOS sounds onto this PC, when the user asks for it.

Apple's recordings are not ours to ship, so the installer carries the app's
own sounds under the Mac's names. This downloads Apple's files, on the
user's choice (the first-run window or Settings > Sounds), from the public
repository the project owner pointed at, into the user's own sound folder
(%APPDATA%\\ClaudeNotch\\Sounds), where soundplay already prefers them.

Every file is checked before it is kept: a size cap, and it must parse as
an uncompressed AIFF (aiffwav.read); anything else is thrown away.
"""

from __future__ import annotations

import os
import urllib.request

from . import aiffwav, soundplay

SOURCE = "https://raw.githubusercontent.com/extratone/macOSsystemsounds/HEAD/aiff/{name}.aiff"
SOURCE_PAGE = "https://github.com/extratone/macOSsystemsounds"
NAMES = ("Funk", "Pop", "Tink", "Glass", "Submarine", "Hero", "Blow", "Bottle", "Frog", "Morse", "Ping", "Purr",
         "Sosumi")
MAX_BYTES = 2 * 1024 * 1024


def have() -> list[str]:
    """The macOS sounds already in the user's folder."""
    folder = soundplay.user_dir()
    return [n for n in NAMES if os.path.isfile(os.path.join(folder, n + ".aiff"))]


def check(data: bytes) -> bool:
    if not data or len(data) > MAX_BYTES:
        return False
    try:
        aiffwav.read(data)
        return True
    except ValueError:
        return False


def download(progress=None, timeout: float = 20.0) -> tuple[int, list[str]]:
    """Fetch every sound not already here. Returns (how many are here now,
    the names that failed). Safe to run again: it skips what it has."""
    folder = soundplay.user_dir()
    os.makedirs(folder, exist_ok=True)
    failed = []
    for i, name in enumerate(NAMES):
        dest = os.path.join(folder, name + ".aiff")
        if progress is not None:
            progress(i, len(NAMES), name)
        if os.path.isfile(dest):
            continue
        req = urllib.request.Request(SOURCE.format(name=name), headers={"User-Agent": "ClaudeNotch-sounds"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read(MAX_BYTES + 1)
        except OSError:
            failed.append(name)
            continue
        if not check(data):
            failed.append(name)
            continue
        tmp = dest + ".part"
        try:
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, dest)
        except OSError:
            failed.append(name)
    return len(have()), failed
