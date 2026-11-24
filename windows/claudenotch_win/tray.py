"""The tray icon: where Windows people look for a background app.

Left click opens the session list (as hovering the pill does). The menu has
Settings, Pause, Show the pill and Quit. The icon follows the taskbar's
theme: a white mark on a dark taskbar, a black one on a light taskbar.

Pause: hooks answer "no opinion" straight away, so Claude Code asks in its
own terminal, as if ClaudeNotch were not running. Nothing is queued.
"""

from __future__ import annotations

from PySide6.QtCore import QTimer
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QMenu, QSystemTrayIcon

from . import paths, winutil


def tray_icon() -> QIcon:
    name = "tray-black.png" if winutil.system_uses_light_theme() else "tray-white.png"
    return QIcon(paths.resource(name))


class Tray(QSystemTrayIcon):
    def __init__(self, overlay, store, on_settings, on_quit, paused=None):
        super().__init__(tray_icon())
        self.overlay = overlay
        self.store = store
        self.paused = paused            # a threading.Event shared with the server, or None
        self.listening = True
        self.setToolTip("ClaudeNotch")

        menu = QMenu()
        self.status_action = QAction("Listening on 127.0.0.1:53127", menu)
        self.status_action.setEnabled(False)
        menu.addAction(self.status_action)
        menu.addSeparator()
        self.notch_action = menu.addAction("Open the Notch", lambda: overlay.show_sessions(8))
        self.settings_action = menu.addAction("Settings…", on_settings)
        self.pause_action = QAction("Pause ClaudeNotch", menu, checkable=True)
        self.pause_action.toggled.connect(self._set_paused)
        menu.addAction(self.pause_action)
        self.pill_action = QAction("Show the pill", menu, checkable=True)
        self.pill_action.setChecked(bool(getattr(store.value, "show_pill", True)))
        self.pill_action.toggled.connect(lambda on: store.update(show_pill=on))
        menu.addAction(self.pill_action)
        menu.addSeparator()
        menu.addAction("Quit ClaudeNotch", on_quit)
        self._menu = menu               # QSystemTrayIcon does not own the menu
        self.setContextMenu(menu)
        self.activated.connect(self._activated)
        store.subscribe(lambda s: QTimer.singleShot(0, self._sync))

        # The taskbar theme can change while we run.
        self._theme_timer = QTimer(self, interval=5000)
        self._theme_timer.timeout.connect(lambda: self.setIcon(tray_icon()))
        self._theme_timer.start()

    def set_shortcuts(self, settings: str, notch: str) -> None:
        """Show the system-wide shortcuts beside their items, as a Mac menu
        shows key equivalents (a tab puts them in the shortcut column)."""
        from . import hotkeys
        for action, title, text in ((self.settings_action, "Settings…", settings),
                                    (self.notch_action, "Open the Notch", notch)):
            key = hotkeys.label(text)
            action.setText(f"{title}\t{key}" if key else title)

    def _sync(self) -> None:
        on = bool(getattr(self.store.value, "show_pill", True))
        if self.pill_action.isChecked() != on:
            self.pill_action.blockSignals(True)
            self.pill_action.setChecked(on)
            self.pill_action.blockSignals(False)

    def _activated(self, reason) -> None:
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
            self.overlay.show_sessions()

    def _set_paused(self, on: bool) -> None:
        if self.paused is not None:
            (self.paused.set if on else self.paused.clear)()
        self._refresh_status()

    def set_listening(self, listening: bool, why: str = "") -> None:
        self.listening = listening
        self._refresh_status(why)

    def _refresh_status(self, why: str = "") -> None:
        if not self.listening:
            text = f"Not listening: {why}" if why else "Not listening"
        elif self.pause_action.isChecked():
            text = "Paused: Claude Code asks in the terminal"
        else:
            text = "Listening on 127.0.0.1:53127"
        self.status_action.setText(text)
        self.setToolTip(f"ClaudeNotch: {text}" if text != "Listening on 127.0.0.1:53127" else "ClaudeNotch")
