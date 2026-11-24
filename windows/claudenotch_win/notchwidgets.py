"""The notch's building blocks, drawn the way the Mac draws them.

Each class names the SwiftUI view it ports and keeps its numbers: paddings,
corner radii, font sizes and weights, colours and opacities. Everything is
painted with QPainter (no style sheets for shapes), so a 0.5 pt hairline or a
capsule is exact at 100, 125 and 150 % scaling.

Text from a hook payload is drawn with QPainter.drawText or set on a QLabel
in Qt.PlainText: never parsed as HTML.
"""

from __future__ import annotations

import math
import time

from PySide6.QtCore import QEasingCurve, QPointF, QRect, QRectF, QSize, Qt, QTimer, QVariantAnimation, Signal
from PySide6.QtGui import QColor, QFontMetricsF, QLinearGradient, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QAbstractButton, QHBoxLayout, QLabel, QMenu, QSizePolicy, QVBoxLayout, QWidget

from . import macstyle as ms
from . import notchgeom

WHITE = ms.WHITE

# --- text -----------------------------------------------------------------------


class Text(QWidget):
    """A one-line SwiftUI Text: a font, a colour, and how it truncates
    (`lineLimit(1)` with `.truncationMode`). Fixed width when it may not
    shrink, like `.fixedSize(horizontal: true)`."""

    def __init__(self, text: str, size: float, weight: str = "regular", rgb=WHITE, opacity: float = 1.0,
                 mono: bool = False, elide: Qt.TextElideMode = Qt.ElideRight, fixed: bool = False,
                 upper: bool = False, display: bool | None = None, parent=None):
        super().__init__(parent)
        self._text = text.upper() if upper else text
        self._font = ms.font(size, weight, mono=mono, display=display)
        self._color = ms.rgba(rgb, opacity)
        self._elide = elide
        self._fixed = fixed
        self._gradient = None
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setSizePolicy(QSizePolicy.Fixed if fixed else QSizePolicy.Preferred, QSizePolicy.Fixed)
        self.setAccessibleName(self._text)

    def text(self) -> str:
        return self._text

    def set_text(self, text: str) -> None:
        if text != self._text:
            self._text = text
            self.updateGeometry()
            self.update()

    def set_color(self, rgb, opacity: float = 1.0) -> None:
        self._color = ms.rgba(rgb, opacity)
        self.update()

    def set_gradient_stops(self, stops) -> None:
        """A horizontal white gradient over the text (the shimmer), or None."""
        self._gradient = stops
        self.update()

    def _fm(self) -> QFontMetricsF:
        return QFontMetricsF(self._font)

    def sizeHint(self) -> QSize:
        fm = self._fm()
        return QSize(int(fm.horizontalAdvance(self._text) + 1.5), int(fm.height() + 0.5))

    def minimumSizeHint(self) -> QSize:
        if self._fixed:
            return self.sizeHint()
        fm = self._fm()
        return QSize(int(min(fm.horizontalAdvance(self._text), fm.horizontalAdvance("…") * 4) + 1),
                     int(fm.height() + 0.5))

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.TextAntialiasing)
        p.setFont(self._font)
        fm = self._fm()
        text = fm.elidedText(self._text, self._elide, self.width() + 0.5)
        if self._gradient:
            g = QLinearGradient(0, 0, max(1.0, fm.horizontalAdvance(text)), 0)
            for loc, op in self._gradient:
                g.setColorAt(loc, ms.rgba(WHITE, op))
            p.setPen(QPen(g, 1))
        else:
            p.setPen(self._color)
        p.drawText(QRectF(self.rect()), Qt.AlignLeft | Qt.AlignVCenter, text)


class LinesText(QWidget):
    """SwiftUI Text with `.lineLimit(n)`: wraps at word boundaries, and the
    last allowed line ends in an ellipsis when there is more."""

    def __init__(self, text: str, size: float, weight: str = "regular", rgb=WHITE, opacity: float = 1.0,
                 max_lines: int = 2, parent=None):
        super().__init__(parent)
        self._text, self._font, self._max = text, ms.font(size, weight), max_lines
        self._color = ms.rgba(rgb, opacity)
        self.setAttribute(Qt.WA_TranslucentBackground)
        sp = QSizePolicy(QSizePolicy.Preferred, QSizePolicy.Preferred)
        sp.setHeightForWidth(True)
        self.setSizePolicy(sp)
        self.setAccessibleName(text)

    def text(self) -> str:
        return self._text

    def lines(self, width: float) -> list[str]:
        fm = QFontMetricsF(self._font)
        words = self._text.split()
        out, cur = [], ""
        for i, w in enumerate(words):
            trial = f"{cur} {w}".strip()
            if fm.horizontalAdvance(trial) <= width or not cur:
                cur = trial
                continue
            out.append(cur)
            cur = w
            if len(out) == self._max - 1:
                rest = " ".join([cur] + words[i + 1:])
                out.append(fm.elidedText(rest, Qt.ElideRight, width))
                return out
        if cur:
            out.append(fm.elidedText(cur, Qt.ElideRight, width) if len(out) == self._max - 1 else cur)
        return out[: self._max] or [""]

    def hasHeightForWidth(self) -> bool:
        return True

    def heightForWidth(self, w: int) -> int:
        fm = QFontMetricsF(self._font)
        return int(len(self.lines(w)) * fm.height() + 0.99)

    def sizeHint(self) -> QSize:
        fm = QFontMetricsF(self._font)
        return QSize(int(fm.horizontalAdvance(self._text) + 1), int(fm.height() + 0.99))

    def minimumSizeHint(self) -> QSize:
        return QSize(40, self.heightForWidth(max(40, self.width())))

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setFont(self._font)
        p.setPen(self._color)
        fm = QFontMetricsF(self._font)
        y = 0.0
        for line in self.lines(self.width()):
            p.drawText(QRectF(0, y, self.width(), fm.height()), Qt.AlignLeft | Qt.AlignVCenter, line)
            y += fm.height()


def wrap_label(text: str, size: float, weight: str = "regular", rgb=WHITE, opacity: float = 1.0,
               mono: bool = False) -> QLabel:
    """A Text that wraps (`.fixedSize(horizontal: false, vertical: true)`)."""
    lbl = QLabel()
    lbl.setTextFormat(Qt.PlainText)
    lbl.setWordWrap(True)
    lbl.setFont(ms.font(size, weight, mono=mono))
    lbl.setStyleSheet(f"color: {ms.css(rgb, opacity)}; background: transparent;")
    lbl.setText(text)
    lbl.setSizePolicy(QSizePolicy.Preferred, QSizePolicy.Minimum)
    return lbl


# --- glyphs ---------------------------------------------------------------------

