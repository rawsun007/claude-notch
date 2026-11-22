"""The Settings window: the Mac's SettingsWindow, page for page.

A sidebar grouped the Mac's way (Workspace, Session, Alerts & Cost, Info,
Permissions) with a search field above it, and pages with a large title
over rounded cards of rows. Built from settingskit, in Windows' light or
dark mode. Every page reads the settings store and writes back through it,
so a change made here reaches the notch at once.

Settings that make destructive commands easier to run (Skip confirmation,
and Auto-Approve's Approve them too) ask the owner first: Windows Hello, or
Windows' own password prompt (ownerauth).
"""

from __future__ import annotations

import os
import webbrowser

from PySide6.QtCore import QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import (QButtonGroup, QComboBox, QDialog, QHBoxLayout, QRadioButton, QScrollArea,
                               QStackedWidget, QVBoxLayout, QWidget)

from claudenotch import autoapprove, hooks

from . import __version__, autostart, hello, ownerauth, paths, winstatus
from . import settingscharts as charts
from . import settingskit as kit
from claudenotch import usage as usage_mod

GITHUB = "https://github.com/rawsun007/claude-notch"
POSITIONS = [("top", "Top centre"), ("bottom-right", "Bottom right, above the tray")]

#: (group title, [(key, title, glyph)]), the Mac's SettingsSection.nav.
NAV = [
    ("Workspace", [("general", "General", "gearshape"), ("notch", "Notch", "menubar.rectangle"),
                   ("pet", "Pet", "pawprint")]),
    ("Session", [("session", "Session", "text.bubble"), ("skills", "Skills", "wand.and.stars.nav")]),
    ("Alerts & Cost", [("alerts", "Alerts", "bell.badge"), ("sounds", "Sounds", "speaker.wave.2"),
                       ("budget", "Budget", "dollarsign.circle"),
                       ("plan", "Plan", "creditcard")]),
    ("Info", [("usage", "Usage", "chart.bar"), ("history", "History", "clock.arrow.circlepath"),
              ("privacy", "Privacy", "lock.shield"),
              ("about", "About", "info.circle")]),
    ("Permissions", [("rules", "Rules", "checkmark.shield")]),
    ("Advanced", [("developer", "Developer", "hammer")]),
]

SEARCH = [
    kit.SearchItem("Launch at login", "startup boot open start", "general"),
    kit.SearchItem("Say hello at start", "greeting running", "general"),
    kit.SearchItem("Auto-approve permissions", "allow automatic bypass dangerous destructive", "general"),
    kit.SearchItem("Setup health", "hooks status line forwarder fix install", "general"),
    kit.SearchItem("Where the notch sits", "position top bottom tray corner", "notch"),
    kit.SearchItem("Keep the notch open", "persistent always show display", "notch"),
    kit.SearchItem("Show sessions on hover", "hover open list", "notch"),
    kit.SearchItem("Show the notch when idle", "hide idle pill", "notch"),
    kit.SearchItem("Hide over fullscreen apps", "game video presentation", "notch"),
    kit.SearchItem("Pet Mode", "mascot creature animation boop", "pet"),
    kit.SearchItem("Auto-approve for a while", "timed window minutes", "session"),
    kit.SearchItem("Skills", "skill skills slash command plugin context listing tokens disable enable off trash delete restore",
                   "skills"),
    kit.SearchItem("Free up skill context", "skills unused name only tokens budget listing", "skills"),
    kit.SearchItem("Snooze passive cards", "mute pause quiet", "session"),
    kit.SearchItem("Completion and notification cards", "done finished notice toast", "alerts"),
    kit.SearchItem("Windows notifications", "toast banner action center", "alerts"),
    kit.SearchItem("Plan-limit warnings", "rate limit 80 95 percent", "alerts"),
    kit.SearchItem("Plan limits", "5 hour weekly limit resets percent pro max", "plan"),
    kit.SearchItem("Cost caps", "budget session day dollars limit", "budget"),
    kit.SearchItem("Mute all sounds", "silence quiet", "sounds"),
    kit.SearchItem("Per-tool sounds", "pop up chime bash edit powershell", "sounds"),
    kit.SearchItem("Alert sound", "chime ding notify", "sounds"),
    kit.SearchItem("Hard-stop at the cap", "block enforce budget", "budget"),
    kit.SearchItem("Hide from screen capture", "recording screenshot privacy share", "privacy"),
    kit.SearchItem("Require Windows Hello", "biometric fingerprint face pin touch id", "privacy"),
    kit.SearchItem("Skip confirmation for destructive commands",
                   "bypass hello biometric hold dangerous destructive one click lock", "privacy"),
    kit.SearchItem("Always-allow rules", "allowlist permissions approved automatically rule", "rules"),
    kit.SearchItem("Version and logs", "about log folder github", "about"),
    kit.SearchItem("Demo cards", "test preview developer permission dangerous diff question", "developer"),
    kit.SearchItem("Activity heatmap", "usage graph history days", "usage"),
    kit.SearchItem("Token usage and cost", "spend dollars money tokens model", "usage"),
    kit.SearchItem("Estimated cost, last 7 days", "trend chart spend week", "usage"),
    kit.SearchItem("Top tools", "bash edit counts stats", "usage"),
    kit.SearchItem("Export usage", "csv download", "usage"),
    kit.SearchItem("Session history", "past sessions log what i did search recall project", "history"),
    kit.SearchItem("Export session history", "csv json download sessions", "history"),
]

TITLES = {key: title for _, items in NAV for key, title, _ in items}


class _Bridge(QObject):
    authed = Signal(str, bool, object)     # what, ok, message
    usage = Signal(object)                 # a usage.Usage, read off the GUI thread


