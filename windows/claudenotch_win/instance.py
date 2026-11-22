"""One ClaudeNotch per user session.

A named mutex, `Local\\ClaudeNotch`, is the lock: the Inno Setup installer's
AppMutex=ClaudeNotch looks for the same name to know the app is running
before an upgrade. The port is the other half: a second launch pings
127.0.0.1:53127 to learn the running copy's version and decides what to do
(see `decide`).
"""

from __future__ import annotations

import sys

MUTEX_NAME = "Local\\ClaudeNotch"
ERROR_ALREADY_EXISTS = 183

# What a launch does when another copy may be running.
START = "start"            # nothing running: start normally
SHOW = "show"              # same version running: open its Settings, exit
TAKE_OVER = "take-over"    # different version running: ask it to quit, then start


def decide(running: str | None, mine: str) -> str:
    """`running` is the version on the port (None: nothing answered, "": a
    copy too old to say)."""
    if running is None:
        return START
    if running == mine:
        return SHOW
    return TAKE_OVER


class SingleInstance:
    """Holds the named mutex for the life of the process. `acquired` is False
    when another process already holds it. Off Windows (tests) it always
    acquires."""

    def __init__(self, name: str = MUTEX_NAME):
        self.name = name
        self.handle = None
        self.acquired = True
        if sys.platform != "win32":
            return
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
        self._kernel32 = kernel32
        self.handle = kernel32.CreateMutexW(None, False, name)
        self.acquired = bool(self.handle) and ctypes.get_last_error() != ERROR_ALREADY_EXISTS

    def release(self) -> None:
        if self.handle:
            self._kernel32.CloseHandle(self.handle)
            self.handle = None

    def wait_for_release(self, timeout: float) -> bool:
        """After asking the old copy to quit: try to take the mutex again until
        it is free or `timeout` seconds pass."""
        import time
        if sys.platform != "win32":
            return True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.release()
            again = SingleInstance(self.name)
            if again.acquired:
                self.handle, self.acquired = again.handle, True
                return True
            again.release()
            time.sleep(0.2)
        return False