FLUENT = "Segoe Fluent Icons"
_FLUENT = {
    "list.bullet.rectangle.portrait": "",
    "chart.bar.fill": "",
    "xmark.circle.fill": "",
    "folder.fill": "",
    "play.fill": "",
    "checkmark": "",
    "xmark": "",
    "minus": "",
    "arrow.right": "",
    "bell": "",
    "clock": "",
    "history": "",            # clock.arrow.circlepath
    "expand": "",             # arrow.up.left.and.arrow.down.right
    "terminal": "",
    "pencil": "",
    "square.and.pencil": "",
    "doc.text": "",
    "magnifyingglass": "",
    "globe": "",
    "checklist": "",
    "checkmark.circle.fill": "",   # CompletedSolid
    "person.fill": "",
    "book": "",
    "wand.and.stars": "",
    "bolt.fill": "",
    "timer": "",
    "lock.fill": "",
    "gearshape": "",
    "menubar.rectangle": "",
    "bell.badge": "",
    "lock.shield": "",
    "info.circle": "",
    "checkmark.shield": "",
    "chart.bar": "",
    "clock.arrow.circlepath": "",
    "dollarsign.circle": "",
    "creditcard": "",
    "speaker.wave.2": "",
    "pawprint": "",
    "wand.and.stars.nav": "",
    "hammer": "",
}


class Glyph(QWidget):
    """An SF Symbol stand-in. The filled symbols that carry meaning on the
    card (the warning triangle, the speech bubbles, the dollar coin, the
    branch) are drawn as paths in the Mac's shapes; the rest come from
    Segoe Fluent Icons, Windows 11's own symbol font."""

    def __init__(self, name: str, size: float, rgb=WHITE, opacity: float = 1.0, parent=None):
        super().__init__(parent)
        self.name, self.size_pt = name, size
        self._color = ms.rgba(rgb, opacity)
        side = int(round(size * 1.25))
        self.setFixedSize(side, side)
        self.setAttribute(Qt.WA_TranslucentBackground)

    def set_color(self, rgb, opacity: float = 1.0) -> None:
        self._color = ms.rgba(rgb, opacity)
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        draw_glyph(p, self.name, QRectF(self.rect()), self.size_pt, self._color)


def _cutout(p: QPainter, rect: QRectF, ch: str, size: float) -> None:
    """Punch a character out of a filled symbol, as SF's .fill symbols do."""
    p.save()
    p.setCompositionMode(QPainter.CompositionMode_Clear)
    f = ms.font(size * 0.72, "bold")
    p.setFont(f)
    p.setPen(Qt.black)
    p.drawText(rect, Qt.AlignCenter, ch)
    p.restore()


