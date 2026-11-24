"""The cards inside the notch, laid out as the Mac lays them out.

PermissionCardView ports NotchPermissionCard.PermissionCard, IdleCardView
ports NotchIdlePill.IdlePill, NoticeCardView ports NotchCards'
NotificationCard and CompletedCard, QuestionCardView ports QuestionCard.
Spacing, sizes and colours are the Swift source's; the widgets that draw
them are in notchwidgets.py.
"""

from __future__ import annotations

import time

from PySide6.QtCore import QEvent, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QPainter, QPainterPath, QPalette, QPen
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLineEdit, QScrollArea, QSizePolicy, QVBoxLayout, QWidget

from claudenotch import protocol

from claudenotch import budget

from . import cardmodel, hello, notchgeom
from . import macstyle as ms
from . import notchwidgets as nw

#: The Mac's keycaps on its buttons: ⎋ on Deny, ⏎ on Allow.
ESC_GLYPH = "⎋"
RETURN_GLYPH = "⏎"


def _row(spacing: int) -> QHBoxLayout:
    r = QHBoxLayout()
    r.setContentsMargins(0, 0, 0, 0)
    r.setSpacing(spacing)
    return r


def accent_for(dangerous: bool, budget: bool = False):
    if dangerous:
        return ms.RED, "exclamationmark.triangle.fill"
    if budget:
        return ms.ORANGE, "dollarsign.circle.fill"
    return ms.YELLOW, "exclamationmark.bubble.fill"


