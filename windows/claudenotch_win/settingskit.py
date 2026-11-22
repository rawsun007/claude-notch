"""The parts the Settings window is built from, shaped like the Mac's.

SettingsWindow.swift draws a sidebar of grouped sections with a search field
above it, and pages made of rounded cards ("cardChrome": 10 pt corners, the
control background, a 1 pt stroke at 8 %) holding rows (title, a caption
under it, a small switch on the right, 14 x 10 padding) split by dividers
inset 14. These widgets draw the same, in Windows' light or dark mode as
the Mac's follow the system appearance.

Text is set as plain text throughout: some rows show paths and rule text.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

from PySide6.QtCore import QEasingCurve, QPointF, QRectF, QSize, Qt, QVariantAnimation, Signal
from PySide6.QtGui import QColor, QFont, QFontMetricsF, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QAbstractButton, QFrame, QHBoxLayout, QLabel, QLineEdit, QSizePolicy, QVBoxLayout,
                               QWidget)

from . import macstyle as ms


# --- theme ------------------------------------------------------------------------------

def windows_dark_mode() -> bool:
    """Windows' "Choose your app mode": AppsUseLightTheme 0 means dark."""
    if sys.platform != "win32":
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            return winreg.QueryValueEx(k, "AppsUseLightTheme")[0] == 0
    except OSError:
        return False


@dataclass(frozen=True)
class Theme:
    dark: bool
    window: QColor
    sidebar: QColor
    card: QColor
    stroke: QColor
    text: QColor
    secondary: QColor
    accent: QColor
    selection: QColor
    field: QColor


def theme(dark: bool | None = None) -> Theme:
    if dark is None:
        dark = windows_dark_mode()
    if dark:
        return Theme(True, QColor(30, 30, 32), QColor(38, 38, 41), QColor(44, 44, 47), ms.rgba(ms.WHITE, 0.08),
                     ms.rgba(ms.WHITE, 0.88), ms.rgba(ms.WHITE, 0.55), QColor(10, 132, 255),
                     QColor(10, 132, 255, 210), QColor(28, 28, 30))
    return Theme(False, QColor(246, 246, 246), QColor(234, 234, 236), QColor(255, 255, 255), QColor(0, 0, 0, 20),
                 QColor(0, 0, 0, 225), QColor(0, 0, 0, 128), QColor(0, 122, 255), QColor(0, 122, 255, 220),
                 QColor(255, 255, 255))


def css(c: QColor) -> str:
    return f"rgba({c.red()},{c.green()},{c.blue()},{c.alphaF():.3f})"


def font(size: float, weight: str = "regular") -> QFont:
    return ms.font(size, weight)


def label(text: str, size: float = 13, weight: str = "regular", color: QColor | None = None,
          wrap: bool = False, selectable: bool = False) -> QLabel:
    lbl = QLabel()
    lbl.setTextFormat(Qt.PlainText)
    lbl.setText(text)
    lbl.setFont(font(size, weight))
    lbl.setWordWrap(wrap)
    if color is not None:
        lbl.setStyleSheet(f"color: {css(color)}; background: transparent;")
    else:
        lbl.setStyleSheet("background: transparent;")
    if selectable:
        lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
    return lbl


# --- the switch --------------------------------------------------------------------------


