"""Small file helpers shared by every module that writes to disk."""

from __future__ import annotations

import os
import time

REPLACE_TRIES = 6
REPLACE_PAUSE = 0.1   # 6 tries over about half a second


def replace(src: str, dst: str, tries: int = REPLACE_TRIES, pause: float = REPLACE_PAUSE) -> None:
    """os.replace, retried briefly on PermissionError.

    On Windows a rename onto a file fails while another process holds it
    open without FILE_SHARE_DELETE: antivirus scanning settings.json for a
    moment, or a sync client. That clears in milliseconds, so try a few
    times before giving up. On Linux and macOS the first try succeeds.
    """
    for attempt in range(tries):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if attempt == tries - 1:
                raise
            time.sleep(pause)