class PermissionCardView(QWidget):
    """The blocking tool-use card. Emits `decided(decision, scope)` where
    scope is "" for a one-off answer, "exact" or "tool" for an always-allow
    rule, or "all" for Allow All (n)."""

    decided = Signal(str, str)
    #: Windows Hello's answer, delivered on the GUI thread.
    _hello_done = Signal(bool, object)

    def __init__(self, card, pending: int = 1, width: float = 564, gate: str = "hold", hwnd: int = 0,
                 parent=None, pet: bool = False, prior_approvals: int = 0):
        super().__init__(parent)
        self.gate, self._hwnd = gate, hwnd
        self._hello_done.connect(self._hello_answered)
        self.card = card
        self.text = cardmodel.card_text(card)
        self.buttons: dict[str, QWidget] = {}
        self.setAttribute(Qt.WA_TranslucentBackground)
        dangerous = bool(card.dangers)
        block = getattr(card, "budget_block", None)
        accent, icon = accent_for(dangerous, block is not None)

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)

        # Header: icon · SOURCE · tool · waiting …  sandbox  project
        head = _row(8)
        head.addWidget(nw.Glyph(icon, 14, accent))
        head.addWidget(nw.Text(self.text.source, 11, "semibold", accent, 0.9, upper=True, fixed=True))
        head.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
        head.addWidget(nw.Text(self.text.tool, 11, "medium", opacity=0.55, fixed=True))
        self._waiting = nw.Text("", 10, "semibold", ms.ORANGE, 0.9, fixed=True)
        self._waiting.hide()
        head.addWidget(self._waiting)
        head.addStretch(1)
        if self.text.project:
            head.addWidget(nw.Text(self.text.project, 10, opacity=0.4, fixed=True))
        v.addLayout(head)

        stale = bool(getattr(card, "stale", False))
        if stale:
            v.addWidget(nw.expired_banner(nw.TOO_LATE_PERMISSION))
        if dangerous:
            v.addWidget(nw.danger_banner(card.dangers, pet=pet))
        if block is not None:
            v.addWidget(self._budget_banner(block))

        v.addWidget(nw.Text(self.text.title, 14, "semibold"))

        if self.text.detail:
            v.addWidget(nw.code_box(self.text.detail))

        p = self.text.preview
        if p is not None:
            if p.kind == "diff":
                v.addWidget(nw.DiffView(p.hunk))
            elif p.kind == "multi":
                box = QVBoxLayout()
                box.setSpacing(4)
                box.addWidget(nw.Text(f"First of {p.count} edits", 10, "semibold", opacity=0.5, upper=True))
                box.addWidget(nw.DiffView(p.hunk))
                v.addLayout(box)
            else:
                more = cardmodel.more_lines_text(p.total) if p.total > cardmodel.MAX_WRITE_LINES else None
                v.addWidget(nw.write_preview(p.head, p.total, more))

        # The buttons sit 18 under the content (8 spacing + 18 padding).
        v.addSpacing(18)
        row = _row(8)
        if stale:
            # Deny goes with Allow: neither reaches the session any more, and a
            # Deny that silently does nothing would read as "I stopped that".
            row.addStretch(1)
            dismiss = nw.NotchButton("Dismiss", "primary")
            dismiss.clicked.connect(lambda: self.decided.emit(protocol.DENY, ""))
            row.addWidget(dismiss)
            self.buttons["dismiss"] = dismiss
            v.addLayout(row)
            self.auth_message = nw.wrap_label("", 11, rgb=ms.ORANGE, opacity=0.95)
            self.auth_message.hide()
            self.setFixedWidth(int(width))
            self._waiting.hide()
            return
        deny = nw.NotchButton("Deny", "destructive", ESC_GLYPH)
        deny.clicked.connect(lambda: self.decided.emit(protocol.DENY, ""))
        row.addWidget(deny)
        self.buttons["deny"] = deny
        # Deny with a reason: tell Claude what to do instead (onDenyReason).
        why = nw.CapsuleButton(icon="text.bubble", fill=0.10)
        why.setToolTip("Deny with a reason, tell Claude what to do instead")
        why.setAccessibleName("Deny with a reason")
        why.clicked.connect(lambda: self.decided.emit(protocol.DENY, "reason"))
        row.addWidget(why)
        self.buttons["deny_reason"] = why
        if not dangerous and block is None:
            always = nw.CapsuleButton("Always Allow…", chevron=True)
            always.clicked.connect(self._always_menu)
            always.setAccessibleDescription(
                f"Choose to always allow this exact command, or every {card.tool} call")
            row.addWidget(always)
            self.buttons["always"] = always
            if prior_approvals > 0:
                # Said at the one moment the answer is obvious: the same
                # command waved through several times already.
                hint = nw.Text(f"allowed {prior_approvals} times", 11, opacity=0.55, fixed=True)
                hint.setAccessibleName(f"You have allowed this command {prior_approvals} times before")
                row.addWidget(hint)
                self.prior_hint = hint
        row.addStretch(1)
        if block is not None:
            # Over budget: explicit choices only, and no Return shortcut.
            once = nw.NotchButton("Allow once", "secondary")
            once.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, ""))
            row.addWidget(once)
            self.buttons["allow"] = once
            raise_to = nw.NotchButton(f"Raise to {budget.money(budget.next_cap(block.cost, block.cap))}", "primary")
            raise_to.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, "raise"))
            row.addWidget(raise_to)
            self.buttons["raise"] = raise_to
        elif dangerous and gate == hello.NONE:
            # Confirmation switched off (behind Windows Hello): still red,
            # still one deliberate press.
            allow = nw.NotchButton("Allow", "destructive", RETURN_GLYPH)
            allow.setToolTip("Confirmation for destructive commands is off in Settings")
            allow.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, ""))
            row.addWidget(allow)
            self.buttons["allow"] = allow
        elif dangerous and gate == hello.HELLO:
            confirm = nw.ConfirmButton("Confirm to Allow")
            confirm.setToolTip("Confirm with Windows Hello to run this destructive command")
            confirm.clicked.connect(self._ask_hello)
            row.addWidget(confirm)
            self.buttons["allow"] = confirm
        elif dangerous:
            hold = nw.HoldToConfirmButton("Hold to Allow", 0.9)
            hold.confirmed.connect(lambda: self.decided.emit(protocol.ALLOW, ""))
            row.addWidget(hold)
            self.buttons["allow"] = hold
        elif pending > 1:
            one = nw.NotchButton("Allow", "secondary")
            one.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, ""))
            row.addWidget(one)
            self.buttons["allow"] = one
            every = nw.NotchButton(f"Allow All ({pending})", "primary", RETURN_GLYPH)
            every.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, "all"))
            row.addWidget(every)
            self.buttons["allow_all"] = every
        else:
            allow = nw.NotchButton("Allow", "primary", RETURN_GLYPH)
            allow.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, ""))
            row.addWidget(allow)
            self.buttons["allow"] = allow
        v.addLayout(row)
        # Why the last Windows Hello attempt did not go through: without it a
        # locked-out Hello makes Confirm look like a button that does nothing.
        self.auth_message = nw.wrap_label("", 11, rgb=ms.ORANGE, opacity=0.95)
        self.auth_message.hide()
        v.addWidget(self.auth_message)

        self.setFixedWidth(int(width))
        self._tick = QTimer(self, interval=15000)
        self._tick.timeout.connect(self._update_waiting)
        self._tick.start()
        self._update_waiting()

    def _budget_banner(self, block) -> QWidget:
        """BudgetBanner: orange 14 % fill, 35 % stroke, a coin, "Over your daily
        budget", the spend against the cap, and Turn off on the right."""
        box = nw.RoundedBox(ms.rgba(ms.ORANGE, 0.14), 8, ms.rgba(ms.ORANGE, 0.35))
        row = QHBoxLayout(box)
        row.setContentsMargins(10, 7, 10, 7)
        row.setSpacing(8)
        row.addWidget(nw.Glyph("dollarsign.circle.fill", 11, ms.ORANGE))
        col = QVBoxLayout()
        col.setSpacing(1)
        col.addWidget(nw.Text(f"Over your {block.scope} budget", 11, "semibold", ms.ORANGE, 0.95))
        col.addWidget(nw.Text(f"{budget.money(block.cost)} of {budget.money(block.cap)} cap ({block.pct}%)", 10,
                              rgb=ms.ORANGE, opacity=0.85))
        row.addLayout(col, 1)
        off = nw.NotchButton("Turn off", "secondary")
        off.setToolTip("Turn off budget enforcement and allow this command")
        off.clicked.connect(lambda: self.decided.emit(protocol.ALLOW, "turn_off"))
        row.addWidget(off)
        self.buttons["turn_off"] = off
        return box

    def _ask_hello(self) -> None:
        from claudenotch.redact import redact
        reason = "Allow this command: " + redact(self.text.detail)[:80]
        hello.confirm_async(self._hwnd, reason, lambda ok, msg: self._hello_done.emit(ok, msg))

    def _hello_answered(self, ok: bool, message) -> None:
        if ok:
            self.decided.emit(protocol.ALLOW, "")
            return
        self.auth_message.setText(message or "")
        self.auth_message.setVisible(bool(message))

    def _update_waiting(self) -> None:
        waited = time.monotonic() - self.card.created
        if waited >= 60:
            self._waiting.set_text(f"⏳ waiting {notchgeom.wait_elapsed(waited)}")
            self._waiting.show()

    def _always_menu(self) -> None:
        menu = nw.dark_menu(self)
        menu.addAction("Always Allow This Exact Command", lambda: self.decided.emit(protocol.ALLOW, "exact"))
        menu.addAction(f"Always Allow All {self.card.tool}", lambda: self.decided.emit(protocol.ALLOW, "tool"))
        btn = self.buttons["always"]
        menu.exec(btn.mapToGlobal(btn.rect().bottomLeft()))

    def budget(self, screen_h: float = 900.0) -> tuple[float, float]:
        """NotchView.size(for: .permission) for this card."""
        return notchgeom.permission_size(dangers=len(self.card.dangers), screen_h=screen_h,
                                         budget=getattr(self.card, "budget_block", None) is not None,
                                         **cardmodel.preview_budget(self.text.preview))


