"""The Mac notch's colours and type, for Qt.

Colours: the notch is black, and SwiftUI's named colours on it resolve to the
dark-appearance system palette, so these are those values. Opacities are
written exactly as the Swift source writes them (`.white.opacity(0.55)`),
via `rgba()`.

Type: SF Pro is not on Windows and is not ours to ship. Segoe UI Variable is
the Windows 11 system face (Display for titles, Text for body, matching SF's
own optical split), Cascadia Mono stands in for SF Mono. Sizes are the Mac's
point sizes, used as Qt pixel sizes: a Mac point and a Windows DIP are the
same length, and Qt scales both for 125 % and 150 %.
"""

from __future__ import annotations

from PySide6.QtGui import QColor, QFont

# SwiftUI dark-appearance system colours.
RED = (255, 69, 58)
ORANGE = (255, 159, 10)
YELLOW = (255, 214, 10)
GREEN = (48, 209, 88)
BLUE = (10, 132, 255)
PURPLE = (191, 90, 242)
CYAN = (100, 210, 255)
GRAY = (142, 142, 147)
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
#: Color(red: 0.29, green: 0.56, blue: 1.0), the task bar and drop tint.
TASK_BLUE = (74, 143, 255)
#: PetCostume.coral, the mascot.
CORAL = (217, 119, 87)

NAMED = {"red": RED, "orange": ORANGE, "yellow": YELLOW, "green": GREEN, "blue": BLUE,
         "purple": PURPLE, "cyan": CYAN, "gray": GRAY, "white": WHITE}


def rgba(rgb: tuple[int, int, int], opacity: float = 1.0) -> QColor:
    c = QColor(*rgb)
    c.setAlphaF(max(0.0, min(1.0, opacity)))
    return c


def css(rgb: tuple[int, int, int], opacity: float = 1.0) -> str:
    """The same colour for a style sheet."""
    return f"rgba({rgb[0]},{rgb[1]},{rgb[2]},{max(0.0, min(1.0, opacity)):.3f})"


TEXT_FAMILY = "Segoe UI Variable Text"
DISPLAY_FAMILY = "Segoe UI Variable Display"
MONO_FAMILY = "Cascadia Mono"
_FALLBACK = ["Segoe UI"]
_MONO_FALLBACK = ["Cascadia Code", "Consolas"]

_WEIGHTS = {
    "regular": QFont.Weight.Normal,
    "medium": QFont.Weight.Medium,
    "semibold": QFont.Weight.DemiBold,
    "bold": QFont.Weight.Bold,
}

#: At and above this size SwiftUI's SF switches to its Display cut; Segoe UI
#: Variable has the same split.
DISPLAY_FROM = 14


def font(size: float, weight: str = "regular", mono: bool = False, display: bool | None = None) -> QFont:
    f = QFont()
    if mono:
        f.setFamilies([MONO_FAMILY, *_MONO_FALLBACK])
        f.setStyleHint(QFont.StyleHint.Monospace)
    else:
        if display is None:
            display = size >= DISPLAY_FROM
        f.setFamilies([DISPLAY_FAMILY if display else TEXT_FAMILY, *_FALLBACK])
    f.setPixelSize(max(1, round(size)))
    f.setWeight(_WEIGHTS.get(weight, QFont.Weight.Normal))
    f.setHintingPreference(QFont.HintingPreference.PreferNoHinting)
    # Greyscale antialiasing, as macOS draws: ClearType's colour fringes
    # show on white text over black, and on a per-pixel-alpha window.
    f.setStyleStrategy(QFont.StyleStrategy(QFont.PreferAntialias | QFont.NoSubpixelAntialias))
    return f
