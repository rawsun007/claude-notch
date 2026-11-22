"""The notch's own all-time counters, kept on this PC (the Mac's UsageStats).

Permissions allowed and denied, auto-approved, dangerous commands flagged,
questions answered, the days it was used, and how often each tool asked.
Saved as JSON next to the settings, written atomically. Payload tool names
are capped in length and in count, so a misbehaving client cannot grow it.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import threading
from dataclasses import asdict, dataclass, field

from . import fsutil

MAX_TOOLS = 64
MAX_DAYS = 400


@dataclass
class Stats:
    allowed: int = 0
    denied: int = 0
    auto_approved: int = 0
    dangerous_flagged: int = 0
    questions_answered: int = 0
    active_days: list = field(default_factory=list)      # "YYYY-MM-DD"
    tool_counts: dict = field(default_factory=dict)
    daily_tools: dict = field(default_factory=dict)      # "YYYY-MM-DD" -> tool requests

    def top_tools(self, n: int = 6) -> list[tuple[str, int]]:
        return sorted(self.tool_counts.items(), key=lambda kv: (-kv[1], kv[0]))[:n]


class StatsStore:
    def __init__(self, path: str | None):
        self.path = path
        self.value = Stats()
        self._lock = threading.Lock()
        if path:
            self._load()

    def _load(self) -> None:
        try:
            with open(self.path, encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError):
            return
        if not isinstance(raw, dict):
            return
        s = Stats()
        for k in ("allowed", "denied", "auto_approved", "dangerous_flagged", "questions_answered"):
            v = raw.get(k)
            if isinstance(v, int) and v >= 0:
                setattr(s, k, v)
        days = raw.get("active_days")
        if isinstance(days, list):
            s.active_days = [d for d in days if isinstance(d, str)][-MAX_DAYS:]
        daily = raw.get("daily_tools")
        if isinstance(daily, dict):
            s.daily_tools = {k: v for k, v in sorted(daily.items())[-MAX_DAYS:]
                             if isinstance(k, str) and isinstance(v, int) and v >= 0}
        tools = raw.get("tool_counts")
        if isinstance(tools, dict):
            s.tool_counts = {str(k)[:64]: v for k, v in list(tools.items())[:MAX_TOOLS]
                             if isinstance(v, int) and v >= 0}
        self.value = s

    def _save(self) -> None:
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(asdict(self.value), f)
            fsutil.replace(tmp, self.path)
        except OSError:
            pass

    def record(self, what: str, tool: str = "", today: _dt.date | None = None) -> None:
        """what: "allowed", "denied", "auto_approved", "dangerous", "question",
        or "tool" (a request from `tool`). Any of them marks today active."""
        day = (today or _dt.date.today()).isoformat()
        with self._lock:
            s = self.value
            if what == "allowed":
                s.allowed += 1
            elif what == "denied":
                s.denied += 1
            elif what == "auto_approved":
                s.auto_approved += 1
                s.allowed += 1
            elif what == "dangerous":
                s.dangerous_flagged += 1
            elif what == "question":
                s.questions_answered += 1
            elif what == "tool" and tool:
                name = tool[:64]
                if name in s.tool_counts or len(s.tool_counts) < MAX_TOOLS:
                    s.tool_counts[name] = s.tool_counts.get(name, 0) + 1
                s.daily_tools[day] = s.daily_tools.get(day, 0) + 1
                if len(s.daily_tools) > MAX_DAYS:
                    del s.daily_tools[min(s.daily_tools)]
            if day not in s.active_days:
                s.active_days = (s.active_days + [day])[-MAX_DAYS:]
            self._save()


def heat_level(n: int) -> int:
    """The Mac heatmap's five levels: 0, 1-5, 6-15, 16-30, more."""
    if n <= 0:
        return 0
    if n <= 5:
        return 1
    if n <= 15:
        return 2
    if n <= 30:
        return 3
    return 4