def idle_header(sessions) -> tuple[str, str, tuple, bool]:
    """IdlePill's row 1, from the core's sessions: the name ("Claude", or
    "Claude · N sessions"), the status word, the dot colour, and whether it
    is active (pulsing dot, shimmering word)."""
    n = len(sessions)
    entity = cardmodel.entity_name(sessions)
    name = f"{entity} · {n} sessions" if n >= 2 else entity
    working = any(s.status in ("working", "waiting") for s in sessions)
    if working:
        return name, "Running command", ms.BLUE, True
    replied = any(s.status == "ready" and s.last_prompt for s in sessions)
    return name, "Ready", (ms.GREEN if replied else ms.GRAY), False


class IdleCardView(QWidget):
    """The open hover card: the mascot, the name, the status dot and word,
    then the model and the context and cost meter. The clock on the right,
    or a click on the name, opens the history drawer (`history`)."""

    history = Signal()
    #: The expand button: Claude's last reply in full.
    expand = Signal()

    def __init__(self, sessions, branch: str = "", rows=None, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TranslucentBackground)
        name, status, dot_rgb, active = idle_header(sessions)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(10)

        r1 = _row(6)
        r1.addWidget(nw.ClaudeIcon(15, "working" if active else "calm"))
        r1.addWidget(nw.Text(name, 12, "semibold", fixed=True))
        r1.addWidget(nw.Dot(dot_rgb, pulse=active))
        if active:
            r1.addWidget(nw.ShimmerText(status, 10))
        else:
            r1.addWidget(nw.Text(status, 10, opacity=0.38, fixed=True))
        agents = sum(s.agents for s in sessions)
        if agents:
            r1.addWidget(_badge("1 agent" if agents == 1 else f"{agents} agents", ms.PURPLE, 0.18))
        r1.addStretch(1)
        clock = nw.Glyph("clock.arrow.circlepath", 11, opacity=0.45)
        clock.setCursor(Qt.PointingHandCursor)
        clock.setToolTip("Show history")
        clock.setAccessibleName("Show history")
        clock.mouseReleaseEvent = lambda e: self.history.emit() if e.button() == Qt.LeftButton else None
        r1.addWidget(clock)
        self.history_button = clock
        self.expand_button = None
        if sessions and getattr(sessions[0], "last_reply", ""):
            grow = nw.Glyph("expand", 11, opacity=0.45)
            grow.setCursor(Qt.PointingHandCursor)
            grow.setToolTip("Show Claude's last reply")
            grow.setAccessibleName("Show Claude's last reply")
            grow.mouseReleaseEvent = lambda e: self.expand.emit() if e.button() == Qt.LeftButton else None
            r1.addWidget(grow)
            self.expand_button = grow
        v.addLayout(r1)

        # Row 2: the TOP session's model, effort, branch and meter, all from
        # that one session so they agree with each other.
        m = cardmodel.idle_meter(sessions[0] if sessions else None, branch)
        r2 = _row(5)
        if m.model_name:
            r2.addWidget(_model_label(m.model_name, m.model_version))
            if m.effort:
                r2.addWidget(_small_dot())
        if m.effort:
            r2.addWidget(nw.Text(f"{m.effort} effort", 10, opacity=0.35, fixed=True))
        if m.branch:
            chip = _row(3)
            chip.addWidget(nw.Glyph("arrow.triangle.branch", 8, opacity=0.3))
            chip.addWidget(nw.Text(m.branch_short, 10, opacity=0.45, fixed=True))
            r2.addLayout(chip)
        r2.addStretch(1)
        r2.addWidget(nw.context_cost_bar(m.context_pct, m.tokens, m.window, m.cost))
        v.addLayout(r2)
        # Row 3: the command strip, only while the top session is working.
        top = sessions[0] if sessions else None
        self.strip = None
        if top is not None and top.status == "working" and getattr(top, "activity", ""):
            self.strip = nw.CommandStrip(top.activity, getattr(top, "activity_started", None))
            v.addWidget(self.strip)
        # The task list, when there is a real one (a lone 1/1 says nothing).
        self.tasks = None
        done, total = getattr(top, "task_progress", (0, 0)) if top is not None else (0, 0)
        if total > 1:
            self.tasks = nw.TaskProgress(done, total)
            v.addWidget(self.tasks)
        self.meter = m
        self.content_width = self._natural_width(name, status, agents, m)
        self.list_view = None
        if rows:
            self.list_view = SessionsListView(rows)
            v.addWidget(self.list_view)
            self.content_width = max(self.content_width, self.list_view.natural_width())

    @staticmethod
    def _natural_width(name: str, status: str, agents: int, m) -> float:
        """NotchView.idleContentWidth for what this card shows."""
        from PySide6.QtGui import QFontMetricsF
        fm12 = QFontMetricsF(ms.font(12, "semibold"))
        fm10 = QFontMetricsF(ms.font(10))
        fm10b = QFontMetricsF(ms.font(10, "semibold"))
        fm9 = QFontMetricsF(ms.font(9))
        fm9m = QFontMetricsF(ms.font(9, "medium"))
        row1 = [15, fm12.horizontalAdvance(name), 5, fm10.horizontalAdvance(status)]
        if agents:
            row1.append(fm9m.horizontalAdvance(f"{agents} agents") + 10)
        row1.append(34)
        w1 = sum(row1) + (len(row1) - 1) * 6
        row2 = []
        if m.model_name:
            label = f"{m.model_name} {m.model_version}" if m.model_version else m.model_name
            row2.append(fm10b.horizontalAdvance(label))
            if m.effort:
                row2.append(2.5)
        if m.effort:
            row2.append(fm10.horizontalAdvance(f"{m.effort} effort"))
        if m.branch:
            row2.append(11 + fm10.horizontalAdvance(m.branch_short))
        bar = [36, fm9.horizontalAdvance(m.meter_label)]
        if m.cost:
            bar.append(fm9.horizontalAdvance(m.cost_label))
        row2.append(sum(bar) + (len(bar) - 1) * 5)
        w2 = sum(row2) + max(0, len(row2) - 1) * 5
        return max(w1, w2)


