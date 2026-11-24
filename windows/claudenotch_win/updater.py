"""The update check in the running app: at start, then once a day, off the
GUI thread (updatecheck.fetch does the network). The tray grows an
"Update available" item and Settings > About can check on demand, as the
Mac's menu item and About button do. Opening the release page is the
update: the installer replaces the running copy itself.
"""

from __future__ import annotations

import threading

from PySide6.QtCore import QObject, QTimer, Signal

from claudenotch import updatecheck

from . import __version__

PREFIX = "windows-v"

#: The running app's checker, for Settings to ask.
APP: "Updater | None" = None


class Updater(QObject):
    #: (version, page) when a newer release exists.
    available = Signal(str, str)
    #: Result of a check the user asked for: "update", "current" or "failed".
    finished = Signal(str)
    _done = Signal(object, bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.latest: tuple[str, str] | None = None
        self._busy = False
        self._done.connect(self._apply)
        self._timer = QTimer(self, interval=updatecheck.DAY * 1000)
        self._timer.timeout.connect(self.check)

    def start(self, first_after_ms: int = 20_000) -> None:
        """Check soon after start (not during it), then daily."""
        QTimer.singleShot(first_after_ms, self.check)
        self._timer.start()

    def check(self, asked: bool = False) -> None:
        if self._busy:
            return
        self._busy = True
        threading.Thread(target=lambda: self._done.emit(updatecheck.fetch(), asked), daemon=True).start()

    def _apply(self, releases, asked: bool) -> None:
        self._busy = False
        found = updatecheck.available(__version__, releases, PREFIX) if releases is not None else None
        if found:
            self.latest = found
            self.available.emit(*found)
        if asked:
            self.finished.emit("update" if found else ("failed" if releases is None else "current"))
