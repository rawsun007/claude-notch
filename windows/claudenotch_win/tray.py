"""The tray icon: where Windows people look for a background app.

Left click opens the session list (as hovering the pill does). The menu has
Settings, Pause, Show the pill and Quit. The icon follows the taskbar's
theme: a white mark on a dark taskbar, a black one on a light taskbar.

Pause: hooks answer "no opinion" straight away, so Claude Code asks in its
own terminal, as if ClaudeNotch were not running. Nothing is queued.
"""

from __future__ import annotations

from PySide6.QtCore import QTimer, Signal
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QMenu, QSystemTrayIcon

from . import paths, winutil


def tray_icon() -> QIcon:
    name = "tray-black.png" if winutil.system_uses_light_theme() else "tray-white.png"
    return QIcon(paths.resource(name))


class Tray(QSystemTrayIcon):
    #: The standup text, built on a worker thread (git), back on the GUI thread.
    standup_ready = Signal(str)

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
        # The Mac's "Update available" item: hidden until a check finds one.
        self.update_action = menu.addAction("Update available", self._open_update)
        self.update_action.setVisible(False)
        self._update_page = ""
        menu.addSeparator()
        # The Mac's quick task actions, above Settings.
        menu.addAction("Start Claude in Folder…", self.start_in_folder)
        self.resume_action = menu.addAction("Resume Last Session", self.resume_last)
        menu.addAction("Copy Today's Standup", self.copy_standup)
        menu.addSeparator()
        self.notch_action = menu.addAction("Open the Notch", lambda: overlay.show_sessions(8))
        self.history_action = menu.addAction("History", overlay.open_history)
        self.compose_action = menu.addAction("Send to Claude…", overlay.begin_compose)
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
        menu.aboutToShow.connect(self._refresh_resume)
        self.standup_ready.connect(self._standup_done)
        self._menu = menu               # QSystemTrayIcon does not own the menu
        self.setContextMenu(menu)
        self.activated.connect(self._activated)
        store.subscribe(lambda s: QTimer.singleShot(0, self._sync))

        # The taskbar theme can change while we run.
        self._theme_timer = QTimer(self, interval=5000)
        self._theme_timer.timeout.connect(lambda: self.setIcon(tray_icon()))
        self._theme_timer.start()

    def show_update(self, version: str, page: str) -> None:
        from claudenotch import updatecheck
        if not page.startswith(updatecheck.PAGE_PREFIX):
            return
        first = not self.update_action.isVisible()
        self._update_page = page
        self.update_action.setText(f"Update available: {version}")
        self.update_action.setVisible(True)
        if first:
            self.showMessage("ClaudeNotch update", f"ClaudeNotch {version} is out. Open the tray menu to get it.")

    def _open_update(self) -> None:
        from claudenotch import updatecheck
        if self._update_page.startswith(updatecheck.PAGE_PREFIX):
            import webbrowser
            webbrowser.open(self._update_page)

    # --- quick task actions (MenuBarController) -------------------------------------------

    def _last(self):
        """The newest archived session that can be resumed here."""
        import os
        from . import terminal
        archive = getattr(self.overlay.state, "archive", None)
        for r in (archive.newest_first() if archive is not None else [])[:20]:
            if r.id and terminal.claude_command(r.id) and os.path.isdir(r.cwd or ""):
                return r
        return None

    def _refresh_resume(self) -> None:
        r = self._last()
        self.resume_action.setEnabled(r is not None)
        self.resume_action.setText(f"Resume Last Session: {r.project}" if r else "Resume Last Session")

    def resume_last(self) -> None:
        from . import terminal
        r = self._last()
        if r is not None and not terminal.launch(r.cwd, r.id):
            self.showMessage("ClaudeNotch", "Could not open a terminal to resume that session.")

    def start_in_folder(self) -> None:
        from PySide6.QtWidgets import QFileDialog
        from . import terminal
        folder = QFileDialog.getExistingDirectory(None, "Start Claude here")
        if folder and not terminal.launch(folder):
            self.showMessage("ClaudeNotch", "Could not open a terminal in that folder.")

    def copy_standup(self) -> None:
        import threading
        from claudenotch import standup
        state = self.overlay.state
        records = list(state.archive.newest_first()) if getattr(state, "archive", None) else []

        def work() -> None:
            self.standup_ready.emit(standup.text(records, standup.commits))

        threading.Thread(target=work, daemon=True).start()

    def _standup_done(self, text: str) -> None:
        from PySide6.QtGui import QGuiApplication
        from claudenotch.state import Toast as toast_cls
        QGuiApplication.clipboard().setText(text)
        state = self.overlay.state
        with state._lock:
            state.toasts = (state.toasts + [toast_cls("Standup copied", "Today's \"what I shipped\" is on your "
                                                      "clipboard.", kind="done")])[-8:]
        state._changed()

    def set_shortcuts(self, settings: str, notch: str, history: str = "", compose: str = "") -> None:
        """Show the system-wide shortcuts beside their items, as a Mac menu
        shows key equivalents (a tab puts them in the shortcut column)."""
        from . import hotkeys
        for action, title, text in ((self.settings_action, "Settings…", settings),
                                    (self.notch_action, "Open the Notch", notch),
                                    (self.history_action, "History", history),
                                    (self.compose_action, "Send to Claude…", compose)):
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
