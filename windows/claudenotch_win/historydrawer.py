"""The notch's history drawer, the Mac's NotchHistoryCard: the tab's icon,
title and count (Export and Clear on the right), the plan limits, the
Sessions / Projects / Events chips, a search field, the Activity filters,
the list, and Close. What it shows comes from historymodel (pure, tested).

Every string from a hook payload or transcript is drawn as plain text.
"""

from __future__ import annotations

import datetime as _dt
import time

from PySide6.QtCore import QRectF, Qt, Signal
from PySide6.QtGui import QFontMetricsF, QPainter, QPainterPath, QPalette
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLineEdit, QScrollArea, QVBoxLayout, QWidget

from claudenotch import budget

from . import historymodel as hm
from . import macstyle as ms
from . import notchgeom
from . import notchwidgets as nw

RETURN_GLYPH = "⏎"
BLUE = (10, 132, 255)

_SCROLL_STYLE = (
    "QScrollArea { background: transparent; }"
    "QScrollBar:vertical { background: transparent; width: 6px; margin: 0; }"
    "QScrollBar::handle:vertical { background: rgba(255,255,255,0.25); border-radius: 3px; min-height: 24px; }"
    "QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page"
    " { background: none; height: 0; }"
)


def _row(spacing: int) -> QHBoxLayout:
    r = QHBoxLayout()
    r.setContentsMargins(0, 0, 0, 0)
    r.setSpacing(spacing)
    return r


class Chip(QWidget):
    """A tab or filter chip: 11 pt medium on a capsule, near-white with
    black text when chosen, else 8 % white with 70 % white text."""

    clicked = Signal()

    def __init__(self, label: str, chosen: bool = False, parent=None):
        super().__init__(parent)
        self.label, self.chosen = label, chosen
        self._font = ms.font(11, "medium")
        self.setFixedSize(int(QFontMetricsF(self._font).horizontalAdvance(label) + 20), 22)
        self.setCursor(Qt.PointingHandCursor)
        self.setAccessibleName(label)

    def set_chosen(self, on: bool) -> None:
        self.chosen = on
        self.setAccessibleDescription("selected" if on else "")
        self.update()

    def mouseReleaseEvent(self, e) -> None:
        if e.button() == Qt.LeftButton and self.rect().contains(e.position().toPoint()):
            self.clicked.emit()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()), self.height() / 2, self.height() / 2)
        p.fillPath(path, ms.rgba(ms.WHITE, 0.9 if self.chosen else 0.08))
        p.setFont(self._font)
        p.setPen(ms.rgba(ms.BLACK, 1.0) if self.chosen else ms.rgba(ms.WHITE, 0.7))
        p.drawText(self.rect(), Qt.AlignCenter, self.label)
        p.end()


class LinkText(QWidget):
    """A plain text button (Export, Clear, Resume): no chrome, a colour."""

    clicked = Signal()

    def __init__(self, label: str, enabled: bool = True, rgb=ms.WHITE, opacity: float = 0.55,
                 weight: str = "medium", size: float = 11, icon: str | None = None, parent=None):
        super().__init__(parent)
        self.label, self.icon = label, icon
        self._font = ms.font(size, weight)
        self._rgb, self._opacity = rgb, opacity
        extra = 13 if icon else 0
        self.setFixedSize(int(QFontMetricsF(self._font).horizontalAdvance(label)) + 2 + extra, 16)
        self.setEnabled(enabled)
        if enabled:
            self.setCursor(Qt.PointingHandCursor)
        self.setAccessibleName(label)

    def mouseReleaseEvent(self, e) -> None:
        if self.isEnabled() and e.button() == Qt.LeftButton:
            self.clicked.emit()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        color = ms.rgba(self._rgb, self._opacity if self.isEnabled() else 0.25)
        x = 0
        if self.icon:
            nw.draw_glyph(p, self.icon, QRectF(0, 3, 10, 10), 8, color)
            x = 13
        p.setFont(self._font)
        p.setPen(color)
        p.drawText(QRectF(x, 0, self.width() - x, self.height()), Qt.AlignVCenter | Qt.AlignLeft, self.label)
        p.end()