class Switch(QAbstractButton):
    """The Mac's small switch (`.toggleStyle(.switch).controlSize(.small)`):
    a 32 x 18 capsule, accent when on, with a white knob that slides."""

    def __init__(self, t: Theme, parent=None):
        super().__init__(parent)
        self.t = t
        self.setCheckable(True)
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedSize(34, 20)
        self._pos = 0.0
        self._anim = QVariantAnimation(self, duration=140, easingCurve=QEasingCurve.OutCubic)
        self._anim.valueChanged.connect(self._moved)
        self.toggled.connect(self._animate)

    def _moved(self, v) -> None:
        self._pos = float(v)
        self.update()

    def _animate(self, on: bool) -> None:
        self._anim.stop()
        self._anim.setStartValue(self._pos)
        self._anim.setEndValue(1.0 if on else 0.0)
        self._anim.start()

    def set_quietly(self, on: bool) -> None:
        """Match a setting without counting as a click."""
        self.blockSignals(True)
        self.setChecked(on)
        self.blockSignals(False)
        self._pos = 1.0 if on else 0.0
        self.update()

    def sizeHint(self) -> QSize:
        return QSize(34, 20)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(1, 1, 32, 18)
        off = QColor(120, 120, 128, 90) if self.t.dark else QColor(120, 120, 128, 60)
        on = self.t.accent
        c = QColor(int(off.red() + (on.red() - off.red()) * self._pos),
                   int(off.green() + (on.green() - off.green()) * self._pos),
                   int(off.blue() + (on.blue() - off.blue()) * self._pos),
                   int(off.alpha() + (on.alpha() - off.alpha()) * self._pos))
        if not self.isEnabled():
            c.setAlphaF(c.alphaF() * 0.4)
        path = QPainterPath()
        path.addRoundedRect(r, 9, 9)
        p.fillPath(path, c)
        knob = 14
        x = r.left() + 2 + (r.width() - knob - 4) * self._pos
        p.setPen(QPen(QColor(0, 0, 0, 30), 0.5))
        p.setBrush(QColor(255, 255, 255))
        p.drawEllipse(QRectF(x, r.top() + 2, knob, knob))


# --- cards, rows, dividers ------------------------------------------------------------------


class Card(QFrame):
    """cardChrome: a rounded 10 pt card on the control background with a
    1 pt stroke at 8 %, 4 pt of padding top and bottom."""

    def __init__(self, t: Theme, parent=None):
        super().__init__(parent)
        self.t = t
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.lay = QVBoxLayout(self)
        self.lay.setContentsMargins(0, 4, 0, 4)
        self.lay.setSpacing(0)
        self._rows = 0

    def add(self, w: QWidget) -> QWidget:
        if self._rows:
            self.lay.addWidget(Divider(self.t))
        self.lay.addWidget(w)
        self._rows += 1
        return w

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 10, 10)
        p.fillPath(path, self.t.card)
        p.setPen(QPen(self.t.stroke, 1))
        p.drawPath(path)


class Divider(QWidget):
    def __init__(self, t: Theme, parent=None):
        super().__init__(parent)
        self.t = t
        self.setFixedHeight(1)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setPen(QPen(self.t.stroke, 1))
        p.drawLine(14, 0, self.width(), 0)


class Row(QWidget):
    """row(title, subtitle, control): title, a caption under it in the
    secondary colour, and a control on the right; 14 x 10 padding."""

    def __init__(self, t: Theme, title: str, subtitle: str | None = None, control: QWidget | None = None,
                 parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TranslucentBackground)
        h = QHBoxLayout(self)
        h.setContentsMargins(14, 10, 14, 10)
        h.setSpacing(12)
        col = QVBoxLayout()
        col.setSpacing(2)
        # Wraps rather than widening the page: a long title (a session's
        # summary, a rule's command) must never push the card off screen.
        self.title = label(title, 13, color=t.text, wrap=True)
        self.title.setMinimumWidth(1)
        col.addWidget(self.title)
        self.subtitle = None
        if subtitle:
            self.subtitle = label(subtitle, 11, color=t.secondary, wrap=True)
            col.addWidget(self.subtitle)
        h.addLayout(col, 1)
        self.control = control
        if control is not None:
            h.addWidget(control, 0, Qt.AlignVCenter)


def section_label(t: Theme, text: str) -> QLabel:
    """A caption between cards (the Mac's sectionLabel)."""
    lbl = label(text.upper(), 11, "semibold", t.secondary)
    lbl.setContentsMargins(4, 6, 0, 0)
    return lbl


