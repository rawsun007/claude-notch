"""Token usage and estimated cost from Claude Code's transcripts.

A port of the Mac's ModelPricing and ClaudeUsageReader.compute: every
assistant turn in ~/.claude/projects/**/*.jsonl carries its token usage;
priced at the public per-token rates they give today, the last five
hours, the last seven days (today and the six before it), a 28-day daily
series for the trend charts, the model and project mix, and what prompt
caching saved. Costs are estimates at API prices, not a subscription bill.

Transcripts are untrusted input: each line is parsed on its own, anything
malformed is skipped, and a file is re-read only when its size or time
changed. A turn is written as several lines repeating one message id, so
each id is billed once per file, as on the Mac.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import threading
from dataclasses import dataclass, field

from .statusline import short_model

HAIKU_LONG_PROMPT = 100_000


@dataclass(frozen=True)
class Price:
    input: float
    output: float
    cache_write_5m: float
    cache_write_1h: float
    cache_read: float


def model_version(model: str) -> float | None:
    """"claude-opus-4-6-20251001" -> 4.6; a date stamp is not a minor version."""
    parts = model.lower().split("-")
    i = 0
    while i < len(parts) and not parts[i].isdigit():
        i += 1
    nums = []
    while i < len(parts) and parts[i].isdigit():
        nums.append(int(parts[i]))
        i += 1
    if not nums:
        return None
    minor = nums[1] if len(nums) > 1 else 0
    return nums[0] + (minor / 10 if minor < 10 else 0)


def price_for(model: str, prompt_tokens: int = 0) -> Price:
    """ModelPricing.price(for:), dollars per million tokens."""
    m = model.lower()
    v = model_version(m) or 0
    if "fable" in m or "mythos" in m:
        return Price(10, 50, 12.5, 20, 0.25 if v >= 5.1 else 1)
    if "opus" in m:
        if v >= 5.5:
            return Price(4, 20, 5, 8, 0.2)
        if v >= 4.5:
            return Price(5, 25, 6.25, 10, 0.5)
        return Price(15, 75, 18.75, 30, 1.5)
    if "haiku" in m:
        if v >= 5.5:
            return (Price(0.5, 2.5, 0.625, 1, 0.05) if prompt_tokens > HAIKU_LONG_PROMPT
                    else Price(0.1, 0.5, 0.125, 0.2, 0.01))
        if 0 < v < 4.5:
            return Price(0.8, 4, 1, 1.6, 0.08)
        return Price(1, 5, 1.25, 2, 0.1)
    if "sonnet" in m and 0 < v < 5:
        return Price(3, 15, 3.75, 6, 0.3)
    return Price(2, 10, 2.5, 4, 0.1 if "sonnet" in m and v >= 5.5 else 0.2)


def cache_writes(u: dict) -> tuple[int, int]:
    total = _int(u.get("cache_creation_input_tokens"))
    split = u.get("cache_creation")
    if not isinstance(split, dict):
        return total, 0
    hour = _int(split.get("ephemeral_1h_input_tokens"))
    five = _int(split.get("ephemeral_5m_input_tokens"))
    return max(five, total - hour), hour


def cost(input_: int, output: int, cache_read: int, write_5m: int, write_1h: int, model: str) -> float:
    p = price_for(model, input_ + cache_read + write_5m + write_1h)
    return (input_ * p.input + output * p.output + cache_read * p.cache_read
            + write_5m * p.cache_write_5m + write_1h * p.cache_write_1h) / 1_000_000


def cache_savings(cache_read: int, model: str) -> float:
    p = price_for(model)
    return cache_read * (p.input - p.cache_read) / 1_000_000


def _int(v) -> int:
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


@dataclass
class Tokens:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_creation: int = 0
    cost_usd: float = 0.0

    @property
    def total(self) -> int:
        return self.input + self.output + self.cache_read + self.cache_creation

    def add(self, o: "Tokens") -> None:
        self.input += o.input
        self.output += o.output
        self.cache_read += o.cache_read
        self.cache_creation += o.cache_creation
        self.cost_usd += o.cost_usd


@dataclass
class Record:
    ts: _dt.datetime          # local time
    model: str
    tokens: Tokens
    session_id: str
    cwd: str


def _parse_ts(s) -> _dt.datetime | None:
    if not isinstance(s, str):
        return None
    try:
        return _dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def parse_lines(lines) -> list[Record]:
    """One transcript's billable records: assistant turns with usage, each
    message id once."""
    billed: set[str] = set()
    out: list[Record] = []
    for line in lines:
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(obj, dict):
            continue
        msg = obj.get("message")
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        u = msg.get("usage")
        ts = _parse_ts(obj.get("timestamp"))
        if not isinstance(u, dict) or ts is None:
            continue
        mid = msg.get("id")
        if isinstance(mid, str) and mid:
            if mid in billed:
                continue
            billed.add(mid)
        model = msg.get("model") if isinstance(msg.get("model"), str) else "unknown"
        inp, outp, cr = _int(u.get("input_tokens")), _int(u.get("output_tokens")), _int(u.get("cache_read_input_tokens"))
        w5, w1 = cache_writes(u)
        t = Tokens(inp, outp, cr, _int(u.get("cache_creation_input_tokens")), cost(inp, outp, cr, w5, w1, model))
        sid = obj.get("sessionId") if isinstance(obj.get("sessionId"), str) else ""
        cwd = obj.get("cwd") if isinstance(obj.get("cwd"), str) else ""
        out.append(Record(ts, model, t, sid, cwd))
    return out


@dataclass
class Usage:
    today: Tokens = field(default_factory=Tokens)
    five_hour: Tokens = field(default_factory=Tokens)
    week: Tokens = field(default_factory=Tokens)
    daily_cost: dict = field(default_factory=dict)       # "YYYY-MM-DD" -> USD, 28 days
    daily_tokens: dict = field(default_factory=dict)
    week_by_model: dict = field(default_factory=dict)    # "opus 5.5" -> Tokens
    week_by_project: dict = field(default_factory=dict)  # cwd -> Tokens
    hour_counts: dict = field(default_factory=dict)
    cache_savings_usd: float = 0.0
    sessions_today: int = 0
    sessions_week: int = 0

    @property
    def cache_hit_rate(self) -> float:
        fresh = self.week.input + self.week.cache_creation
        seen = fresh + self.week.cache_read
        return self.week.cache_read / seen if seen else 0.0


def projects_dir() -> str:
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(base, "projects")


_cache: dict[str, tuple[float, int, list[Record]]] = {}
_cache_lock = threading.Lock()
MAX_FILE_BYTES = 64 * 1024 * 1024


def _records(path: str, mtime: float, size: int) -> list[Record]:
    with _cache_lock:
        hit = _cache.get(path)
    if hit and hit[0] == mtime and hit[1] == size:
        return hit[2]
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            if size > MAX_FILE_BYTES:
                f.seek(size - MAX_FILE_BYTES)
                f.readline()
            recs = parse_lines(f)
    except OSError:
        recs = []
    with _cache_lock:
        _cache[path] = (mtime, size, recs)
    return recs


def compute(root: str | None = None, now: _dt.datetime | None = None) -> Usage:
    """ClaudeUsageReader.compute. Reads files: call it off the GUI thread."""
    root = root or projects_dir()
    now = now or _dt.datetime.now().astimezone()
    start_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_ago = start_today - _dt.timedelta(days=6)
    month_ago = start_today - _dt.timedelta(days=28)
    five_hours_ago = now - _dt.timedelta(hours=5)
    u = Usage()
    s_today, s_week, seen = set(), set(), set()
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if _dt.datetime.fromtimestamp(st.st_mtime).astimezone() < month_ago:
                continue
            seen.add(path)
            for r in _records(path, st.st_mtime, st.st_size):
                if r.ts < month_ago:
                    continue
                day = r.ts.strftime("%Y-%m-%d")
                u.daily_tokens[day] = u.daily_tokens.get(day, 0) + r.tokens.total
                u.daily_cost[day] = u.daily_cost.get(day, 0.0) + r.tokens.cost_usd
                if r.ts < week_ago:
                    continue
                u.week.add(r.tokens)
                u.week_by_model.setdefault(short_model(r.model), Tokens()).add(r.tokens)
                if r.cwd:
                    u.week_by_project.setdefault(r.cwd, Tokens()).add(r.tokens)
                u.hour_counts[r.ts.hour] = u.hour_counts.get(r.ts.hour, 0) + 1
                u.cache_savings_usd += cache_savings(r.tokens.cache_read, r.model)
                if r.session_id:
                    s_week.add(r.session_id)
                if r.ts >= start_today:
                    u.today.add(r.tokens)
                    if r.session_id:
                        s_today.add(r.session_id)
                if r.ts >= five_hours_ago:
                    u.five_hour.add(r.tokens)
    with _cache_lock:
        for k in [k for k in _cache if k not in seen]:
            del _cache[k]
    u.sessions_today, u.sessions_week = len(s_today), len(s_week)
    return u


def daily_series(daily: dict, days: int, as_of: _dt.date) -> list[tuple[str, float]]:
    """The last `days` days, oldest first, as (weekday label, value)."""
    out = []
    for i in range(days - 1, -1, -1):
        d = as_of - _dt.timedelta(days=i)
        out.append((d.strftime("%a"), daily.get(d.isoformat(), 0.0)))
    return out


def weekly_cost_buckets(daily: dict, weeks: int, as_of: _dt.date) -> list[tuple[str, float]]:
    """ClaudeUsageReader.weeklyCostBuckets: `weeks` seven-day totals ending
    today, oldest first, labelled by each week's first day ("Nov 2")."""
    out = []
    for w in range(weeks - 1, -1, -1):
        end = as_of - _dt.timedelta(days=7 * w)
        start = end - _dt.timedelta(days=6)
        total = sum(daily.get((start + _dt.timedelta(days=i)).isoformat(), 0.0) for i in range(7))
        out.append((f"{start.strftime('%b')} {start.day}", total))
    return out


def fmt_tokens(n: int) -> str:
    """formatTokens: 950, 12.3k, 4.5M."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(n)



def export_csv(daily_tokens: dict, daily_cost: dict) -> str:
    """Days with their tokens and estimated cost, oldest first, as CSV."""
    rows = ["day,tokens,estimated_cost_usd"]
    for day in sorted(set(daily_tokens) | set(daily_cost)):
        rows.append(f"{day},{daily_tokens.get(day, 0)},{daily_cost.get(day, 0.0):.4f}")
    return "\n".join(rows) + "\n"
