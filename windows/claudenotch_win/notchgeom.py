"""The notch's geometry and motion, as pure functions: no Qt, so every number
is tested on any machine. Each one is a port of a named piece of the macOS
app, with the same constants, so the two editions cannot drift by eye.

    NotchShape.swift            notch_path()
    CardSizeAnimator            ease_out_back(), ease_out_cubic(), rebased_start(), SizeAnimator
    MouseTracker.swift          trigger_zone(), keep_region(), should_hover()
    NotchView.size(for:)        collapsed_size(), idle_open_size(), permission_size()
    NotchView                   top_radius(), bottom_radius(), elide()
    ContextCostBar              fmt_k(), context_tint()
    IdlePill.shimmerGradient    shimmer_stops()

Units are Mac points, which are Windows DIPs (Qt logical pixels): 12 pt on
a Mac at 1x and 12 px in Qt at 100 % are the same size, and Qt scales both
the drawing and the fonts for 125 % and 150 %.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# --- NotchView constants -----------------------------------------------------

#: Horizontal breathing room between card content and the notch edges.
CONTENT_H_PAD = 28
#: The Mac's notch inset on a Mac without a hardware notch is the menu bar
#: height, 24 pt. Windows has no menu bar, so the card keeps that band (it is
#: what the collapsed notch fills) and every card's content starts below it.
INSET = 24
#: NotchView.collapsedSize on a Mac without a notch: 200 x max(28, menu bar).
COLLAPSED_W = 200
COLLAPSED_H = 28
#: Content top padding is inset + 10, bottom padding 10.
CONTENT_TOP_GAP = 10
CONTENT_BOTTOM_PAD = 10

EXPAND_SECONDS = 0.42
COLLAPSE_SECONDS = 0.34

#: MouseTracker polls the cursor every 0.2 s.
HOVER_POLL_MS = 200


# --- NotchShape --------------------------------------------------------------

def notch_path(x: float, y: float, w: float, h: float, top: float, bottom: float):
    """The notch outline as drawing commands: ("move", x, y), ("line", x, y),
    ("quad", cx, cy, x, y), ("close",). Concave top "ears" of radius `top`
    that span the full width at the top edge, convex bottom corners of
    radius `bottom`. Same control points as NotchShape.path(in:)."""
    t = max(0.0, top)
    b = max(0.0, bottom)
    min_x, min_y, max_x, max_y = x, y, x + w, y + h
    return [
        ("move", min_x, min_y),
        ("quad", min_x + t, min_y, min_x + t, min_y + t),
        ("line", min_x + t, max_y - b),
        ("quad", min_x + t, max_y, min_x + t + b, max_y),
        ("line", max_x - t - b, max_y),
        ("quad", max_x - t, max_y, max_x - t, max_y - b),
        ("line", max_x - t, min_y + t),
        ("quad", max_x - t, min_y, max_x, min_y),
        ("line", min_x, min_y),
        ("close",),
    ]


def top_radius(collapsed: bool) -> float:
    """Concave top radius: 9 closed (about the real notch), 12 open."""
    return 9.0 if collapsed else 12.0


def bottom_radius(collapsed: bool, mode: str = "") -> float:
    """Convex bottom radius: 10 closed, 18 for cards, 22 for the tall drawers."""
    if collapsed:
        return 10.0
    return 22.0 if mode in ("responseDetail", "history") else 18.0


# --- CardSizeAnimator ----------------------------------------------------------

def ease_out_cubic(t: float) -> float:
    p = 1 - t
    return 1 - p * p * p


def ease_out_back(t: float) -> float:
    c1 = 1.70158
    c3 = c1 + 1
    p = t - 1
    return 1 + c3 * p * p * p + c1 * p * p


def rebased_start(current: float, target: float, eased: float) -> float:
    """The start value that puts a curve eased to `eased` exactly at
    `current` while ending at `target`. Only meaningful below 1."""
    return (current - target * eased) / (1 - eased)


class SizeAnimator:
    """CardSizeAnimator without the display link: the caller ticks it with a
    clock (seconds) from a timer and reads `size`. Expanding overshoots
    (ease-out-back, 0.42 s), collapsing eases in cleanly (cubic, 0.34 s), and
    a new target in the same direction mid-flight bends the running curve
    instead of restarting it."""

    def __init__(self):
        self.size = (0.0, 0.0)
        self._from = (0.0, 0.0)
        self._to = (0.0, 0.0)
        self._start = 0.0
        self._duration = EXPAND_SECONDS
        self._overshoot = True
        self.running = False

    @property
    def target(self) -> tuple[float, float]:
        return self._to

    def set(self, size: tuple[float, float]) -> None:
        self.running = False
        self.size = (float(size[0]), float(size[1]))
        self._to = self.size

    def _eased(self, now: float) -> tuple[float, float]:
        raw = min(1.0, max(0.0, (now - self._start) / self._duration))
        return raw, (ease_out_back(raw) if self._overshoot else ease_out_cubic(raw))

    def animate(self, size: tuple[float, float], expanding: bool, now: float) -> None:
        w, h = float(size[0]), float(size[1])
        if abs(self._to[0] - w) < 0.5 and abs(self._to[1] - h) < 0.5:
            return
        if self.running and expanding == self._overshoot:
            _, e = self._eased(now)
            if e < 0.85:
                self._from = (rebased_start(self.size[0], w, e), rebased_start(self.size[1], h, e))
                self._to = (w, h)
                return
        self._from = self.size
        self._to = (w, h)
        self._overshoot = expanding
        self._duration = EXPAND_SECONDS if expanding else COLLAPSE_SECONDS
        self._start = now
        self.running = True

    def tick(self, now: float) -> tuple[float, float]:
        if not self.running:
            return self.size
        raw, e = self._eased(now)
        if raw >= 1:
            self.size = self._to
            self.running = False
        else:
            fw, fh = self._from
            tw, th = self._to
            self.size = (fw + (tw - fw) * e, fh + (th - fh) * e)
        return self.size


def is_expanding(new: tuple[float, float], current: tuple[float, float]) -> bool:
    """NotchView: growing toward a bigger card overshoots."""
    return new[0] * new[1] >= current[0] * current[1]


# --- MouseTracker ----------------------------------------------------------------

def trigger_zone(screen: tuple[int, int, int, int]) -> tuple[float, float, float, float]:
    """The zone under the top edge that opens the card: 340 wide, 44 tall,
    centred. `screen` and the result are (x, y, w, h), y down."""
    sx, sy, sw, _ = screen
    width, height = 340.0, 44.0
    return (sx + sw / 2 - width / 2, float(sy), width, height)


def screen_to_follow(screens: list, current: int, px: float, py: float, busy: bool) -> int:
    """NotchWindowController.currentScreen, gated as the Mac gates it: the
    notch moves to another screen only when the pointer reaches that
    screen's trigger zone (its top centre), and never while a card is on
    screen. `screens` are (x, y, w, h); returns the index to use."""
    if busy:
        return current
    for i, rect in enumerate(screens):
        if i != current and contains(trigger_zone(rect), px, py):
            return i
    return current


def keep_region(screen: tuple[int, int, int, int], target_w: float, target_h: float):
    """Where the cursor may wander without the open card closing: the target
    card padded by 140 x 90, at least 460 x 160, hung from the top."""
    sx, sy, sw, _ = screen
    width = max(target_w + 140, 460.0)
    height = max(target_h + 90, 160.0)
    return (sx + sw / 2 - width / 2, float(sy), width, height)


def contains(rect, px: float, py: float) -> bool:
    x, y, w, h = rect
    return x <= px < x + w and y <= py < y + h


def should_hover(is_hovering: bool, button_down: bool, suppressed: bool,
                 in_keep_region: bool, in_trigger_zone: bool) -> bool:
    """MouseTracker.shouldHover, verbatim: an open card stays open while the
    cursor is in its keep region (a held button over it is a click on it); a
    closed one opens only from the trigger zone, never mid-drag."""
    if suppressed:
        return False
    if is_hovering:
        return in_keep_region
    if button_down:
        return False
    return in_trigger_zone


# --- sizes ---------------------------------------------------------------------

def collapsed_size() -> tuple[float, float]:
    return (float(COLLAPSED_W), float(COLLAPSED_H))


def idle_open_size(content_width: float) -> tuple[float, float]:
    """The hover card: its content plus 56 of padding and 12 of slack,
    clamped to 230..520, inset + 64 tall."""
    return (min(520.0, max(230.0, content_width + 56 + 12)), float(INSET + 64))


def permission_size(dangers: int = 0, diff_rows: int = 0, write_rows: int = 0,
                    expired: bool = False, budget: bool = False, screen_h: float = 900.0,
                    multi: bool = False) -> tuple[float, float]:
    """NotchView.size(for: .permission): 620 wide, the formula height as a
    floor. Every optional row is budgeted here, as on the Mac: a row drawn
    but not counted pushes the buttons out of the window."""
    visible = 152.0
    if dangers:
        text = 28 + dangers * 14
        visible += max(text, 30 + 14) + 8
    if budget:
        visible += 46
    if expired:
        visible += 96
    if diff_rows:
        visible += diff_rows * 16 + (28 if multi else 16)
    if write_rows:
        visible += write_rows * 14 + 16
    cap = max(180.0, screen_h * 0.85 - INSET)
    return (620.0, INSET + min(visible, cap))


# --- small text helpers -------------------------------------------------------

def elide(text: str, limit: int) -> str:
    """Shorten from the middle, keeping both ends ("feature/…-name")."""
    if len(text) <= limit or limit <= 3:
        return text
    keep = limit - 1
    head = keep - keep // 2
    tail = keep // 2
    return text[:head] + "…" + (text[-tail:] if tail else "")


def fmt_k(n: int) -> str:
    if n >= 1_000_000:
        m = n / 1_000_000
        return f"{int(m)}M" if m == round(m) else f"{m:.1f}M"
    return f"{n // 1000}k" if n >= 1000 else str(n)


def context_tint(percent: float) -> str:
    """ContextCostBar's bar colour: blue, then orange past 60 %, red past 85 %."""
    if percent < 0.6:
        return "blue"
    if percent < 0.85:
        return "orange"
    return "red"


