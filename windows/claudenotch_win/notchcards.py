"""The cards inside the notch, laid out as the Mac lays them out.

PermissionCardView ports NotchPermissionCard.PermissionCard, IdleCardView
ports NotchIdlePill.IdlePill. Spacing, sizes and colours are the Swift
source's; the widgets that draw them are in notchwidgets.py.
"""

from __future__ import annotations

import time

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtWidgets import QHBoxLayout, QVBoxLayout, QWidget

from claudenotch import protocol

from . import cardmodel, notchgeom
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

    def __init__(self, card, pending: int = 1, width: float = 564, parent=None):
        super().__init__(parent)
        self.card = card
        self.text = cardmodel.card_text(card)
        self.buttons: dict[str, QWidget] = {}
        self.setAttribute(Qt.WA_TranslucentBackground)
        dangerous = bool(card.dangers)
        accent, icon = accent_for(dangerous)

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

        if dangerous:
            v.addWidget(nw.danger_banner(card.dangers))

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
        deny = nw.NotchButton("Deny", "destructive", ESC_GLYPH)
        deny.clicked.connect(lambda: self.decided.emit(protocol.DENY, ""))
        row.addWidget(deny)
        self.buttons["deny"] = deny
        if not dangerous:
            always = nw.CapsuleButton("Always Allow…", chevron=True)
            always.clicked.connect(self._always_menu)
            always.setAccessibleDescription(
                f"Choose to always allow this exact command, or every {card.tool} call")
            row.addWidget(always)
            self.buttons["always"] = always
        row.addStretch(1)
        if dangerous:
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

        self.setFixedWidth(int(width))
        self._tick = QTimer(self, interval=15000)
        self._tick.timeout.connect(self._update_waiting)
        self._tick.start()
        self._update_waiting()

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
                                         **cardmodel.preview_budget(self.text.preview))


def idle_header(sessions) -> tuple[str, str, tuple, bool]:
    """IdlePill's row 1, from the core's sessions: the name ("Claude", or
    "Claude · N sessions"), the status word, the dot colour, and whether it
    is active (pulsing dot, shimmering word)."""
    n = len(sessions)
    name = f"Claude · {n} sessions" if n >= 2 else "Claude"
    working = any(s.status in ("working", "waiting") for s in sessions)
    if working:
        return name, "Running command", ms.BLUE, True
    replied = any(s.status == "ready" and s.last_prompt for s in sessions)
    return name, "Ready", (ms.GREEN if replied else ms.GRAY), False


class IdleCardView(QWidget):
    """The open hover card: the mascot, the name, the status dot and word,
    then the model and the context and cost meter."""

    def __init__(self, sessions, parent=None):
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
        v.addLayout(r1)

        r2 = _row(5)
        r2.addStretch(1)
        r2.addWidget(nw.context_cost_bar())
        v.addLayout(r2)
        self.content_width = self._natural_width(name, status, agents)

    @staticmethod
    def _natural_width(name: str, status: str, agents: int) -> float:
        """NotchView.idleContentWidth for what this card shows."""
        from PySide6.QtGui import QFontMetricsF
        fm12 = QFontMetricsF(ms.font(12, "semibold"))
        fm10 = QFontMetricsF(ms.font(10))
        fm9 = QFontMetricsF(ms.font(9, "medium"))
        row1 = [15, fm12.horizontalAdvance(name), 5, fm10.horizontalAdvance(status)]
        if agents:
            row1.append(fm9.horizontalAdvance(f"{agents} agents") + 10)
        row1.append(34)
        w1 = sum(row1) + (len(row1) - 1) * 6
        w2 = 36 + QFontMetricsF(ms.font(9)).horizontalAdvance("no usage yet") + 5
        return max(w1, w2)


def _badge(text: str, rgb, fill: float) -> QWidget:
    box = nw.RoundedBox(ms.rgba(rgb, fill), 4)
    lay = QHBoxLayout(box)
    lay.setContentsMargins(5, 2, 5, 2)
    lay.addWidget(nw.Text(text, 9, "medium", rgb, 0.95, fixed=True))
    return box