class SettingsWindow(QWidget):
    _instance: "SettingsWindow | None" = None

    @classmethod
    def present(cls, state, store, page: str | None = None, on_quit=None, overlay=None) -> "SettingsWindow":
        """Open the one Settings window, or bring it forward, on `page`
        (a key such as "privacy", or a title such as "Privacy")."""
        if cls._instance is None:
            cls._instance = SettingsWindow(state, store, on_quit, overlay)
        w = cls._instance
        if page:
            key = page.lower() if page.lower() in TITLES else next(
                (k for k, t in TITLES.items() if t.lower() == page.lower()), None)
            if key:
                w.show_page(key)
        w.refresh()
        w.show()
        w.setWindowState((w.windowState() & ~Qt.WindowMinimized) | Qt.WindowActive)
        w.raise_()
        w.activateWindow()
        return w

    def __init__(self, state, store, on_quit=None, overlay=None):
        super().__init__(None)
        self.state, self.store, self.on_quit, self.overlay = state, store, on_quit, overlay
        self.t = kit.theme()
        self.switches: dict[str, kit.Switch] = {}
        self.pages: dict[str, int] = {}
        self.nav_items: dict[str, kit.NavItem] = {}
        self.messages: dict[str, kit.QLabel] = {}
        self._bridge = _Bridge()
        self._bridge.authed.connect(self._authed)
        self._bridge.usage.connect(self._fill_usage)
        self._usage_busy = False
        self.setWindowTitle("Settings")      # Qt adds " - ClaudeNotch"
        self.setWindowIcon(QIcon(paths.resource("ClaudeNotch.ico")))
        self.resize(880, 640)
        self.setMinimumSize(720, 480)
        self.setAutoFillBackground(True)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), self.t.window)
        self.setPalette(pal)

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(self._sidebar())
        self.stack = QStackedWidget()
        root.addWidget(self.stack, 1)
        for key, build in (("general", self._page_general), ("notch", self._page_notch), ("pet", self._page_pet),
                           ("session", self._page_session), ("skills", self._page_skills),
                           ("alerts", self._page_alerts),
                           ("plan", self._page_plan), ("budget", self._page_budget),
                           ("sounds", self._page_sounds),
                           ("usage", self._page_usage), ("history", self._page_history),
                           ("privacy", self._page_privacy), ("about", self._page_about),
                           ("rules", self._page_rules), ("developer", self._page_developer)):
            self.pages[key] = self.stack.addWidget(self._scroll(build()))
        self.show_page("general")

        self._tick = QTimer(self, interval=1000)
        self._tick.timeout.connect(self._refresh_live)
        self._tick.start()
        state.subscribe(lambda: QTimer.singleShot(0, self._refresh_rules_if_open))
        if store is not None:
            store.subscribe(lambda _s: QTimer.singleShot(0, self.refresh))

    # --- frame ----------------------------------------------------------------------

    def _sidebar(self) -> QWidget:
        side = QWidget()
        side.setFixedWidth(220)
        side.setAutoFillBackground(True)
        pal = side.palette()
        pal.setColor(side.backgroundRole(), self.t.sidebar)
        side.setPalette(pal)
        v = QVBoxLayout(side)
        v.setContentsMargins(10, 14, 10, 14)
        v.setSpacing(2)
        self.search = kit.SearchField(self.t)
        self.search.changed.connect(self._search)
        v.addWidget(self.search)
        v.addSpacing(8)
        self.nav_box = QWidget()
        nb = QVBoxLayout(self.nav_box)
        nb.setContentsMargins(0, 0, 0, 0)
        nb.setSpacing(1)
        for group, items in NAV:
            head = kit.label(group, 11, "semibold", self.t.secondary)
            head.setContentsMargins(10, 8, 0, 2)
            nb.addWidget(head)
            for key, title, glyph in items:
                item = kit.NavItem(self.t, key, title, glyph)
                item.clicked.connect(lambda _=False, k=key: self.show_page(k))
                nb.addWidget(item)
                self.nav_items[key] = item
        v.addWidget(self.nav_box)
        self.results = QWidget()
        self.results_lay = QVBoxLayout(self.results)
        self.results_lay.setContentsMargins(0, 0, 0, 0)
        self.results_lay.setSpacing(1)
        self.results.hide()
        v.addWidget(self.results)
        v.addStretch(1)
        return side

    def _scroll(self, page: QWidget) -> QScrollArea:
        sc = QScrollArea()
        sc.setWidgetResizable(True)
        sc.setFrameShape(QScrollArea.NoFrame)
        sc.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        sc.setStyleSheet(f"QScrollArea {{ background: {kit.css(self.t.window)}; }}")
        page.setAutoFillBackground(True)
        pal = page.palette()
        pal.setColor(page.backgroundRole(), self.t.window)
        page.setPalette(pal)
        sc.setWidget(page)
        return sc

    def _page(self, title: str) -> tuple[QWidget, QVBoxLayout]:
        """page(title): a large bold title, then 18 between blocks."""
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(28, 24, 28, 28)
        v.setSpacing(18)
        head = QHBoxLayout()
        head.addWidget(kit.label(title, 26, "bold", self.t.text))
        head.addStretch(1)
        head.addWidget(kit.label(f"v{__version__}", 11, color=self.t.secondary))
        v.addLayout(head)
        return page, v

    def show_page(self, key: str) -> None:
        if key not in self.pages:
            return
        if key == "usage":
            self._load_usage()
        if key == "history":
            self._fill_history()
        if key == "plan":
            self._fill_plan()
        if key == "skills":
            self._fill_skills()
        self.stack.setCurrentIndex(self.pages[key])
        for k, item in self.nav_items.items():
            item.setChecked(k == key)
        self.current = key

    def _search(self, text: str) -> None:
        while self.results_lay.count():
            w = self.results_lay.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        hits = kit.search(SEARCH, text)
        searching = bool(text.strip())
        self.nav_box.setVisible(not searching)
        self.results.setVisible(searching)
        if searching and not hits:
            self.results_lay.addWidget(kit.label("No matching settings", 12, color=self.t.secondary))
        for it in hits:
            glyph = next(g for _, items in NAV for k, _, g in items if k == it.section)
            row = kit.NavItem(self.t, it.section, it.title, glyph)
            row.clicked.connect(lambda _=False, k=it.section: (self.show_page(k), self.search.edit.clear()))
            self.results_lay.addWidget(row)

    # --- rows ---------------------------------------------------------------------------

    def _switch(self, key: str, on_set=None) -> kit.Switch:
        sw = kit.Switch(self.t)

        def changed(on: bool) -> None:
            if on_set is not None:
                on_set(on)
            else:
                self.store.update(**{key: on})
            QTimer.singleShot(0, self.refresh)

        sw.toggled.connect(changed)
        self.switches[key] = sw
        return sw

    def _toggle_row(self, card: kit.Card, key: str, title: str, subtitle: str, on_set=None) -> kit.Row:
        return card.add(kit.Row(self.t, title, subtitle, self._switch(key, on_set)))

    def _message(self, key: str, v: QVBoxLayout) -> kit.QLabel:
        lbl = kit.label("", 11, color=kit.QColor(255, 69, 58), wrap=True)
        lbl.hide()
        v.addWidget(lbl)
        self.messages[key] = lbl
        return lbl

    def _say(self, key: str, text: str | None) -> None:
        lbl = self.messages.get(key)
        if lbl is not None:
            lbl.setText(text or "")
            lbl.setVisible(bool(text))

    # --- General --------------------------------------------------------------------------

    def _page_general(self) -> QWidget:
        page, v = self._page("General")
        card = kit.Card(self.t)
        self._toggle_row(card, "start_at_login", "Launch at login",
                         "Open ClaudeNotch when you sign in to Windows, so prompts reach it from the first session.",
                         on_set=self._set_autostart)
        self._toggle_row(card, "greeting", "Say hello at start",
                         "Show \"ClaudeNotch is running\" for a few seconds after it starts.")
        v.addWidget(card)
        self._message("general", v)

        v.addWidget(kit.section_label(self.t, "Auto-Approve"))
        auto = kit.Card(self.t)
        change = kit.PushButton(self.t, "Change…")
        change.clicked.connect(lambda: self._auto_approve_sheet(editing=True))
        row = auto.add(kit.Row(self.t, "Auto-approve permissions", "", self._switch(
            "auto_approve", on_set=self._set_auto_approve)))
        self.auto_summary = row.subtitle or kit.label("", 11, color=self.t.secondary, wrap=True)
        if row.subtitle is None:
            row.layout().itemAt(0).layout().addWidget(self.auto_summary)
        row.layout().insertWidget(1, change)
        v.addWidget(auto)

        v.addWidget(kit.section_label(self.t, "Setup health"))
        health = kit.Card(self.t)
        self.hooks_row = health.add(kit.Row(self.t, "Claude Code hooks", " "))
        self.status_row = health.add(kit.Row(self.t, "Status line", " "))
        buttons = QHBoxLayout()
        buttons.setContentsMargins(14, 6, 14, 8)
        self.install_btn = kit.PushButton(self.t, "Install hooks", primary=True)
        self.install_btn.clicked.connect(lambda: self._hooks(winstatus.install_hooks))
        self.remove_btn = kit.PushButton(self.t, "Remove hooks", destructive=True)
        self.remove_btn.clicked.connect(lambda: self._hooks(hooks.uninstall))
        folder = kit.PushButton(self.t, "Open Claude Code settings folder")
        folder.clicked.connect(lambda: _open(os.path.dirname(hooks.settings_path())))
        buttons.addWidget(self.install_btn)
        buttons.addWidget(self.remove_btn)
        buttons.addStretch(1)
        buttons.addWidget(folder)
        box = QWidget()
        box.setLayout(buttons)
        health.add(box)
        v.addWidget(health)
        self._message("hooks", v)
        v.addStretch(1)
        return page

    def _set_autostart(self, on: bool) -> None:
        try:
            autostart.set_enabled(on)
            self._say("general", None)
        except OSError as e:
            self._say("general", f"Could not change launch at login: {e.strerror or e}")
        self.store.update(start_at_login=on)

    def _hooks(self, action) -> None:
        try:
            action()
            self._say("hooks", None)
        except hooks.UnreadableSettings as e:
            self._say("hooks", str(e))
        self.refresh()

    # --- Auto-Approve ------------------------------------------------------------------------

    def _set_auto_approve(self, on: bool) -> None:
        if on and not self.store.value.auto_approve:
            # Switching it on asks what it should answer, as the Mac's sheet does.
            self.switches["auto_approve"].set_quietly(False)
            self._auto_approve_sheet(editing=False)
            return
        if self.overlay is not None:
            self.overlay.auto_until = None
        self.store.update(auto_approve=on)

    def _auto_approve_sheet(self, editing: bool) -> None:
        sheet = AutoApproveSheet(self, self.t, self.store.value, editing, hello.check_availability() == hello.AVAILABLE)
        if sheet.exec() != QDialog.Accepted:
            return
        scope, dangerous = sheet.scope(), sheet.dangerous()
        current = self.store.value.auto_approve_dangerous

        def apply():
            self.store.update(auto_approve_scope=scope, auto_approve_dangerous=dangerous,
                              auto_approve=True if not editing else self.store.value.auto_approve)
            if not editing and self.overlay is not None:
                self.overlay.auto_until = None
        if autoapprove.needs_authentication(current, dangerous):
            self._pending_auth = apply
            ownerauth.confirm_owner(int(self.winId()), "Let Auto-Approve approve destructive commands too",
                                    lambda ok, msg: self._bridge.authed.emit("auto", ok, msg))
        else:
            apply()

    def _authed(self, what: str, ok: bool, message) -> None:
        if what == "auto":
            if ok:
                self._pending_auth()
                self._say("general", None)
            else:
                self._say("general", message)
        elif what == "skip":
            if ok:
                self.store.update(skip_destructive_confirm=True)
                self._say("privacy", None)
            else:
                self._say("privacy", message)
        self.refresh()

    # --- Notch ------------------------------------------------------------------------------

    def _page_notch(self) -> QWidget:
        page, v = self._page("Notch")
        card = kit.Card(self.t)
        self._toggle_row(card, "keep_open", "Keep the notch open",
                         "Show the open notch with its meters all the time, instead of only when you point at it.")
        self._toggle_row(card, "hover_sessions", "Show sessions on hover",
                         "Pointing at the notch opens it: the model, context, cost and the other sessions.")
        self._toggle_row(card, "show_pill", "Show the notch when idle",
                         "Off: only cards that need an answer appear. The tray icon stays either way.")
        self._toggle_row(card, "hide_in_fullscreen", "Hide over fullscreen apps",
                         "Games, videos and presentations. A card that needs an answer still shows.")
        v.addWidget(card)
        place = kit.Card(self.t)
        self.position = QComboBox()
        for value, text in POSITIONS:
            self.position.addItem(text, value)
        self.position.currentIndexChanged.connect(self._set_position)
        place.add(kit.Row(self.t, "Where the notch sits",
                          "Top centre is the Mac's place. Bottom right sits above the tray.", self.position))
        v.addWidget(place)
        v.addStretch(1)
        return page

    def _set_position(self, _i: int) -> None:
        value = self.position.currentData()
        if value and value != self.store.value.position:
            self.store.update(position=value)

    # --- Pet --------------------------------------------------------------------------------

    def _page_pet(self) -> QWidget:
        page, v = self._page("Pet")
        card = kit.Card(self.t)
        self._toggle_row(card, "pet_enabled", "Pet Mode",
                         "The mascot lives in the closed notch: it peeks out, strolls, naps when nothing is "
                         "happening, keeps Claude company while it works, celebrates a finished task and flinches "
                         "when one fails. Click the notch to boop it; three quick boops make it flip.")
        v.addWidget(card)
        v.addWidget(kit.section_label(self.t, "Try an activity"))
        tries = kit.Card(self.t)
        from . import petengine
        for key, title in (("peek", "Peek"), ("lookAround", "Look around"), ("stroll", "Stroll"),
                           ("hangLeft", "Hang off the left corner"), ("hangRight", "Hang off the right corner"),
                           ("sleep", "Sleep"), ("celebrate", "Celebrate"), ("watch", "Watch Claude work"),
                           ("flinch", "Flinch"), ("fret", "Fret (limit almost up)"), ("spin", "Backflip")):
            btn = kit.PushButton(self.t, "Play")
            btn.clicked.connect(lambda _=False, a=key: self._pet_try(a))
            tries.add(kit.Row(self.t, title, None, btn))
        v.addWidget(tries)
        v.addWidget(kit.label("Pet Mode needs the notch at the top of the screen.", 11, color=self.t.secondary))
        v.addStretch(1)
        return page

    def _pet_try(self, activity: str) -> None:
        import time as _t
        ov = self.overlay
        if ov is None:
            return
        if not self.store.value.pet_enabled:
            self.store.update(pet_enabled=True)
        ov.pet._start(activity, _t.monotonic())
        ov._retarget()

    # --- Session ----------------------------------------------------------------------------

    def _page_session(self) -> QWidget:
        page, v = self._page("Session")
        v.addWidget(kit.section_label(self.t, "Auto-approve for a while"))
        card = kit.Card(self.t)
        timed = QWidget()
        h = QHBoxLayout(timed)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(6)
        for minutes in (15, 30, 60):
            b = kit.PushButton(self.t, f"{minutes} min" if minutes < 60 else "1 hour")
            b.clicked.connect(lambda _=False, m=minutes: self._timed(m))
            h.addWidget(b)
        self.timed_stop = kit.PushButton(self.t, "Stop", destructive=True)
        self.timed_stop.clicked.connect(lambda: self._set_auto_approve(False))
        h.addWidget(self.timed_stop)
        self.timed_row = card.add(kit.Row(self.t, "Approve requests without a card",
                                          "Turns Auto-Approve on, with your Auto-Approve choices, then off again by "
                                          "itself. Not kept across a restart.", timed))
        v.addWidget(card)
        v.addWidget(kit.section_label(self.t, "Snooze"))
        snooze = kit.Card(self.t)
        box = QWidget()
        h2 = QHBoxLayout(box)
        h2.setContentsMargins(0, 0, 0, 0)
        h2.setSpacing(6)
        for minutes in (30, 60):
            b = kit.PushButton(self.t, f"{minutes} min" if minutes < 60 else "1 hour")
            b.clicked.connect(lambda _=False, m=minutes: self._snooze(m))
            h2.addWidget(b)
        self.snooze_stop = kit.PushButton(self.t, "Wake")
        self.snooze_stop.clicked.connect(lambda: self._snooze(0))
        h2.addWidget(self.snooze_stop)
        self.snooze_row = snooze.add(kit.Row(self.t, "Snooze passive cards",
                                             "Finished-turn cards and notifications are logged quietly instead of "
                                             "shown. Permission cards and questions still show.", box))
        v.addWidget(snooze)
        v.addStretch(1)
        return page

    def _timed(self, minutes: int) -> None:
        if self.overlay is not None:
            self.overlay.enable_auto_approve_for(minutes)
        self.refresh()

    def _snooze(self, minutes: int) -> None:
        if self.overlay is not None:
            self.overlay.snooze_for(minutes)
        self.refresh()

    # --- Skills -----------------------------------------------------------------------------

    def _page_skills(self) -> QWidget:
        page, v = self._page("Skills")
        v.addWidget(kit.label("Every skill adds a little to each Claude turn, even unused ones. Turn off what you "
                              "don't need.", 13, color=self.t.text, wrap=True))
        v.addWidget(kit.label("Changes apply to new sessions, or run /reload-skills in one that's already running.",
                              11, color=self.t.secondary, wrap=True))
        self.skills_total = kit.label("", 13, "semibold", self.t.text)
        v.addWidget(self.skills_total)
        self.skills_search = kit.SearchField(self.t, "Search skills")
        self.skills_search.changed.connect(lambda _q: self._fill_skills())
        v.addWidget(self.skills_search)
        self.skills_box = QVBoxLayout()
        self.skills_box.setSpacing(14)
        v.addLayout(self.skills_box)
        self._message("skills", v)
        v.addStretch(1)
        return page

    def _skill_projects(self) -> list[str]:
        """Recent projects (the Mac keeps 8): folders of sessions seen here."""
        seen, out = set(), []
        for r in self.state.archive.newest_first():
            if r.cwd and r.cwd not in seen and os.path.isdir(r.cwd):
                seen.add(r.cwd)
                out.append(r.cwd)
        for s in self.state.snapshot()[3]:
            if s.cwd and s.cwd not in seen and os.path.isdir(s.cwd):
                seen.add(s.cwd)
                out.append(s.cwd)
        return out[:8]

    def _fill_skills(self) -> None:
        from claudenotch import skills as sk
        lay = self.skills_box
        while lay.count():
            w = lay.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        found = sk.scan(self._skill_projects())
        data = sk._read(sk.settings_path())
        ov = sk.overrides(data)
        plugins_on = sk.enabled_plugins(data)
        tokens = 0
        for s in found:
            vis = ov.get(s.name, "on")
            if vis == "on":
                tokens += s.listing_tokens
            elif vis == "name-only":
                tokens += (len(s.name) + 4 + 3) // 4
        self.skills_total.setText(f"{len(found)} skill{'' if len(found) == 1 else 's'} · about {tokens:,} tokens "
                                  "of listing in every turn")
        query = self.skills_search.edit.text().strip().lower()
        if query:
            found = [s for s in found if query in f"{s.name} {s.description} {s.plugin}".lower()]
        groups = (("personal", "Personal"), ("synced", "From claude.ai"), ("project", "Projects"),
                  ("plugin", "Plugins"))
        any_shown = False
        for source, title in groups:
            items = [s for s in found if s.source == source]
            if not items:
                continue
            any_shown = True
            lay.addWidget(kit.section_label(self.t, title))
            card = kit.Card(self.t)
            for s in sorted(items, key=lambda x: x.name.lower()):
                card.add(self._skill_row(s, ov.get(s.name, "on"), plugins_on))
            lay.addWidget(card)
        if not any_shown:
            lay.addWidget(kit.label("No matching skills." if query else "No skills found in ~/.claude/skills, "
                                    "your recent projects or your plugins.", 12, color=self.t.secondary))
        entries = sk.trash_list()
        if entries:
            lay.addWidget(kit.section_label(self.t, "Trash · kept 30 days"))
            card = kit.Card(self.t)
            for e in entries:
                btn = kit.PushButton(self.t, "Restore")
                btn.clicked.connect(lambda _=False, en=e: self._skill_restore(en))
                left = f"{e.days_left} days left" if e.days_left is not None else ""
                card.add(kit.Row(self.t, e.name, left, btn))
            lay.addWidget(card)

    def _skill_row(self, s, vis: str, plugins_on: dict) -> QWidget:
        from claudenotch import skills as sk
        box = QWidget()
        h = QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(6)
        combo = QComboBox()
        for key in sk.VISIBILITIES:
            combo.addItem(sk.VISIBILITY_LABELS[key][0], key)
            combo.setItemData(combo.count() - 1, sk.VISIBILITY_LABELS[key][1], Qt.ToolTipRole)
        combo.setCurrentIndex(combo.findData(vis))
        combo.currentIndexChanged.connect(lambda _i, c=combo, name=s.name: self._skill_visibility(name, c.currentData()))
        h.addWidget(combo)
        if s.can_trash:
            bin_ = kit.PushButton(self.t, "Move to Trash…", destructive=True)
            bin_.clicked.connect(lambda _=False, sk_=s: self._skill_trash(sk_))
            h.addWidget(bin_)
        bits = []
        if s.refused:
            bits.append("Won't load: its folder name has a character Claude Code refuses")
        if s.description:
            bits.append(s.description[:160])
        bits.append(f"~{s.listing_tokens} tokens" if s.listing_tokens else "not listed to Claude")
        if s.project:
            bits.append(os.path.basename(s.project))
        row = kit.Row(self.t, s.name, " · ".join(bits), box)
        row.title.setToolTip(s.path)
        return row

    def _skill_visibility(self, name: str, vis: str) -> None:
        from claudenotch import skills as sk
        try:
            sk.set_visibility(name, vis)
            self._say("skills", None)
        except (sk.Unreadable, OSError) as e:
            self._say("skills", f"{sk.settings_path()} is not valid JSON, so ClaudeNotch left it alone."
                      if isinstance(e, sk.Unreadable) else str(e))
        self._fill_skills()

    def _skill_trash(self, s) -> None:
        from PySide6.QtWidgets import QMessageBox
        from claudenotch import skills as sk
        if QMessageBox.question(self, "Move to Trash", f"Move {s.name} to the trash?\n\nYou can restore it from this "
                                "page for 30 days.", QMessageBox.Yes | QMessageBox.No, QMessageBox.No) != QMessageBox.Yes:
            return
        try:
            sk.trash(s)
            self._say("skills", None)
        except (ValueError, OSError) as e:
            self._say("skills", str(e))
        self._fill_skills()

    def _skill_restore(self, entry) -> None:
        from claudenotch import skills as sk
        try:
            sk.restore(entry)
            self._say("skills", None)
        except OSError as e:
            self._say("skills", str(e))
        self._fill_skills()

    # --- Alerts -----------------------------------------------------------------------------

    def _page_alerts(self) -> QWidget:
        page, v = self._page("Alerts")
        card = kit.Card(self.t)
        self._toggle_row(card, "toasts", "Completion and notification cards",
                         "A card in the notch when a session finishes or Claude Code sends a notification.")
        self._toggle_row(card, "limit_warnings", "Plan-limit warnings",
                         "A card at 80% and again at 95% of your 5-hour or weekly plan limit, once per window.")
        v.addWidget(card)
        v.addWidget(kit.section_label(self.t, "Windows notifications"))
        win = kit.Card(self.t)
        self._toggle_row(win, "desktop_notifications", "Mirror cards to Windows notifications",
                         "A Windows notification for each permission request and question, for when the notch "
                         "is on another screen or behind a fullscreen window.")
        self._toggle_row(win, "notify_dangerous_only", "Only for destructive commands",
                         "Just the requests that get the red card, such as Remove-Item -Recurse -Force.")
        v.addWidget(win)
        v.addStretch(1)
        return page

    # --- Usage ------------------------------------------------------------------------------

    def _page_usage(self) -> QWidget:
        page, v = self._page("Usage")
        self.usage_box = QVBoxLayout()
        self.usage_box.setSpacing(18)
        v.addLayout(self.usage_box)
        self.usage_box.addWidget(kit.label("Reading transcripts…", 13, color=self.t.secondary))
        v.addStretch(1)
        return page

    def _load_usage(self) -> None:
        """Read the transcripts on a worker thread; the page fills in when done."""
        if self._usage_busy:
            return
        self._usage_busy = True
        import threading

        def run():
            try:
                result = usage_mod.compute()
            except OSError:
                result = None
            self._bridge.usage.emit(result)
        threading.Thread(target=run, daemon=True, name="usage").start()

    def _fill_usage(self, u) -> None:
        import datetime as _dt
        self._usage_busy = False
        self.last_usage = u
        lay = self.usage_box
        while lay.count():
            w = lay.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        t = self.t
        today = _dt.date.today()
        if u is not None:
            trend = usage_mod.daily_series(u.daily_cost, 7, today)
            if any(c > 0 for _, c in trend):
                lay.addWidget(kit.section_label(t, "Estimated cost, last 7 days"))
                lay.addWidget(kit.label("Estimated at public API (pay-as-you-go) prices. On a Pro, Max, Team, or "
                                        "Enterprise subscription you pay a flat fee, so this is not your actual bill, "
                                        "it is what the usage would cost per token.", 11, color=t.secondary,
                                        wrap=True))
                lay.addWidget(_padded(t, charts.BarChart(t, trend)))
            weeks = usage_mod.weekly_cost_buckets(u.daily_cost, 4, today)
            if any(c > 0 for _, c in weeks):
                lay.addWidget(kit.section_label(t, "Estimated cost, last 4 weeks"))
                lay.addWidget(_padded(t, charts.BarChart(t, weeks)))
        lay.addWidget(kit.section_label(t, "Activity, last 7 weeks"))
        lay.addWidget(_padded(t, charts.Heatmap(t, self.state.stats.value.daily_tools, today)))

        lay.addWidget(kit.label("All-time counters for the notch itself, kept locally on this PC.", 12,
                                color=t.secondary))
        sv = self.state.stats.value
        card = kit.Card(t)
        for title, value in (("Permissions allowed", sv.allowed), ("Permissions denied", sv.denied),
                             ("Auto-approved", sv.auto_approved),
                             ("Dangerous commands flagged", sv.dangerous_flagged),
                             ("Questions answered", sv.questions_answered), ("Active days", len(sv.active_days))):
            card.add(charts.stat_row(t, title, str(value)))
        lay.addWidget(card)
        top = sv.top_tools(6)
        if top:
            lay.addWidget(kit.section_label(t, "Top tools"))
            tools = kit.Card(t)
            for name, n in top:
                tools.add(charts.stat_row(t, name, str(n)))
            lay.addWidget(tools)
        if u is None:
            lay.addWidget(kit.label("The transcripts could not be read.", 12, color=t.secondary))
            return
        leaders = sorted(((cwd, tk.cost_usd) for cwd, tk in u.week_by_project.items() if tk.cost_usd > 0),
                         key=lambda kv: -kv[1])[:6]
        if leaders:
            from claudenotch.state import project_name
            lay.addWidget(kit.section_label(t, "Top projects by estimated cost (7 days)"))
            box = kit.Card(t)
            for cwd, c in leaders:
                box.add(charts.leader_row(t, project_name(cwd) or cwd, charts.usd(c), c / leaders[0][1]))
            lay.addWidget(box)
        lay.addWidget(kit.section_label(t, "Claude usage (from transcripts)"))
        lay.addWidget(kit.label("Costs are estimates at public API prices, not your subscription bill.", 11,
                                color=t.secondary))
        f = usage_mod.fmt_tokens
        box = kit.Card(t)
        for title, value in (("Today", f"{f(u.today.total)} tok · {charts.usd(u.today.cost_usd)}"),
                             ("Last 5 hours", f"{f(u.five_hour.total)} tok · {charts.usd(u.five_hour.cost_usd)}"),
                             ("This week", f"{f(u.week.total)} tok · {charts.usd(u.week.cost_usd)}"),
                             ("Sessions this week", str(u.sessions_week)),
                             ("Cache hit rate", f"{int(u.cache_hit_rate * 100)}%"),
                             ("Cache savings", charts.usd(u.cache_savings_usd))):
            box.add(charts.stat_row(t, title, value))
        lay.addWidget(box)
        models = sorted(((m, tk.cost_usd) for m, tk in u.week_by_model.items() if tk.cost_usd > 0),
                        key=lambda kv: -kv[1])
        if models:
            lay.addWidget(kit.section_label(t, "Model mix (last 7 days)"))
            box = kit.Card(t)
            for m, c in models:
                box.add(charts.leader_row(t, m, charts.usd(c), c / models[0][1]))
            lay.addWidget(box)
        row = QHBoxLayout()
        export = kit.PushButton(t, "Export usage (CSV)")
        export.clicked.connect(self._export_usage)
        row.addWidget(export)
        row.addStretch(1)
        holder = QWidget()
        holder.setLayout(row)
        lay.addWidget(holder)

    def _export_usage(self) -> None:
        from PySide6.QtWidgets import QFileDialog
        u = getattr(self, "last_usage", None)
        if u is None:
            return
        path, _ = QFileDialog.getSaveFileName(self, "Export usage", os.path.expanduser("~/claudenotch-usage.csv"),
                                              "CSV (*.csv)")
        if path:
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(usage_mod.export_csv(u.daily_tokens, u.daily_cost))

    # --- History ----------------------------------------------------------------------------

    def _page_history(self) -> QWidget:
        page, v = self._page("History")
        v.addWidget(kit.label("Every session is archived here with a one-line summary, its cost, and where it "
                              "ran. Search to recall what you did in a project last week.", 12,
                              color=self.t.secondary, wrap=True))
        self.history_total = kit.label("", 13, color=self.t.text)
        v.addWidget(self.history_total)
        self.history_search = kit.SearchField(self.t, "Search by project, summary, branch…")
        self.history_search.changed.connect(lambda _q: self._fill_history())
        v.addWidget(self.history_search)
        self.history_card = kit.Card(self.t)
        v.addWidget(self.history_card)
        row = QHBoxLayout()
        export = kit.PushButton(self.t, "Export…")
        export.clicked.connect(self._export_history)
        clear = kit.PushButton(self.t, "Clear history", destructive=True)
        clear.clicked.connect(self._clear_history)
        row.addWidget(export)
        row.addStretch(1)
        row.addWidget(clear)
        v.addLayout(row)
        v.addStretch(1)
        return page

    def _fill_history(self) -> None:
        import time as _t
        from claudenotch.statusline import fmt_money, short_model
        archive = self.state.archive
        every = archive.newest_first()
        query = self.history_search.edit.text()
        matches = archive.newest_first(query)
        lay = self.history_card.lay
        while lay.count():
            w = lay.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        self.history_card._rows = 0
        total = sum(r.cost_usd for r in every)
        n = len(every)
        self.history_total.setText(f"{'1 session' if n == 1 else f'{n} sessions'}    {fmt_money(total)}")
        if not every:
            self.history_card.add(kit.Row(self.t, "No sessions yet",
                                          "They show up here after a session finishes its first turn."))
            return
        if not matches:
            self.history_card.add(kit.Row(self.t, f"No sessions match \u201c{query}\u201d."))
            return
        for r in matches[:100]:
            when = _t.strftime("%b %d, %H:%M", _t.localtime(r.last))
            bits = [when, f"{r.turns} turn{'' if r.turns == 1 else 's'}"]
            if r.model:
                bits.append(short_model(r.model))
            if r.branch:
                bits.append(r.branch)
            row = kit.Row(self.t, f"{r.project}  ·  {r.summary or 'no prompt recorded'}", "  ·  ".join(bits),
                          kit.label(fmt_money(r.cost_usd) if r.cost_usd else "", 13, "semibold", self.t.text))
            row.title.setToolTip(r.cwd)
            self.history_card.add(row)

    def _export_history(self) -> None:
        from PySide6.QtWidgets import QFileDialog
        from claudenotch import archive as archive_mod
        path, chosen = QFileDialog.getSaveFileName(self, "Export session history",
                                                   os.path.expanduser("~/claudenotch-sessions.csv"),
                                                   "CSV (*.csv);;JSON (*.json)")
        if not path:
            return
        recs = self.state.archive.newest_first()
        text = archive_mod.export_json(recs) if path.lower().endswith(".json") or "JSON" in chosen \
            else archive_mod.export_csv(recs)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)

    def _clear_history(self) -> None:
        from PySide6.QtWidgets import QMessageBox
        if QMessageBox.question(self, "Clear history", "Remove every archived session? This cannot be undone.",
                                QMessageBox.Yes | QMessageBox.No, QMessageBox.No) == QMessageBox.Yes:
            self.state.archive.clear()
            self._fill_history()

    # --- Sounds -----------------------------------------------------------------------------

    def _page_sounds(self) -> QWidget:
        from claudenotch import sounds
        from . import soundplay
        page, v = self._page("Sounds")
        card = kit.Card(self.t)
        self._toggle_row(card, "sound_muted", "Mute all sounds", "Silence every notch sound.")
        self._toggle_row(card, "per_tool_sounds", "Per-tool sounds",
                         "Different sound for different kinds of tool request.")
        v.addWidget(card)
        names = [sounds.SILENT] + soundplay.available(sounds.CHOICES)
        self.sound_pickers = {}

        def picker(kind: str, key: str, default) -> QComboBox:
            combo = QComboBox()
            for n in names:
                combo.addItem(n, n)
            combo.currentIndexChanged.connect(lambda _i, c=combo: self._set_sound(kind, key, c.currentData(), default))
            self.sound_pickers[(kind, key)] = (combo, default)
            return combo

        self.alert_label = kit.section_label(self.t, "Alert sound")
        v.addWidget(self.alert_label)
        self.alert_card = kit.Card(self.t)
        self.alert_card.add(kit.Row(self.t, "Alert sound", None, picker("alert", "", sounds.DEFAULT_ALERT)))
        v.addWidget(self.alert_card)
        self.tools_label = kit.section_label(self.t, "Sound per pop-up type")
        v.addWidget(self.tools_label)
        self.tools_card = kit.Card(self.t)
        for key, title, detail, default in sounds.CATEGORIES:
            self.tools_card.add(kit.Row(self.t, title, detail, picker("tool", key, default)))
        v.addWidget(self.tools_card)
        v.addWidget(kit.section_label(self.t, "Sound per event"))
        v.addWidget(kit.label("Every noise the app makes, one row each. Pick a different sound, or pick None to "
                              "silence just that one. The prompts follow the alert sound above until you give them "
                              "one of their own.", 12, color=self.t.secondary, wrap=True))
        events = kit.Card(self.t)
        for key, title, detail, default in sounds.EVENTS:
            events.add(kit.Row(self.t, title, detail, picker("event", key, default)))
        v.addWidget(events)
        v.addStretch(1)
        return page

    def _sound_value(self, kind: str, key: str, default) -> str:
        from claudenotch import sounds
        v = self.store.value
        if kind == "alert":
            return v.alert_sound
        if kind == "tool":
            return v.sound_tools.get(key, default)
        return v.sound_events.get(key, default if default is not None else v.alert_sound)

    def _refresh_sounds(self) -> None:
        v = self.store.value
        for (kind, key), (combo, default) in self.sound_pickers.items():
            want = self._sound_value(kind, key, default)
            idx = combo.findData(want)
            if idx >= 0 and idx != combo.currentIndex():
                combo.blockSignals(True)
                combo.setCurrentIndex(idx)
                combo.blockSignals(False)
            combo.setEnabled(not v.sound_muted)
        self.tools_label.setVisible(v.per_tool_sounds)
        self.tools_card.setVisible(v.per_tool_sounds)
        self.alert_label.setVisible(not v.per_tool_sounds)
        self.alert_card.setVisible(not v.per_tool_sounds)

    def _set_sound(self, kind: str, key: str, name: str, default) -> None:
        from claudenotch import sounds
        from . import soundplay
        v = self.store.value
        if kind == "alert":
            self.store.update(alert_sound=name)
        elif kind == "tool":
            self.store.update(sound_tools=sounds.set_override(v.sound_tools, key, name, default))
        else:
            self.store.update(sound_events=sounds.set_override(v.sound_events, key, name, default))
        if name != sounds.SILENT:
            soundplay.play(name)              # a preview, as the Mac's picker plays one

    # --- Budget -----------------------------------------------------------------------------

    def _page_budget(self) -> QWidget:
        page, v = self._page("Budget")
        v.addWidget(kit.label("Caps on what Claude spends, at public API prices: the session's own Claude Code "
                              "figure, and today's estimate from the transcripts.", 12, color=self.t.secondary,
                              wrap=True))
        card = kit.Card(self.t)
        self.caps = {}
        for key, title, sub in (("session_cost_cap", "Session cap", "What one session may spend."),
                                ("daily_cost_cap", "Daily cap", "What all sessions together may spend today.")):
            combo = QComboBox()
            combo.addItem("Off", 0.0)
            for amount in (1, 2, 5, 10, 25, 50, 100, 200, 500):
                combo.addItem(f"${amount}", float(amount))
            combo.currentIndexChanged.connect(lambda _i, k=key, c=combo: self.store.update(**{k: c.currentData()}))
            self.caps[key] = combo
            card.add(kit.Row(self.t, title, sub, combo))
        self._toggle_row(card, "enforce_budget", "Hard-stop at the cap",
                         "Once a cap is reached, hold every tool request on the card with Allow once, Raise the cap "
                         "or Turn off, instead of letting it through. Auto-Approve never answers these.")
        v.addWidget(card)
        v.addStretch(1)
        return page

    # --- Plan -------------------------------------------------------------------------------

    def _page_plan(self) -> QWidget:
        page, v = self._page("Plan")
        v.addWidget(kit.label("Your plan limits, as Claude Code's own status line reports them. They update while "
                              "a session is open.", 12, color=self.t.secondary, wrap=True))
        self.plan_card = kit.Card(self.t)
        v.addWidget(self.plan_card)
        v.addStretch(1)
        return page

    def _fill_plan(self) -> None:
        import time as _t
        from claudenotch.limits import reset_countdown
        lay = self.plan_card.lay
        while lay.count():
            w = lay.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        self.plan_card._rows = 0
        lim = dict(self.state.limits)
        shown = False
        for key, title in (("five_hour", "5-hour limit"), ("seven_day", "Weekly limit")):
            pct = lim.get(key + "_pct")
            if pct is None:
                continue
            shown = True
            reset = lim.get(key + "_resets_at")
            when = f"resets in {reset_countdown(reset - _t.time())}" if reset else "reset time not reported"
            self.plan_card.add(charts.leader_row(self.t, title, f"{int(round(pct * 100))}%", pct))
            note = kit.label(when, 11, color=self.t.secondary)
            note.setContentsMargins(14, 0, 14, 8)
            lay.addWidget(note)
        if not shown:
            self.plan_card.add(kit.Row(self.t, "No limits reported yet",
                                       "Claude Code sends them through the status line once a session is open."))

    # --- Privacy ----------------------------------------------------------------------------

    def _page_privacy(self) -> QWidget:
        page, v = self._page("Privacy")
        card = kit.Card(self.t)
        self._toggle_row(card, "hide_from_capture", "Hide from screen capture",
                         "Exclude the notch from screen shares, recordings, and other apps' screenshots. It renders "
                         "commands, paths, and code, so this is on by default.")
        self._toggle_row(card, "require_hello", "Require Windows Hello for permissions",
                         "Ask for Windows Hello before allowing a destructive command from the notch. Without "
                         "Windows Hello set up on this PC, it is press and hold.")
        self._toggle_row(card, "skip_destructive_confirm", "Skip confirmation for destructive commands",
                         "Give destructive commands a plain Allow button, with no Windows Hello and no "
                         "press-and-hold. The card still turns red and says Destructive, and Allow All and "
                         "notifications still never allow one for you. Turning this on asks for Windows Hello or "
                         "your Windows password every time; turning it off never does.",
                         on_set=self._set_skip)
        v.addWidget(card)
        self._message("privacy", v)
        self.hello_note = kit.label("", 11, color=self.t.secondary, wrap=True)
        v.addWidget(self.hello_note)
        v.addStretch(1)
        return page

    def _set_skip(self, on: bool) -> None:
        current = self.store.value.skip_destructive_confirm
        if not hello.needs_authentication(current, on):
            self.store.update(skip_destructive_confirm=on)
            return
        self.switches["skip_destructive_confirm"].set_quietly(False)
        ownerauth.confirm_owner(int(self.winId()), "Skip confirmation for destructive commands",
                                lambda ok, msg: self._bridge.authed.emit("skip", ok, msg))

    # --- Rules ------------------------------------------------------------------------------

    def _page_rules(self) -> QWidget:
        page, v = self._page("Rules")
        v.addWidget(kit.label("Calls you allowed with Always Allow are answered without a card. Destructive calls "
                              "never are, whatever is listed here.", 12, color=self.t.secondary, wrap=True))
        self.rules_card = kit.Card(self.t)
        v.addWidget(self.rules_card)
        v.addStretch(1)
        self._refresh_rules()
        return page

    def _refresh_rules_if_open(self) -> None:
        if self.isVisible():
            self._refresh_rules()

    def _refresh_rules(self) -> None:
        lay = self.rules_card.lay
        while lay.count():
            w = lay.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        self.rules_card._rows = 0
        rules = list(self.state.rules)
        if not rules:
            self.rules_card.add(kit.Row(self.t, "No rules yet", "Use Always Allow on a card to add one."))
        for rule in rules:
            btn = kit.PushButton(self.t, "Remove", destructive=True)
            btn.clicked.connect(lambda _=False, r=rule: self.state.remove_rule(r))
            row = kit.Row(self.t, rule.tool, rule.exact or "Every call of this tool", btn)
            row.title.setTextInteractionFlags(Qt.TextSelectableByMouse)
            self.rules_card.add(row)

    # --- Developer --------------------------------------------------------------------------

    def _page_developer(self) -> QWidget:
        page, v = self._page("Developer")
        v.addWidget(kit.label("Show any card in the notch without waiting for Claude Code. Its answer goes "
                              "nowhere.", 12, color=self.t.secondary, wrap=True))
        from . import demo
        card = kit.Card(self.t)
        for name, title in (("permission", "Permission card"), ("dangerous", "Destructive command"),
                            ("dangerous-powershell", "Destructive PowerShell command"), ("diff", "Edit with a diff"),
                            ("write", "Write a file"), ("queue", "Three queued requests"),
                            ("budget", "Over budget"), ("question", "Question card"),
                            ("notification", "Notification"), ("completed", "Finished turn"),
                            ("failure", "Rate-limited turn")):
            btn = kit.PushButton(self.t, "Show")
            btn.clicked.connect(lambda _=False, n=name: self._demo(n))
            card.add(kit.Row(self.t, title, None, btn))
        v.addWidget(card)
        v.addStretch(1)
        return page

    def _demo(self, name: str) -> None:
        from . import demo
        if name == "budget":
            saved = self.state.approver
            demo.load(self.state, name)
            self.state.approver = saved
        else:
            demo.load(self.state, name)

    # --- About ------------------------------------------------------------------------------

    def _page_about(self) -> QWidget:
        page, v = self._page("About")
        card = kit.Card(self.t)
        card.add(kit.Row(self.t, "ClaudeNotch for Windows", f"Version {__version__}"))
        for title, path in (("Log", paths.log_path()), ("ClaudeNotch settings", paths.config_dir()),
                            ("Claude Code settings", hooks.settings_path())):
            path = os.path.normpath(path)
            btn = kit.PushButton(self.t, "Open")
            btn.clicked.connect(lambda _=False, p=path: _open(p if os.path.exists(p) else os.path.dirname(p)))
            row = kit.Row(self.t, title, path, btn)
            row.subtitle.setTextInteractionFlags(Qt.TextSelectableByMouse)
            card.add(row)
        v.addWidget(card)
        buttons = QHBoxLayout()
        site = kit.PushButton(self.t, "Project page")
        site.clicked.connect(lambda: webbrowser.open(GITHUB))
        quit_btn = kit.PushButton(self.t, "Quit ClaudeNotch", destructive=True)
        quit_btn.clicked.connect(lambda: self.on_quit and self.on_quit())
        buttons.addWidget(site)
        buttons.addStretch(1)
        buttons.addWidget(quit_btn)
        v.addLayout(buttons)
        v.addStretch(1)
        return page

    # --- state ------------------------------------------------------------------------------

    def refresh(self) -> None:
        v = self.store.value
        try:
            start = autostart.enabled()
        except OSError:
            start = v.start_at_login
        values = {"start_at_login": start}
        for key in ("greeting", "hover_sessions", "toasts", "show_pill", "hide_in_fullscreen",
                    "desktop_notifications", "notify_dangerous_only", "keep_open", "hide_from_capture",
                    "require_hello", "skip_destructive_confirm", "auto_approve", "limit_warnings",
                    "enforce_budget", "sound_muted", "per_tool_sounds", "pet_enabled"):
            values[key] = getattr(v, key, False)
        for key, value in values.items():
            sw = self.switches.get(key)
            if sw is not None and sw.isChecked() != value:
                sw.set_quietly(value)
        self.switches["notify_dangerous_only"].setEnabled(not v.desktop_notifications)
        idx = self.position.findData(v.position)
        if idx >= 0 and idx != self.position.currentIndex():
            self.position.blockSignals(True)
            self.position.setCurrentIndex(idx)
            self.position.blockSignals(False)
        for key, combo in getattr(self, "caps", {}).items():
            idx = combo.findData(float(getattr(v, key, 0.0)))
            if idx < 0:
                combo.addItem(f"${getattr(v, key):.2f}", float(getattr(v, key)))
                idx = combo.count() - 1
            if idx != combo.currentIndex():
                combo.blockSignals(True)
                combo.setCurrentIndex(idx)
                combo.blockSignals(False)
        if hasattr(self, "sound_pickers"):
            self._refresh_sounds()
        scope_title = autoapprove.SCOPE_LABELS.get(v.auto_approve_scope, ("", ""))[0]
        danger_title = autoapprove.DANGEROUS_LABELS.get(v.auto_approve_dangerous, ("", ""))[0]
        self.auto_summary.setText(f"{scope_title}. Destructive commands: {danger_title.lower()}.")
        on = hooks.installed()
        self.hooks_row.subtitle.setText(f"{'Installed' if on else 'Not installed'} in "
                                        f"{os.path.normpath(hooks.settings_path())}")
        try:
            wired = hooks.status_wired(hooks._load(), winstatus.command(winstatus.installed_path()))
        except hooks.UnreadableSettings:
            wired = False
        self.status_row.subtitle.setText(
            "Wired: the notch gets the model, context and cost." if wired
            else "Not wired: the notch cannot show context or cost. Install hooks to fix it.")
        self.install_btn.setText("Reinstall hooks" if on else "Install hooks")
        self.remove_btn.setEnabled(on)
        avail = hello.check_availability() == hello.AVAILABLE
        self.hello_note.setText("Windows Hello is set up on this PC." if avail else
                                "Windows Hello is not set up on this PC, so destructive commands use press and "
                                "hold, and owner checks use your Windows password.")
        self._refresh_live()
        self._refresh_rules()

    def _refresh_live(self) -> None:
        """The parts that count down: the timed Auto-Approve and snooze."""
        import time as _t
        ov = self.overlay
        until = getattr(ov, "auto_until", None) if ov is not None else None
        if until and until > _t.time():
            left = int(until - _t.time())
            self.timed_row.subtitle.setText(f"On for {left // 60}m {left % 60:02d}s more, then off by itself.")
            self.timed_stop.setEnabled(True)
        else:
            self.timed_row.subtitle.setText("Turns Auto-Approve on, with your Auto-Approve choices, then off "
                                            "again by itself. Not kept across a restart.")
            self.timed_stop.setEnabled(False)
        snooze = getattr(ov, "snooze_until", None) if ov is not None else None
        if snooze and snooze > _t.time():
            left = int(snooze - _t.time())
            self.snooze_row.subtitle.setText(f"Snoozed for {left // 60}m {left % 60:02d}s more.")
            self.snooze_stop.setEnabled(True)
        else:
            self.snooze_row.subtitle.setText("Finished-turn cards and notifications are logged quietly instead "
                                             "of shown. Permission cards and questions still show.")
            self.snooze_stop.setEnabled(False)

    def closeEvent(self, event) -> None:
        # Closing hides; the app keeps running in the tray.
        event.ignore()
        self.hide()


