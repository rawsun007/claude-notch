"""Past sessions, for Settings > History (the Mac's sessionHistory).

One record per Claude Code session: its folder, the first thing you asked
it (the one-line summary), when it started and last finished a turn, how
many turns, the model and Claude Code's own cost. Updated at the end of
every turn (Stop) rather than only at SessionEnd, because Claude Code does
not send every lifecycle event to HTTP hooks; the record is the same.

Saved as JSON beside the settings, capped at 200 sessions, newest kept.
Everything in it came from hook payloads, so text is redacted and capped.
"""

from __future__ import annotations

import csv
import io
import json
import os
import threading
import time
from dataclasses import asdict, dataclass

from . import fsutil
from .redact import redact

MAX_RECORDS = 200
MAX_TEXT = 200


@dataclass
class SessionRecord:
    id: str
    cwd: str
    project: str
    summary: str = ""
    started: float = 0.0
    last: float = 0.0
    turns: int = 0
    model: str = ""
    branch: str = ""
    cost_usd: float = 0.0

    def matches(self, query: str) -> bool:
        words = [w for w in query.lower().split() if w]
        hay = f"{self.project} {self.summary} {self.branch} {self.model} {self.cwd}".lower()
        return all(w in hay for w in words)


class Archive:
    def __init__(self, path: str | None):
        self.path = path
        self.records: list[SessionRecord] = []
        self._lock = threading.Lock()
        if path:
            self._load()

    def _load(self) -> None:
        try:
            with open(self.path, encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError):
            return
        out = []
        for r in raw if isinstance(raw, list) else []:
            if not isinstance(r, dict) or not isinstance(r.get("id"), str):
                continue
            try:
                out.append(SessionRecord(
                    id=r["id"][:128], cwd=str(r.get("cwd", ""))[:512], project=str(r.get("project", ""))[:MAX_TEXT],
                    summary=str(r.get("summary", ""))[:MAX_TEXT], started=float(r.get("started", 0)),
                    last=float(r.get("last", 0)), turns=int(r.get("turns", 0)), model=str(r.get("model", ""))[:64],
                    branch=str(r.get("branch", ""))[:MAX_TEXT], cost_usd=float(r.get("cost_usd", 0))))
            except (TypeError, ValueError):
                continue
        self.records = out[-MAX_RECORDS:]

    def _save(self) -> None:
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump([asdict(r) for r in self.records], f)
            fsutil.replace(tmp, self.path)
        except OSError:
            pass

    def note_turn(self, sid: str, cwd: str, project: str, prompt: str = "", model: str = "", branch: str = "",
                  cost_usd: float | None = None, now: float | None = None) -> None:
        """A turn finished in session `sid`: create or update its record."""
        if not sid:
            return
        now = now or time.time()
        with self._lock:
            rec = next((r for r in self.records if r.id == sid), None)
            if rec is None:
                rec = SessionRecord(id=sid[:128], cwd=cwd[:512], project=project[:MAX_TEXT], started=now)
                self.records = (self.records + [rec])[-MAX_RECORDS:]
            if prompt and not rec.summary:
                rec.summary = redact(" ".join(prompt.split()))[:MAX_TEXT]
            if model:
                rec.model = model[:64]
            if branch:
                rec.branch = branch[:MAX_TEXT]
            if cost_usd is not None and cost_usd >= 0:
                rec.cost_usd = cost_usd
            rec.turns += 1
            rec.last = now
            self._save()

    def newest_first(self, query: str = "") -> list[SessionRecord]:
        with self._lock:
            recs = list(self.records)
        recs.sort(key=lambda r: -r.last)
        return [r for r in recs if r.matches(query)] if query.strip() else recs

    def clear(self) -> None:
        with self._lock:
            self.records = []
            self._save()


def export_csv(records: list[SessionRecord]) -> str:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["session_id", "project", "summary", "started", "last", "turns", "model", "branch",
                "cost_usd"])
    for r in records:
        w.writerow([r.id, r.project, r.summary, time.strftime("%Y-%m-%d %H:%M", time.localtime(r.started)),
                    time.strftime("%Y-%m-%d %H:%M", time.localtime(r.last)), r.turns, r.model, r.branch,
                    f"{r.cost_usd:.4f}"])
    return buf.getvalue()


def export_json(records: list[SessionRecord]) -> str:
    return json.dumps([asdict(r) for r in records], indent=2)