class Hairline(QWidget):
    """The 0.5 pt white 8 % rule above the session list."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(1)
        self.setAttribute(Qt.WA_TranslucentBackground)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setPen(QPen(ms.rgba(ms.WHITE, 0.08), 0.5))
        p.drawLine(0, 0, self.width(), 0)


def _chip(text: str, rgb, size: float = 8, weight: str = "bold", pad=(4, 1), radius: float = 3,
          fill: float = 0.18) -> QWidget:
    box = nw.RoundedBox(ms.rgba(rgb, fill), radius)
    lay = QHBoxLayout(box)
    lay.setContentsMargins(pad[0], pad[1], pad[0], pad[1])
    lay.addWidget(nw.Text(text, size, weight, rgb, 0.95, fixed=True))
    box.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
    return box


def _icon_text(icon: str, text: str, size: float = 9, icon_size: float = 7, opacity: float = 0.4):
    row = _row(2)
    row.addWidget(nw.Glyph(icon, icon_size, opacity=opacity))
    row.addWidget(nw.Text(text, size, opacity=opacity, fixed=True))
    return row


class _ClickRow(QWidget):
    """A session row you can click (showSessionResponse)."""

    clicked = Signal(str)

    def __init__(self, sid: str, parent=None):
        super().__init__(parent)
        self.sid = sid
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setCursor(Qt.PointingHandCursor)
        self.setToolTip("Show this session's last reply")

    def mouseReleaseEvent(self, e) -> None:
        if e.button() == Qt.LeftButton:
            self.clicked.emit(self.sid)


class SessionsListView(QWidget):
    """SessionsList: a hairline, then one row per other session, 3 pt of
    padding above and below each: the status dot (6 pt, blue and pulsing
    while working, else green), a CLI chip, the folder at 11 pt medium, its
    branch and worktree, the hourglass, agents, and the status word at
    10 pt, with the session's context meter 14 in on a second line."""

    #: A row was clicked: that session's id.
    selected = Signal(str)

    def __init__(self, rows, parent=None):
        super().__init__(parent)
        self.rows = rows
        self.setAttribute(Qt.WA_TranslucentBackground)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        v.addWidget(Hairline())
        v.addSpacing(4)
        for r in rows:
            box = QVBoxLayout()
            box.setContentsMargins(0, 3, 0, 3)
            box.setSpacing(2)
            line = _row(8)
            line.addWidget(nw.Dot(ms.BLUE if r.working else ms.GREEN, pulse=r.working, diameter=6))
            if r.agent:
                line.addWidget(_chip(r.agent, ms.TEAL))
            line.addWidget(nw.Text(r.label, 11, "medium", opacity=0.9))
            if r.branch_short:
                line.addLayout(_icon_text("arrow.triangle.branch", r.branch_short))
            if r.worktree_short:
                line.addLayout(_icon_text("square.on.square", r.worktree_short))
            if r.waiting:
                line.addWidget(_chip(r.waiting, ms.ORANGE, 9, "semibold", (5, 2), 4))
            if r.agents:
                line.addWidget(_chip("1 agent" if r.agents == 1 else f"{r.agents} agents", ms.PURPLE, 9,
                                     "medium", (5, 2), 4))
            line.addStretch(1)
            line.addSpacing(8)
            line.addWidget(nw.Text(r.status, 10, opacity=0.5, fixed=True))
            box.addLayout(line)
            if r.meter is not None:
                meter = _row(0)
                meter.addSpacing(14)
                meter.addWidget(nw.context_cost_bar(r.meter.context_pct, r.meter.tokens, r.meter.window,
                                                    r.meter.cost))
                meter.addStretch(1)
                box.addLayout(meter)
            holder = _ClickRow(r.id)
            holder.setLayout(box)
            holder.clicked.connect(self.selected.emit)
            v.addWidget(holder)

    def natural_width(self) -> float:
        """NotchView.idleContentWidth's estimate for these rows."""
        from PySide6.QtGui import QFontMetricsF
        fm11 = QFontMetricsF(ms.font(11, "medium"))
        fm10 = QFontMetricsF(ms.font(10))
        fm9 = QFontMetricsF(ms.font(9))
        widest = 0.0
        for r in self.rows:
            parts = [6]
            if r.agent:
                parts.append(44)
            parts.append(fm11.horizontalAdvance(r.label))
            if r.branch_short:
                parts.append(11 + fm10.horizontalAdvance(r.branch_short))
            if r.worktree_short:
                parts.append(11 + fm10.horizontalAdvance(r.worktree_short))
            if r.waiting:
                parts.append(fm9.horizontalAdvance(r.waiting) + 10)
            if r.agents:
                parts.append(fm9.horizontalAdvance(f"{r.agents} agents") + 10)
            parts.append(fm10.horizontalAdvance(r.status) + 12)
            widest = max(widest, sum(parts) + (len(parts) - 1) * 8)
            if r.meter is not None:
                bar = 14 + 36 + 5 + fm9.horizontalAdvance(r.meter.meter_label)
                if r.meter.cost:
                    bar += 5 + fm9.horizontalAdvance(r.meter.cost_label)
                widest = max(widest, bar)
        return widest


