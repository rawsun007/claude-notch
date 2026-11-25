"""The first-run window, the Mac's Onboarding: a list of choices, each with
a switch that starts on, and one button to start.

- Connect Claude Code (required): the hooks and the status line.
- Launch at login.
- Auto-approve everything: tool requests run without a card; the notch
  shows what ran.
- Destructive commands too: also approved without asking (the project
  owner's default; every one is logged in History).
- Use the macOS sounds: downloads Apple's sound files (macsounds) into the
  user's own sound folder.

Closing the window keeps everything as it was and does not come back; the
same switches are in Settings.
"""

from __future__ import annotations

import threading

from PySide6.QtCore import QObject, Qt, Signal
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QHBoxLayout, QVBoxLayout, QWidget

from claudenotch import hooks

from . import autostart, macsounds, paths, winstatus
from . import settingskit as kit

TIP = ("ClaudeNotch sits at the top centre of your screen and in the tray (Windows may tuck new tray icons "
       "under the ^ arrow). Ctrl+Alt+, opens Settings from anywhere.")


class _Sounds(QObject):
    done = Signal(int, list)


class Onboarding(QWidget):
    _instance: "Onboarding | None" = None

    @classmethod
    def present(cls, state, store, overlay=None) -> "Onboarding":
        if cls._instance is None:
            cls._instance = Onboarding(state, store, overlay)
        w = cls._instance
        w.show()
        w.raise_()
        w.activateWindow()
        return w

    def __init__(self, state, store, overlay=None, parent=None):
        super().__init__(parent)
        self.state, self.store, self.overlay = state, store, overlay
        self.finished = False
        self.t = t = kit.theme()
        self.setWindowTitle("Welcome")
        self.setWindowIcon(QIcon(paths.resource("ClaudeNotch.ico")))
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.setStyleSheet(f"background: {kit.css(t.window)};")
        self.setMinimumWidth(560)

        v = QVBoxLayout(self)
        v.setContentsMargins(28, 26, 28, 22)
        v.setSpacing(10)
        v.addWidget(kit.label("Welcome to ClaudeNotch", 22, "semibold", color=t.text))
        v.addWidget(kit.label("Your Claude Code prompts, questions and status in a notch at the top of your "
                              "screen. Choose how it should work; every switch is in Settings later too.",
                              13, color=t.secondary, wrap=True))
        v.addSpacing(6)

        card = kit.Card(t)
        self.switches: dict[str, kit.Switch] = {}

        def row(key: str, title: str, subtitle: str, on: bool = True, locked: bool = False, danger: bool = False):
            sw = kit.Switch(t)
            sw.setChecked(on)
            sw.setEnabled(not locked)
            r = card.add(kit.Row(t, title, subtitle, sw))
            if danger:
                r.title.setStyleSheet(f"color: {kit.css(kit.QColor(255, 69, 58))}; background: transparent;")
            self.switches[key] = sw
            return r

        row("hooks", "Connect Claude Code",
            "Required. Sends permission prompts, questions and status to the notch, for the terminal and the VS "
            "Code extension. Your Claude Code settings are backed up first.", locked=True)
        row("login", "Launch at login", "Start ClaudeNotch when you sign in to Windows, so it is always ready.")
        row("auto", "Auto-approve everything",
            "Tool requests run without a card; the notch shows what ran. Turn it off any time in Settings.")
        self.danger_row = row(
            "danger", "Destructive commands too",
            "Remove-Item -Recurse, rd /s, git push --force and the like also run without asking. Every one is "
            "logged in History.", danger=True)
        row("sounds", "Use the macOS sounds",
            f"Downloads Apple's macOS sounds (about 4.6 MB) from {macsounds.SOURCE_PAGE.replace('https://', '')} "
            "into your sound folder. Off: the app's own sounds.")
        self.switches["auto"].toggled.connect(self._auto_changed)
        v.addWidget(card)

        self.status = kit.label("", 12, color=t.secondary, wrap=True)
        self.status.hide()
        v.addWidget(self.status)
        v.addWidget(kit.label(TIP, 12, color=t.secondary, wrap=True))
        v.addSpacing(6)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        self.start = kit.PushButton(t, "Start using ClaudeNotch", primary=True)
        self.start.clicked.connect(self.finish)
        buttons.addWidget(self.start)
        box = QWidget()
        box.setLayout(buttons)
        v.addWidget(box)
        self._sounds = _Sounds()
        self._sounds.done.connect(self._sounds_done)
        # As tall as its content at this width: a wrapped label alone asks for
        # more height than it needs, which left gaps between the rows.
        self.resize(600, max(420, self.layout().heightForWidth(600)))

    def _auto_changed(self, on: bool) -> None:
        sw = self.switches["danger"]
        sw.setEnabled(on)
        if not on:
            sw.setChecked(False)

    def choices(self) -> dict:
        s = self.switches
        auto = s["auto"].isChecked()
        return {"start_at_login": s["login"].isChecked(), "auto_approve": auto,
                "auto_approve_scope": "everything",
                "auto_approve_dangerous": "allow" if auto and s["danger"].isChecked() else "ask",
                "sounds": s["sounds"].isChecked()}

    def finish(self) -> None:
        """Apply the switches, then say hello in the notch."""
        c = self.choices()
        problems = []
        try:
            winstatus.install_hooks()
        except hooks.UnreadableSettings as e:
            problems.append(str(e))
        try:
            autostart.set_enabled(c["start_at_login"])
        except OSError as e:
            problems.append(f"Launch at login: {e.strerror or e}")
        self.store.update(start_at_login=c["start_at_login"], auto_approve=c["auto_approve"],
                          auto_approve_scope=c["auto_approve_scope"],
                          auto_approve_dangerous=c["auto_approve_dangerous"], onboarded=True)
        self.finished = True
        if problems:
            self.status.setText(" ".join(problems))
            self.status.show()
        if c["sounds"]:
            self.status.setText("Downloading the macOS sounds…")
            self.status.show()
            self.start.setEnabled(False)
            threading.Thread(target=lambda: self._sounds.done.emit(*macsounds.download()), daemon=True,
                             name="mac-sounds").start()
            return
        self._close_with_hello()

    def _sounds_done(self, have: int, failed: list) -> None:
        if failed and self.state is not None:
            self.state.notice("Some macOS sounds did not download",
                              f"{have} of {len(macsounds.NAMES)} are in place. Try again in Settings > Sounds.")
        self._close_with_hello()

    def _close_with_hello(self) -> None:
        if self.state is not None:
            self.state.greet()
        self.close()

    def closeEvent(self, event) -> None:
        if not self.finished:
            # Closed without choosing: nothing changes, and it does not nag.
            self.store.update(onboarded=True)
        Onboarding._instance = None
        super().closeEvent(event)
