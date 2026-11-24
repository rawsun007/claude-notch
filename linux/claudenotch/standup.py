"""Today's standup, the Mac's AppState.standupText: "what I shipped",
grouped by project from the archived sessions (their summaries, session
count and cost) and each project's own git commit subjects.

text() is pure; commits() runs git with the config keys that could make a
repo run a program (signature checks, fsmonitor) forced off, since a
project folder can be any repository the user opened.
"""

from __future__ import annotations

import datetime as _dt
import os
import subprocess

from .archive import SessionRecord


def start_of_window(days: int, now: _dt.datetime | None = None) -> _dt.datetime:
    now = now or _dt.datetime.now()
    first = now.date() - _dt.timedelta(days=max(days, 1) - 1)
    return _dt.datetime.combine(first, _dt.time())


def text(records: list[SessionRecord], commits_for, days: int = 1, extra_dirs: list[str] | None = None,
         now: _dt.datetime | None = None) -> str:
    """The standup. `commits_for(dir, since)` gives commit subjects."""
    now = now or _dt.datetime.now()
    since = start_of_window(days, now)
    header = f"Standup, {now:%a %b} {now.day}" if days <= 1 else f"What I shipped, last {days} days"
    recent = [r for r in records if r.started >= since.timestamp()]
    order: list[str] = []
    by: dict[str, list[SessionRecord]] = {}
    for r in sorted(recent, key=lambda r: r.started):
        key = r.cwd or r.project
        if key not in by:
            order.append(key)
            by[key] = []
        by[key].append(r)
    for d in extra_dirs or []:
        if d and d not in by:
            by[d] = []
            order.append(d)
    blocks = []
    for key in order:
        rs = by[key]
        lines, seen = [], set()
        for r in rs:
            s = r.summary.strip()
            if s and s.lower() not in seen:
                seen.add(s.lower())
                lines.append(f"  • {s}")
        for c in commits_for(key, since)[:8]:
            lines.append(f"  · {c}")
        if not lines:
            continue
        label = rs[0].project if rs else (os.path.basename(key.rstrip("\\/")) or key)
        meta = []
        if rs:
            meta.append(f"{len(rs)} session{'s' if len(rs) != 1 else ''}")
        cost = sum(r.cost_usd for r in rs)
        if cost > 0:
            meta.append(f"~${cost:.2f}")
        block = [label] + lines + ([f"  ({', '.join(meta)})"] if meta else [])
        blocks.append("\n".join(block))
    if not blocks:
        return header + "\n\nNo sessions or commits in this window."
    return header + "\n\n" + "\n\n".join(blocks)


def commits(directory: str, since: _dt.datetime, limit: int = 20) -> list[str]:
    """Commit subjects in `directory` since `since`, merges left out. Empty
    when it is not a repository or git is missing."""
    if not directory or not os.path.isdir(os.path.join(directory, ".git")):
        return []
    try:
        out = subprocess.run(
            ["git", "-c", "log.showSignature=false", "-c", "core.fsmonitor=false", "-C", directory, "log",
             "--no-merges", f"--since={since.isoformat(timespec='seconds')}", f"-n{limit}", "--format=%s"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=5,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.SubprocessError):
        return []
    if out.returncode != 0:
        return []
    return [line.strip()[:200] for line in out.stdout.splitlines() if line.strip()]