def _model_label(name: str, version: str) -> QWidget:
    """"Opus" at 10 pt semibold 65 %, " 5.5" at 10 pt regular 45 %: one run."""
    w = QWidget()
    w.setAttribute(Qt.WA_TranslucentBackground)
    row = _row(0)
    w.setLayout(row)
    row.addWidget(nw.Text(name, 10, "semibold", opacity=0.65, fixed=True))
    if version:
        row.addWidget(nw.Text(f" {version}", 10, opacity=0.45, fixed=True))
    return w


def _small_dot() -> QWidget:
    d = nw.Dot(ms.WHITE, diameter=2.5)
    d.set_opacity(0.18)
    return d


def _badge(text: str, rgb, fill: float) -> QWidget:
    box = nw.RoundedBox(ms.rgba(rgb, fill), 4)
    lay = QHBoxLayout(box)
    lay.setContentsMargins(5, 2, 5, 2)
    lay.addWidget(nw.Text(text, 9, "medium", rgb, 0.95, fixed=True))
    return box


# --- notification and done cards ------------------------------------------------------------


class NoticeCardView(QWidget):
    """NotificationCard (orange bell, Dismiss, Open IDE) or CompletedCard
    (green seal, Open IDE, Done), chosen by cardmodel.notice_text. Rows 14
    apart; the title wraps to two lines next to the buttons, 16 between.
    Emits `action("dismiss" | "open")`."""

    action = Signal(str)

    def __init__(self, toast, width: float, parent=None, pet: bool = False):
        super().__init__(parent)
        self.toast = toast
        self.text = cardmodel.notice_text(toast)
        self.buttons: dict[str, QWidget] = {}
        self.setAttribute(Qt.WA_TranslucentBackground)
        done = self.text.card == "completed"
        accent = ms.GREEN if done else ms.ORANGE

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(14)

        head = _row(8)
        head.addWidget(nw.Glyph("checkmark.seal.fill" if done else "bell.fill", 14 if done else 13, accent))
        inner = _row(6)
        inner.addWidget(nw.Text(self.text.source, 11, "semibold", accent, 0.9, upper=True, fixed=True))
        inner.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
        self._ago = nw.Text(notchgeom.time_ago(0), 10, opacity=0.45, fixed=True)
        inner.addWidget(self._ago)
        head.addLayout(inner)
        head.addStretch(1)
        # Top right of the header: the pet dances out a finished task, or
        # cries over a plan limit.
        if pet and done:
            head.addWidget(nw.pet_badge_slot(self, 32, loop=3.4, dance=True))
        elif pet and getattr(toast, "kind", "") == "limit":
            head.addWidget(nw.pet_badge_slot(self, 32, activity="fret", loop=1.6, emote="teardrop"))
        v.addLayout(head)

        body = _row(16)
        col = QVBoxLayout()
        col.setContentsMargins(0, 0, 0, 0)
        col.setSpacing(3)
        col.addWidget(nw.LinesText(self.text.title, 14, "semibold", max_lines=2))
        if self.text.detail:
            if done:
                col.addWidget(nw.LinesText(self.text.detail, 11, opacity=0.6, max_lines=2))
            else:
                col.addWidget(nw.Text(self.text.detail, 11, opacity=0.55, elide=Qt.ElideMiddle))
        body.addLayout(col, 1)
        buttons = _row(8)
        if done:
            reply = nw.NotchButton("Reply", "secondary")
            reply.setToolTip("Send Claude a follow-up message")
            reply.clicked.connect(lambda: self.action.emit("reply"))
            buttons.addWidget(reply)
            self.buttons["reply"] = reply
            opener, close = nw.NotchButton("Open IDE", "secondary"), nw.NotchButton("Done", "primary")
            buttons.addWidget(opener)
            buttons.addWidget(close)
        else:
            close, opener = nw.NotchButton("Dismiss", "secondary"), nw.NotchButton("Open IDE", "primary")
            buttons.addWidget(close)
            buttons.addWidget(opener)
        self.buttons.update(open=opener, dismiss=close)
        opener.clicked.connect(lambda: self.action.emit("open"))
        close.clicked.connect(lambda: self.action.emit("dismiss"))
        body.addLayout(buttons)
        v.addLayout(body)
        self.setFixedWidth(int(width))

        self._tick = QTimer(self, interval=5000)
        self._tick.timeout.connect(self._update_ago)
        self._tick.start()
        self._update_ago()

    def _update_ago(self) -> None:
        self._ago.set_text(notchgeom.time_ago(time.monotonic() - self.toast.created))


