"""Claude Code's status line: what it reports, parsed the Mac's way. Pure.

Claude Code runs the `statusLine.command` from settings.json on every status
redraw, with a JSON document on stdin. That document is the only local
source of the authoritative context-window numbers, Claude Code's own cost
for the session, the running model and effort, and the 5-hour and weekly
plan limits. A small forwarder posts it to the app's /statusline.

Two steps, as on the Mac:

- `flatten(raw)`: Claude Code's nested document to the flat body the Mac's
  forwarder posts (`bin/claudenotch-statusline.sh`, its jq program, key for
  key). The wire stays identical across editions; the Windows forwarder
  produces the same body.
- `parse(body)`: that body to a `Reading`, with EventServer.handleStatusLine's
  rules: numbers may arrive as int, float or string; percentages are 0..100;
  a body with nothing usable is ignored rather than churning the UI.

Untrusted input: every value is type-checked and strings are capped.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

MAX_TEXT = 200


def _get(d, *path):
    for key in path:
        if not isinstance(d, dict):
            return None
        d = d.get(key)
    return d


def _first(*values):
    """jq's `a // b`: the first value that is not null or false."""
    for v in values:
        if v is not None and v is not False:
            return v
    return None


def flatten(raw: dict) -> dict:
    """The Mac forwarder's jq program, in Python."""
    raw = raw if isinstance(raw, dict) else {}
    causes = _get(raw, "prompt_cache", "last_miss_cause", "causes")
    return {
        "cwd": _first(_get(raw, "workspace", "current_dir"), raw.get("cwd"), "") or "",
        "session_id": _first(raw.get("session_id"), "") or "",
        "model": _first(_get(raw, "model", "id"), _get(raw, "model", "display_name"), "") or "",
        "session_name": _first(raw.get("session_name"), "") or "",
        "worktree": _first(_get(raw, "workspace", "git_worktree"), _get(raw, "worktree", "name"), "") or "",
        "pr_number": _first(_get(raw, "pr", "number")),
        "pr_url": _first(_get(raw, "pr", "url"), "") or "",
        "pr_state": _first(_get(raw, "pr", "review_state"), "") or "",
        "effort": _first(_get(raw, "effort", "level"), "") or "",
        "cost_usd": _first(_get(raw, "cost", "total_cost_usd")),
        "lines_added": _first(_get(raw, "cost", "total_lines_added")),
        "lines_removed": _first(_get(raw, "cost", "total_lines_removed")),
        "context_pct": _first(_get(raw, "context_window", "used_percentage")),
        "context_window": _first(_get(raw, "context_window", "context_window_size")),
        "context_tokens": _first(_get(raw, "context_window", "total_input_tokens")),
        "five_hour_pct": _first(_get(raw, "rate_limits", "five_hour", "used_percentage")),
        "seven_day_pct": _first(_get(raw, "rate_limits", "seven_day", "used_percentage")),
        "five_hour_resets_at": _first(_get(raw, "rate_limits", "five_hour", "resets_at")),
        "seven_day_resets_at": _first(_get(raw, "rate_limits", "seven_day", "resets_at")),
        "spend_pct": _first(_get(raw, "rate_limits", "spend_limit", "used_percentage")),
        "spend_resets_at": _first(_get(raw, "rate_limits", "spend_limit", "resets_at")),
        "spend_used_usd": _first(_get(raw, "rate_limits", "spend_limit", "used_usd")),
        "spend_limit_usd": _first(_get(raw, "rate_limits", "spend_limit", "limit_usd")),
        "spend_period": _first(_get(raw, "rate_limits", "spend_limit", "period"), "") or "",
        # A plain path, not `//`: false must stay false (a cold cache).
        "cache_warm": _get(raw, "prompt_cache", "warm"),
        "cache_expires_at": _first(_get(raw, "prompt_cache", "expires_at")),
        "cache_ttl": _first(_get(raw, "prompt_cache", "ttl"), "") or "",
        "cache_hit_ratio": _first(_get(raw, "prompt_cache", "hit_ratio")),
        "cache_recache_tokens": _first(_get(raw, "prompt_cache", "recache_tokens_if_cold")),
        "cache_miss_causes": ",".join(str(c) for c in causes) if isinstance(causes, list) else "",
    }


