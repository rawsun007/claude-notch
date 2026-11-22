"""Plan-limit warnings, the Mac's checkRateLimit. Pure.

Claude Code's status line reports how much of the 5-hour and weekly plan
limits is used. At 80 % and again at 95 % the notch says so, once per
window: a new reset instant starts a new window and re-arms both.
"""

from __future__ import annotations

import math

THRESHOLDS = (0.80, 0.95)


def warning_level(pct: float, already_warned: float) -> float | None:
    """rateLimitWarning: the highest threshold reached that was not yet warned."""
    hits = [t for t in THRESHOLDS if pct >= t and t > already_warned]
    return hits[-1] if hits else None


def reset_countdown(seconds: float) -> str:
    """ClaudeUsageReader.resetCountdown: "now", "42m", "3h 5m", "2d 4h"."""
    if seconds <= 0:
        return "now"
    minutes = math.ceil(seconds / 60)
    if minutes < 60:
        return f"{minutes}m"
    hours, rest = divmod(minutes, 60)
    if hours >= 24:
        days, rest_h = divmod(hours, 24)
        return f"{days}d {rest_h}h" if rest_h else f"{days}d"
    return f"{hours}h {rest}m" if rest else f"{hours}h"


class Armed:
    """What was already warned in the current window of one limit."""

    def __init__(self):
        self.reset: float | None = None
        self.level = 0.0

    def check(self, name: str, pct: float, reset_at: float | None, now: float) -> tuple[str, str] | None:
        """(title, detail) to show, or None. `name` is "5-hour" or "weekly"."""
        if reset_at != self.reset:
            self.reset, self.level = reset_at, 0.0
        level = warning_level(pct, self.level)
        if level is None:
            return None
        self.level = level
        left = f" · resets in {reset_countdown(reset_at - now)}" if reset_at else ""
        return (f"{int(round(level * 100))}% of your {name} limit used",
                f"You are at {int(pct * 100)}% of the {name} plan limit{left}.")