# --- question card ------------------------------------------------------------------------


class OptionRow(QWidget):
    """One answer: the radio or checkbox symbol (13 pt, purple when picked),
    the label at 12 pt medium, the description at 10 pt wrapping; 8 x 5
    padding on a 6 pt rounded fill, purple 18 % when picked, else white 4 %."""

    toggled = Signal()

    def __init__(self, label: str, description: str, multi: bool, parent=None):
        super().__init__(parent)
        self.label, self.multi, self.selected = label, multi, False
        self.setCursor(Qt.PointingHandCursor)
        self.setAttribute(Qt.WA_TranslucentBackground)
        row = QHBoxLayout(self)
        row.setContentsMargins(8, 5, 8, 5)
        row.setSpacing(8)
        icon_col = QVBoxLayout()
        icon_col.setContentsMargins(0, 0, 0, 0)
        self._icon = nw.Glyph("square" if multi else "circle", 13, opacity=0.4)
        icon_col.addWidget(self._icon)
        icon_col.addStretch(1)
        row.addLayout(icon_col)
        col = QVBoxLayout()
        col.setContentsMargins(0, 0, 0, 0)
        col.setSpacing(1)
        col.addWidget(nw.Text(label, 12, "medium"))
        if description:
            col.addWidget(nw.wrap_label(description, 10, opacity=0.5))
        row.addLayout(col, 1)
        self.setAccessibleName(f"{label}. {description}" if description else label)
        self.setAccessibleDescription("Choose one or more" if multi else "Choose one")

    def set_selected(self, on: bool) -> None:
        self.selected = on
        if self.multi:
            self._icon.name = "checkmark.square.fill" if on else "square"
        else:
            self._icon.name = "largecircle.fill.circle" if on else "circle"
        self._icon.set_color(ms.PURPLE if on else ms.WHITE, 1.0 if on else 0.4)
        self.update()

    def setChecked(self, on: bool) -> None:
        """Tests and keyboard: pick this option as a click would."""
        if on != self.selected:
            self.toggled.emit()

    def mousePressEvent(self, e) -> None:
        if e.button() == Qt.LeftButton:
            self.toggled.emit()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()), 6, 6)
        p.fillPath(path, ms.rgba(ms.PURPLE, 0.18) if self.selected else ms.rgba(ms.WHITE, 0.04))