def _padded(t: kit.Theme, inner: QWidget) -> QWidget:
    """A chart in a card with 14 of padding, as the Mac's .padding(14).cardChrome()."""
    card = kit.Card(t)
    card.lay.setContentsMargins(14, 14, 14, 14)
    card.lay.addWidget(inner)
    return card


class AutoApproveSheet(QDialog):
    """The Mac's AutoApproveSetupSheet: what to approve, and what to do with
    a destructive command. Nothing changes until Turn On or Save."""

    def __init__(self, parent, t: kit.Theme, value, editing: bool, hello_available: bool):
        super().__init__(parent)
        self.setWindowTitle("Auto-approve permissions")
        self.setFixedWidth(460)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), t.window)
        self.setPalette(pal)
        self.setAutoFillBackground(True)
        v = QVBoxLayout(self)
        v.setContentsMargins(20, 20, 20, 20)
        v.setSpacing(14)
        v.addWidget(kit.label("Auto-approve permissions", 17, "semibold", t.text))
        v.addWidget(kit.label("What should it approve for you?", 13, "semibold", t.text))
        self._scope = QButtonGroup(self)
        for key in autoapprove.SCOPES:
            rb = QRadioButton(autoapprove.SCOPE_LABELS[key][0])
            rb.setStyleSheet(f"color: {kit.css(t.text)};")
            rb.setProperty("key", key)
            rb.setChecked(key == value.auto_approve_scope)
            self._scope.addButton(rb)
            v.addWidget(rb)
        self.scope_note = kit.label("", 11, color=t.secondary, wrap=True)
        v.addWidget(self.scope_note)
        v.addWidget(kit.label("Destructive commands", 13, "semibold", t.text))
        v.addWidget(kit.label("Deleting files, Remove-Item -Recurse -Force, force pushes and the like: the ones "
                              "that get the red card.", 11, color=t.secondary, wrap=True))
        self._danger = QButtonGroup(self)
        choices = autoapprove.DANGEROUS_CHOICES if hello_available else (autoapprove.ASK, autoapprove.ALLOW_TOO)
        current = value.auto_approve_dangerous if value.auto_approve_dangerous in choices else autoapprove.ASK
        for key in choices:
            rb = QRadioButton(autoapprove.DANGEROUS_LABELS[key][0])
            rb.setStyleSheet(f"color: {kit.css(t.text)};")
            rb.setProperty("key", key)
            rb.setChecked(key == current)
            self._danger.addButton(rb)
            v.addWidget(rb)
        self.danger_note = kit.label("", 11, color=t.secondary, wrap=True)
        v.addWidget(self.danger_note)
        self._t = t
        self._scope.buttonToggled.connect(lambda *_: self._notes())
        self._danger.buttonToggled.connect(lambda *_: self._notes())
        self._notes()
        row = QHBoxLayout()
        row.addStretch(1)
        cancel = kit.PushButton(t, "Cancel")
        cancel.clicked.connect(self.reject)
        ok = kit.PushButton(t, "Save" if editing else "Turn On", primary=True)
        ok.clicked.connect(self.accept)
        row.addWidget(cancel)
        row.addWidget(ok)
        v.addLayout(row)

    def scope(self) -> str:
        return self._scope.checkedButton().property("key")

    def dangerous(self) -> str:
        return self._danger.checkedButton().property("key")

    def _notes(self) -> None:
        self.scope_note.setText(autoapprove.SCOPE_LABELS[self.scope()][1])
        d = self.dangerous()
        self.danger_note.setText(autoapprove.DANGEROUS_LABELS[d][1])
        red = kit.QColor(255, 69, 58) if d == autoapprove.ALLOW_TOO else self._t.secondary
        self.danger_note.setStyleSheet(f"color: {kit.css(red)}; background: transparent;")


def _open(path: str) -> None:
    """Open a local file or folder with its default app. Only our own paths
    reach here, never one from a hook payload."""
    if os.path.exists(path):
        QDesktopServices.openUrl(QUrl.fromLocalFile(path))
