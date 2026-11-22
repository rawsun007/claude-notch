"""The pill at the top of the screen, and the cards it grows into. PySide6.

One frameless, translucent, always-on-top QWidget that is never in the
taskbar and never takes the keyboard from the terminal on its own. Mirrors
linux/claudenotch/ui.py: a small black pill with the sessions' summary that
grows into a permission card, a question card, the session list (on hover)
or a short toast.

Focus (WINDOWS.md section 3): the window carries WS_EX_NOACTIVATE, so it
takes clicks without being activated and typing in the terminal is never
interrupted. Enter / Esc need the keyboard, so the first click on a card
lifts WS_EX_NOACTIVATE and activates the card; when the card closes the
style goes back and the window that had the keyboard before gets it back.

Threading: AppState calls listeners on the server's threads. The listener
only emits a Qt signal; the queued connection runs render() on the GUI
thread, the Qt version of GLib.idle_add.

Every string from a hook payload is set as plain text (Qt.PlainText): a
QLabel would otherwise guess "rich text" and render HTML from a payload.
"""

from __future__ import annotations

import time

from PySide6.QtCore import QEvent, QObject, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QCursor, QGuiApplication, QPainter, QPainterPath
from PySide6.QtWidgets import (QApplication, QButtonGroup, QCheckBox, QHBoxLayout, QLabel, QLayout, QMenu, QPushButton,
                               QRadioButton, QSizePolicy, QVBoxLayout, QWidget)

from claudenotch import protocol
from claudenotch.state import AppState

from . import theme, view, winutil


class _Bridge(QObject):
    """Carries 'state changed' from server threads to the GUI thread."""
    changed = Signal()


def label(text: str, role: str = "", wrap: bool = False, elide: int = 0, select: bool = False) -> QLabel:
    lbl = QLabel()
    lbl.setTextFormat(Qt.PlainText)
    if role:
        lbl.setProperty("role", role)
    if wrap:
        lbl.setWordWrap(True)
    if elide:
        # Measure with the role's font: polish applies the style sheet first.
        lbl.ensurePolished()
        text = lbl.fontMetrics().elidedText(text, Qt.ElideRight, elide)
    lbl.setText(text)
    if select:
        lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
    return lbl


def dot(status: str) -> QLabel:
    d = QLabel("●")
    d.setTextFormat(Qt.PlainText)
    d.setStyleSheet(f"color: {theme.DOTS.get(status, theme.DOTS['ready'])}; font-size: 11px;")
    return d


def button(text: str, role: str = "") -> QPushButton:
    b = QPushButton(text)
    b.setCursor(Qt.PointingHandCursor)
    b.setFocusPolicy(Qt.NoFocus)        # Enter means Allow, not "press the focused button"
    if role:
        b.setProperty("role", role)
    return b


