"""The compose card, the Mac's ComposeCard: send Claude a message without
leaving the notch, reply to a finished session, or deny a held tool call
with a reason.

Header: a paper plane (a raised hand for a deny) and "SEND TO CLAUDE",
and on the right where it goes: "-> Windows Terminal" or a project, a
menu to pick another. Then the message box, a line for any error, and
Cancel / Send (Keep prompt / Deny). Ctrl+Enter sends, Enter is a new
line, Esc cancels. Emits `send(text)`, `cancel()` and
`target(cwd or "")`.
"""

from __future__ import annotations

from PySide6.QtCore import QEvent, QRectF, Qt, Signal
from PySide6.QtGui import QFontMetricsF, QPainter, QPainterPath, QPalette
from PySide6.QtWidgets import QHBoxLayout, QMenu, QPlainTextEdit, QVBoxLayout, QWidget

from . import macstyle as ms
from . import notchwidgets as nw

CYAN = (100, 210, 255)
SEND_GLYPH = "Ctrl ⏎"
ESC_GLYPH = "⎋"


class TargetChip(QWidget):
    """-> where the message goes, on a 10 % capsule, with a chevron."""

    clicked = Signal()

    def __init__(self, label: str, icon: str, parent=None):
        super().__init__(parent)
        self._font = ms.font(11, "medium")
        self.set(label, icon)
        self.setCursor(Qt.PointingHandCursor)

    def set(self, label: str, icon: str) -> None:
        self.label, self.icon = label, icon
        w = QFontMetricsF(self._font).horizontalAdvance("→ " + label)
        self.setFixedSize(int(min(w, 260) + 8 + 13 + 14), 20)
        self.setAccessibleName(f"Send to {label}. Choose where")
        self.update()

    def mouseReleaseEvent(self, e) -> None:
        if e.button() == Qt.LeftButton:
            self.clicked.emit()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()), 10, 10)
        p.fillPath(path, ms.rgba(ms.WHITE, 0.10))
        color = ms.rgba(ms.WHITE, 0.75)
        nw.draw_glyph(p, self.icon, QRectF(7, 5, 10, 10), 9, color)
        p.setFont(self._font)
        p.setPen(color)
        text = QFontMetricsF(self._font).elidedText("→ " + self.label, Qt.ElideRight, 260)
        p.drawText(QRectF(20, 0, self.width() - 34, self.height()), Qt.AlignVCenter | Qt.AlignLeft, text)
        nw.draw_glyph(p, "chevron.down", QRectF(self.width() - 14, 0, 8, self.height()), 8,
                      ms.rgba(ms.WHITE, 0.45))
        p.end()


class ComposeCardView(QWidget):
    send = Signal(str)
    cancel = Signal()
    target = Signal(str)

    def __init__(self, width: float, height: float, deny: bool = False, terminal_label: str = "",
                 context_label: str = "", project_cwd: str = "", projects=(), parent=None):
        super().__init__(parent)
        self.deny = deny
        self.terminal_label = terminal_label
        self.context_label = context_label
        self.projects = list(projects)               # [(name, cwd)]
        self.project_cwd = project_cwd
        self.buttons: dict[str, QWidget] = {}
        self.setAttribute(Qt.WA_TranslucentBackground)
        accent = ms.RED if deny else CYAN

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)

        head = QHBoxLayout()
        head.setContentsMargins(0, 0, 0, 0)
        head.setSpacing(8)
        head.addWidget(nw.Glyph("hand.raised.fill" if deny else "paperplane.fill", 13, accent))
        head.addWidget(nw.Text("Deny with a reason" if deny else "Send to Claude", 11, "semibold", accent, 0.9,
                               upper=True, fixed=True))
        head.addStretch(1)
        self.chip = None
        if not deny:
            self.chip = TargetChip("", "terminal.fill")
            self.chip.clicked.connect(self._pick)
            head.addWidget(self.chip)
            self._show_target()
        v.addLayout(head)

        box = nw.RoundedBox(ms.rgba(ms.WHITE, 0.08), 10)
        bl = QVBoxLayout(box)
        bl.setContentsMargins(10, 8, 10, 8)
        self.edit = QPlainTextEdit()
        self.edit.setFont(ms.font(13))
        self.edit.setFrameShape(QPlainTextEdit.NoFrame)
        self.edit.setStyleSheet("QPlainTextEdit { background: transparent; color: white; border: none; }")
        self.edit.viewport().setAutoFillBackground(False)
        pal = self.edit.palette()
        pal.setColor(QPalette.PlaceholderText, ms.rgba(ms.WHITE, 0.35))
        self.edit.setPalette(pal)
        self.edit.setPlaceholderText(
            "tell Claude why, or what to do instead · Ctrl+Enter to deny, Esc to keep the prompt" if deny
            else "type your message · Ctrl+Enter to send, Esc to cancel")
        self.edit.setAccessibleName(self.edit.placeholderText())
        self.edit.setMinimumHeight(64)
        self.edit.installEventFilter(self)
        bl.addWidget(self.edit)
        v.addWidget(box, 1)

        self.error = nw.wrap_label("", 10, rgb=ms.ORANGE, opacity=0.9)
        self.error.hide()
        v.addWidget(self.error)

        v.addSpacing(10)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(8)
        row.addStretch(1)
        cancel = nw.NotchButton("Keep prompt" if deny else "Cancel", "secondary", ESC_GLYPH)
        cancel.clicked.connect(self.cancel.emit)
        go = nw.NotchButton("Deny" if deny else "Send", "destructive" if deny else "primary", SEND_GLYPH)
        go.clicked.connect(self._send)
        row.addWidget(cancel)
        row.addWidget(go)
        self.buttons.update(cancel=cancel, send=go)
        v.addLayout(row)

        self.setFixedWidth(int(width))
        self.setFixedHeight(int(height))

    # --- where it goes ---------------------------------------------------------------------

    def _show_target(self) -> None:
        if self.chip is None:
            return
        if self.project_cwd:
            name = next((n for n, c in self.projects if c == self.project_cwd), "") or self.project_cwd
            self.chip.set(name, "folder.fill")
        else:
            label = self.terminal_label or "no terminal"
            self.chip.set(f"{self.context_label} · {label}" if self.context_label else label, "terminal.fill")

    def _pick(self) -> None:
        menu = QMenu(self)
        here = menu.addAction(f"Active terminal ({self.terminal_label or 'none found'})")
        here.triggered.connect(lambda: self.set_project(""))
        if self.projects:
            menu.addSeparator()
            menu.addSection("Open in project")
            for name, cwd in self.projects:
                act = menu.addAction(name)
                act.setToolTip(cwd)
                act.triggered.connect(lambda _=False, c=cwd: self.set_project(c))
        menu.exec(self.chip.mapToGlobal(self.chip.rect().bottomLeft()))

    def set_project(self, cwd: str) -> None:
        self.project_cwd = cwd
        self.say(None)
        self._show_target()
        self.target.emit(cwd)

    # --- sending -------------------------------------------------------------------------

    def text(self) -> str:
        return self.edit.toPlainText()

    def say(self, message: str | None) -> None:
        self.error.setText(message or "")
        self.error.setVisible(bool(message))

    def _send(self) -> None:
        self.send.emit(self.text())

    def eventFilter(self, obj, event) -> bool:
        if obj is self.edit and event.type() == QEvent.KeyPress:
            if event.key() in (Qt.Key_Return, Qt.Key_Enter) and event.modifiers() & Qt.ControlModifier:
                self._send()
                return True
            if event.key() == Qt.Key_Escape:
                self.cancel.emit()
                return True
        return False