class HoverRow(nw.RoundedBox):
    """A row on 4 % white that brightens to 7 % under the pointer; with a
    folder to go back to, its time gives way to a green Resume there
    (SessionHistoryRow, ProjectStatsRow)."""

    resume = Signal()

    def __init__(self, can_resume: bool, parent=None):
        super().__init__(ms.rgba(ms.WHITE, 0.04), 8, parent=parent)
        self.can_resume = can_resume
        self.when: QWidget | None = None
        self.resume_btn: QWidget | None = None

    def add_when(self, when: QWidget, row: QHBoxLayout) -> None:
        self.when = when
        row.addWidget(when)
        if self.can_resume:
            btn = LinkText("Resume", rgb=ms.GREEN, opacity=0.9, weight="semibold", size=10, icon="play.fill")
            btn.clicked.connect(self.resume.emit)
            btn.hide()
            row.addWidget(btn)
            self.resume_btn = btn

    def _hover(self, on: bool) -> None:
        self.fill = ms.rgba(ms.WHITE, 0.07 if on else 0.04)
        if self.resume_btn is not None:
            self.resume_btn.setVisible(on)
            if self.when is not None:
                self.when.setVisible(not on)
        self.update()

    def enterEvent(self, e) -> None:
        self._hover(True)
        super().enterEvent(e)

    def leaveEvent(self, e) -> None:
        self._hover(False)
        super().leaveEvent(e)


class Sparkline(QWidget):
    """Seven green bars, 16 pt tall, scaled to the week's busiest day."""

    def __init__(self, days: list[float], parent=None):
        super().__init__(parent)
        self.days = days
        self.setFixedSize(7 * 4 + 6 * 2, 16)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        top = max(self.days) if self.days and max(self.days) > 0 else 1.0
        for i, v in enumerate(self.days):
            h = max(2.0, 16 * v / top)
            path = QPainterPath()
            path.addRoundedRect(QRectF(i * 6, 16 - h, 4, h), 1.5, 1.5)
            p.fillPath(path, ms.rgba(ms.GREEN, 0.85 if i == len(self.days) - 1 else 0.5))
        p.end()


def _icon_tile(name: str, rgb, round_: bool) -> QWidget:
    tile = nw.RoundedBox(ms.rgba(rgb, 0.20 if round_ else 0.15), 11 if round_ else 5)
    tile.setFixedSize(22, 22)
    lay = QHBoxLayout(tile)
    lay.setContentsMargins(0, 0, 0, 0)
    lay.addWidget(nw.Glyph(name, 10, rgb, 1.0 if round_ else 0.8), 0, Qt.AlignCenter)
    return tile


def _meta(text: str, icon: str) -> QHBoxLayout:
    r = _row(3)
    r.addWidget(nw.Glyph(icon, 8, opacity=0.4))
    r.addWidget(nw.Text(text, 10, opacity=0.55, fixed=True))
    return r


def _ago(ts: float, now: float) -> str:
    return notchgeom.time_ago(now - ts) if ts else ""


def _one_line(text: str) -> str:
    return " ".join(str(text or "").split())


