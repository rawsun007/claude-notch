"""Mirror new cards to the desktop's notification server, when asked to.

Off by default (Settings > Notifications): the card is already on screen,
and GNOME puts its notification banner at the top centre, right over it.

The overlay is only useful when it is on the screen being looked at; a
desktop notification reaches the user on another workspace or with the
terminal fullscreen. Uses `notify-send` (libnotify-bin) when present, so
there is no D-Bus binding to depend on, and does nothing when it is absent.
Text is already redacted by AppState.
"""

from __future__ import annotations

import shutil
import subprocess
import threading

from .state import AppState


def wanted(desktop_notifications: bool, dangerous_only: bool, dangerous: bool) -> bool:
    """Whether a card gets a desktop notification under these settings."""
    if desktop_notifications:
        return True
    return dangerous_only and dangerous


class DesktopNotifier:
    def __init__(self, state: AppState, store=None):
        self.state = state
        self.store = store
        self.binary = shutil.which("notify-send")
        self._seen: set[int] = set()
        self._lock = threading.Lock()
        if self.binary:
            state.subscribe(self._on_change)

    def _on_change(self) -> None:
        perms, questions, _, _ = self.state.snapshot()
        cfg = self.store.value if self.store is not None else None
        on = cfg.desktop_notifications if cfg else False
        dangerous_only = cfg.notify_dangerous_only if cfg else False
        fresh = []
        with self._lock:
            for c in perms:
                if c.id not in self._seen:
                    self._seen.add(c.id)
                    if not wanted(on, dangerous_only, bool(c.dangers)):
                        continue
                    fresh.append((f"Claude wants to use {c.title}", c.detail[:200], "critical" if c.dangers else "normal"))
            for q in questions:
                if q.id not in self._seen:
                    self._seen.add(q.id)
                    if not wanted(on, dangerous_only, False):
                        continue
                    text = q.questions[0].text if q.questions else ""
                    fresh.append(("Claude has a question", text[:200], "normal"))
            if len(self._seen) > 512:
                live = {c.id for c in perms} | {q.id for q in questions}
                self._seen &= live
        for title, body, urgency in fresh:
            self._send(title, body, urgency)

    def _send(self, title: str, body: str, urgency: str) -> None:
        # Argument list, never a shell: the body came from a hook payload.
        try:
            subprocess.Popen([self.binary, "--app-name=ClaudeNotch", f"--urgency={urgency}", "--", title, body],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass
