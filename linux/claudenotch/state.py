"""Everything the UI draws, and the only place it changes.

The server answers each hook on its own thread and GTK draws on the main one,
so every mutation takes the lock and then tells the listeners. A listener is
called on whatever thread made the change; the UI wraps its own in
GLib.idle_add.

Collections fed by hook payloads are capped, as on the Mac: a misbehaving
client cannot grow this without bound.
"""

from __future__ import annotations

import itertools
import json
import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

from . import fsutil, protocol
from .danger import danger_reasons
from .redact import redact

MAX_SESSIONS = 12
MAX_QUEUE = 64
MAX_HISTORY = 500
MAX_RULES = 200

_ids = itertools.count(1)


def project_name(cwd: str) -> str:
    """The last folder of a working directory, for either slash: a Windows
    session reports C:\\Users\\a\\proj, which os.path on Linux (and the tests)
    would read as one long name."""
    return re.split(r"[\\/]", cwd.rstrip("/\\"))[-1] if cwd else ""


@dataclass
class PermissionCard:
    tool: str
    tool_input: dict
    cwd: str
    kind: str                       # protocol.PERMISSION or protocol.PERM_REQUEST
    session_id: str = ""
    resolve: Callable[[str, str | None], None] = lambda d, r: None
    id: int = field(default_factory=lambda: next(_ids))
    created: float = field(default_factory=time.monotonic)

    def __post_init__(self):
        pv = protocol.preview(self.tool, self.tool_input)
        # Redacted once, here: nothing downstream (card, notification,
        # history) ever sees the raw text.
        self.title = pv.title
        self.detail = redact(pv.detail)
        self.old = redact(pv.old)
        self.new = redact(pv.new)
        self.extra = [redact(x) for x in pv.extra if x]
        self.dangers = danger_reasons(self.tool, self.tool_input)
        # What an always-allow rule is matched against: the raw text, never
        # the redacted one, or a rule for one command would match another.
        self.match_text = pv.detail

    @property
    def project(self) -> str:
        return project_name(self.cwd)

    def expired(self, now: float | None = None) -> bool:
        return ((now or time.monotonic()) - self.created) >= protocol.DECISION_WINDOW


@dataclass
class QuestionCard:
    questions: list
    cwd: str
    session_id: str = ""
    resolve: Callable[[list | None], None] = lambda a: None
    id: int = field(default_factory=lambda: next(_ids))
    created: float = field(default_factory=time.monotonic)

    @property
    def project(self) -> str:
        return project_name(self.cwd)

    def expired(self, now: float | None = None) -> bool:
        return ((now or time.monotonic()) - self.created) >= protocol.DECISION_WINDOW


@dataclass
class Session:
    id: str
    cwd: str
    status: str = "ready"           # "working", "waiting", "ready"
    last_prompt: str = ""
    updated: float = field(default_factory=time.time)
    agents: int = 0

    @property
    def project(self) -> str:
        return project_name(self.cwd) or "session"


@dataclass
class Toast:
    title: str
    body: str
    system: bool = False   # the app's own note (greeting, update), not a session's
    # What it reports, so a UI can draw the Mac's card for it: "done" (Stop),
    # "failure" (StopFailure), "notice" (Notification), "" for the app's own.
    kind: str = ""
    cwd: str = ""          # the session's folder, for the project name
    id: int = field(default_factory=lambda: next(_ids))
    created: float = field(default_factory=time.monotonic)


@dataclass(frozen=True)
class AllowRule:
    tool: str
    exact: str                      # the exact command or path; "" = any call of the tool

    def matches(self, card: PermissionCard) -> bool:
        return card.tool == self.tool and (not self.exact or card.match_text == self.exact)

    def label(self) -> str:
        return f"{self.tool}: {redact(self.exact)}" if self.exact else self.tool


def is_windows() -> bool:
    """Read at call time, not import time, so tests can switch platforms."""
    return sys.platform == "win32"


def windows_appdata() -> str:
    """%APPDATA% (Roaming), where Windows apps keep per-user settings."""
    return os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")


def config_dir() -> str:
    """Settings and always-allow rules. Windows: %APPDATA%\\ClaudeNotch.
    Linux: $XDG_CONFIG_HOME/claudenotch."""
    if is_windows():
        return os.path.join(windows_appdata(), "ClaudeNotch")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "claudenotch")


class AppState:
    def __init__(self, persist: bool = True):
        self._lock = threading.RLock()
        self._listeners: list[Callable[[], None]] = []
        self.permissions: list[PermissionCard] = []
        self.questions: list[QuestionCard] = []
        self.toasts: list[Toast] = []
        self.sessions: dict[str, Session] = {}
        self.history: list[dict] = []
        self.rules: list[AllowRule] = []
        self._persist = persist
        if persist:
            self._load_rules()

    # --- listeners ---------------------------------------------------------

    def subscribe(self, fn: Callable[[], None]) -> None:
        self._listeners.append(fn)

    def _changed(self) -> None:
        for fn in list(self._listeners):
            try:
                fn()
            except Exception:  # a broken listener must not take a hook down
                pass

    # --- permission cards --------------------------------------------------

    def enqueue_permission(self, card: PermissionCard) -> bool:
        """Queue a card. Returns False when it was decided without one: an
        always-allow rule matched (never for a dangerous call), or the queue is
        full, in which case it is answered with no opinion."""
        with self._lock:
            if not card.dangers and any(r.matches(card) for r in self.rules):
                self._log("auto-allowed", card.title, card.detail, card.project)
                decided = protocol.ALLOW
            elif len(self.permissions) >= MAX_QUEUE:
                decided = protocol.ASK
            else:
                self.permissions.append(card)
                self._touch(card.session_id, card.cwd, "waiting")
                decided = None
        if decided is not None:
            card.resolve(decided, None)
            self._changed()
            return False
        self._changed()
        return True

    def resolve_permission(self, card_id: int, decision: str, always: bool = False,
                           reason: str | None = None, scope: str = "exact") -> None:
        """`always` with `scope` "exact" saves a rule for this exact command
        (the Mac's "Always Allow This Exact Command"); "tool" saves one for
        every call of the tool ("Always Allow All Bash"). Never for a
        dangerous call."""
        with self._lock:
            card = next((c for c in self.permissions if c.id == card_id), None)
            if card is None:
                return
            self.permissions.remove(card)
            if always and decision == protocol.ALLOW and not card.dangers:
                rule = AllowRule(card.tool, "" if scope == "tool" else card.match_text)
                if rule not in self.rules:
                    self.rules = (self.rules + [rule])[-MAX_RULES:]
                    self._save_rules()
            self._log({"allow": "allowed", "deny": "denied", "ask": "sent to terminal"}[decision],
                      card.title, card.detail, card.project)
            self._touch(card.session_id, card.cwd, "working" if decision == protocol.ALLOW else "ready")
        card.resolve(decision, reason)
        self._changed()

    def resolve_all_permissions(self, decision: str) -> None:
        """The Mac's "Allow All (n)": one press answers every queued card.
        A dangerous card is never swept up by it; it stays for its own
        deliberate answer."""
        with self._lock:
            ids = [c.id for c in self.permissions if not (decision == protocol.ALLOW and c.dangers)]
        for card_id in ids:
            self.resolve_permission(card_id, decision)

    def drop_permission(self, card_id: int) -> None:
        """The hook gave up waiting (Claude Code asked in the terminal)."""
        with self._lock:
            before = len(self.permissions)
            self.permissions = [c for c in self.permissions if c.id != card_id]
            changed = len(self.permissions) != before
        if changed:
            self._changed()

    # --- questions ---------------------------------------------------------

    def enqueue_question(self, card: QuestionCard) -> bool:
        with self._lock:
            if len(self.questions) >= MAX_QUEUE:
                full = True
            else:
                full = False
                self.questions.append(card)
                self._touch(card.session_id, card.cwd, "waiting")
        if full:
            card.resolve(None)
            return False
        self._changed()
        return True

    def resolve_question(self, card_id: int, answers: list | None) -> None:
        with self._lock:
            card = next((c for c in self.questions if c.id == card_id), None)
            if card is None:
                return
            self.questions.remove(card)
            self._log("answered" if answers else "question skipped", "Question",
                      card.questions[0].text if card.questions else "", card.project)
        card.resolve(answers)
        self._changed()

    def drop_question(self, card_id: int) -> None:
        with self._lock:
            self.questions = [c for c in self.questions if c.id != card_id]
        self._changed()

    # --- sessions and informational events -----------------------------------

    def _touch(self, session_id: str, cwd: str, status: str | None = None) -> Session | None:
        key = session_id or cwd
        if not key:
            return None
        s = self.sessions.get(key)
        if s is None:
            if len(self.sessions) >= MAX_SESSIONS:
                oldest = min(self.sessions.values(), key=lambda x: x.updated)
                del self.sessions[oldest.id]
            s = Session(key, cwd)
            self.sessions[key] = s
        if cwd:
            s.cwd = cwd
        if status:
            s.status = status
        s.updated = time.time()
        return s

    def handle_event(self, payload: dict) -> None:
        event = payload.get("hook_event_name") or ""
        sid = str(payload.get("session_id") or "")
        cwd = str(payload.get("cwd") or "")
        toast = None
        with self._lock:
            if event == "SessionStart":
                self._touch(sid, cwd, "ready")
            elif event == "SessionEnd":
                self.sessions.pop(sid or cwd, None)
            elif event == "UserPromptSubmit":
                s = self._touch(sid, cwd, "working")
                if s:
                    s.last_prompt = redact(str(payload.get("prompt") or ""))[:200]
            elif event in ("PostToolUse", "SubagentStop"):
                self._touch(sid, cwd, "working")
            elif event == "SubagentStart":
                s = self._touch(sid, cwd, "working")
                if s:
                    s.agents += 1
            elif event == "Stop":
                s = self._touch(sid, cwd, "ready")
                if s:
                    s.agents = 0
                toast = Toast("Claude is done", s.project if s else "", kind="done", cwd=cwd)
            elif event == "StopFailure":
                self._touch(sid, cwd, "ready")
                toast = Toast("Claude stopped with an error", redact(str(payload.get("error") or ""))[:200],
                              kind="failure", cwd=cwd)
            elif event == "Notification":
                self._touch(sid, cwd)
                title = redact(str(payload.get("title") or "Claude Code"))[:80]
                toast = Toast(title, redact(str(payload.get("message") or "Claude needs your attention"))[:300],
                              kind="notice", cwd=cwd)
            if toast:
                self.toasts = (self.toasts + [toast])[-8:]
                self._log("notice", toast.title, toast.body, "")
        self._changed()

    def greet(self, updated_from: str | None = None, version: str = "") -> None:
        """Shown once at start, so launching the app has a visible result.
        After an in-place upgrade it says so instead."""
        if updated_from and version and updated_from != version:
            toast = Toast(f"ClaudeNotch updated to {version}", f"Was {updated_from}. Nothing to do on your side.",
                          system=True)
        else:
            toast = Toast("ClaudeNotch is running", "Claude Code prompts will appear here.", system=True)
        with self._lock:
            self.toasts = (self.toasts + [toast])[-8:]
        self._changed()

    def dismiss_toast(self, toast_id: int) -> None:
        with self._lock:
            self.toasts = [t for t in self.toasts if t.id != toast_id]
        self._changed()

    # --- history and rules -------------------------------------------------

    def _log(self, what: str, title: str, detail: str, project: str) -> None:
        self.history.append({"at": time.time(), "what": what, "title": title,
                             "detail": detail[:300], "project": project})
        del self.history[:-MAX_HISTORY]

    def remove_rule(self, rule: AllowRule) -> None:
        with self._lock:
            self.rules = [r for r in self.rules if r != rule]
            self._save_rules()
        self._changed()

    def _rules_path(self) -> str:
        return os.path.join(config_dir(), "rules.json")

    def _load_rules(self) -> None:
        try:
            with open(self._rules_path(), encoding="utf-8") as f:
                raw = json.load(f)
            self.rules = [AllowRule(str(r["tool"]), str(r.get("exact") or ""))
                          for r in raw if isinstance(r, dict) and r.get("tool")][:MAX_RULES]
        except (OSError, ValueError, TypeError):
            self.rules = []

    def _save_rules(self) -> None:
        if not self._persist:
            return
        d = config_dir()
        os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = self._rules_path() + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump([{"tool": r.tool, "exact": r.exact} for r in self.rules], f, indent=2)
        fsutil.replace(tmp, self._rules_path())

    # --- what the UI shows ---------------------------------------------------

    def snapshot(self):
        """A consistent copy for one draw."""
        with self._lock:
            return (list(self.permissions), list(self.questions), list(self.toasts),
                    sorted(self.sessions.values(), key=lambda s: -s.updated))