class HistoryDrawerView(QWidget):
    """Emits `closed`, `resume(cwd, session id or "")`, `export(tab)` and
    `clear(tab)`; the overlay does the work."""

    closed = Signal()
    resume = Signal(str, str)
    export = Signal(str)
    clear = Signal(str)

    def __init__(self, state, width: float, height: float, status_items=None, week_costs=None,
                 daily_cost=None, parent=None):
        super().__init__(parent)
        self.state = state
        self.tab, self.filter, self.query = "sessions", "all", ""
        self.week_costs = week_costs or {}
        self.daily_cost = daily_cost or {}
        self.buttons: dict[str, QWidget] = {}
        self.rows = 0
        self.setAttribute(Qt.WA_TranslucentBackground)

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)

        self.head_box = QWidget()
        self.head = QHBoxLayout(self.head_box)
        self.head.setContentsMargins(0, 0, 0, 0)
        self.head.setSpacing(8)
        v.addWidget(self.head_box)

        # The plan limits (StatusBarRow): this is the screen you open when you
        # want the numbers, with room for the reset countdowns in full.
        self.status_bar = None
        if status_items is not None:
            box = nw.RoundedBox(ms.rgba(ms.WHITE, 0.04), 8)
            lay = QHBoxLayout(box)
            lay.setContentsMargins(16, 6, 16, 6)
            self.status_bar = nw.StatusBar(status_items)
            lay.addWidget(self.status_bar)
            v.addWidget(box)

        tabs = _row(6)
        self.tab_chips: dict[str, Chip] = {}
        for t in hm.TABS:
            chip = Chip(hm.TAB_CHIPS[t], t == self.tab)
            chip.clicked.connect(lambda t=t: self.set_tab(t))
            tabs.addWidget(chip)
            self.tab_chips[t] = chip
        tabs.addStretch(1)
        v.addLayout(tabs)

        search = nw.RoundedBox(ms.rgba(ms.WHITE, 0.06), 8)
        sl = QHBoxLayout(search)
        sl.setContentsMargins(10, 7, 10, 7)
        sl.setSpacing(6)
        sl.addWidget(nw.Glyph("magnifyingglass", 11, opacity=0.4))
        self.search = QLineEdit()
        self.search.setFont(ms.font(12))
        self.search.setFrame(False)
        self.search.setStyleSheet("QLineEdit { background: transparent; color: white; border: none; padding: 0; }")
        pal = self.search.palette()
        pal.setColor(QPalette.PlaceholderText, ms.rgba(ms.WHITE, 0.35))
        self.search.setPalette(pal)
        self.search.textChanged.connect(self._searched)
        sl.addWidget(self.search, 1)
        self.clear_search = LinkText("", icon="xmark.circle.fill", opacity=0.4)
        self.clear_search.setFixedSize(14, 16)
        self.clear_search.setAccessibleName("Clear search")
        self.clear_search.clicked.connect(self.search.clear)
        self.clear_search.hide()
        sl.addWidget(self.clear_search)
        v.addWidget(search)

        self.filters_box = QWidget()
        fl = QHBoxLayout(self.filters_box)
        fl.setContentsMargins(0, 0, 0, 0)
        fl.setSpacing(6)
        self.filter_chips: dict[str, Chip] = {}
        for key, label in hm.FILTERS:
            chip = Chip(label, key == self.filter)
            chip.clicked.connect(lambda k=key: self.set_filter(k))
            fl.addWidget(chip)
            self.filter_chips[key] = chip
        fl.addStretch(1)
        v.addWidget(self.filters_box)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.scroll.setStyleSheet(_SCROLL_STYLE)
        self.scroll.viewport().setAutoFillBackground(False)
        self.scroll.viewport().setStyleSheet("background: transparent;")
        v.addWidget(self.scroll, 1)

        v.addSpacing(10)
        foot = _row(8)
        foot.addStretch(1)
        close = nw.NotchButton("Close", "primary", RETURN_GLYPH)
        close.clicked.connect(self.closed.emit)
        foot.addWidget(close)
        self.buttons["close"] = close
        v.addLayout(foot)

        self.setFixedWidth(int(width))
        self.setFixedHeight(int(height))
        self.refresh()

    # --- choices -------------------------------------------------------------------------

    def set_tab(self, tab: str) -> None:
        self.tab = tab
        for t, chip in self.tab_chips.items():
            chip.set_chosen(t == tab)
        self.refresh()

    def set_filter(self, key: str) -> None:
        self.filter = key
        for k, chip in self.filter_chips.items():
            chip.set_chosen(k == key)
        self.refresh()

    def _searched(self, text: str) -> None:
        self.query = text
        self.clear_search.setVisible(bool(text))
        self.refresh()

    def keyPressEvent(self, event) -> None:
        if event.key() in (Qt.Key_Escape, Qt.Key_Return, Qt.Key_Enter):
            self.closed.emit()
            return
        super().keyPressEvent(event)

    # --- content -------------------------------------------------------------------------

    def _records(self) -> list:
        archive = getattr(self.state, "archive", None)
        return archive.newest_first() if archive is not None else []

    def refresh(self) -> None:
        now = time.time()
        records = self._records()
        history = list(getattr(self.state, "history", []))
        if self.tab == "sessions":
            items, total, anything = hm.sessions(records, self.query), len(records), bool(records)
        elif self.tab == "projects":
            items = hm.project_stats(records, self.week_costs, self.query)
            total, anything = len(items), bool(records)
        else:
            items, total, anything = hm.events(history, self.filter, self.query), len(history), bool(history)
        self._header(len(items), total, anything)
        self.search.setPlaceholderText(hm.placeholder(self.tab))
        self.search.setAccessibleName("Search history" if self.tab == "events" else "Search projects")
        self.filters_box.setVisible(self.tab == "events")

        body = QWidget()
        body.setAttribute(Qt.WA_TranslucentBackground)
        col = QVBoxLayout(body)
        col.setContentsMargins(0, 0, 6, 0)
        col.setSpacing(4)
        if self.tab == "projects" and items:
            week_ago = now - 7 * 86400
            col.addWidget(self._week_header(sum(1 for r in records if r.last >= week_ago)))
            col.addSpacing(2)
        if not items:
            empty = nw.wrap_label(hm.empty_text(self.tab, anything), 12, opacity=0.55)
            empty.setAlignment(Qt.AlignCenter)
            col.addStretch(1)
            col.addWidget(empty)
        for it in items[:200]:
            if self.tab == "sessions":
                col.addWidget(self._session_row(it, now))
            elif self.tab == "projects":
                col.addWidget(self._project_row(it, now))
            else:
                col.addWidget(self._event_row(it, now))
        col.addStretch(1)
        self.scroll.setWidget(body)
        self.rows = len(items)

    def _header(self, shown: int, total: int, anything: bool) -> None:
        while self.head.count():
            item = self.head.takeAt(0)
            if item.widget() is not None:
                item.widget().deleteLater()
        self.head.addWidget(nw.Glyph(hm.TAB_ICONS[self.tab], 13, opacity=0.85))
        self.head.addWidget(nw.Text(hm.TAB_LABELS[self.tab], 11, "semibold", opacity=0.9, upper=True, fixed=True))
        self.head.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
        self.count_label = nw.Text(hm.count_label(self.tab, shown, total), 11, "medium", opacity=0.5, fixed=True)
        self.head.addWidget(self.count_label)
        self.head.addStretch(1)
        self.buttons.pop("export", None)
        self.buttons.pop("clear", None)
        if self.tab in ("sessions", "events"):
            exp = LinkText("Export", anything)
            exp.clicked.connect(lambda: self.export.emit(self.tab))
            clr = LinkText("Clear", anything)
            clr.clicked.connect(lambda: self.clear.emit(self.tab))
            self.head.addWidget(exp)
            self.head.addWidget(nw.Text("·", 13, opacity=0.2, fixed=True))
            self.head.addWidget(clr)
            self.buttons["export"], self.buttons["clear"] = exp, clr

    def _week_header(self, sessions_count: int) -> QWidget:
        days, total = hm.week_spend(self.daily_cost, _dt.date.today())
        box = nw.RoundedBox(ms.rgba(ms.GREEN, 0.08), 8)
        lay = QHBoxLayout(box)
        lay.setContentsMargins(10, 6, 10, 6)
        lay.setSpacing(8)
        lay.addWidget(Sparkline(days))
        lay.addWidget(nw.Text(f"Last 7 days: {budget.money(total)}", 11, "semibold", opacity=0.85, fixed=True))
        lay.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
        n = sessions_count
        lay.addWidget(nw.Text("1 session" if n == 1 else f"{n} sessions", 11, opacity=0.5, fixed=True))
        lay.addStretch(1)
        box.setAccessibleName(f"Spend, last 7 days: {budget.money(total)} across {n} sessions")
        return box

    def _session_row(self, r, now: float) -> QWidget:
        from claudenotch import statusline
        from claudenotch.state import running_duration
        row = HoverRow(bool(r.cwd))
        row.resume.connect(lambda: self.resume.emit(r.cwd, r.id))
        h = QHBoxLayout(row)
        h.setContentsMargins(10, 7, 10, 7)
        h.setSpacing(10)
        h.addWidget(_icon_tile("folder.fill", BLUE, False), 0, Qt.AlignTop)
        col = QVBoxLayout()
        col.setSpacing(3)
        top = _row(6)
        top.addWidget(nw.Text(r.project, 11, "semibold", opacity=0.9, elide=Qt.ElideMiddle))
        top.addStretch(1)
        row.add_when(nw.Text(_ago(r.started, now), 10, opacity=0.4, fixed=True), top)
        col.addLayout(top)
        if r.summary:
            col.addWidget(nw.Text(_one_line(r.summary), 11, opacity=0.7))
        meta = _row(8)
        if r.last > r.started > 0:
            meta.addLayout(_meta(running_duration(r.last - r.started), "clock"))
        if r.cost_usd > 0:
            meta.addLayout(_meta(budget.money(r.cost_usd), "dollarsign.circle.fill"))
        if r.turns:
            meta.addLayout(_meta(f"{r.turns} turn{'s' if r.turns != 1 else ''}", "arrow.right"))
        if r.branch:
            meta.addLayout(_meta(r.branch, "arrow.triangle.branch"))
        meta.addStretch(1)
        col.addLayout(meta)
        model = statusline.short_model(r.model) if r.model else ""
        if model and model != "unknown":
            col.addWidget(nw.Text(model, 9, opacity=0.3))
        h.addLayout(col, 1)
        row.setToolTip(r.cwd)
        row.setAccessibleName(f"{r.project}, {_ago(r.started, now)}. {_one_line(r.summary)}")
        return row

    def _project_row(self, p, now: float) -> QWidget:
        row = HoverRow(bool(p.cwd))
        row.resume.connect(lambda: self.resume.emit(p.cwd, ""))
        h = QHBoxLayout(row)
        h.setContentsMargins(10, 7, 10, 7)
        h.setSpacing(10)
        h.addWidget(_icon_tile("chart.bar.fill", ms.GREEN, False), 0, Qt.AlignTop)
        col = QVBoxLayout()
        col.setSpacing(3)
        top = _row(6)
        top.addWidget(nw.Text(p.project, 11, "semibold", opacity=0.9, elide=Qt.ElideMiddle))
        top.addStretch(1)
        row.add_when(nw.Text(_ago(p.last, now), 10, opacity=0.4, fixed=True), top)
        col.addLayout(top)
        meta = _row(8)
        meta.addLayout(_meta(f"{p.sessions} session{'s' if p.sessions != 1 else ''}",
                             "list.bullet.rectangle.portrait"))
        if p.cost_usd > 0:
            meta.addLayout(_meta(budget.money(p.cost_usd), "dollarsign.circle.fill"))
        if p.turns:
            meta.addLayout(_meta(f"{p.turns} turns", "arrow.right"))
        meta.addStretch(1)
        col.addLayout(meta)
        h.addLayout(col, 1)
        row.setToolTip(p.cwd)
        row.setAccessibleName(f"{p.project}, {p.sessions} sessions")
        return row

    def _event_row(self, e: dict, now: float) -> QWidget:
        kind, label = hm.outcome(str(e.get("what", "")))
        rgb, icon = hm.OUTCOME_STYLE[kind]
        box = nw.RoundedBox(ms.rgba(ms.WHITE, 0.04), 8)
        h = QHBoxLayout(box)
        h.setContentsMargins(10, 7, 10, 7)
        h.setSpacing(10)
        h.addWidget(_icon_tile(icon, rgb, True), 0, Qt.AlignTop)
        col = QVBoxLayout()
        col.setSpacing(1)
        top = _row(6)
        top.addWidget(nw.Text(_one_line(e.get("title", "")), 11, "semibold", opacity=0.9, fixed=True))
        if e.get("project"):
            top.addWidget(nw.Text(_one_line(e["project"]), 10, opacity=0.45, fixed=True))
        top.addStretch(1)
        top.addWidget(nw.Text(_ago(float(e.get("at", 0) or 0), now), 10, opacity=0.4, fixed=True))
        col.addLayout(top)
        if e.get("detail"):
            col.addWidget(nw.Text(_one_line(e["detail"]), 11, opacity=0.7, mono=True, elide=Qt.ElideMiddle))
        col.addWidget(nw.Text(label, 10, "medium", rgb, 0.95, fixed=True))
        h.addLayout(col, 1)
        box.setAccessibleName(f"{_one_line(e.get('title', ''))}, {label}. {_one_line(e.get('detail', ''))}")
        return box