class Overlay(QWidget):
    def __init__(self, state: AppState, store=None, on_settings=None, on_quit=None):
        super().__init__(None)
        self.state = state
        self.store = store
        self.on_settings = on_settings
        self.on_quit = on_quit

        self.hovering = False
        self.pinned_until = 0.0            # tray click: show the session list for a few seconds
        self.fullscreen = False
        self._shown_key = None
        self._view = view.PILL
        self._content: QWidget | None = None
        self._confirm_until: dict[int, float] = {}
        self._question_inputs: list[list[tuple[str, QWidget]]] = []
        self._keyboard = False             # WS_EX_NOACTIVATE lifted for Enter / Esc
        self._focus_return = 0             # the window that had the keyboard before
        self.buttons: dict[str, QWidget] = {}

        self.setObjectName("notch")
        self.setWindowTitle("ClaudeNotch")
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setStyleSheet(theme.STYLE)
        self.setMouseTracking(True)

        self._layout = QVBoxLayout(self)
        self._layout.setSpacing(0)
        self._layout.setSizeConstraint(QLayout.SizeConstraint.SetFixedSize)

        self._bridge = _Bridge()
        self._bridge.changed.connect(self.render)
        state.subscribe(self._bridge.changed.emit)
        if store is not None:
            store.subscribe(lambda _s: self._bridge.changed.emit())

        self._collapse_timer = QTimer(self, singleShot=True, interval=view.COLLAPSE_DELAY_MS)
        self._collapse_timer.timeout.connect(self._collapse)
        self._tick_timer = QTimer(self, interval=500)
        self._tick_timer.timeout.connect(self._tick)
        self._tick_timer.start()
        self._fullscreen_timer = QTimer(self, interval=2000)
        self._fullscreen_timer.timeout.connect(self._poll_fullscreen)
        self._fullscreen_timer.start()

        app = QGuiApplication.instance()
        app.primaryScreenChanged.connect(lambda *_: self._watch_screens())
        app.screenAdded.connect(lambda *_: self._watch_screens())
        app.screenRemoved.connect(lambda *_: self._watch_screens())
        self._watched = set()
        self._watch_screens()
        QApplication.instance().installEventFilter(self)

        self.render()

    # --- settings ------------------------------------------------------------------

    def _setting(self, name: str, default):
        return getattr(self.store.value, name, default) if self.store is not None else default

    @property
    def position(self) -> str:
        return self._setting("position", "top")

    # --- placement -----------------------------------------------------------------

    def _watch_screens(self) -> None:
        for screen in QGuiApplication.screens():
            if id(screen) in self._watched:
                continue
            self._watched.add(id(screen))
            screen.availableGeometryChanged.connect(lambda *_: self._place())
            screen.geometryChanged.connect(lambda *_: self._place())
        self._place()

    def _place(self) -> None:
        screen = QGuiApplication.primaryScreen()
        if screen is None:
            return
        g = screen.availableGeometry()
        x, y = view.place(self.position, (g.x(), g.y(), g.width(), g.height()), self.width(), self.height())
        self.move(x, y)

    # --- drawing -------------------------------------------------------------------

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect())
        radius = theme.RADIUS_PILL if self._view == view.PILL else theme.RADIUS_CARD
        path = QPainterPath()
        if self.position == "top":
            # Hung from the top edge: square top corners, round bottom ones.
            # A rounded rect taller by one radius, clipped by the window.
            path.addRoundedRect(r.adjusted(0, -radius, 0, 0), radius, radius)
        else:
            path.addRoundedRect(r, radius, radius)
        p.fillPath(path, QColor(theme.BG))
        p.end()

    def render(self) -> None:
        perms, questions, toasts, sessions = self.state.snapshot()
        if not self._setting("toasts", True):
            toasts = [t for t in toasts if t.system]
        hovering = self.hovering or time.monotonic() < self.pinned_until
        v = view.choose(perms, questions, toasts, hovering, self._setting("hover_sessions", True))
        if v == view.PERMISSION:
            card = perms[0]
            key = (v, card.id, len(perms), card.id in self._confirm_until, self.position)
            build = lambda: self._permission_card(card, len(perms) - 1)  # noqa: E731
        elif v == view.QUESTION:
            card = questions[0]
            key = (v, card.id, len(questions), self.position)
            build = lambda: self._question_card(card, len(questions) - 1)  # noqa: E731
        elif v == view.SESSIONS:
            key = (v, tuple((s.id, s.status, s.last_prompt, s.agents) for s in sessions), self.position)
            build = lambda: self._session_list(sessions)  # noqa: E731
        elif v == view.TOAST:
            t = toasts[-1]
            key = (v, t.id, self.position)
            build = lambda: self._toast(t)  # noqa: E731
        else:
            key = (v, tuple((s.id, s.status) for s in sessions), self.position)
            build = lambda: self._pill(sessions)  # noqa: E731

        if key != self._shown_key:
            self._shown_key = key
            was_card = self._view in (view.PERMISSION, view.QUESTION)
            self._view = v
            self.buttons = {}
            if self._content is not None:
                self._layout.removeWidget(self._content)
                self._content.deleteLater()
            if v == view.PILL:
                self._layout.setContentsMargins(16, 6, 16, 8)
            else:
                self._layout.setContentsMargins(22, 10, 22, 14)
            self._content = build()
            self._layout.addWidget(self._content)
            self._layout.activate()
            self.adjustSize()
            self._place()
            self.update()
            if was_card and v not in (view.PERMISSION, view.QUESTION):
                self._give_keyboard_back()
        self._update_visibility()

    def _update_visibility(self) -> None:
        show = view.visible(self._view, self._setting("show_pill", True), self.fullscreen,
                            self._setting("hide_in_fullscreen", True))
        if show and not self.isVisible():
            self.show()
            self._apply_native_style()
        elif not show and self.isVisible():
            self.hide()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._apply_native_style()
        self._place()

    def _hwnd(self) -> int:
        return int(self.winId())

    def _apply_native_style(self) -> None:
        winutil.set_no_activate(self._hwnd(), not self._keyboard)

    # --- the pill, the session list, toasts --------------------------------------------

    def _pill(self, sessions) -> QWidget:
        text, status = view.summary(sessions)
        w = QWidget()
        row = QHBoxLayout(w)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(6)
        row.addStretch(1)
        row.addWidget(dot(status))
        row.addWidget(label(text, "status", elide=view.PILL_WIDTH - 60))
        row.addStretch(1)
        w.setFixedWidth(view.PILL_WIDTH - 32)
        return w

    def _session_list(self, sessions) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(4)
        v.addWidget(label("Sessions", "title"))
        if not sessions:
            v.addWidget(label("No Claude Code sessions yet. Start one with `claude` in a terminal.", "muted",
                              wrap=True))
        for s in sessions:
            row = QHBoxLayout()
            row.setSpacing(8)
            row.addWidget(dot(s.status))
            row.addWidget(label(s.project, "status", elide=180))
            row.addStretch(1)
            row.addWidget(label(view.session_note(s), "muted"))
            v.addLayout(row)
            if s.last_prompt:
                v.addWidget(label(s.last_prompt, "muted", elide=view.SESSIONS_WIDTH - 50))
        w.setFixedWidth(view.SESSIONS_WIDTH - 44)
        return w

    def _toast(self, t) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        v.addWidget(label(t.title, "title", elide=view.TOAST_WIDTH - 50))
        if t.body:
            v.addWidget(label(t.body, "muted", wrap=True))
        w.setFixedWidth(view.TOAST_WIDTH - 44)
        w.setProperty("toast_id", t.id)
        return w

    # --- permission card -----------------------------------------------------------------

    def _header(self, title: str, project: str, more: int) -> QHBoxLayout:
        head = QHBoxLayout()
        head.setSpacing(8)
        head.addWidget(label(title, "title", elide=view.CARD_WIDTH - 200))
        head.addStretch(1)
        t = view.tail(project, more)
        if t:
            head.addWidget(label(t, "muted", elide=160))
        return head

    def _permission_card(self, card, more: int) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)
        v.addLayout(self._header(view.permission_heading(card), card.project, more))

        if card.dangers:
            box = QWidget()
            box.setProperty("role", "danger")
            box.setAttribute(Qt.WA_StyledBackground)
            d = QVBoxLayout(box)
            d.setContentsMargins(10, 8, 10, 8)
            d.setSpacing(2)
            d.addWidget(label("Careful: this can do real damage", "danger-title"))
            for r in card.dangers:
                d.addWidget(label(f"• {r}", "danger", wrap=True))
            v.addWidget(box)

        inner = view.CARD_WIDTH - 44
        if card.old or card.new:
            v.addWidget(label(card.detail, "muted", elide=inner))
            diff = QWidget()
            diff.setProperty("role", "diff")
            diff.setAttribute(Qt.WA_StyledBackground)
            dl = QVBoxLayout(diff)
            dl.setContentsMargins(10, 8, 10, 8)
            dl.setSpacing(0)
            for kind, text in view.diff_rows(card.old, card.new):
                dl.addWidget(label(text, "muted" if kind == "more" else kind, elide=inner - 24))
            v.addWidget(diff)
        elif card.detail:
            lines, cut = view.trim_lines(card.detail, view.DETAIL_LINES)
            code = label("\n".join(lines) + ("\n…" if cut else ""), "code", wrap=True, select=True)
            code.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
            v.addWidget(code)
        for x in card.extra:
            v.addWidget(label(x, "muted", wrap=True))

        row = QHBoxLayout()
        row.setSpacing(8)
        row.addStretch(1)
        deny = button("Deny  Esc")
        deny.clicked.connect(lambda: self._decide(card, protocol.DENY))
        row.addWidget(deny)
        self.buttons["deny"] = deny
        if not card.dangers:
            always = button("Always allow")
            always.clicked.connect(lambda: self._decide(card, protocol.ALLOW, always=True))
            row.addWidget(always)
            self.buttons["always"] = always
        allow = button(view.allow_label(bool(card.dangers), card.id in self._confirm_until),
                       "warn" if card.dangers else "primary")
        allow.clicked.connect(lambda: self._allow_clicked(card))
        row.addWidget(allow)
        self.buttons["allow"] = allow
        v.addSpacing(4)
        v.addLayout(row)
        w.setFixedWidth(inner)
        return w

    def _allow_clicked(self, card) -> None:
        # A dangerous call takes two deliberate clicks: the first arms it, the
        # second within a few seconds allows. One stray click cannot.
        if card.dangers and card.id not in self._confirm_until:
            self._confirm_until[card.id] = time.monotonic() + view.CONFIRM_SECONDS
            self._shown_key = None
            self.render()
            return
        self._decide(card, protocol.ALLOW)

    def _decide(self, card, decision: str, always: bool = False) -> None:
        self._confirm_until.pop(card.id, None)
        self.state.resolve_permission(card.id, decision, always=always,
                                      reason="Denied in ClaudeNotch" if decision == protocol.DENY else None)

    # --- question card -------------------------------------------------------------------

    def _question_card(self, card, more: int) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(6)
        v.addLayout(self._header("Claude has a question", card.project, more))
        self._question_inputs = []
        for qi, q in enumerate(card.questions):
            if q.header:
                v.addWidget(label(q.header, "muted"))
            v.addWidget(label(q.text, "status", wrap=True))
            group = None
            if not q.multi_select:
                group = QButtonGroup(w)
                group.setExclusive(True)
            inputs = []
            for oi, (text, desc) in enumerate(q.options):
                btn = QCheckBox() if q.multi_select else QRadioButton()
                btn.setText(text)          # QAbstractButton text is never rich text
                btn.setFocusPolicy(Qt.NoFocus)
                btn.setCursor(Qt.PointingHandCursor)
                if group is not None:
                    group.addButton(btn)
                    if oi == 0:
                        btn.setChecked(True)
                v.addWidget(btn)
                self.buttons[f"q{qi}o{oi}"] = btn
                if desc:
                    d = label(desc, "option-desc", wrap=True)
                    d.setContentsMargins(24, 0, 0, 0)
                    v.addWidget(d)
                inputs.append((text, btn))
            self._question_inputs.append(inputs)
        row = QHBoxLayout()
        row.setSpacing(8)
        row.addStretch(1)
        skip = button("Answer in terminal")
        skip.clicked.connect(lambda: self.state.resolve_question(card.id, None))
        send = button("Send  ⏎", "primary")
        send.clicked.connect(lambda: self._send_answers(card))
        row.addWidget(skip)
        row.addWidget(send)
        self.buttons["skip"] = skip
        self.buttons["send"] = send
        v.addSpacing(4)
        v.addLayout(row)
        w.setFixedWidth(view.CARD_WIDTH - 44)
        return w

    def _send_answers(self, card) -> None:
        answers = [[text for text, btn in inputs if btn.isChecked()] for inputs in self._question_inputs]
        self.state.resolve_question(card.id, answers)

    # --- keyboard ------------------------------------------------------------------------

    def _take_keyboard(self) -> None:
        """First click on a card: let it have the keyboard for Enter / Esc."""
        if self._keyboard or self._view not in (view.PERMISSION, view.QUESTION):
            return
        self._focus_return = winutil.foreground_window()
        self._keyboard = True
        self._apply_native_style()
        self.activateWindow()
        self.raise_()
        self.setFocus(Qt.MouseFocusReason)

    def _give_keyboard_back(self) -> None:
        """The card closed: no-activate again, and hand the keyboard back to
        the window that had it (the terminal), so the next keystrokes do not
        land on the pill."""
        if not self._keyboard:
            return
        self._keyboard = False
        self._apply_native_style()
        if self._focus_return and self._focus_return != self._hwnd():
            winutil.set_foreground(self._focus_return)
        self._focus_return = 0

    def keyPressEvent(self, event) -> None:
        perms, questions, _, _ = self.state.snapshot()
        key = event.key()
        enter = key in (Qt.Key_Return, Qt.Key_Enter)
        if perms:
            if enter:
                return self._allow_clicked(perms[0])
            if key == Qt.Key_Escape:
                return self._decide(perms[0], protocol.DENY)
        elif questions:
            if enter:
                return self._send_answers(questions[0])
            if key == Qt.Key_Escape:
                return self.state.resolve_question(questions[0].id, None)
        super().keyPressEvent(event)

    # --- mouse -----------------------------------------------------------------------------

    def eventFilter(self, obj, event) -> bool:
        # A press anywhere in this window, buttons included: arm the keyboard.
        if event.type() == QEvent.MouseButtonPress and isinstance(obj, QWidget) and obj.window() is self:
            if event.button() == Qt.LeftButton:
                self._take_keyboard()
                if self._view == view.TOAST and self._content is not None:
                    toast_id = self._content.property("toast_id")
                    if toast_id:
                        self.state.dismiss_toast(int(toast_id))
        return False

    def contextMenuEvent(self, event) -> None:
        menu = QMenu(self)
        menu.addAction("Settings…", lambda: self.on_settings and self.on_settings())
        menu.addAction("Hide the pill", lambda: self.store and self.store.update(show_pill=False))
        menu.addSeparator()
        menu.addAction("Quit ClaudeNotch", lambda: self.on_quit and self.on_quit())
        menu.exec(event.globalPos())

    def enterEvent(self, event) -> None:
        self._collapse_timer.stop()
        if not self.hovering:
            self.hovering = True
            self.render()
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self._collapse_timer.start()
        super().leaveEvent(event)

    def _collapse(self) -> None:
        if self.frameGeometry().contains(QCursor.pos()):
            return    # left into a child widget, or the window grew under the cursor
        self.hovering = False
        self.render()

    def show_sessions(self, seconds: float = 6.0) -> None:
        """From the tray: open the session list for a few seconds."""
        self.pinned_until = time.monotonic() + seconds
        self._shown_key = None
        self.render()
        QTimer.singleShot(int(seconds * 1000) + 50, self.render)

    # --- timers ----------------------------------------------------------------------------

    def _tick(self) -> None:
        now = time.monotonic()
        _, _, toasts, _ = self.state.snapshot()
        for t in toasts:
            if now - t.created > view.TOAST_SECONDS:
                self.state.dismiss_toast(t.id)
        expired = [cid for cid, until in self._confirm_until.items() if now > until]
        for cid in expired:
            del self._confirm_until[cid]
            self._shown_key = None
        if expired:
            self.render()

    def _poll_fullscreen(self) -> None:
        full = winutil.fullscreen_in_front()
        if full != self.fullscreen:
            self.fullscreen = full
            self._update_visibility()
        if self.isVisible():
            winutil.keep_topmost(self._hwnd())

    def rerender(self) -> None:
        self._shown_key = None
        self.render()
