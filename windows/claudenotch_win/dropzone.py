"""The drop panel, the Mac's NotchView.dropZone: while a file or folder is
dragged over the notch it becomes a black panel with a dashed box, a
download glyph and "Drop here" in blue; with the file right over the box
it glows green and says "Release to open".
"""

from __future__ import annotations

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QWidget

from . import macstyle as ms
from . import notchwidgets as nw

BLUE = (74, 143, 255)


class DropZoneView(QWidget):
    def __init__(self, width: float, height: float, parent=None):
        super().__init__(parent)
        self.hot = False
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        self.setFixedSize(int(width), int(height))
        self.setAccessibleName("Drop a folder or file here to open Claude Code there")

    def box(self) -> QRectF:
        """The dashed box, in this widget's coordinates: even margins, 14 at
        the sides and 12 underneath (the top margin is the notch's own)."""
        return QRectF(0, 0, self.width(), self.height()).adjusted(0, 0, 0, 0)

    def set_hot(self, hot: bool) -> None:
        if hot != self.hot:
            self.hot = hot
            self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        tint = ms.GREEN if self.hot else BLUE
        r = self.box().adjusted(0.8, 0.8, -0.8, -0.8)
        path = QPainterPath()
        path.addRoundedRect(r, 12, 12)
        p.fillPath(path, ms.rgba(tint, 0.16 if self.hot else 0.08))
        pen = QPen(ms.rgba(tint, 0.95 if self.hot else 0.7), 1.6)
        pen.setDashPattern([5 / 1.6, 4 / 1.6])
        p.setPen(pen)
        p.drawPath(path)
        cy = r.center().y()
        nw.draw_glyph(p, "square.and.arrow.down.fill", QRectF(r.center().x() - 11, cy - 20, 22, 22), 18,
                      ms.rgba(tint))
        p.setFont(ms.font(9.5, "semibold"))
        p.setPen(ms.rgba(tint))
        p.drawText(QRectF(r.left(), cy + 3, r.width(), 14), Qt.AlignHCenter | Qt.AlignTop,
                   "Release to open" if self.hot else "Drop here")
        p.end()