def draw_glyph(p: QPainter, name: str, r: QRectF, size: float, color: QColor) -> None:
    s = size
    cx, cy = r.center().x(), r.center().y()
    if name == "exclamationmark.triangle.fill":
        w, h = s * 1.08, s * 0.96
        path = QPainterPath()
        top = QPointF(cx, cy - h / 2)
        path.moveTo(top)
        path.lineTo(cx + w / 2, cy + h / 2)
        path.lineTo(cx - w / 2, cy + h / 2)
        path.closeSubpath()
        p.setPen(QPen(color, s * 0.16, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        p.setBrush(color)
        p.drawPath(path)
        _cutout(p, QRectF(cx - s / 2, cy - h / 2 + h * 0.18, s, h * 0.8), "!", s)
        return
    if name in ("exclamationmark.bubble.fill", "questionmark.bubble.fill", "text.bubble"):
        w, h = s * 1.0, s * 0.82
        body = QRectF(cx - w / 2, cy - h / 2 - s * 0.06, w, h)
        path = QPainterPath()
        path.addRoundedRect(body, h * 0.3, h * 0.3)
        tail = QPainterPath()
        tail.moveTo(body.left() + w * 0.22, body.bottom() - 1)
        tail.lineTo(body.left() + w * 0.18, body.bottom() + s * 0.2)
        tail.lineTo(body.left() + w * 0.42, body.bottom() - 1)
        tail.closeSubpath()
        path = path.united(tail)
        if name == "text.bubble":
            p.setPen(QPen(color, max(1.0, s * 0.1)))
            p.setBrush(Qt.NoBrush)
            p.drawPath(path)
            for i, frac in enumerate((0.36, 0.62)):
                y = body.top() + h * frac
                x1 = body.left() + w * 0.24
                x2 = body.right() - w * (0.24 if i == 0 else 0.4)
                p.drawLine(QPointF(x1, y), QPointF(x2, y))
            return
        p.setPen(Qt.NoPen)
        p.setBrush(color)
        p.drawPath(path)
        _cutout(p, body, "!" if name.startswith("exclamation") else "?", s)
        return
    if name == "dollarsign.circle.fill":
        p.setPen(Qt.NoPen)
        p.setBrush(color)
        p.drawEllipse(QPointF(cx, cy), s * 0.5, s * 0.5)
        _cutout(p, r, "$", s)
        return
    if name == "chevron.down":
        p.setPen(QPen(color, max(1.2, s * 0.2), Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        path = QPainterPath()
        path.moveTo(cx - s * 0.36, cy - s * 0.16)
        path.lineTo(cx, cy + s * 0.2)
        path.lineTo(cx + s * 0.36, cy - s * 0.16)
        p.drawPath(path)
        return
    if name == "bolt.badge.checkmark.fill":
        # A lightning bolt with a small check badge at its foot.
        bolt = QPainterPath()
        pts = [(0.08, -0.5), (-0.3, 0.06), (-0.02, 0.06), (-0.12, 0.46), (0.28, -0.12), (0.0, -0.12), (0.08, -0.5)]
        bolt.moveTo(cx + pts[0][0] * s, cy + pts[0][1] * s)
        for x, y in pts[1:]:
            bolt.lineTo(cx + x * s, cy + y * s)
        p.setPen(Qt.NoPen)
        p.setBrush(color)
        p.drawPath(bolt)
        bx, by, br = cx + s * 0.3, cy + s * 0.3, s * 0.24
        p.drawEllipse(QPointF(bx, by), br, br)
        p.save()
        p.setCompositionMode(QPainter.CompositionMode_Clear)
        tick = QPainterPath(QPointF(bx - br * 0.5, by))
        tick.lineTo(bx - br * 0.1, by + br * 0.4)
        tick.lineTo(bx + br * 0.55, by - br * 0.4)
        p.setPen(QPen(Qt.black, max(1.0, br * 0.35), Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        p.setBrush(Qt.NoBrush)
        p.drawPath(tick)
        p.restore()
        return
    if name == "square.on.square":
        # The worktree chip: two overlapping squares.
        pen = QPen(color, max(1.0, s * 0.12))
        p.setPen(pen)
        p.setBrush(Qt.NoBrush)
        d = s * 0.62
        p.drawRoundedRect(QRectF(cx - s * 0.42, cy - s * 0.42, d, d), s * 0.12, s * 0.12)
        p.drawRoundedRect(QRectF(cx - s * 0.2, cy - s * 0.2, d, d), s * 0.12, s * 0.12)
        return
    if name == "arrow.triangle.branch":
        pen = QPen(color, max(1.0, s * 0.16), Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        p.setPen(pen)
        x0 = cx - s * 0.2
        p.drawLine(QPointF(x0, cy - s * 0.45), QPointF(x0, cy + s * 0.45))
        path = QPainterPath(QPointF(x0, cy + s * 0.15))
        path.cubicTo(x0, cy - s * 0.1, cx + s * 0.25, cy - s * 0.05, cx + s * 0.25, cy - s * 0.45)
        p.drawPath(path)
        return
    if name == "bell.fill":
        path = QPainterPath()
        w = s * 0.78
        top = cy - s * 0.46
        path.moveTo(cx - w / 2, cy + s * 0.22)
        path.cubicTo(cx - w * 0.42, cy - s * 0.1, cx - w * 0.38, top, cx, top)
        path.cubicTo(cx + w * 0.38, top, cx + w * 0.42, cy - s * 0.1, cx + w / 2, cy + s * 0.22)
        path.closeSubpath()
        p.setPen(Qt.NoPen)
        p.setBrush(color)
        p.drawPath(path)
        p.drawRoundedRect(QRectF(cx - w * 0.6, cy + s * 0.16, w * 1.2, s * 0.13), s * 0.06, s * 0.06)
        p.drawEllipse(QPointF(cx, cy + s * 0.4), s * 0.11, s * 0.11)
        return
    if name == "checkmark.seal.fill":
        import math
        path = QPainterPath()
        n = 12
        for i in range(n * 2 + 1):
            a = math.pi * i / n - math.pi / 2
            rad = s * (0.5 if i % 2 == 0 else 0.42)
            pt = QPointF(cx + rad * math.cos(a), cy + rad * math.sin(a))
            path.moveTo(pt) if i == 0 else path.lineTo(pt)
        path.closeSubpath()
        p.setPen(QPen(color, s * 0.06, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        p.setBrush(color)
        p.drawPath(path)
        p.save()
        p.setCompositionMode(QPainter.CompositionMode_Clear)
        tick = QPainterPath(QPointF(cx - s * 0.18, cy + s * 0.01))
        tick.lineTo(cx - s * 0.04, cy + s * 0.15)
        tick.lineTo(cx + s * 0.2, cy - s * 0.12)
        p.setPen(QPen(Qt.black, s * 0.11, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        p.setBrush(Qt.NoBrush)
        p.drawPath(tick)
        p.restore()
        return
    if name in ("circle", "largecircle.fill.circle", "square", "checkmark.square.fill",
                "pencil.circle", "pencil.circle.fill"):
        d = s * 0.92
        box = QRectF(cx - d / 2, cy - d / 2, d, d)
        ring = QPen(color, max(1.0, s * 0.085))
        if name in ("circle", "pencil.circle"):
            p.setPen(ring)
            p.setBrush(Qt.NoBrush)
            p.drawEllipse(box.adjusted(0.5, 0.5, -0.5, -0.5))
        elif name == "square":
            p.setPen(ring)
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(box.adjusted(0.5, 0.5, -0.5, -0.5), d * 0.22, d * 0.22)
        elif name == "largecircle.fill.circle":
            p.setPen(ring)
            p.setBrush(Qt.NoBrush)
            p.drawEllipse(box.adjusted(0.5, 0.5, -0.5, -0.5))
            p.setPen(Qt.NoPen)
            p.setBrush(color)
            p.drawEllipse(QPointF(cx, cy), d * 0.27, d * 0.27)
        elif name == "checkmark.square.fill":
            p.setPen(Qt.NoPen)
            p.setBrush(color)
            p.drawRoundedRect(box, d * 0.22, d * 0.22)
            p.save()
            p.setCompositionMode(QPainter.CompositionMode_Clear)
            tick = QPainterPath(QPointF(cx - d * 0.24, cy + d * 0.0))
            tick.lineTo(cx - d * 0.06, cy + d * 0.18)
            tick.lineTo(cx + d * 0.26, cy - d * 0.18)
            p.setPen(QPen(Qt.black, d * 0.13, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
            p.setBrush(Qt.NoBrush)
            p.drawPath(tick)
            p.restore()
        else:   # pencil.circle.fill
            p.setPen(Qt.NoPen)
            p.setBrush(color)
            p.drawEllipse(box)
        if name.startswith("pencil"):
            # A pencil, not a stroke: a slash in a circle reads as "not
            # allowed". Body and point, tilted 45 degrees, tip at bottom left.
            p.save()
            if name.endswith("fill"):
                p.setCompositionMode(QPainter.CompositionMode_Clear)
            p.translate(cx, cy)
            p.rotate(-45)
            pencil = QPainterPath()
            pencil.moveTo(-d * 0.3, 0)
            pencil.lineTo(-d * 0.16, -d * 0.075)
            pencil.lineTo(d * 0.26, -d * 0.075)
            pencil.lineTo(d * 0.26, d * 0.075)
            pencil.lineTo(-d * 0.16, d * 0.075)
            pencil.closeSubpath()
            p.setPen(Qt.NoPen)
            p.setBrush(Qt.black if name.endswith("fill") else color)
            p.drawPath(pencil)
            p.restore()
        return
    glyph = _FLUENT.get(name)
    if glyph:
        f = ms.font(s, "regular")
        f.setFamilies([FLUENT, "Segoe MDL2 Assets"])
        p.setFont(f)
        p.setPen(color)
        p.drawText(r, Qt.AlignCenter, glyph)


# --- the mascot -----------------------------------------------------------------

# PetRig.PetBody on its 16-cell grid: three torso slabs, two arms, four legs,
# and the two eye holes punched out.
_TORSO = [(2, 3, 12, 4), (2, 7, 12, 2), (2, 9, 12, 2)]
_ARMS = [(0, 7, 4, 2), (12, 7, 4, 2)]
_LEGS = [(3, 10, 1, 3), (5, 10, 1, 3), (10, 10, 1, 3), (12, 10, 1, 3)]
_EYES = [(4, 5, 1, 2), (11, 5, 1, 2)]


EMOTES = {"zzz": "z", "heart": "\u2665", "sparkle": "\u2726", "bang": "!", "dots": "\u2026",
          "teardrop": "\u25cf"}
EMOTE_RGB = {"heart": (255, 107, 140), "sparkle": (255, 204, 89), "teardrop": (115, 179, 255)}


_SHOULDERS = [(2, 8), (14, 8)]      # PetBody.shoulderLeft/Right, mid-height


def draw_pet(p: QPainter, cx: float, cy: float, size: float, pose=None, blink: bool = False, rig=None) -> None:
    """PetSprite: the coral mascot from PetBody's 16-cell grid, centred on
    (cx, cy), with a pose's tilt, squash and stretch, facing and emote, and
    a PetRig's limbs: legs stepping, lifting and tucking, arms turning about
    the shoulders, eyes blinking and following the pointer. Limbs first and
    the torso last, so the body covers every joint."""
    cell = size / 16.0
    p.save()
    p.translate(cx, cy)
    if pose is not None:
        p.rotate(pose.rotation)
        p.scale(pose.scale_x * (-1 if pose.flipped else 1), pose.scale_y)
        p.setOpacity(max(0.0, min(1.0, pose.opacity)))
    p.translate(-8 * cell, -8 * cell)
    coral = ms.rgba(ms.CORAL)
    lift = rig.leg_lift if rig else [0.0] * 4
    swing = rig.leg_swing if rig else [0.0] * 4
    tuck = rig.leg_tuck if rig else [0.0] * 4
    for i, (x, y, w, h) in enumerate(_LEGS):
        height = max(0.0, h - tuck[i])
        if height > 0.01:
            p.fillRect(QRectF((x + swing[i]) * cell, (y - lift[i]) * cell, w * cell, height * cell),
                       coral)
    angles = (rig.arm_left, -rig.arm_right) if rig else (0.0, 0.0)
    for (x, y, w, h), (px, py), angle in zip(_ARMS, _SHOULDERS, angles):
        p.save()
        p.translate(px * cell, py * cell)
        p.rotate(angle)
        p.translate(-px * cell, -py * cell)
        p.fillRect(QRectF(x * cell, y * cell, w * cell, h * cell), coral)
        p.restore()
    for x, y, w, h in _TORSO:
        p.fillRect(QRectF(x * cell, y * cell, w * cell, h * cell), coral)
    open_ = max(0.0, rig.eye_open) if rig else (0.3 if blink else 1.0)
    shift = rig.eye_shift if rig else 0.0
    if open_ > 0.02:
        for x, y, w, h in _EYES:
            lid = h * open_
            p.fillRect(QRectF((x + shift) * cell, (y + h - lid) * cell, w * cell, lid * cell), Qt.black)
    p.restore()
    if pose is not None and pose.emote:
        p.save()
        rgb = EMOTE_RGB.get(pose.emote, WHITE)
        f = ms.font(max(7.0, size * 0.28 * pose.emote_scale), "bold")
        p.setFont(f)
        p.setPen(ms.rgba(rgb, 0.85 if pose.emote in EMOTE_RGB else 0.55))
        ex = cx + (size * 0.38 if not pose.flipped else -size * 0.52)
        p.drawText(QRectF(ex, cy - size * 0.62, size * 0.4, size * 0.3), Qt.AlignCenter,
                   EMOTES.get(pose.emote, ""))
        p.restore()


class PetBadge(QWidget):
    """PetCardBadge: the mascot performing on a card, in place, no
    drop-out-of-the-lip envelope. Decorative only. It is painted on a box
    larger than its slot (see pet_badge_slot) so a hop or the dance's jump
    is not cut off, and lets every click through."""

    def __init__(self, size: float = 34, activity: str = "celebrate", loop: float = 2.4, emote: str | None = None,
                 jitter: bool = False, dance: bool = False, parent=None):
        super().__init__(parent)
        self.size_pt, self.activity, self.loop = size, activity, loop
        self.emote, self.jitter, self.dance = emote, jitter, dance
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        self.setAccessibleName("")
        self.slot: QWidget | None = None
        self._timer = QTimer(self, interval=16)
        self._timer.timeout.connect(self._tick)
        self._timer.start()

    def _tick(self) -> None:
        slot = self.slot
        if slot is not None:
            try:
                host = slot.window()
                visible = slot.isVisible()
            except RuntimeError:                    # the slot's card is gone
                self.deleteLater()
                return
            if not visible:
                self.hide()
                return
            if self.parentWidget() is not host:
                self.setParent(host)
            m = int(self.size_pt * self.MARGIN)
            at = slot.mapTo(host, slot.rect().topLeft())
            want = QRect(at.x() - m, at.y() - m, slot.width() + 2 * m, slot.height() + 2 * m)
            if self.geometry() != want:
                self.setGeometry(want)
            if not self.isVisible():
                self.show()
            self.raise_()
        self.update()

    #: How far past its slot the badge may draw, in sprite sizes.
    MARGIN = 0.6

    def frame(self, clock: float):
        """(rig, centre dx, centre dy, pose) for the moment `clock`, in
        pixels from the slot's centre. Pure, so it can be tested."""
        from . import petengine as pe
        size = self.size_pt
        t = (clock % self.loop) / self.loop
        if self.dance:
            rig, ox, oy, rot = pe.dance(t, clock)
            return rig, ox * size, -oy * size, pe.Pose(rotation=rot)
        rig = pe.rig(self.activity, t, clock)
        if self.activity == "celebrate":
            lift = abs(math.sin(t * 3 * math.pi)) * size * 0.28
        elif self.activity in ("peek", "lookAround"):
            lift = math.sin(t * 2 * math.pi) * size * 0.04
        else:
            lift = 0.0
        shake = math.sin(clock * 22) * size * 0.045 if self.jitter else 0.0
        return rig, shake, -lift, pe.Pose(emote=self.emote)

    def paintEvent(self, _e) -> None:
        rig, dx, dy, pose = self.frame(time.monotonic())
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, False)
        draw_pet(p, self.width() / 2 + dx, self.height() / 2 + dy, self.size_pt, pose, rig=rig)
        p.end()


def pet_badge_slot(card: QWidget, size: float, **kw) -> QWidget:
    """A size x size space in a layout with a PetBadge floating over it.
    SwiftUI does not clip an offset view and a Qt child is clipped by its
    parent, so the badge lives on the slot's top-level window and follows
    the slot every frame; it goes when the slot does."""
    slot = QWidget()
    slot.setFixedSize(int(size), int(size))
    badge = PetBadge(size, parent=card, **kw)
    badge.slot = slot
    badge.hide()
    slot.destroyed.connect(badge.deleteLater)
    slot.badge = badge
    return slot


class ClaudeIcon(QWidget):
    """ClaudeIconView: the coral mascot at 15 pt, bobbing at its mood's tempo
    and blinking. Painted from the same grid PetSprite uses."""

    def __init__(self, size: float = 15, mood: str = "calm", parent=None):
        super().__init__(parent)
        self.size_pt = size
        self.mood = mood
        self.setFixedSize(int(size) + 1, int(size) + 5)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self._t0 = time.monotonic()
        self._timer = QTimer(self, interval=33)
        self._timer.timeout.connect(self.update)
        self._timer.start()

    def paintEvent(self, _e) -> None:
        clock = time.monotonic() - self._t0
        dy = notchgeom.bob_offset(self.mood, clock)
        cell = self.size_pt / 16.0
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, False)
        p.translate(0.5, 2 + dy)
        coral = ms.rgba(ms.CORAL)
        for x, y, w, h in _LEGS + _ARMS + _TORSO:
            p.fillRect(QRectF(x * cell, y * cell, w * cell, h * cell), coral)
        # A blink every few seconds, eyes shut while sleepy.
        blink = self.mood == "sleepy" or (clock % 4.2) < 0.12
        for x, y, w, h in _EYES:
            eye = QRectF(x * cell, (y + (1.4 if blink else 0)) * cell, w * cell, (0.6 if blink else h) * cell)
            p.fillRect(eye, Qt.black)


# --- buttons ----------------------------------------------------------------------


class NotchButton(QAbstractButton):
    """NotchButton: 12 pt semibold, 12 x 7 padding, 8 pt rounded rectangle.
    primary is near-white with black text, secondary a faint white, and
    destructive red text on a red tint. The shortcut glyph trails at 10 pt
    medium and 55 % of the text colour."""

    STYLES = {
        # (text rgb, text opacity, bg rgb, bg opacity, hover bg opacity)
        "primary": (ms.BLACK, 1.0, WHITE, 0.94, 1.0),
        "secondary": (WHITE, 0.85, WHITE, 0.10, 0.18),
        "destructive": (ms.RED, 0.95, ms.RED, 0.13, 0.22),
    }

    def __init__(self, label: str, style: str = "secondary", shortcut: str | None = None, parent=None):
        super().__init__(parent)
        self.label, self.style_name, self.shortcut = label, style, shortcut
        self._font = ms.font(12, "semibold")
        self._sfont = ms.font(10, "medium")
        self._hover = False
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.NoFocus)
        self.setAttribute(Qt.WA_Hover)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self.setAccessibleName(label)

    def set_label(self, label: str) -> None:
        self.label = label
        self.updateGeometry()
        self.update()

    def sizeHint(self) -> QSize:
        fm, sfm = QFontMetricsF(self._font), QFontMetricsF(self._sfont)
        w = fm.horizontalAdvance(self.label)
        if self.shortcut:
            w += 6 + sfm.horizontalAdvance(self.shortcut)
        return QSize(int(w + 24 + 0.99), int(fm.height() + 14 + 0.5))

    def enterEvent(self, e) -> None:
        self._hover = True
        self.update()
        super().enterEvent(e)

    def leaveEvent(self, e) -> None:
        self._hover = False
        self.update()
        super().leaveEvent(e)

    def paintEvent(self, _e) -> None:
        fg, fgo, bg, bgo, hbgo = self.STYLES[self.style_name]
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()), 8, 8)
        p.fillPath(path, ms.rgba(bg, hbgo if self._hover else bgo))
        fm, sfm = QFontMetricsF(self._font), QFontMetricsF(self._sfont)
        x = 12.0
        p.setFont(self._font)
        p.setPen(ms.rgba(fg, fgo))
        p.drawText(QRectF(x, 0, self.width() - x, self.height()), Qt.AlignLeft | Qt.AlignVCenter, self.label)
        if self.shortcut:
            x += fm.horizontalAdvance(self.label) + 6
            p.setFont(self._sfont)
            p.setPen(ms.rgba(fg, fgo * 0.55))
            p.drawText(QRectF(x, 0, self.width() - x, self.height()), Qt.AlignLeft | Qt.AlignVCenter,
                       self.shortcut)


class CapsuleButton(QAbstractButton):
    """The capsule-shaped buttons: "Always Allow…" with its chevron (white
    14 %), and the icon-only deny-with-reason bubble (white 10 %)."""

    def __init__(self, label: str = "", icon: str = "", chevron: bool = False, fill: float = 0.14,
                 pad_h: float = 12, parent=None):
        super().__init__(parent)
        self.label, self.icon, self.chevron, self.fill, self.pad_h = label, icon, chevron, fill, pad_h
        self._font = ms.font(12, "semibold")
        self._hover = False
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.NoFocus)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self.setAccessibleName(label or icon)

    def sizeHint(self) -> QSize:
        fm = QFontMetricsF(self._font)
        w = 0.0
        if self.icon:
            w += 15
        if self.label:
            w += fm.horizontalAdvance(self.label)
        if self.chevron:
            w += 4 + 9
        return QSize(int(w + 2 * self.pad_h + 0.99), int(fm.height() + 14 + 0.5))

    def enterEvent(self, e) -> None:
        self._hover = True
        self.update()

    def leaveEvent(self, e) -> None:
        self._hover = False
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect())
        path = QPainterPath()
        path.addRoundedRect(r, r.height() / 2, r.height() / 2)
        p.fillPath(path, ms.rgba(WHITE, self.fill + (0.06 if self._hover else 0)))
        x = self.pad_h
        if self.icon:
            draw_glyph(p, self.icon, QRectF(x, 0, 15, r.height()), 12, ms.rgba(WHITE, 0.8))
            x += 15
        if self.label:
            p.setFont(self._font)
            p.setPen(ms.rgba(WHITE))
            fm = QFontMetricsF(self._font)
            p.drawText(QRectF(x, 0, r.width(), r.height()), Qt.AlignLeft | Qt.AlignVCenter, self.label)
            x += fm.horizontalAdvance(self.label)
        if self.chevron:
            x += 4
            p.setOpacity(0.7)
            draw_glyph(p, "chevron.down", QRectF(x, 0, 9, r.height()), 9, ms.rgba(WHITE))


class ConfirmButton(QAbstractButton):
    """The Mac's "Confirm to Allow": a red 85 % capsule, 14 x 7 padding, a
    lock symbol and the label at 12 pt semibold in white. Pressing it asks
    Windows Hello; only a verified answer allows the command."""

    def __init__(self, label: str, parent=None):
        super().__init__(parent)
        self.label = label
        self._font = ms.font(12, "semibold")
        self._hover = False
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.NoFocus)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self.setAccessibleName("Confirm to allow")
        self.setAccessibleDescription("This command is destructive. Confirms with Windows Hello before running it")

    def sizeHint(self) -> QSize:
        fm = QFontMetricsF(self._font)
        return QSize(int(28 + 14 + 5 + fm.horizontalAdvance(self.label) + 0.99), int(fm.height() + 14 + 0.5))

    def enterEvent(self, e) -> None:
        self._hover = True
        self.update()

    def leaveEvent(self, e) -> None:
        self._hover = False
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect())
        cap = QPainterPath()
        cap.addRoundedRect(r, r.height() / 2, r.height() / 2)
        p.fillPath(cap, ms.rgba(ms.RED, 0.95 if self._hover else 0.85))
        draw_glyph(p, "lock.fill", QRectF(14, 0, 14, r.height()), 12, ms.rgba(WHITE))
        p.setFont(self._font)
        p.setPen(ms.rgba(WHITE))
        p.drawText(QRectF(14 + 14 + 5, 0, r.width(), r.height()), Qt.AlignLeft | Qt.AlignVCenter, self.label)


class HoldToConfirmButton(QWidget):
    """HoldToConfirmButton: press and hold for 0.9 s, a red fill sweeping
    left to right over a 45 % red capsule (110 x 26 at least, 14 x 7
    padding, 12 pt semibold). Let go early and it drains in 0.15 s. Reads
    "Hold…" while held. Keyboard and screen readers activate it directly,
    as VoiceOver's accessibilityAction does on the Mac."""

    confirmed = Signal()

    def __init__(self, label: str = "Hold to Allow", duration: float = 0.9, parent=None):
        super().__init__(parent)
        self.label = label
        self.duration = duration
        self.progress = 0.0
        self.pressing = False
        self._font = ms.font(12, "semibold")
        self._anim = QVariantAnimation(self)
        self._anim.valueChanged.connect(self._set_progress)
        self._anim.finished.connect(self._finished)
        self.setCursor(Qt.PointingHandCursor)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self.setAccessibleName(label)
        self.setAccessibleDescription("This command is destructive. Activating runs it")
        self.setToolTip("Press and hold to confirm, this command was flagged as destructive")

    def sizeHint(self) -> QSize:
        fm = QFontMetricsF(self._font)
        w = max(fm.horizontalAdvance(self.label), fm.horizontalAdvance("Hold…")) + 28
        return QSize(int(max(110.0, w) + 0.99), int(max(26.0, fm.height() + 14) + 0.5))

    def _set_progress(self, v) -> None:
        self.progress = float(v)
        self.update()

    def _run(self, to: float, ms_: int, curve) -> None:
        self._anim.stop()
        self._anim.setStartValue(self.progress)
        self._anim.setEndValue(to)
        self._anim.setDuration(ms_)
        self._anim.setEasingCurve(curve)
        self._anim.start()

    def mousePressEvent(self, e) -> None:
        if e.button() != Qt.LeftButton or self.pressing:
            return
        self.pressing = True
        self.update()
        self._run(1.0, int(self.duration * 1000), QEasingCurve.Linear)

    def mouseReleaseEvent(self, e) -> None:
        if not self.pressing:
            return
        self.pressing = False
        self._run(0.0, 150, QEasingCurve.OutQuad)

    def _finished(self) -> None:
        if self.pressing and self.progress >= 1.0:
            self.pressing = False
            self.progress = 0.0
            self.update()
            self.confirmed.emit()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect())
        cap = QPainterPath()
        cap.addRoundedRect(r, r.height() / 2, r.height() / 2)
        p.fillPath(cap, ms.rgba(ms.RED, 0.45))
        if self.progress > 0:
            p.save()
            p.setClipPath(cap)
            fill = QPainterPath()
            w = r.width() * self.progress
            fill.addRoundedRect(QRectF(0, 0, w, r.height()), min(w, r.height()) / 2, r.height() / 2)
            p.fillPath(fill, ms.rgba(ms.RED))
            p.restore()
        p.setFont(self._font)
        p.setPen(ms.rgba(WHITE))
        p.drawText(r, Qt.AlignCenter, "Hold…" if self.pressing else self.label)


# --- boxes ----------------------------------------------------------------------------


class RoundedBox(QWidget):
    """A rounded rectangle behind a layout: `.background(RoundedRectangle
    (cornerRadius:).fill(...))` with an optional 1 pt stroke overlay."""

    def __init__(self, fill: QColor, radius: float = 8, stroke: QColor | None = None, parent=None):
        super().__init__(parent)
        self.fill, self.radius, self.stroke = fill, radius, stroke
        self.setAttribute(Qt.WA_TranslucentBackground)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        path = QPainterPath()
        path.addRoundedRect(r, self.radius, self.radius)
        p.fillPath(path, self.fill)
        if self.stroke is not None:
            p.setPen(QPen(self.stroke, 1))
            p.drawPath(path)


def danger_banner(reasons: list[str], pet: bool = False) -> QWidget:
    """DangerBanner: red 14 % fill, red 35 % 1 pt stroke, 8 pt corners,
    10 x 7 padding. An 11 pt bold triangle, "This command is destructive"
    at 11 pt semibold, and a bullet per reason at 10 pt, wrapping."""
    box = RoundedBox(ms.rgba(ms.RED, 0.14), 8, ms.rgba(ms.RED, 0.35))
    row = QHBoxLayout(box)
    row.setContentsMargins(10, 7, 10, 7)
    row.setSpacing(8)
    icon = Glyph("exclamationmark.triangle.fill", 11, ms.RED)
    col_icon = QVBoxLayout()
    col_icon.setContentsMargins(0, 1, 0, 0)
    col_icon.addWidget(icon)
    col_icon.addStretch(1)
    row.addLayout(col_icon)
    col = QVBoxLayout()
    col.setSpacing(2)
    col.setContentsMargins(0, 0, 0, 0)
    col.addWidget(Text("This command is destructive", 11, "semibold", ms.RED, 0.95))
    for reason in reasons:
        col.addWidget(wrap_label("• " + reason, 10, "regular", ms.RED, 0.85))
    row.addLayout(col, 1)
    if pet:
        # The pet peers at the command, shaking, a startled "!": a second
        # pair of eyes that says "careful".
        badge = pet_badge_slot(box, 30, activity="lookAround", loop=1.4, emote="bang", jitter=True)
        holder = QVBoxLayout()
        holder.setContentsMargins(2, 0, 0, 0)
        holder.addWidget(badge)
        holder.addStretch(1)
        row.addLayout(holder)
    box.setAccessibleName(" ".join(["This command is destructive."] + list(reasons)))
    return box


TOO_LATE_PERMISSION = ("Claude stopped waiting after about five minutes and asked again where the session is "
                       "running: your terminal, the VS Code extension, or a cloud session. Allowing or denying "
                       "here would not reach it.")
TOO_LATE_QUESTION = ("Claude stopped waiting after about five minutes and asked again where the session is "
                     "running. Answering here would not reach it.")


def expired_banner(body: str) -> QWidget:
    """PermissionCard.expiredBanner: an orange clock, "Too late to answer
    here" at 12 pt semibold and why at 11 pt, on an orange 12 % fill."""
    box = RoundedBox(ms.rgba(ms.ORANGE, 0.12), 8, ms.rgba(ms.ORANGE, 0.3))
    row = QHBoxLayout(box)
    row.setContentsMargins(10, 8, 10, 8)
    row.setSpacing(8)
    icon = QVBoxLayout()
    icon.setContentsMargins(0, 1, 0, 0)
    icon.addWidget(Glyph("clock.arrow.circlepath", 13, ms.ORANGE))
    icon.addStretch(1)
    row.addLayout(icon)
    col = QVBoxLayout()
    col.setSpacing(2)
    col.addWidget(Text("Too late to answer here", 12, "semibold", ms.ORANGE, 1.0))
    col.addWidget(wrap_label(body, 11, "medium", WHITE, 0.7))
    row.addLayout(col, 1)
    box.setAccessibleName("Too late to answer here. " + body)
    return box


_ACTIVITY_ICONS = {"bash": "terminal", "powershell": "terminal", "edit": "pencil", "multiedit": "pencil",
                   "write": "square.and.pencil", "read": "doc.text", "websearch": "magnifyingglass",
                   "webfetch": "globe", "todowrite": "checklist", "agent": "person.fill", "task": "person.fill",
                   "notebookedit": "book", "skill": "wand.and.stars"}


def parse_activity(activity: str) -> tuple[str, str]:
    """NotchIdlePill.parseActivity: ("terminal", "npm test") from
    "Bash: npm test"; the tool name alone when there is no detail."""
    tool, _, arg = activity.partition(":")
    tool, arg = tool.strip(), arg.strip()
    return _ACTIVITY_ICONS.get(tool.lower(), "bolt.fill"), arg or tool


class TaskProgress(QWidget):
    """The task-list bar: a checklist glyph, a 4 pt capsule (blue, green
    when every task is done) and "done/total" at 9 pt."""

    BLUE = (74, 143, 255)

    def __init__(self, done: int, total: int, parent=None):
        super().__init__(parent)
        self.done, self.total = min(done, total), total
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setFixedHeight(12)
        self.setMinimumWidth(1)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        full = self.done >= self.total
        cy = self.height() / 2
        draw_glyph(p, "checkmark.circle.fill" if full else "checklist", QRectF(0, cy - 5, 10, 10), 9,
                   ms.rgba(ms.GREEN, 0.8) if full else ms.rgba(WHITE, 0.5))
        label = f"{self.done}/{self.total}"
        f = ms.font(9, "medium")
        lw = QFontMetricsF(f).horizontalAdvance(label)
        x0, x1 = 16, self.width() - lw - 6
        bar = QRectF(x0, cy - 2, max(0.0, x1 - x0), 4)
        track = QPainterPath()
        track.addRoundedRect(bar, 2, 2)
        p.fillPath(track, ms.rgba(WHITE, 0.12))
        fill = QPainterPath()
        fill.addRoundedRect(QRectF(bar.left(), bar.top(), max(3.0, bar.width() * self.done / max(1, self.total)), 4),
                            2, 2)
        p.fillPath(fill, ms.rgba(ms.GREEN if full else self.BLUE, 1.0))
        p.setFont(f)
        p.setPen(ms.rgba(WHITE, 0.55))
        p.drawText(QRectF(x1 + 6, 0, lw + 1, self.height()), Qt.AlignVCenter, label)
        p.end()


class CommandStrip(QWidget):
    """CommandLineBlock: what Claude is running, centred in mono 10 pt on a
    4 % white strip whose hairline border shimmers, and how long it has been
    going, warming to orange past a minute: "is it stuck or still working"
    at a glance."""

    def __init__(self, activity: str, started: float | None, parent=None):
        super().__init__(parent)
        self.icon, self.text = parse_activity(activity)
        self.started = started
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setFixedHeight(22)
        self.setMinimumWidth(1)
        self._t0 = time.monotonic()
        self._timer = QTimer(self, interval=33)
        self._timer.timeout.connect(self.update)
        self._timer.start()

    def clock(self, now: float | None = None) -> str:
        from claudenotch.state import running_duration
        if self.started is None:
            return ""
        running = (now if now is not None else time.time()) - self.started
        return running_duration(running) if running >= 1 else ""

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        r = QRectF(self.rect()).adjusted(0.25, 0.25, -0.25, -0.25)
        path = QPainterPath()
        path.addRoundedRect(r, 7, 7)
        p.fillPath(path, ms.rgba(WHITE, 0.04))
        phase = ((time.monotonic() - self._t0) % 2.5) / 2.5
        pos = phase * 1.6 - 0.3
        grad = QLinearGradient(r.topLeft(), r.topRight())
        for at, a in ((0.0, 0.07), (max(0.0, min(1.0, pos - 0.22)), 0.07), (max(0.0, min(1.0, pos)), 0.28),
                      (max(0.0, min(1.0, pos + 0.22)), 0.07), (1.0, 0.07)):
            grad.setColorAt(at, ms.rgba(WHITE, a))
        p.setPen(QPen(grad, 0.5))
        p.drawPath(path)
        clock = self.clock()
        mono = ms.font(10, mono=True)
        small = ms.font(9)
        fm, fms = QFontMetricsF(mono), QFontMetricsF(small)
        clock_w = fms.horizontalAdvance(clock) + 5 if clock else 0
        room = max(0.0, self.width() - 20 - 15 - clock_w)
        text = fm.elidedText(self.text, Qt.ElideMiddle, room)
        total = 15 + fm.horizontalAdvance(text) + clock_w
        x = (self.width() - total) / 2
        cy = self.height() / 2
        draw_glyph(p, self.icon, QRectF(x, cy - 5.5, 11, 11), 10, ms.rgba(WHITE, 0.38))
        p.setFont(mono)
        p.setPen(ms.rgba(WHITE, 0.42))
        p.drawText(QRectF(x + 15, 0, fm.horizontalAdvance(text) + 1, self.height()), Qt.AlignVCenter, text)
        if clock:
            running = time.time() - (self.started or time.time())
            p.setFont(small)
            p.setPen(ms.rgba(ms.ORANGE if running >= 60 else WHITE, 0.5))
            p.drawText(QRectF(x + total - clock_w + 5, 0, clock_w, self.height()), Qt.AlignVCenter, clock)
        p.end()


def code_box(detail: str) -> QWidget:
    """The command or path: 12 pt monospaced at 78 % white, two lines at
    most, cut in the middle, in a 6 % white box with 8 pt corners."""
    box = RoundedBox(ms.rgba(WHITE, 0.06), 8)
    v = QVBoxLayout(box)
    v.setContentsMargins(10, 6, 10, 6)
    v.setSpacing(0)
    lines = detail.split("\n")
    shown = lines[:2]
    if len(lines) > 2:
        shown[-1] = shown[-1] + " …"
    for line in shown:
        v.addWidget(Text(line, 12, mono=True, opacity=0.78, elide=Qt.ElideMiddle))
    return box


class DiffView(QWidget):
    """DiffPreviewView: one row per line, 11 pt monospaced, a 10 pt bold
    marker in a 10 pt column, 8 x 1 padding; removals red 90 % on red 18 %,
    additions green 95 % on green 18 %, a "⋯" row where a side was cut. The
    whole block is clipped to 8 pt corners."""

    ROW_PAD_V = 1

    def __init__(self, hunk, parent=None):
        super().__init__(parent)
        self.hunk = hunk
        self._font = ms.font(11, mono=True)
        self._mfont = ms.font(10, "bold", mono=True)
        self._efont = ms.font(10, mono=True)
        self.rows = []
        for line in hunk.old:
            self.rows.append(("−", line, ms.RED, 0.9))
        if hunk.cut_old:
            self.rows.append(("⋯", "", ms.RED, 0.6))
        for line in hunk.new:
            self.rows.append(("+", line, ms.GREEN, 0.95))
        if hunk.cut_new:
            self.rows.append(("⋯", "", ms.GREEN, 0.6))
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setAccessibleName(spoken_diff(hunk))

    def _row_h(self) -> float:
        return QFontMetricsF(self._font).height() + 2 * self.ROW_PAD_V

    def sizeHint(self) -> QSize:
        return QSize(200, int(len(self.rows) * self._row_h() + 0.99))

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        clip = QPainterPath()
        clip.addRoundedRect(QRectF(self.rect()), 8, 8)
        p.setClipPath(clip)
        h = self._row_h()
        y = 0.0
        w = self.width()
        for marker, line, rgb, op in self.rows:
            row = QRectF(0, y, w, h)
            if marker == "⋯":
                p.fillRect(row, ms.rgba(rgb, op * 0.08))
                p.setFont(self._efont)
                p.setPen(ms.rgba(rgb, op))
                p.drawText(row.adjusted(8, 0, -8, 0), Qt.AlignLeft | Qt.AlignVCenter, "⋯")
            else:
                p.fillRect(row, ms.rgba(rgb, 0.18))
                p.setFont(self._mfont)
                p.setPen(ms.rgba(rgb, op * 0.75))
                p.drawText(QRectF(8, y, 10, h), Qt.AlignCenter, marker)
                p.setFont(self._font)
                p.setPen(ms.rgba(rgb, op))
                fm = QFontMetricsF(self._font)
                text = fm.elidedText(line if line else " ", Qt.ElideRight, w - 8 - 10 - 6 - 8)
                p.drawText(QRectF(8 + 10 + 6, y, w, h), Qt.AlignLeft | Qt.AlignVCenter, text)
            y += h


def spoken_diff(hunk) -> str:
    """DiffPreviewView.spoken: the diff as one passage for a screen reader."""
    parts: list[str] = []
    if hunk.old:
        n = len(hunk.old)
        parts.append(f"Removing {n} line{'' if n == 1 else 's'}:")
        parts.extend(hunk.old)
        if hunk.cut_old:
            parts.append("and more.")
    if hunk.new:
        n = len(hunk.new)
        parts.append(f"Adding {n} line{'' if n == 1 else 's'}:")
        parts.extend(hunk.new)
        if hunk.cut_new:
            parts.append("and more.")
    return " ".join(parts) if parts else "No changes"


class _ClipBox(QWidget):
    """Clips its children to rounded corners by painting its own background
    and leaving the children transparent: WritePreviewView's 8 pt clip."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TranslucentBackground)


def write_preview(head: str, total: int, more_text: str | None) -> QWidget:
    """WritePreviewView: the first lines, 11 pt monospaced at 85 % white on a
    green 12 % box, then "…and N more lines" at 10 pt on a 4 % strip."""
    outer = QWidget()
    v = QVBoxLayout(outer)
    v.setContentsMargins(0, 0, 0, 0)
    v.setSpacing(0)
    body = _Band(ms.rgba(ms.GREEN, 0.12), top=True, bottom=more_text is None)
    bl = QVBoxLayout(body)
    bl.setContentsMargins(10, 6, 10, 6)
    bl.setSpacing(0)
    for line in head.split("\n"):
        bl.addWidget(Text(line if line else " ", 11, mono=True, opacity=0.85))
    v.addWidget(body)
    if more_text:
        strip = _Band(ms.rgba(WHITE, 0.04), top=False, bottom=True)
        sl = QVBoxLayout(strip)
        sl.setContentsMargins(10, 3, 10, 3)
        sl.addWidget(Text(more_text, 10, opacity=0.45))
        v.addWidget(strip)
    return outer


class _Band(QWidget):
    """A fill whose top and/or bottom corners are rounded 8 pt."""

    def __init__(self, fill: QColor, top: bool, bottom: bool, parent=None):
        super().__init__(parent)
        self.fill, self.top, self.bottom = fill, top, bottom
        self.setAttribute(Qt.WA_TranslucentBackground)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect())
        path = QPainterPath()
        path.addRoundedRect(r, 8, 8)
        if not self.top:
            path = path.united(_rect_path(QRectF(r.left(), r.top(), r.width(), r.height() / 2)))
        if not self.bottom:
            path = path.united(_rect_path(QRectF(r.left(), r.center().y(), r.width(), r.height() / 2)))
        p.fillPath(path, self.fill)


def _rect_path(r: QRectF) -> QPainterPath:
    path = QPainterPath()
    path.addRect(r)
    return path


def context_cost_bar(percent: float = 0.0, tokens: int = 0, window: int = 0, cost: float = 0.0) -> QWidget:
    percent, tokens, window, cost = percent or 0.0, tokens or 0, window or 0, cost or 0.0
    """ContextCostBar: a 36 x 3 capsule warming blue, orange, red, then the
    token label at 9 pt, or "no usage yet" at 30 % before any status line."""
    w = QWidget()
    row = QHBoxLayout(w)
    row.setContentsMargins(0, 0, 0, 0)
    row.setSpacing(5)
    tint = ms.NAMED[notchgeom.context_tint(percent)]
    row.addWidget(_Meter(percent, tint))
    if tokens > 0:
        label = f"{notchgeom.fmt_k(tokens)}/{notchgeom.fmt_k(window or tokens)}"
        row.addWidget(Text(label, 9, rgb=tint, opacity=0.85, fixed=True))
    elif percent > 0:
        row.addWidget(Text(f"{round(percent * 100)}%", 9, opacity=0.45, fixed=True))
    else:
        row.addWidget(Text("no usage yet", 9, opacity=0.3, fixed=True))
    if cost > 0:
        from claudenotch.statusline import fmt_money
        row.addWidget(Text(fmt_money(cost), 9, opacity=0.4, fixed=True))
    return w


class _Meter(QWidget):
    def __init__(self, percent: float, tint, parent=None):
        super().__init__(parent)
        self.percent, self.tint = max(0.0, min(1.0, percent)), tint
        self.setFixedSize(36, 11)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        y = (self.height() - 3) / 2
        track = QPainterPath()
        track.addRoundedRect(QRectF(0, y, 36, 3), 1.5, 1.5)
        p.fillPath(track, ms.rgba(WHITE, 0.12))
        if self.percent > 0:
            fill = QPainterPath()
            fill.addRoundedRect(QRectF(0, y, 36 * self.percent, 3), 1.5, 1.5)
            p.fillPath(fill, ms.rgba(self.tint, 0.9))


class Dot(QWidget):
    """The status dot: a 5 pt circle; while working it pulses between 40 %
    and 100 % on a 1.2 s cycle."""

    def __init__(self, rgb, pulse: bool = False, diameter: float = 5, parent=None):
        super().__init__(parent)
        self.rgb, self.pulse, self.d = rgb, pulse, diameter
        self.opacity = 1.0
        self.setFixedSize(int(diameter) + 1, int(diameter) + 1)
        self._t0 = time.monotonic()
        if pulse:
            self._timer = QTimer(self, interval=33)
            self._timer.timeout.connect(self.update)
            self._timer.start()

    def set_opacity(self, opacity: float) -> None:
        self.opacity = opacity
        self.update()

    def paintEvent(self, _e) -> None:
        import math
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        op = self.opacity
        if self.pulse:
            phase = ((time.monotonic() - self._t0) % 1.2) / 1.2 * 2 * math.pi
            op = notchgeom.pulse_opacity(phase)
        p.setPen(Qt.NoPen)
        p.setBrush(ms.rgba(self.rgb, op))
        p.drawEllipse(QRectF(0.5, 0.5, self.d, self.d))


class ShimmerText(Text):
    """The working status label: 10 pt with a white highlight sweeping left
    to right every 2.5 s (IdlePill.shimmerGradient)."""

    def __init__(self, text: str, size: float = 10, base: float = 0.32, peak: float = 0.72, parent=None):
        super().__init__(text, size, fixed=True, parent=parent)
        self.base, self.peak = base, peak
        self._t0 = time.monotonic()
        self._timer = QTimer(self, interval=33)
        self._timer.timeout.connect(self._tick)
        self._timer.start()
        self._tick()

    def _tick(self) -> None:
        phase = ((time.monotonic() - self._t0) % 2.5) / 2.5
        self.set_gradient_stops(notchgeom.shimmer_stops(phase, self.base, self.peak))


def dark_menu(parent=None) -> QMenu:
    """The Always Allow menu, dark like the Mac's menu over the notch."""
    m = QMenu(parent)
    m.setAttribute(Qt.WA_TranslucentBackground)
    m.setWindowFlags(m.windowFlags() | Qt.FramelessWindowHint | Qt.NoDropShadowWindowHint)
    m.setFont(ms.font(13))
    m.setStyleSheet(
        "QMenu { background: rgba(40,40,42,0.97); border: 1px solid rgba(255,255,255,0.12);"
        " border-radius: 8px; padding: 5px; color: white; }"
        "QMenu::item { padding: 4px 18px 4px 12px; border-radius: 5px; }"
        "QMenu::item:selected { background: rgba(10,132,255,0.95); }")
    return m