def _num(body: dict, key: str) -> float | None:
    v = body.get(key)
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def _text(body: dict, key: str) -> str:
    v = body.get(key)
    return v[:MAX_TEXT] if isinstance(v, str) else ""


@dataclass
class Reading:
    session_id: str = ""
    cwd: str = ""
    model: str = ""
    session_name: str = ""
    worktree: str = ""
    effort: str = ""
    pr_number: int | None = None
    pr_url: str = ""
    pr_state: str = ""
    cost_usd: float | None = None
    lines_added: int | None = None
    lines_removed: int | None = None
    context_pct: float | None = None        # 0..1
    context_window: int | None = None
    context_tokens: int | None = None
    five_hour_pct: float | None = None      # 0..1
    seven_day_pct: float | None = None      # 0..1
    five_hour_resets_at: float | None = None   # unix seconds
    seven_day_resets_at: float | None = None
    cache_warm: bool | None = None
    extra: dict = field(default_factory=dict)


def _pct(v: float | None) -> float | None:
    return None if v is None else min(1.0, max(0.0, v / 100.0))


def _int(v: float | None) -> int | None:
    return None if v is None else int(v)


def parse(body: dict) -> Reading | None:
    """handleStatusLine: None when the body carries nothing usable."""
    if not isinstance(body, dict):
        return None
    r = Reading(
        session_id=_text(body, "session_id"),
        cwd=_text(body, "cwd"),
        model=_text(body, "model"),
        session_name=_text(body, "session_name"),
        worktree=_text(body, "worktree"),
        effort=_text(body, "effort"),
        pr_number=_int(_num(body, "pr_number")),
        pr_url=_text(body, "pr_url"),
        pr_state=_text(body, "pr_state"),
        cost_usd=_num(body, "cost_usd"),
        lines_added=_int(_num(body, "lines_added")),
        lines_removed=_int(_num(body, "lines_removed")),
        context_pct=_pct(_num(body, "context_pct")),
        context_window=_int(_num(body, "context_window")),
        context_tokens=_int(_num(body, "context_tokens")),
        five_hour_pct=_pct(_num(body, "five_hour_pct")),
        seven_day_pct=_pct(_num(body, "seven_day_pct")),
        five_hour_resets_at=_num(body, "five_hour_resets_at"),
        seven_day_resets_at=_num(body, "seven_day_resets_at"),
        cache_warm=body.get("cache_warm") if isinstance(body.get("cache_warm"), bool) else None,
    )
    usable = (r.context_pct is not None or r.five_hour_pct is not None or r.seven_day_pct is not None
              or r.context_window is not None or r.session_name or r.worktree or r.pr_number is not None
              or r.effort or r.cost_usd is not None or r.cache_warm is not None
              or _num(body, "spend_pct") is not None)
    return r if usable else None


# --- how the numbers are shown (ClaudeUsageReader) -----------------------------

_FAMILIES = ("fable", "mythos", "opus", "sonnet", "haiku")


def model_version_label(model: str) -> str:
    """"claude-opus-4-6-20250101" -> "4.6": dated suffixes dropped, the
    all-digit parts joined with dots."""
    stripped = re.sub(r"-?\d{6,}", "", model.lower())
    return ".".join(p for p in stripped.split("-") if p and p.isdigit())


def model_name_version(model: str) -> tuple[str, str]:
    m = model.lower()
    for fam in _FAMILIES:
        if fam in m:
            return fam.capitalize(), model_version_label(model)
    if model:
        return model, model_version_label(model)
    return "", ""


def short_model(model: str) -> str:
    m = model.lower()
    for fam in _FAMILIES:
        if fam in m:
            v = model_version_label(model)
            return f"{fam} {v}" if v else fam
    return model


def fmt_money(d: float) -> str:
    return f"${d:.0f}" if d >= 100 else f"${d:.2f}"


def capitalized(effort: str) -> str:
    """noteLiveEffort: "high" -> "High"."""
    return effort[:1].upper() + effort[1:] if effort else ""
