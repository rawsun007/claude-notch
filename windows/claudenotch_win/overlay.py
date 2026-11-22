"""The notch at the top of the screen, and the cards it grows into. PySide6.

A port of NotchView + NotchWindowController + MouseTracker. Windows has no
hardware notch, so this is the Mac's "no notch" rendering: a black 200 x 28
notch hanging from the top centre of the screen, which grows out into a
card with NotchShape's outline (concave top ears, round bottom corners).

How it moves, as on the Mac:
- The card's size is driven by notchgeom.SizeAnimator at the display's
  refresh rate: ease-out-back with a little overshoot to open (0.42 s),
  ease-out-cubic to close (0.34 s).
- The content is laid out once at its FINAL size and revealed by the
  growing clip, so it never reflows mid-animation.
- The card's height is the measured content height, with the Mac's
  formula height as a floor so the button row can never fall outside.
- Hover is polled every 0.2 s against MouseTracker's trigger zone (340 x 44
  under the top edge) and keep region (the card plus 140 x 90), so a
  cursor drifting a little off the card does not snap it shut.

Focus (WINDOWS.md section 3): the window carries WS_EX_NOACTIVATE, so it
takes clicks without being activated and typing in the terminal is never
interrupted. Enter / Esc need the keyboard, so the first click on a card
lifts WS_EX_NOACTIVATE; when the card closes the style goes back and the
window that had the keyboard gets it back.

Threading: AppState calls listeners on the server's threads. The listener
only emits a Qt signal; the queued connection runs render() on the GUI
thread.

Every string from a hook payload is drawn as plain text: Text widgets paint
it with QPainter, and QLabels are set to Qt.PlainText.
"""

from __future__ import annotations

import time

from PySide6.QtCore import QEvent, QObject, QRect, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QCursor, QGuiApplication, QPainter, QPainterPath, QPen, QRegion
from PySide6.QtWidgets import QApplication, QLabel, QMenu, QVBoxLayout, QWidget

from claudenotch import gitinfo, protocol
from claudenotch.state import AppState

from . import cardmodel, hello
from claudenotch import autoapprove, budget, sounds, usage
from . import macstyle as ms
from . import notchgeom as geom
from . import notchwidgets as nw
from . import petengine, soundplay, view, winutil
from .notchcards import AutoInfoCardView, IdleCardView, NoticeCardView, PermissionCardView, QuestionCardView

FRAME_MS = 8                 # the animation clock; frames land on the display's vsync
BOTTOM_RIGHT_MARGIN = 12


class _Bridge(QObject):
    """Carries 'state changed' from server threads to the GUI thread."""
    changed = Signal()


def label(text: str, size: float = 12, weight: str = "regular", opacity: float = 1.0, wrap: bool = False,
          rgb=ms.WHITE) -> QLabel:
    lbl = QLabel()
    lbl.setTextFormat(Qt.PlainText)
    lbl.setFont(ms.font(size, weight))
    lbl.setStyleSheet(f"color: {ms.css(rgb, opacity)}; background: transparent;")
    lbl.setWordWrap(wrap)
    lbl.setText(text)
    return lbl


