"""What the notch's history drawer shows, as pure functions (the Mac's
NotchHistoryCard): three tabs (Sessions, Projects, Activity), a search,
the Activity filters, per-project stats and the 7-day spend header.

Sessions come from the archive (one record per session), activity from
the state's log of resolved cards, money from the transcripts (usage), as
on the Mac, so the Projects tab agrees with Settings > Usage.
"""

from __future__ import annotations

import datetime as _dt
import os
import tempfile
from dataclasses import dataclass

TABS = ("sessions", "projects", "events")
TAB_LABELS = {"sessions": "Sessions", "projects": "Projects", "events": "Activity"}
# The tab strip says "Events" for the log, the header "Activity", as on the Mac.
TAB_CHIPS = {"sessions": "Sessions", "projects": "Projects", "events": "Events"}
TAB_ICONS = {"sessions": "list.bullet.rectangle.portrait", "projects": "chart.bar.fill",
             "events": "clock.arrow.circlepath"}

FILTERS = (("all", "All"), ("allowed", "Allowed"), ("denied", "Denied"), ("dangerous", "Risky"),
           ("questions", "Q&A"))

#: outcome kind -> (rgb, icon), HistoryRow's outcomeColor and outcomeIcon.
OUTCOME_STYLE = {
    "allowed": ((48, 209, 88), "checkmark"),
    "denied": ((255, 69, 58), "xmark"),
    "dismissed": ((142, 142, 147), "minus"),
    "answered": ((191, 90, 242), "arrow.right"),
    "info": ((100, 210, 255), "bell"),
    "dangerous": ((255, 159, 10), "exclamationmark.triangle.fill"),
}


def outcome(what: str) -> tuple[str, str]:
    """(kind, label) for a log entry's "what"."""
    what = what or ""
    if what in ("allowed, destructive", "auto-approved, destructive"):
        return "dangerous", "allowed (destructive)" if what.startswith("allowed") else "auto-approved (destructive)"
    if what in ("allowed", "auto-allowed", "auto-approved"):
        return "allowed", what
    if what == "denied":
        return "denied", "denied"
    if what == "answered":
        return "answered", "answered"
    if what in ("sent to terminal", "question skipped"):
        return "dismissed", what
    return "info", "notification" if what == "notice" else what


def filter_matches(f: str, kind: str) -> bool:
    return {"all": True, "allowed": kind == "allowed", "denied": kind == "denied",
            "dangerous": kind == "dangerous", "questions": kind == "answered"}.get(f, True)


def _q(query: str) -> str:
    return (query or "").strip().lower()


def events(history: list, f: str = "all", query: str = "") -> list[dict]:
    """The log, newest first, through the filter and the search (title,
    detail, project)."""
    q = _q(query)
    out = []
    for e in reversed(history):
        if not isinstance(e, dict) or not filter_matches(f, outcome(str(e.get("what", "")))[0]):
            continue
        if q and not any(q in str(e.get(k, "")).lower() for k in ("title", "detail", "project", "what")):
            continue
        out.append(e)
    return out


def sessions(records: list, query: str = "") -> list:
    """Archived sessions (newest first already), matching project, folder or
    summary."""
    q = _q(query)
    if not q:
        return list(records)
    return [r for r in records if q in r.project.lower() or q in r.cwd.lower() or q in (r.summary or "").lower()]


def is_real_project(cwd: str) -> bool:
    """AppState.isRealProject: a run in a temp folder is work, but not a
    project; it would sit next to a repo you have lived in for weeks."""
    if not cwd:
        return False
    tmp = os.path.normcase(os.path.abspath(tempfile.gettempdir()))
    here = os.path.normcase(os.path.abspath(cwd))
    return not (here == tmp or here.startswith(tmp + os.sep))


@dataclass
class ProjectStats:
    project: str
    cwd: str
    sessions: int
    cost_usd: float
    turns: int
    last: float


def project_stats(records: list, week_cost_by_cwd: dict | None = None, query: str = "") -> list[ProjectStats]:
    """Per project, newest activity first. Money is the last seven days from
    the transcripts (week_cost_by_cwd), as on the Mac; the records' own
    figures only fill in where the transcripts have nothing."""
    groups: dict[str, list] = {}
    for r in records:
        if is_real_project(r.cwd):
            groups.setdefault(r.project, []).append(r)
    week = week_cost_by_cwd or {}
    out = []
    for project, rs in groups.items():
        cwd = max(rs, key=lambda r: r.last).cwd
        cost = week.get(cwd)
        out.append(ProjectStats(project, cwd, len(rs), cost if cost is not None else sum(r.cost_usd for r in rs),
                                sum(r.turns for r in rs), max(r.last for r in rs)))
    q = _q(query)
    if q:
        out = [p for p in out if q in p.project.lower()]
    return sorted(out, key=lambda p: -p.last)


def week_spend(daily_cost: dict, as_of: _dt.date) -> tuple[list[float], float]:
    """Seven days of spend, oldest first, and the total."""
    days = [daily_cost.get((as_of - _dt.timedelta(days=i)).isoformat(), 0.0) for i in range(6, -1, -1)]
    return days, sum(days)


def count_label(tab: str, shown: int, total: int) -> str:
    noun = {"sessions": "session", "projects": "project", "events": "event"}[tab]
    if tab == "events" and shown != total:
        return f"{shown} of {total}"
    n = shown
    return f"{n} {noun}{'' if n == 1 else 's'}"


def empty_text(tab: str, anything: bool) -> str:
    if tab == "sessions":
        return "No sessions match your search." if anything else \
            "No sessions yet, completed sessions will appear here."
    if tab == "projects":
        return "No projects match your search." if anything else \
            "No sessions yet, run some Claude sessions to see per-project stats."
    return "No events match your search." if anything else \
        "Nothing yet, permissions and questions you resolve will show up here."


def placeholder(tab: str) -> str:
    return "Search tool, command, project…" if tab == "events" else "Search project…"


def events_csv(history: list) -> str:
    import csv
    import io
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["time", "outcome", "title", "detail", "project"])
    for e in history:
        at = _dt.datetime.fromtimestamp(float(e.get("at", 0))).isoformat(timespec="seconds")
        w.writerow([at, e.get("what", ""), e.get("title", ""), e.get("detail", ""), e.get("project", "")])
    return buf.getvalue()
