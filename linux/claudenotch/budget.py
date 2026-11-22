"""Spending caps with a hard stop: the Mac's budgetBlock. Pure.

With enforcement on, a tool request whose session (or today) has spent
its cap is held on the card with a budget banner: Allow once, Raise to $X
(the next sensible cap above both the cap and the spend), or Turn off.
The daily cap is checked first, as it is broader. Costs are the session's
own Claude Code figure and today's estimate from the transcripts.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

PRESETS = (1, 2, 5, 10, 25, 50, 100, 200, 500)


@dataclass(frozen=True)
class BudgetBlock:
    scope: str          # "daily" or "session"
    cost: float
    cap: float

    @property
    def pct(self) -> int:
        return int(round(self.cost / self.cap * 100)) if self.cap > 0 else 0


def block_for(enforce: bool, today_cost: float, session_cost: float, daily_cap: float,
              session_cap: float) -> BudgetBlock | None:
    if not enforce:
        return None
    if daily_cap > 0 and today_cost >= daily_cap:
        return BudgetBlock("daily", today_cost, daily_cap)
    if session_cap > 0 and session_cost >= session_cap:
        return BudgetBlock("session", session_cost, session_cap)
    return None


def next_cap(cost: float, cap: float) -> float:
    """nextCap(covering:current:)."""
    for n in PRESETS:
        if n > cost and n > cap:
            return float(n)
    return math.floor(cost / 50) * 50 + 50.0


def money(v: float) -> str:
    return f"${v:.0f}" if v >= 100 else f"${v:.2f}"