def wait_elapsed(seconds: float) -> str:
    """How long a card has waited, as the Mac's waitElapsed (NotchMarkdown):
    "45s", "3m", "1h 5m", "2h"."""
    s = max(0, int(seconds))
    if s < 60:
        return f"{s}s"
    m = s // 60
    if m < 60:
        return f"{m}m"
    h, rm = divmod(m, 60)
    return f"{h}h {rm}m" if rm else f"{h}h"


def shimmer_stops(phase: float, base: float = 0.32, peak: float = 0.72) -> list[tuple[float, float]]:
    """(location, white opacity) stops of the travelling highlight. phase
    0..1 maps the bright spot from -0.3 to 1.3 so it enters and leaves the
    text cleanly."""
    pos = phase * 1.6 - 0.3
    span = 0.22
    stops = [(0.0, base)]
    lo, hi = pos - span, pos + span
    if 0.01 < lo < 0.99:
        stops.append((lo, base))
    if 0.01 < pos < 0.99:
        stops.append((pos, peak))
    if 0.01 < hi < 0.99:
        stops.append((hi, base))
    stops.append((1.0, base))
    return sorted(stops)


def pulse_opacity(phase: float) -> float:
    """The working dot's pulse: 0.4 + 0.6 * (0.5 + 0.5 sin), phase in radians."""
    return 0.4 + 0.6 * (0.5 + 0.5 * math.sin(phase))


