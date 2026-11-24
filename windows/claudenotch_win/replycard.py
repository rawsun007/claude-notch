"""The full-reply card, the Mac's ResponseDetailCard: a green speech
bubble, "CLAUDE'S LAST REPLY" and the project, the reply as markdown
blocks (markdown.parse) in a scrolling box, then Copy and Close.

Every word is a plain-text label, selectable with the mouse; nothing in a
reply is rendered as rich text or becomes a link. Ctrl+C copies the whole
reply, Enter or Esc closes. Emits `closed`.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QScrollArea, QVBoxLayout, QWidget

from . import macstyle as ms
from . import markdown
from . import notchwidgets as nw

RETURN_GLYPH = "⏎"
COPY_GLYPH = "Ctrl C"

_SCROLL_STYLE = (
    "QScrollArea { background: transparent; }"
    "QScrollBar:vertical { background: transparent; width: 6px; margin: 0; }"
    "QScrollBar::handle:vertical { background: rgba(255,255,255,0.25); border-radius: 3px; min-height: 24px; }"
    "QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page"
    " { background: none; height: 0; }"
)


def _label(text: str, size: float, weight: str = "regular", opacity: float = 0.9, mono: bool = False) -> QLabel:
    lbl = nw.wrap_label(text, size, weight, ms.WHITE, opacity, mono=mono)
    lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
    lbl.setCursor(Qt.IBeamCursor)
    return lbl


def block_widget(b: markdown.Block) -> QWidget:
    """MarkdownBlockView for one block."""
    if b.kind == "heading":
        lbl = _label(b.text, {1: 16, 2: 14}.get(b.level, 13), "bold", 1.0)
        lbl.setContentsMargins(0, 6 if b.level == 1 else 2, 0, 0)
        return lbl
    if b.kind in ("bullet", "numbered"):
        row = QWidget()
        h = QHBoxLayout(row)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        mark = nw.Text("•" if b.kind == "bullet" else f"{b.level}.", 12, "semibold", opacity=0.6, fixed=True)
        mark.setFixedWidth(10 if b.kind == "bullet" else 18)
        h.addWidget(mark, 0, Qt.AlignTop)
        h.addWidget(_label(b.text, 12), 1)
        return row
    if b.kind == "code":
        box = nw.RoundedBox(ms.rgba(ms.WHITE, 0.08), 6)
        v = QVBoxLayout(box)
        v.setContentsMargins(10, 10, 10, 10)
        v.setSpacing(4)
        if b.language:
            v.addWidget(nw.Text(b.language, 9, "semibold", opacity=0.45, upper=True))
        v.addWidget(_label(b.text, 11, mono=True))
        return box
    if b.kind == "blank":
        gap = QWidget()
        gap.setFixedHeight(2)
        return gap
    return _label(b.text, 12)


class ResponseDetailView(QWidget):
    closed = Signal()

    def __init__(self, text: str, project: str, width: float, height: float, parent=None):
        super().__init__(parent)
        self.reply = text
        self.buttons: dict[str, QWidget] = {}
        self.setAttribute(Qt.WA_TranslucentBackground)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)

        head = QHBoxLayout()
        head.setContentsMargins(0, 0, 0, 0)
        head.setSpacing(8)
        head.addWidget(nw.Glyph("text.bubble.fill", 13, ms.GREEN))
        head.addWidget(nw.Text("Claude's last reply", 11, "semibold", ms.GREEN, 0.9, upper=True, fixed=True))
        if project:
            head.addWidget(nw.Text("·", 13, opacity=0.3, fixed=True))
            head.addWidget(nw.Text(project, 11, "medium", opacity=0.6))
        head.addStretch(1)
        v.addLayout(head)

        body = QWidget()
        body.setAttribute(Qt.WA_TranslucentBackground)
        col = QVBoxLayout(body)
        col.setContentsMargins(12, 12, 12, 12)
        col.setSpacing(6)
        self.blocks = markdown.parse(text)
        for b in self.blocks:
            col.addWidget(block_widget(b))
        col.addStretch(1)
        scroll = QScrollArea()
        scroll.setWidget(body)
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setStyleSheet(_SCROLL_STYLE)
        scroll.viewport().setAutoFillBackground(False)
        scroll.viewport().setStyleSheet("background: transparent;")
        frame = nw.RoundedBox(ms.rgba(ms.WHITE, 0.05), 10)
        fl = QVBoxLayout(frame)
        fl.setContentsMargins(0, 0, 0, 0)
        fl.addWidget(scroll)
        v.addWidget(frame, 1)
        self.scroll = scroll

        v.addSpacing(10)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(8)
        row.addStretch(1)
        self.copy_btn = nw.NotchButton("Copy", "secondary", COPY_GLYPH)
        self.copy_btn.clicked.connect(self.copy)
        close = nw.NotchButton("Close", "primary", RETURN_GLYPH)
        close.clicked.connect(self.closed.emit)
        row.addWidget(self.copy_btn)
        row.addWidget(close)
        self.buttons.update(copy=self.copy_btn, close=close)
        v.addLayout(row)

        self.setFocusPolicy(Qt.StrongFocus)
        self.setFixedWidth(int(width))
        self.setFixedHeight(int(height))

    def copy(self) -> None:
        """Copy the whole reply, as Claude wrote it; "Copied" for a moment."""
        QGuiApplication.clipboard().setText(self.reply)
        self.copy_btn.set_label("Copied ✓")
        QTimer.singleShot(1400, lambda: self.copy_btn.set_label("Copy"))

    def keyPressEvent(self, event) -> None:
        if event.key() in (Qt.Key_Escape, Qt.Key_Return, Qt.Key_Enter):
            self.closed.emit()
            return
        if event.key() == Qt.Key_C and event.modifiers() & Qt.ControlModifier:
            # A selection inside a block copies itself; with none, the reply.
            focus = QGuiApplication.focusObject()
            if not (isinstance(focus, QLabel) and focus.hasSelectedText()):
                self.copy()
                return
        super().keyPressEvent(event)
