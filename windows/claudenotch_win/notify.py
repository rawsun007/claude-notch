"""Windows toasts for new cards, when asked to (Settings > Notifications).

Off by default, as on Linux: the card is already on screen. A toast helps
when the pill is on another monitor or hidden behind a fullscreen app.

v1 uses QSystemTrayIcon.showMessage, which makes a real Windows toast with
our icon and no extra dependency. Clicking it opens the card's session
list. Actionable toasts (Allow / Deny on the toast) are v1.1 and need the
AppUserModelID the installer already sets.

The decision of what gets a toast is linux `notify.wanted`, so the two
editions agree. Text is already redacted by AppState.
"""

from __future__ import annotations

import threading

from PySide6.QtCore import QObject, Signal
from PySide6.QtWidgets import QSystemTrayIcon

from claudenotch.notify import wanted

from . import winutil


def fresh_items(perms, questions, seen: set, on: bool, dangerous_only: bool, fullscreen: bool = False):
    """(title, body, dangerous) for cards not seen before that should toast.
    Marks them seen either way. A card that shows over a fullscreen app also
    toasts when dangerous-only is on, since the user may not see the pill."""
    out = []
    for c in perms:
        if c.id in seen:
            continue
        seen.add(c.id)
        if wanted(on, dangerous_only, bool(c.dangers)):
            out.append((f"Claude wants to use {c.title}", c.detail[:200], bool(c.dangers)))
    for q in questions:
        if q.id in seen:
            continue
        seen.add(q.id)
        if wanted(on, dangerous_only, False):
            out.append(("Claude has a question", (q.questions[0].text if q.questions else "")[:200], False))
    if len(seen) > 512:
        seen &= {c.id for c in perms} | {q.id for q in questions}
    return out


class Notifier(QObject):
    _send = Signal(str, str, bool)

    def __init__(self, state, store, tray: QSystemTrayIcon, overlay=None):
        super().__init__()
        self.state, self.store, self.tray, self.overlay = state, store, tray, overlay
        self._seen: set[int] = set()
        self._lock = threading.Lock()
        self._send.connect(self._show)          # queued: showMessage runs on the GUI thread
        tray.messageClicked.connect(lambda: overlay and overlay.show_sessions())
        state.subscribe(self._on_change)

    def _on_change(self) -> None:
        perms, questions, _, _ = self.state.snapshot()
        cfg = self.store.value
        with self._lock:
            items = fresh_items(perms, questions, self._seen, cfg.desktop_notifications,
                                cfg.notify_dangerous_only, winutil.fullscreen_in_front())
        for title, body, dangerous in items:
            self._send.emit(title, body, dangerous)

    def _show(self, title: str, body: str, dangerous: bool) -> None:
        icon = QSystemTrayIcon.Warning if dangerous else QSystemTrayIcon.Information
        self.tray.showMessage(title, body, icon, 8000)