@dataclass(frozen=True)
class Beat:
    period: float
    amplitude: float


#: ClaudeIconView: the mascot's bob, per mood.
BEATS = {
    "working": Beat(0.7, 1.6),
    "thinking": Beat(1.1, 1.2),
    "celebrating": Beat(0.45, 2.4),
    "startled": Beat(0.3, 2.0),
    "sleepy": Beat(3.2, 0.5),
    "curious": Beat(1.5, 1.0),
    "calm": Beat(1.8, 0.9),
}


def bob_offset(mood: str, clock: float) -> float:
    beat = BEATS.get(mood, BEATS["calm"])
    phase = (clock % beat.period) / beat.period
    wave = -abs(math.sin(phase * math.pi * 2)) if mood == "celebrating" else math.sin(phase * 2 * math.pi)
    return wave * beat.amplitude


def time_ago(seconds: float) -> str:
    """timeAgo (NotchMarkdown): "just now", "12s ago", "3m ago", "2h ago",
    "4d ago". Past a week the Mac prints the date; the caller does that."""
    s = max(0, int(seconds))
    if s < 5:
        return "just now"
    if s < 60:
        return f"{s}s ago"
    m = s // 60
    if m < 60:
        return f"{m}m ago"
    h = m // 60
    if h < 24:
        return f"{h}h ago"
    return f"{h // 24}d ago"


def notice_size() -> tuple[float, float]:
    """NotificationCard: 500 wide, inset + 100 as the floor."""
    return (500.0, float(INSET + 100))


def completed_size(audit: bool = False) -> tuple[float, float]:
    """CompletedCard: 560 wide, inset + 100, plus 44 for an audit banner."""
    return (560.0, float(INSET + 100 + (44 if audit else 0)))


def question_size(questions, screen_h: float = 900.0, link: bool = False) -> tuple[float, float]:
    """NotchView.size(for: .question). Each question: 26 heading + 6, an
    option row of 38 (66 with a description), 44 for the free-text row;
    104 of header, buttons and padding; capped at 85 % of the screen, past
    which the list scrolls. `questions` holds (option descriptions,
    allows_custom) pairs."""
    total = 0.0
    for descriptions, custom in questions:
        options = sum(66 if d else 38 for d in descriptions)
        total += 26 + 6 + options + (44 if custom else 0)
    want = 104 + total + (44 if link else 0)
    cap = max(360.0, screen_h * 0.85 - INSET)
    return (600.0, INSET + min(want, cap))


def history_size(screen_h: float = 900.0) -> tuple[float, float]:
    """NotchView.size(for: .history): a tall drawer, 640 wide, inset + 520,
    capped at 72 % of the screen on small displays."""
    return (640.0, float(min(INSET + 520, screen_h * 0.72)))


def auto_info_size() -> tuple[float, float]:
    """AutoInfoCard: compact and button-less, 460 x inset + 96."""
    return (460.0, float(INSET + 96))