class OtherRow(QWidget):
    """The free-text answer: a pencil symbol and "Something else… (type your
    own answer)", purple once something is typed, outlined while focused."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TranslucentBackground)
        row = QHBoxLayout(self)
        row.setContentsMargins(8, 7, 8, 7)
        row.setSpacing(8)
        self._icon = nw.Glyph("pencil.circle", 13, opacity=0.4)
        row.addWidget(self._icon)
        self.edit = QLineEdit()
        self.edit.setPlaceholderText("Something else… (type your own answer)")
        self.edit.setFont(ms.font(12, "medium"))
        self.edit.setFrame(False)
        self.edit.setStyleSheet("QLineEdit { background: transparent; color: white; border: none; padding: 0; }")
        pal = self.edit.palette()
        pal.setColor(QPalette.PlaceholderText, ms.rgba(ms.WHITE, 0.35))
        self.edit.setPalette(pal)
        self.edit.setAccessibleName("Your own answer")
        self.edit.setAccessibleDescription("Type an answer if none of the options fit")
        self.edit.textChanged.connect(self._changed)
        self.edit.installEventFilter(self)
        row.addWidget(self.edit, 1)

    @property
    def active(self) -> bool:
        return bool(self.edit.text().strip())

    def _changed(self) -> None:
        on = self.active
        self._icon.name = "pencil.circle.fill" if on else "pencil.circle"
        self._icon.set_color(ms.PURPLE if on else ms.WHITE, 1.0 if on else 0.4)
        self.update()

    def eventFilter(self, obj, e) -> bool:
        if e.type() in (QEvent.FocusIn, QEvent.FocusOut):
            self.update()
        return False

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 6, 6)
        p.fillPath(path, ms.rgba(ms.PURPLE, 0.18) if self.active else ms.rgba(ms.WHITE, 0.04))
        if self.edit.hasFocus():
            p.setPen(QPen(ms.rgba(ms.PURPLE, 0.6), 1))
            p.drawPath(path)


def _header_pill(text: str) -> QWidget:
    box = nw.RoundedBox(ms.rgba(ms.PURPLE, 0.18), 4)
    lay = QHBoxLayout(box)
    lay.setContentsMargins(6, 2, 6, 2)
    lay.addWidget(nw.Text(text, 10, "bold", ms.PURPLE, 0.85, fixed=True))
    box.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
    return box


_SCROLL_STYLE = (
    "QScrollArea { background: transparent; }"
    "QScrollBar:vertical { background: transparent; width: 6px; margin: 0; }"
    "QScrollBar::handle:vertical { background: rgba(255,255,255,0.25); border-radius: 3px; min-height: 24px; }"
    "QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page"
    " { background: none; height: 0; }")


class QuestionCardView(QWidget):
    """QuestionCard: purple header with the question count, then each
    question (header pill, the question at 13 pt semibold, its option rows,
    the free-text row) in a list that scrolls only past the height cap,
    then Cancel and Send 18 below. Nothing is picked to start with, as on
    the Mac. Emits `answered(list | None)`."""

    answered = Signal(object)

    def __init__(self, card, width: float, height: float, allow_custom: bool = True, parent=None):
        super().__init__(parent)
        self.card = card
        self.buttons: dict[str, QWidget] = {}
        self.selections: list[set] = [set() for _ in card.questions]
        self.rows: list[list[OptionRow]] = []
        self.others: list[OtherRow | None] = []
        self.setAttribute(Qt.WA_TranslucentBackground)

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(10)
        head = _row(8)
        head.addWidget(nw.Glyph("questionmark.bubble.fill", 14, ms.PURPLE))
        head.addWidget(nw.Text("Claude Code", 11, "semibold", ms.PURPLE, 0.9, upper=True, fixed=True))
        head.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
        head.addWidget(nw.Text(cardmodel.question_count_text(len(card.questions)), 11, "medium", opacity=0.55,
                               fixed=True))
        head.addStretch(1)
        v.addLayout(head)
        if getattr(card, "stale", False):
            v.addWidget(nw.expired_banner(nw.TOO_LATE_QUESTION))

        body = QWidget()
        body.setAttribute(Qt.WA_TranslucentBackground)
        body.setStyleSheet("background: transparent;")
        bl = QVBoxLayout(body)
        bl.setContentsMargins(0, 0, 0, 0)
        bl.setSpacing(14)
        for qi, q in enumerate(card.questions):
            block = QVBoxLayout()
            block.setSpacing(6)
            top = _row(6)
            if q.header:
                pill_col = QVBoxLayout()
                pill_col.setContentsMargins(0, 0, 0, 0)
                pill_col.addWidget(_header_pill(q.header))
                pill_col.addStretch(1)
                top.addLayout(pill_col)
            top.addWidget(nw.wrap_label(q.text, 13, "semibold"), 1)
            block.addLayout(top)
            rows = []
            for oi, (label, desc) in enumerate(q.options):
                r = OptionRow(label, desc, q.multi_select)
                r.toggled.connect(lambda qi=qi, label=label: self._toggle(qi, label))
                block.addWidget(r)
                rows.append(r)
                self.buttons[f"q{qi}o{oi}"] = r
            self.rows.append(rows)
            other = OtherRow() if allow_custom else None
            if other is not None:
                block.addWidget(other)
            self.others.append(other)
            bl.addLayout(block)
        bl.addStretch(1)

        scroll = QScrollArea()
        scroll.setWidget(body)
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setStyleSheet(_SCROLL_STYLE)
        scroll.viewport().setAutoFillBackground(False)
        scroll.viewport().setStyleSheet("background: transparent;")
        v.addWidget(scroll, 1)

        v.addSpacing(18 - 10)
        row = _row(8)
        row.addStretch(1)
        if getattr(card, "stale", False):
            dismiss = nw.NotchButton("Dismiss", "primary")
            dismiss.clicked.connect(lambda: self.answered.emit(None))
            row.addWidget(dismiss)
            self.buttons.update(dismiss=dismiss)
        else:
            cancel = nw.NotchButton("Cancel", "secondary")
            cancel.clicked.connect(lambda: self.answered.emit(None))
            send = nw.NotchButton("Send", "primary")
            send.clicked.connect(self._send)
            row.addWidget(cancel)
            row.addWidget(send)
            self.buttons.update(skip=cancel, send=send)
        v.addLayout(row)

        self.setFixedWidth(int(width))
        self.setFixedHeight(int(height))

    def _toggle(self, qi: int, label: str) -> None:
        q = self.card.questions[qi]
        sel = self.selections[qi]
        if q.multi_select:
            sel.symmetric_difference_update({label})
        else:
            sel.clear()
            sel.add(label)
        for r in self.rows[qi]:
            r.set_selected(r.label in sel)

    def answers(self) -> list[list[str]]:
        return cardmodel.build_answers([q.multi_select for q in self.card.questions], self.selections,
                                       [o.edit.text() if o else "" for o in self.others])

    def _send(self) -> None:
        self.answered.emit(self.answers())


# --- the Auto-allowed card (NotchCards.AutoInfoCard) ---------------------------------------


class AutoInfoCardView(QWidget):
    """AutoInfoCard: no buttons, it already happened. A green bolt badge,
    AUTO-ALLOWED · tool, "click to dismiss" at 9 pt, the title, and the
    command in 12 pt monospaced at 70 %, cut in the middle. A click takes
    it down; otherwise it goes after four seconds."""

    clicked = Signal()

    def __init__(self, card, width: float, parent=None):
        super().__init__(parent)
        self.card = card
        text = cardmodel.card_text(card)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setCursor(Qt.PointingHandCursor)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)
        head = _row(8)
        head.addWidget(nw.Glyph("bolt.badge.checkmark.fill", 13, ms.GREEN))
        head.addWidget(nw.Text("Auto-allowed", 11, "semibold", ms.GREEN, 0.9, upper=True, fixed=True))
        head.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
        head.addWidget(nw.Text(card.tool, 11, "medium", opacity=0.55, fixed=True))
        head.addStretch(1)
        head.addWidget(nw.Text("click to dismiss", 9, opacity=0.3, fixed=True))
        v.addLayout(head)
        v.addWidget(nw.Text(text.title, 14, "semibold"))
        if text.detail:
            v.addWidget(nw.Text(text.detail.splitlines()[0], 12, mono=True, opacity=0.7, elide=Qt.ElideMiddle))
        self.setFixedWidth(int(width))
        self.setAccessibleName(" ".join(x for x in ("Auto-allowed.", text.title, f"Tool: {card.tool}.") if x))

    def mousePressEvent(self, e) -> None:
        if e.button() == Qt.LeftButton:
            self.clicked.emit()
