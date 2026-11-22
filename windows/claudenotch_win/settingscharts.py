"""The charts on Settings > Usage, drawn the Mac's way.

spendTrend: one bar per day or week, accent at 75 %, 3 pt corners, up to
90 pt tall, the amount in 9 pt above and the label in a caption below.
activityHeatmap: seven weeks by seven days of 16 pt cells, 4 pt apart,
weekday labels on the left, shaded by how many tool requests that day had.
spendLeaderRow: a name, a capsule bar of its share, and the amount.
"""

from __future__ import annotations

import datetime as _dt

from PySide6.QtCore import QRectF, QSize, Qt
from PySide6.QtGui import QColor, QFontMetricsF, QPainter, QPainterPath
from PySide6.QtWidgets import QHBoxLayout, QSizePolicy, QWidget

from claudenotch.stats import heat_level

from . import settingskit as kit


def usd(v: float) -> str:
    return f"${v:.2f}"


class BarChart(QWidget):
    """spendTrend."""

    def __init__(self, t: kit.Theme, data: list[tuple[str, float]], parent=None):
        super().__init__(parent)
        self.t, self.data = t, data
        self.setMinimumHeight(140)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def sizeHint(self) -> QSize:
        return QSize(400, 140)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        n = max(1, len(self.data))
        top = max([v for _, v in self.data] + [0.0001])
        gap = 10
        w = (self.width() - gap * (n - 1)) / n
        small, cap = kit.font(9), kit.font(10)
        bar = QColor(self.t.accent)
        bar.setAlphaF(0.75)
        for i, (label, value) in enumerate(self.data):
            x = i * (w + gap)
            h = max(2.0, value / top * 90)
            base = self.height() - 18
            path = QPainterPath()
            path.addRoundedRect(QRectF(x, base - h, w, h), 3, 3)
            p.fillPath(path, bar)
            p.setPen(self.t.secondary)
            p.setFont(small)
            if value >= 0.005:
                p.drawText(QRectF(x - 6, base - h - 16, w + 12, 14), Qt.AlignCenter, usd(value))
            p.setFont(cap)
            p.drawText(QRectF(x - 6, base + 3, w + 12, 14), Qt.AlignCenter, label)


class Heatmap(QWidget):
    """activityHeatmap: the last seven weeks, today in the last column."""

    CELL, GAP, LABEL_W = 16, 4, 32
    WEEKS = 7

    def __init__(self, t: kit.Theme, daily: dict, today: _dt.date | None = None, parent=None):
        super().__init__(parent)
        self.t, self.daily = t, daily
        self.today = today or _dt.date.today()
        self.setFixedHeight(7 * (self.CELL + self.GAP))
        self.setMinimumWidth(self.LABEL_W + self.WEEKS * (self.CELL + self.GAP))
        self.setMouseTracking(True)

    def cell_day(self, row: int, col: int) -> _dt.date | None:
        """Row 0 is Sunday, as on the Mac; col 6 is this week."""
        today_row = (self.today.weekday() + 1) % 7
        back = (today_row - row) + (self.WEEKS - 1 - col) * 7
        return None if back < 0 else self.today - _dt.timedelta(days=back)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setFont(kit.font(10))
        names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        for row in range(7):
            y = row * (self.CELL + self.GAP)
            if row % 2 == 1:
                p.setPen(self.t.secondary)
                p.drawText(QRectF(0, y, self.LABEL_W - 4, self.CELL), Qt.AlignLeft | Qt.AlignVCenter, names[row])
            for col in range(self.WEEKS):
                day = self.cell_day(row, col)
                if day is None:
                    continue
                level = heat_level(self.daily.get(day.isoformat(), 0))
                c = QColor(self.t.accent)
                if level == 0:
                    c = QColor(127, 127, 127, 40)
                else:
                    c.setAlphaF((0.25, 0.45, 0.7, 1.0)[level - 1])
                x = self.LABEL_W + col * (self.CELL + self.GAP)
                path = QPainterPath()
                path.addRoundedRect(QRectF(x, y, self.CELL, self.CELL), 3, 3)
                p.fillPath(path, c)

    def mouseMoveEvent(self, e) -> None:
        col = int((e.position().x() - self.LABEL_W) // (self.CELL + self.GAP))
        row = int(e.position().y() // (self.CELL + self.GAP))
        day = self.cell_day(row, col) if 0 <= col < self.WEEKS and 0 <= row < 7 else None
        if day is None:
            self.setToolTip("")
            return
        n = self.daily.get(day.isoformat(), 0)
        self.setToolTip(f"{day.strftime('%b')} {day.day}, {day.year}: {n} tool call{'' if n == 1 else 's'}")


class _Capsule(QWidget):
    def __init__(self, t: kit.Theme, fraction: float, parent=None):
        super().__init__(parent)
        self.t, self.fraction = t, max(0.0, min(1.0, fraction))
        self.setFixedHeight(6)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        track = QPainterPath()
        track.addRoundedRect(QRectF(self.rect()), 3, 3)
        p.fillPath(track, QColor(127, 127, 127, 36))
        fill = QPainterPath()
        fill.addRoundedRect(QRectF(0, 0, max(3.0, self.width() * self.fraction), self.height()), 3, 3)
        c = QColor(self.t.accent)
        c.setAlphaF(0.7)
        p.fillPath(fill, c)


def leader_row(t: kit.Theme, name: str, value: str, fraction: float) -> QWidget:
    """spendLeaderRow: name (130 wide), a capsule of its share, the amount."""
    w = QWidget()
    h = QHBoxLayout(w)
    h.setContentsMargins(14, 9, 14, 9)
    h.setSpacing(10)
    lbl = kit.label(name, 13, color=t.text)
    lbl.setFixedWidth(130)
    lbl.setText(QFontMetricsF(lbl.font()).elidedText(name, Qt.ElideMiddle, 130))
    h.addWidget(lbl)
    h.addWidget(_Capsule(t, fraction), 1)
    amount = kit.label(value, 13, "semibold", t.text)
    amount.setFixedWidth(70)
    amount.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
    h.addWidget(amount)
    return w


def stat_row(t: kit.Theme, title: str, value: str) -> QWidget:
    """statRow: the title, and the value in the secondary colour."""
    w = QWidget()
    h = QHBoxLayout(w)
    h.setContentsMargins(14, 8, 14, 8)
    h.addWidget(kit.label(title, 13, color=t.text))
    h.addStretch(1)
    h.addWidget(kit.label(value, 13, color=t.secondary))
    return w
