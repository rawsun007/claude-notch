"""The Settings window: same pages and wording as the Linux edition.

General, Notifications, Claude Code, Always allow, About. A plain QWidget
with a list on the left and the pages on the right. Qt 6.7's windows11
style follows the system's light or dark mode by itself, so no colours are
set here; only the overlay is always black.
"""

from __future__ import annotations

import os
import webbrowser

from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices, QIcon, QPalette
from PySide6.QtWidgets import (QCheckBox, QComboBox, QHBoxLayout, QLabel, QListWidget, QPushButton, QScrollArea,
                               QStackedWidget, QVBoxLayout, QWidget)

from claudenotch import hooks

from . import __version__, autostart, paths, winstatus

GITHUB = "https://github.com/rawsun007/claude-notch"
POSITIONS = [("top", "Top centre"), ("bottom-right", "Bottom right, above the tray")]


def _note(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setTextFormat(Qt.PlainText)
    lbl.setWordWrap(True)
    lbl.setForegroundRole(QPalette.PlaceholderText)   # the theme's secondary text colour
    return lbl


def _heading(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setTextFormat(Qt.PlainText)
    font = lbl.font()
    font.setPointSizeF(font.pointSizeF() * 1.35)
    font.setBold(True)
    lbl.setFont(font)
    return lbl


class SettingsWindow(QWidget):
    _instance: "SettingsWindow | None" = None

    PAGES = ["General", "Notifications", "Claude Code", "Always allow", "About"]

    @classmethod
    def present(cls, state, store, page: str | None = None, on_quit=None) -> "SettingsWindow":
        """Open the one Settings window, or bring it forward."""
        if cls._instance is None:
            cls._instance = SettingsWindow(state, store, on_quit)
        w = cls._instance
        if page in cls.PAGES:
            w.nav.setCurrentRow(cls.PAGES.index(page))
        w.refresh()
        w.show()
        w.setWindowState((w.windowState() & ~Qt.WindowMinimized) | Qt.WindowActive)
        w.raise_()
        w.activateWindow()
        return w

    def __init__(self, state, store, on_quit=None):
        super().__init__(None)
        self.state, self.store, self.on_quit = state, store, on_quit
        self.checks: dict[str, QCheckBox] = {}
        self._refreshing = False
        self.setWindowTitle("ClaudeNotch Settings")
        self.setWindowIcon(QIcon(paths.resource("ClaudeNotch.ico")))
        self.resize(720, 480)

        self.nav = QListWidget()
        self.nav.addItems(self.PAGES)
        self.nav.setFixedWidth(170)
        self.stack = QStackedWidget()
        for build in (self._page_general, self._page_notifications, self._page_claude, self._page_rules,
                      self._page_about):
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(QScrollArea.NoFrame)
            scroll.setWidget(build())
            self.stack.addWidget(scroll)
        self.nav.currentRowChanged.connect(self.stack.setCurrentIndex)
        self.nav.setCurrentRow(0)

        root = QHBoxLayout(self)
        root.addWidget(self.nav)
        root.addWidget(self.stack, 1)

        # The rules list changes when a card is answered with Always allow.
        state.subscribe(lambda: QTimer.singleShot(0, self._refresh_rules_if_open))

    # --- building blocks ------------------------------------------------------------

    def _page(self) -> tuple[QWidget, QVBoxLayout]:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(22, 22, 22, 22)
        v.setSpacing(10)
        return page, v

    def _switch_row(self, v: QVBoxLayout, key: str, title: str, note: str, on_set=None) -> QCheckBox:
        box = QCheckBox(title)
        box.setObjectName(f"switch-{key}")

        def changed(on: bool) -> None:
            if self._refreshing:
                return    # set to match the settings; not a click
            if on_set is not None:
                on_set(on)
            else:
                self.store.update(**{key: on})
            self.refresh()

        box.toggled.connect(changed)
        v.addWidget(box)
        if note:
            n = _note(note)
            n.setContentsMargins(24, 0, 0, 6)
            v.addWidget(n)
        self.checks[key] = box
        return box

    # --- pages ------------------------------------------------------------------------

    def _page_general(self) -> QWidget:
        page, v = self._page()
        v.addWidget(_heading("General"))
        self._switch_row(v, "start_at_login", "Start at login",
                         "Open ClaudeNotch when you sign in to Windows, so prompts reach it from the first session.",
                         on_set=self._set_autostart)
        self._switch_row(v, "greeting", "Say hello at start",
                         "Show \"ClaudeNotch is running\" for a few seconds after it starts.")
        self._switch_row(v, "hover_sessions", "Show sessions on hover",
                         "Pointing at the pill opens the list of Claude Code sessions.")
        self._switch_row(v, "toasts", "Show session updates",
                         "A short note in the pill when a session finishes or Claude Code sends a notice.")
        self._switch_row(v, "show_pill", "Show the pill when idle",
                         "Off: only cards that need an answer appear. The tray icon stays either way.")
        self._switch_row(v, "hide_in_fullscreen", "Hide the pill over fullscreen apps",
                         "Games, videos and presentations. A card that needs an answer still shows.")
        row = QHBoxLayout()
        row.addWidget(QLabel("Where the pill sits"))
        self.position = QComboBox()
        for value, text in POSITIONS:
            self.position.addItem(text, value)
        self.position.currentIndexChanged.connect(self._set_position)
        row.addWidget(self.position)
        row.addStretch(1)
        v.addLayout(row)
        self.general_error = _note("")
        v.addWidget(self.general_error)
        v.addStretch(1)
        return page

    def _page_notifications(self) -> QWidget:
        page, v = self._page()
        v.addWidget(_heading("Notifications"))
        v.addWidget(_note("Permission and question cards always appear in the pill. These also send them to "
                          "Windows notifications, which helps when the pill is on another screen or behind a "
                          "fullscreen window. They are off unless you want them."))
        self._switch_row(v, "desktop_notifications", "Notify for every card",
                         "A Windows notification for each permission request and question.")
        self._switch_row(v, "notify_dangerous_only", "Notify for dangerous calls only",
                         "Just for calls that get the red warning, such as Remove-Item -Recurse -Force.")
        v.addStretch(1)
        return page

    def _page_claude(self) -> QWidget:
        page, v = self._page()
        v.addWidget(_heading("Claude Code hooks"))
        v.addWidget(_note("ClaudeNotch hears from Claude Code through hooks in its settings file. Your own hooks "
                          "are kept, and a backup is written before any change. Sessions read the hooks when they "
                          "start, so a session that was already open needs restarting."))
        self.hooks_status = QLabel()
        self.hooks_status.setTextFormat(Qt.PlainText)
        self.hooks_status.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.hooks_status.setWordWrap(True)
        v.addWidget(self.hooks_status)
        row = QHBoxLayout()
        self.install_btn = QPushButton("Install hooks")
        self.install_btn.clicked.connect(lambda: self._hooks(winstatus.install_hooks))
        self.remove_btn = QPushButton("Remove hooks")
        self.remove_btn.clicked.connect(lambda: self._hooks(hooks.uninstall))
        open_btn = QPushButton("Open settings.json folder")
        open_btn.clicked.connect(lambda: _open(os.path.dirname(hooks.settings_path())))
        row.addWidget(self.install_btn)
        row.addWidget(self.remove_btn)
        row.addWidget(open_btn)
        row.addStretch(1)
        v.addLayout(row)
        self.hooks_error = _note("")
        v.addWidget(self.hooks_error)
        v.addStretch(1)
        return page

    def _page_rules(self) -> QWidget:
        page, v = self._page()
        v.addWidget(_heading("Always allow"))
        v.addWidget(_note("Calls you allowed with Always allow are answered without a card. Dangerous calls "
                          "never are, whatever is listed here."))
        self.rules_box = QVBoxLayout()
        self.rules_box.setSpacing(4)
        v.addLayout(self.rules_box)
        v.addStretch(1)
        self._refresh_rules()
        return page

    def _page_about(self) -> QWidget:
        page, v = self._page()
        v.addWidget(_heading("ClaudeNotch for Windows"))
        v.addWidget(QLabel(f"Version {__version__}"))
        v.addWidget(_note(f"Log: {paths.log_path()}\nSettings: {paths.config_dir()}\n"
                          f"Claude Code settings: {hooks.settings_path()}"))
        row = QHBoxLayout()
        log_btn = QPushButton("Open log")
        log_btn.clicked.connect(lambda: _open(paths.log_path()))
        site = QPushButton("Project page")
        site.clicked.connect(lambda: webbrowser.open(GITHUB))
        quit_btn = QPushButton("Quit ClaudeNotch")
        quit_btn.clicked.connect(lambda: self.on_quit and self.on_quit())
        row.addWidget(log_btn)
        row.addWidget(site)
        row.addStretch(1)
        row.addWidget(quit_btn)
        v.addLayout(row)
        v.addStretch(1)
        return page

    # --- state ------------------------------------------------------------------------

    def refresh(self) -> None:
        self._refreshing = True
        try:
            self._refresh()
        finally:
            self._refreshing = False

    def _refresh(self) -> None:
        v = self.store.value
        try:
            start = autostart.enabled()
        except OSError:
            start = v.start_at_login
        values = {
            "start_at_login": start,
            "greeting": v.greeting,
            "hover_sessions": v.hover_sessions,
            "toasts": v.toasts,
            "show_pill": v.show_pill,
            "hide_in_fullscreen": v.hide_in_fullscreen,
            "desktop_notifications": v.desktop_notifications,
            "notify_dangerous_only": v.notify_dangerous_only,
        }
        for key, value in values.items():
            box = self.checks.get(key)
            if box is not None and box.isChecked() != value:
                box.setChecked(value)
        # Every card already notifies; the narrower switch means nothing then.
        self.checks["notify_dangerous_only"].setEnabled(not v.desktop_notifications)
        idx = self.position.findData(v.position)
        if idx >= 0 and idx != self.position.currentIndex():
            self.position.setCurrentIndex(idx)
        on = hooks.installed()
        self.hooks_status.setText(f"{'Installed' if on else 'Not installed'} in {hooks.settings_path()}")
        self.install_btn.setText("Reinstall hooks" if on else "Install hooks")
        self.remove_btn.setEnabled(on)
        self._refresh_rules()

    def _refresh_rules_if_open(self) -> None:
        if self.isVisible():
            self._refresh_rules()

    def _refresh_rules(self) -> None:
        while self.rules_box.count():
            item = self.rules_box.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()
        rules = list(self.state.rules)
        if not rules:
            self.rules_box.addWidget(_note("Nothing yet. Use Always allow on a card to add one."))
        for rule in rules:
            row = QWidget()
            h = QHBoxLayout(row)
            h.setContentsMargins(0, 0, 0, 0)
            lbl = QLabel(rule.label())
            lbl.setTextFormat(Qt.PlainText)
            lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
            btn = QPushButton("Remove")
            btn.clicked.connect(lambda _=False, r=rule: self.state.remove_rule(r))
            h.addWidget(lbl, 1)
            h.addWidget(btn)
            self.rules_box.addWidget(row)

    def _set_position(self, _index: int) -> None:
        if self._refreshing:
            return
        value = self.position.currentData()
        if value and value != self.store.value.position:
            self.store.update(position=value)

    def _set_autostart(self, on: bool) -> None:
        try:
            autostart.set_enabled(on)
            self.general_error.setText("")
        except OSError as e:
            self.general_error.setText(f"Could not change start at login: {e.strerror or e}")
        self.store.update(start_at_login=on)

    def _hooks(self, action) -> None:
        try:
            action()
            self.hooks_error.setText("")
        except hooks.UnreadableSettings as e:
            self.hooks_error.setText(str(e))
        self.refresh()

    def closeEvent(self, event) -> None:
        # Closing hides; the app keeps running in the tray.
        event.ignore()
        self.hide()


def _open(path: str) -> None:
    """Open a local file or folder with its default app. Only our own paths
    reach here, never one from a hook payload."""
    if os.path.exists(path):
        QDesktopServices.openUrl(QUrl.fromLocalFile(path))