class Overlay(QWidget):
    def __init__(self, state: AppState, store=None, on_settings=None, on_quit=None):
        super().__init__(None)
        self.state = state
        self.store = store
        self.on_settings = on_settings
        self.on_quit = on_quit

        self.hovering = False
        self.pinned_until = 0.0            # tray click: hold the card open for a few seconds
        self.fullscreen = False
        self._shown_key = None
        self._view = view.PILL
        self._content: QWidget | None = None
        self._card_w = geom.COLLAPSED_W
        self._formula_h = geom.COLLAPSED_H
        self._question_view = None
        self._originators: dict[int, int] = {}
        self._last_foreign = 0
        self._keyboard = False
        self._focus_return = 0
        self.buttons: dict[str, QWidget] = {}
        self._hello = hello.Availability()
        self.auto_until: float | None = None
        self.snooze_until: float | None = None
        self.pet = petengine.Scheduler()
        self._pet_last_mood = ""
        self._pet_timer = QTimer(self, interval=33)
        self._pet_timer.timeout.connect(self._pet_tick)
        self._pet_timer.start()
        # Today's estimated spend from the transcripts, for the daily cap;
        # refreshed off the GUI thread once a minute.
        self.today_cost = 0.0
        self._cost_timer = QTimer(self, interval=60_000)
        self._cost_timer.timeout.connect(self._refresh_today_cost)
        self._cost_timer.start()
        QTimer.singleShot(2000, self._refresh_today_cost)
        self._capture_hidden = None
        state.approver = self._approve
        self._sizer = geom.SizeAnimator()
        self._sizer.set(geom.collapsed_size())
        self._clock0 = time.monotonic()

        self.setWindowTitle("ClaudeNotch")
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
                            | Qt.NoDropShadowWindowHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setAutoFillBackground(False)

        self._bridge = _Bridge()
        self._bridge.changed.connect(self.render)
        state.subscribe(self._bridge.changed.emit)
        if store is not None:
            store.subscribe(lambda _s: self._bridge.changed.emit())

        self._frame = QTimer(self, interval=FRAME_MS)
        self._frame.setTimerType(Qt.PreciseTimer)
        self._frame.timeout.connect(self._on_frame)
        self._hover_timer = QTimer(self, interval=geom.HOVER_POLL_MS)
        self._hover_timer.timeout.connect(self._poll_hover)
        self._hover_timer.start()
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

    @property
    def top(self) -> bool:
        return self.position != "bottom-right"

    # --- geometry ------------------------------------------------------------------

    def _screen(self):
        return QGuiApplication.primaryScreen()

    def _screen_rect(self) -> tuple[int, int, int, int]:
        s = self._screen()
        if s is None:
            return (0, 0, 1920, 1080)
        g = s.availableGeometry()
        return (g.x(), g.y(), g.width(), g.height())

    def _watch_screens(self) -> None:
        for screen in QGuiApplication.screens():
            if id(screen) in self._watched:
                continue
            self._watched.add(id(screen))
            screen.availableGeometryChanged.connect(lambda *_: self._place())
            screen.geometryChanged.connect(lambda *_: self._place())
        self._place()

    def _target(self) -> tuple[float, float]:
        if self._content is None:
            w, h = geom.collapsed_size()
            a = self.pet.activity if self._pet_on() else "tucked"
            if a != "tucked":
                # The notch swells a little to be the pet's stage (NotchView.size).
                return (w + petengine.stage_width_pad(a), geom.INSET + petengine.stage_drop(a))
            return (w, h)
        measured = self._content.sizeHint().height()
        return (float(self._card_w), float(max(self._formula_h, measured)))

    def _window_size(self) -> tuple[int, int]:
        """Big enough for the card now and the card it is heading to, so the
        window only changes size at the start and end of a motion, never on
        every frame. The overshoot gets a little room too."""
        cw, ch = self._sizer.size
        tw, th = self._sizer.target
        w = max(cw, tw) * 1.06 + 8
        h = max(ch, th) * 1.06 + 8
        return int(w + 0.99), int(h + 0.99)

    def _place(self) -> None:
        w, h = self._window_size()
        sx, sy, sw, sh = self._screen_rect()
        if self.top:
            x, y = sx + (sw - w) // 2, sy
        else:
            x = sx + sw - w - BOTTOM_RIGHT_MARGIN
            y = sy + sh - h - BOTTOM_RIGHT_MARGIN
        if self.geometry() != QRect(x, y, w, h):
            self.setGeometry(x, y, w, h)
        self._layout_content()

    def _card_rect(self, w: float, h: float) -> QRectF:
        W, H = self.width(), self.height()
        if self.top:
            return QRectF((W - w) / 2, 0, w, h)
        return QRectF(W - w, H - h, w, h)

    def _layout_content(self) -> None:
        if self._content is None:
            return
        hint = self._content.sizeHint()
        full = self._card_rect(self._card_w, max(self._formula_h, hint.height()))
        self._content.setGeometry(int(full.x()), int(full.y()), int(self._card_w), int(full.height()))
        # The growing clip: only the part of the final layout inside the
        # card's current size shows.
        w, h = self._sizer.size
        cur = self._card_rect(w, h).translated(-full.x(), -full.y())
        self._content.setMask(QRegion(cur.toAlignedRect()))

    # --- motion -------------------------------------------------------------------------

    def _now(self) -> float:
        return time.monotonic() - self._clock0

    def _retarget(self, animate: bool = True) -> None:
        target = self._target()
        if not animate or not self.isVisible():
            self._sizer.set(target)
        else:
            expanding = geom.is_expanding(target, self._sizer.size)
            self._sizer.animate(target, expanding, self._now())
        self._place()
        if self._sizer.running and not self._frame.isActive():
            self._frame.start()
        self.update()

    def _on_frame(self) -> None:
        self._sizer.tick(self._now())
        if not self._sizer.running:
            self._frame.stop()
            self._place()           # shrink the window to the resting card
        self._layout_content()
        self.update()

    @property
    def collapsed(self) -> bool:
        return self._view == view.PILL

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        w, h = self._sizer.size
        r = self._card_rect(w, h)
        collapsed = self.collapsed and not self._sizer.running
        path = QPainterPath()
        if self.top:
            for cmd in geom.notch_path(r.x(), r.y(), r.width(), r.height(),
                                       geom.top_radius(self.collapsed), geom.bottom_radius(self.collapsed)):
                if cmd[0] == "move":
                    path.moveTo(cmd[1], cmd[2])
                elif cmd[0] == "line":
                    path.lineTo(cmd[1], cmd[2])
                elif cmd[0] == "quad":
                    path.quadTo(cmd[1], cmd[2], cmd[3], cmd[4])
                else:
                    path.closeSubpath()
        else:
            radius = geom.bottom_radius(self.collapsed)
            path.addRoundedRect(r, radius, radius)
        p.fillPath(path, QColor(0, 0, 0))
        if self.collapsed and self._pet_on() and self.pet.activity != "tucked":
            self._paint_pet(p, path, r)
        if not collapsed:
            p.setPen(QPen(ms.rgba(ms.WHITE, 0.05), 0.5))
            p.drawPath(path)
        p.end()

    # --- what to show --------------------------------------------------------------------

    def render(self) -> None:
        self.state.limit_warnings = self._setting("limit_warnings", True)
        perms, questions, toasts, sessions = self.state.snapshot()
        if not self._setting("toasts", True) or self.snoozed:
            # Snoozed (or switched off): passive cards are logged, not shown.
            for t in toasts:
                if not t.system:
                    self.state.dismiss_toast(t.id)
            toasts = [t for t in toasts if t.system]
        hovering = (self.hovering or time.monotonic() < self.pinned_until
                    or self._setting("keep_open", False))
        auto = self.state.auto_info
        if auto is not None and time.monotonic() - self.state.auto_info_at > view.AUTO_INFO_SECONDS:
            auto = None
        v = view.choose(perms, questions, toasts, hovering, self._setting("hover_sessions", True), auto)
        if v == view.AUTO:
            key = (v, auto.id, self.position)
            build = lambda: self._auto_info_card(auto)  # noqa: E731
        elif v == view.PERMISSION:
            card = perms[0]
            key = (v, card.id, len(perms), self.position)
            build = lambda: self._permission_card(card, len(perms))  # noqa: E731
        elif v == view.QUESTION:
            card = questions[0]
            key = (v, card.id, len(questions), self.position)
            build = lambda: self._question_card(card, len(questions) - 1)  # noqa: E731
        elif v == view.SESSIONS:
            branches = {s.id: gitinfo.branch(s.cwd) for s in sessions}
            branch = branches[sessions[0].id] if sessions else ""
            waiting: dict = {}
            for c in list(perms) + list(questions):
                waiting[c.cwd] = min(waiting.get(c.cwd, c.created), c.created)
            # The list shows only with two or more sessions, as on the Mac.
            rows = cardmodel.session_rows(sessions, branches, waiting, time.monotonic())                 if len(sessions) >= 2 else []
            key = (v, tuple((s.id, s.status, s.last_prompt, s.agents, s.model, s.effort, s.context_pct,
                             s.context_tokens, s.context_window, s.cost_usd, s.worktree) for s in sessions),
                   tuple(branches.items()), tuple(r.waiting for r in rows), self.position)
            build = lambda: self._idle_card(sessions, branch, rows)  # noqa: E731
        elif v == view.TOAST:
            # The oldest first, as the Mac's queues are: completedQueue.first.
            t = toasts[0]
            self._note_originator(t)
            key = (v, t.id, self.position)
            build = lambda: self._toast(t)  # noqa: E731
        else:
            key = (v, self.position)
            build = None

        if key != self._shown_key:
            self._sound_for_view(v, key, perms, questions, toasts, auto)
            self._shown_key = key
            was_card = self._view in (view.PERMISSION, view.QUESTION)
            self._view = v
            self.buttons = {}
            if self._content is not None:
                self._content.hide()
                self._content.deleteLater()
                self._content = None
            if build is not None:
                self._content = self._frame_content(build())
                self._content.show()
            else:
                self._card_w, self._formula_h = geom.collapsed_size()
            self._retarget()
            if was_card and v not in (view.PERMISSION, view.QUESTION):
                self._give_keyboard_back()
        self._update_visibility()
        if self.isVisible() and self._setting("hide_from_capture", True) != self._capture_hidden:
            self._apply_native_style()

    @property
    def snoozed(self) -> bool:
        return self.snooze_until is not None and time.time() < self.snooze_until

    def snooze_for(self, minutes: int) -> None:
        """Snooze passive cards for `minutes` (0 wakes them). Not saved."""
        self.snooze_until = time.time() + minutes * 60 if minutes > 0 else None
        if minutes > 0:
            QTimer.singleShot(int(minutes * 60 * 1000) + 100, self.rerender)

    # --- Pet mode --------------------------------------------------------------------

    def _pet_on(self) -> bool:
        return bool(self._setting("pet_enabled", False)) and self.top

    def _pet_mood(self, now: float) -> str:
        _, _, toasts, sessions = self.state.snapshot()
        kinds = {getattr(t, "kind", "") for t in toasts if now - t.created < 6}
        working = any(s.status == "working" for s in sessions)
        newest = max((s.updated for s in sessions), default=0.0)
        idle = time.time() - newest if newest else 9999
        return petengine.mood("failure" in kinds, "done" in kinds, working, False, idle)

    def _pet_tick(self) -> None:
        if not self._pet_on() or not self.collapsed or not self.isVisible():
            return
        now = time.monotonic()
        m = self._pet_mood(now)
        if m != self._pet_last_mood and m in ("celebrating", "startled"):
            self.pet.react(m, now)
        self._pet_last_mood = m
        before = self.pet.activity
        self.pet.tick(now, m)
        if self.pet.activity != before:
            self._retarget()
        self.update()

    def _paint_pet(self, p: QPainter, clip: QPainterPath, r) -> None:
        now = time.monotonic()
        a = self.pet.activity
        pos = QCursor.pos() - self.mapToGlobal(r.center().toPoint())
        cursor_x = max(-40.0, min(40.0, float(pos.x()))) if abs(pos.y()) < 120 else 0.0
        pose = petengine.pose(a, self.pet.progress(now), geom.INSET, r.width() / 2, cursor_x)
        size = petengine.sprite_size(a)          # the Mac draws PetSprite at spriteSize
        p.save()
        p.setClipPath(clip)
        blink = (now % 4.2) < 0.12 or a == "sleep"
        nw.draw_pet(p, r.center().x() + pose.x, r.top() + pose.y, size, pose, blink)
        p.restore()

    def boop_pet(self) -> None:
        if self._pet_on():
            self.pet.boop(time.monotonic())
            self._retarget()

    def mousePressEvent(self, event) -> None:
        # Clicking the bare notch wakes the pet, as on the Mac.
        if self.collapsed and event.button() == Qt.LeftButton:
            self.boop_pet()
        super().mousePressEvent(event)

    def _sound(self, event: str, tool: str | None = None) -> None:
        name = sounds.sound_for(
            event, tool, muted=self._setting("sound_muted", False), per_tool=self._setting("per_tool_sounds", False),
            alert=self._setting("alert_sound", sounds.DEFAULT_ALERT), per_event=self._setting("sound_events", {}),
            per_category=self._setting("sound_tools", {}))
        soundplay.play(name)

    def _sound_for_view(self, v, key, perms, questions, toasts, auto) -> None:
        """A card that just came up makes its sound, once (AppState.play)."""
        if self._shown_key is not None and key[:2] == self._shown_key[:2]:
            return
        if v == view.PERMISSION:
            self._sound("permission", perms[0].tool)
        elif v == view.QUESTION:
            self._sound("question")
        elif v == view.TOAST:
            kind = getattr(toasts[0], "kind", "")
            self._sound({"done": "completed", "limit": "limit"}.get(kind, "permission"),
                        "Notification" if kind in ("notice", "failure") else None)
        elif v == view.AUTO:
            self._sound("autoApproved", auto.tool)

    def _frame_content(self, inner: QWidget) -> QWidget:
        """NotchView's padding around every card: 28 a side, inset + 10 on
        top (the band the collapsed notch fills), 10 at the bottom."""
        box = QWidget(self)
        box.setAttribute(Qt.WA_TranslucentBackground)
        lay = QVBoxLayout(box)
        top = geom.INSET + geom.CONTENT_TOP_GAP if self.top else 14
        lay.setContentsMargins(geom.CONTENT_H_PAD, top, geom.CONTENT_H_PAD, geom.CONTENT_BOTTOM_PAD)
        lay.setSpacing(0)
        lay.addWidget(inner)
        lay.addStretch(1)
        box.setFixedWidth(int(self._card_w))
        box.adjustSize()
        return box

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
        self._capture_hidden = self._setting("hide_from_capture", True)
        winutil.exclude_from_capture(self._hwnd(), self._capture_hidden)

    # --- cards ------------------------------------------------------------------------

    def _idle_card(self, sessions, branch: str = "", rows=None) -> QWidget:
        card = IdleCardView(sessions, branch, rows)
        self._card_w, self._formula_h = geom.idle_open_size(card.content_width)
        return card

    def _permission_card(self, card, pending: int) -> QWidget:
        self._card_w = 620
        g = hello.gate(self._setting("require_hello", True), self._hello.available,
                       self._setting("skip_destructive_confirm", False))
        w = PermissionCardView(card, pending, width=620 - 2 * geom.CONTENT_H_PAD, gate=g, hwnd=self._hwnd())
        if getattr(card, "confirm_now", False) and g == hello.HELLO:
            # Auto-Approve set to confirm destructive commands: the prompt
            # comes up on its own, so a glance or a finger allows it.
            QTimer.singleShot(300, w._ask_hello)
        sx, sy, sw, sh = self._screen_rect()
        self._card_w, self._formula_h = w.budget(screen_h=sh)
        w.decided.connect(lambda d, scope: self._decide(card, d, scope))
        self.buttons = w.buttons
        return w

    def _decide(self, card, decision: str, scope: str = "") -> None:
        self._sound("approved" if decision == protocol.ALLOW else "dismissed")
        block = getattr(card, "budget_block", None)
        if scope == "raise" and block is not None and self.store is not None:
            key = "daily_cost_cap" if block.scope == "daily" else "session_cost_cap"
            self.store.update(**{key: budget.next_cap(block.cost, block.cap)})
            scope = ""
        elif scope == "turn_off" and self.store is not None:
            self.store.update(enforce_budget=False)
            scope = ""
        if scope == "all":
            self.state.resolve_all_permissions(decision)
            return
        self.state.resolve_permission(card.id, decision, always=scope in ("exact", "tool"),
                                      scope=scope or "exact",
                                      reason="Denied in ClaudeNotch" if decision == protocol.DENY else None)

    def _allow_current(self) -> None:
        """Return on a card: Allow, unless it is dangerous, which only a
        deliberate hold allows."""
        perms, _, _, _ = self.state.snapshot()
        if perms and hello.return_allows(bool(perms[0].dangers), self._setting("skip_destructive_confirm", False)):
            self._decide(perms[0], protocol.ALLOW)

    def _auto_info_card(self, card) -> QWidget:
        self._card_w, self._formula_h = geom.auto_info_size()
        w = AutoInfoCardView(card, self._card_w - 2 * geom.CONTENT_H_PAD)
        w.clicked.connect(self.state.dismiss_auto_info)
        return w

    # --- Auto-Approve ----------------------------------------------------------------

    def _approve(self, card) -> str:
        """state.approver: the budget check, then the Mac's AutoApprovePolicy
        with this PC's settings. Called on a server thread; reads only."""
        session = self.state.sessions.get(card.session_id or card.cwd)
        block = budget.block_for(self._setting("enforce_budget", False), self.today_cost,
                                 (session.cost_usd or 0.0) if session else 0.0,
                                 self._setting("daily_cost_cap", 0.0), self._setting("session_cost_cap", 0.0))
        card.budget_block = block
        if block is not None:
            return autoapprove.SHOW_CARD          # over budget: explicit choices only
        dangerous = self._setting("auto_approve_dangerous", autoapprove.ASK)
        if dangerous == autoapprove.CONFIRM and not self._hello.available:
            dangerous = autoapprove.ASK          # no Hello: nothing to bring up on its own
        return autoapprove.verdict(
            autoapprove.active(self._setting("auto_approve", False), self.auto_until, time.time()),
            self._setting("auto_approve_scope", autoapprove.EVERYTHING), dangerous, card.tool, bool(card.dangers))

    def _refresh_today_cost(self) -> None:
        if not self._setting("enforce_budget", False) or not self._setting("daily_cost_cap", 0.0):
            return
        import threading

        def run():
            try:
                self.today_cost = usage.compute().today.cost_usd
            except OSError:
                pass
        threading.Thread(target=run, daemon=True, name="today-cost").start()

    def enable_auto_approve_for(self, minutes: int) -> None:
        """"Auto-approve for a while": on now, off again by itself after
        `minutes`. Not saved, as on the Mac: a restart ends the window."""
        self.auto_until = time.time() + minutes * 60
        if self.store is not None:
            self.store.update(auto_approve=True)
        QTimer.singleShot(int(minutes * 60 * 1000) + 100, self._end_timed_auto_approve)

    def _end_timed_auto_approve(self) -> None:
        if self.auto_until is not None and time.time() >= self.auto_until:
            self.auto_until = None
            if self.store is not None:
                self.store.update(auto_approve=False)

    def _toast(self, t) -> QWidget:
        text = cardmodel.notice_text(t)
        w, h = geom.completed_size() if text.card == "completed" else geom.notice_size()
        self._card_w, self._formula_h = w, h
        card = NoticeCardView(t, w - 2 * geom.CONTENT_H_PAD)
        card.action.connect(lambda what: self._notice_action(t, what))
        self.buttons = card.buttons
        return card

    def _note_originator(self, t) -> None:
        """Remember the window that was in front when this card arrived, so
        Open IDE can bring it back (the Mac's capturedOriginator). A window
        handle the OS gave us, never anything from the payload."""
        if t.id not in self._originators:
            fg = winutil.foreground_window()
            self._originators[t.id] = fg if fg and fg != self._hwnd() else self._last_foreign
            self._originators = dict(list(self._originators.items())[-16:])

    def _notice_action(self, t, what: str) -> None:
        if what == "open":
            hwnd = self._originators.get(t.id) or 0
            if hwnd:
                winutil.set_foreground(hwnd)
        self._originators.pop(t.id, None)
        self.state.dismiss_toast(t.id)

    def _question_card(self, card, more: int) -> QWidget:
        sx, sy, sw, sh = self._screen_rect()
        self._card_w, self._formula_h = geom.question_size(
            [([d for _, d in q.options], True) for q in card.questions], screen_h=sh)
        top = geom.INSET + geom.CONTENT_TOP_GAP if self.top else 14
        inner_h = self._formula_h - top - geom.CONTENT_BOTTOM_PAD
        w = QuestionCardView(card, self._card_w - 2 * geom.CONTENT_H_PAD, inner_h)
        w.answered.connect(lambda answers: self.state.resolve_question(card.id, answers))
        self._question_view = w
        self.buttons = w.buttons
        return w

    def _send_answers(self, card) -> None:
        if self._question_view is not None:
            self.state.resolve_question(card.id, self._question_view.answers())

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
                return self._allow_current()
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
        if event.type() == QEvent.MouseButtonPress and isinstance(obj, QWidget) and obj.window() is self:
            if event.button() == Qt.LeftButton:
                self._take_keyboard()
        return False

    def contextMenuEvent(self, event) -> None:
        menu = QMenu(self)
        menu.addAction("Settings…", lambda: self.on_settings and self.on_settings())
        menu.addAction("Hide the notch", lambda: self.store and self.store.update(show_pill=False))
        menu.addSeparator()
        menu.addAction("Quit ClaudeNotch", lambda: self.on_quit and self.on_quit())
        menu.exec(event.globalPos())

    def _poll_hover(self) -> None:
        """MouseTracker.check: open from the trigger zone, stay open inside
        the keep region, never open mid-drag."""
        if not self.isVisible() or not self.top:
            return
        pos = QCursor.pos()
        screen = self._screen_rect()
        tw, th = (self._card_w, max(self._formula_h, self._target()[1])) if self._content else (380, 88)
        inside = geom.should_hover(
            is_hovering=self.hovering,
            button_down=bool(QGuiApplication.mouseButtons() & Qt.LeftButton),
            suppressed=False,
            in_keep_region=geom.contains(geom.keep_region(screen, tw, th), pos.x(), pos.y()),
            in_trigger_zone=geom.contains(geom.trigger_zone(screen), pos.x(), pos.y()),
        )
        if inside != self.hovering:
            self.hovering = inside
            self.render()

    def enterEvent(self, event) -> None:
        # Bottom-right has no trigger zone: hovering the card itself opens it.
        if not self.top and not self.hovering:
            self.hovering = True
            self.render()
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        if not self.top:
            QTimer.singleShot(view.COLLAPSE_DELAY_MS, self._collapse_bottom_right)
        super().leaveEvent(event)

    def _collapse_bottom_right(self) -> None:
        if self.frameGeometry().contains(QCursor.pos()):
            return
        self.hovering = False
        self.render()

    def show_sessions(self, seconds: float = 6.0) -> None:
        """From the tray: open the card for a few seconds."""
        self.pinned_until = time.monotonic() + seconds
        self._shown_key = None
        self.render()
        QTimer.singleShot(int(seconds * 1000) + 50, self.render)

    # --- timers ----------------------------------------------------------------------------

    def _tick(self) -> None:
        # A session's card waits until it is dismissed, as on the Mac; only
        # the app's own hello and update notes go by themselves.
        now = time.monotonic()
        _, _, toasts, _ = self.state.snapshot()
        for t in toasts:
            if t.system and now - t.created > view.TOAST_SECONDS:
                self.state.dismiss_toast(t.id)
        if self.state.auto_info is not None and now - self.state.auto_info_at > view.AUTO_INFO_SECONDS:
            self.state.dismiss_auto_info()
        fg = winutil.foreground_window()
        if fg and fg != self._hwnd():
            self._last_foreign = fg

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