class PushButton(QAbstractButton):
    """A Mac push button: 6 pt corners, the card colour with a hairline, or
    the accent when it is the default action."""

    def __init__(self, t: Theme, text: str, primary: bool = False, destructive: bool = False, parent=None):
        super().__init__(parent)
        self.t, self.text_, self.primary, self.destructive = t, text, primary, destructive
        self._font = font(13, "medium" if primary else "regular")
        self.setCursor(Qt.PointingHandCursor)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self._hover = False

    def setText(self, text: str) -> None:
        self.text_ = text
        self.updateGeometry()
        self.update()

    def text(self) -> str:
        return self.text_

    def sizeHint(self) -> QSize:
        fm = QFontMetricsF(self._font)
        return QSize(int(fm.horizontalAdvance(self.text_) + 24), 26)

    def enterEvent(self, e) -> None:
        self._hover = True
        self.update()

    def leaveEvent(self, e) -> None:
        self._hover = False
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        path = QPainterPath()
        path.addRoundedRect(r, 6, 6)
        if self.primary:
            bg = QColor(self.t.accent)
            fg = QColor(255, 255, 255)
        else:
            bg = QColor(self.t.card if not self.t.dark else QColor(70, 70, 74))
            # A copy: dimming below must never change the theme's own colour.
            fg = QColor(255, 69, 58) if self.destructive else QColor(self.t.text)
        if self._hover:
            bg = bg.lighter(112) if self.t.dark or self.primary else bg.darker(104)
        if not self.isEnabled():
            fg.setAlphaF(0.35)
        p.fillPath(path, bg)
        if not self.primary:
            p.setPen(QPen(self.t.stroke, 1))
            p.drawPath(path)
        p.setPen(fg)
        p.setFont(self._font)
        p.drawText(r, Qt.AlignCenter, self.text_)


# --- the sidebar -----------------------------------------------------------------------------


class SearchField(QFrame):
    """SearchField: a magnifying glass, the field, and a clear button once
    something is typed; 7 x 12 padding on an 8 pt rounded field."""

    changed = Signal(str)

    def __init__(self, t: Theme, placeholder: str = "Search settings", parent=None):
        super().__init__(parent)
        self.t = t
        self.setAttribute(Qt.WA_TranslucentBackground)
        h = QHBoxLayout(self)
        h.setContentsMargins(10, 5, 8, 5)
        h.setSpacing(6)
        from .notchwidgets import Glyph
        h.addWidget(Glyph("magnifyingglass", 11, rgb=(t.secondary.red(), t.secondary.green(), t.secondary.blue()),
                          opacity=t.secondary.alphaF()))
        self.edit = QLineEdit()
        self.edit.setPlaceholderText(placeholder)
        self.edit.setFrame(False)
        self.edit.setFont(font(13))
        self.edit.setStyleSheet(f"QLineEdit {{ background: transparent; border: none; color: {css(t.text)}; }}")
        self.edit.textChanged.connect(self.changed.emit)
        h.addWidget(self.edit, 1)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 8, 8)
        p.fillPath(path, self.t.field)
        p.setPen(QPen(self.t.stroke, 1))
        p.drawPath(path)


class NavItem(QAbstractButton):
    """A sidebar row: the section's symbol and name; selected rows fill with
    the accent and turn white, as the Mac's source list does."""

    def __init__(self, t: Theme, key: str, text: str, glyph: str, parent=None):
        super().__init__(parent)
        self.t, self.key, self.text_, self.glyph = t, key, text, glyph
        self.setCheckable(True)
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedHeight(28)
        self._font = font(13)

    def paintEvent(self, _e) -> None:
        from .notchwidgets import draw_glyph
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(6, 1, -6, -1)
        if self.isChecked():
            path = QPainterPath()
            path.addRoundedRect(r, 6, 6)
            p.fillPath(path, self.t.selection)
            fg = QColor(255, 255, 255)
            icon = QColor(255, 255, 255)
        else:
            fg = QColor(self.t.text)
            icon = QColor(self.t.accent)
        draw_glyph(p, self.glyph, QRectF(r.left() + 6, r.top(), 18, r.height()), 13, icon)
        p.setFont(self._font)
        p.setPen(fg)
        p.drawText(QRectF(r.left() + 32, r.top(), r.width() - 36, r.height()), Qt.AlignLeft | Qt.AlignVCenter,
                   self.text_)


def search(items, query: str, limit: int = 12):
    """SettingsSearchItem matching: every word of the query must appear in
    the title or the keywords. Pure, for tests. Returns the matching items,
    titles that start with the query first."""
    words = [w for w in query.lower().split() if w]
    if not words:
        return []
    hits = []
    for it in items:
        hay = f"{it.title} {it.keywords}".lower()
        if all(w in hay for w in words):
            hits.append(it)
    hits.sort(key=lambda it: (not it.title.lower().startswith(words[0]), it.title.lower()))
    return hits[:limit]


@dataclass(frozen=True)
class SearchItem:
    title: str
    keywords: str
    section: str
