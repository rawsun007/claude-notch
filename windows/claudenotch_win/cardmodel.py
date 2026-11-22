"""What a permission card says, the Mac's way. Pure, so it is tested here.

Ports of EventServer.humanTitle / humanDetail and ToolPreviewParser.preview,
so a Windows card reads word for word like the Mac one: "Run shell command"
over the command, "Edit file" over the path and a red/green diff, "Write
file" over the first twelve lines.

Hook payloads are untrusted: every string that reaches a label is redacted
here (the same SecretRedactor rules, from the shared core) and becomes plain
text in a QLabel, never HTML.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from claudenotch.redact import redact

MAX_DIFF_LINES = 10
MAX_WRITE_LINES = 12
MULTI_DIFF_LINES = 8

_TITLES = {
    "Bash": "Run shell command",
    "Write": "Write file",
    "Edit": "Edit file",
    "MultiEdit": "Edit file",
    "Read": "Read file",
    "NotebookEdit": "Edit notebook",
    "TaskUpdate": "Update task",
    "TaskCreate": "Create task",
    "TaskList": "List tasks",
    "TaskGet": "Get task",
    "TaskStop": "Stop task",
    "WebFetch": "Fetch URL",
    "WebSearch": "Search the web",
    "Task": "Spawn subagent",
    "ExitPlanMode": "Approve plan",
    "TodoWrite": "Update todos",
    "SlashCommand": "Run slash command",
    "Skill": "Load skill",
    "write_stdin": "Send input to a running command",
    "apply_patch": "Edit file",
    "read_file": "Read file",
    "web_search": "Search the web",
    "view_image": "View image",
    "update_plan": "Update plan",
}
_SHELLS = ("shell", "local_shell", "exec", "exec_command", "unified_exec")
_WEB = ("webrun", "web.run", "web")


def human_title(tool: str) -> str:
    if tool in _SHELLS:
        return "Run shell command"
    if tool in _WEB:
        return "Search the web"
    return _TITLES.get(tool, f"Run {tool}")


def _s(ti: dict, key: str) -> str:
    v = ti.get(key)
    return v if isinstance(v, str) else ""


def _first(ti: dict, keys) -> str:
    for k in keys:
        v = ti.get(k)
        if isinstance(v, str) and v.strip():
            return v
    return ""


def _command(ti: dict) -> str:
    cmd = ti.get("command")
    if isinstance(cmd, list):
        return " ".join(str(x) for x in cmd)
    return cmd if isinstance(cmd, str) else ""


def human_detail(tool: str, ti: dict) -> str:
    ti = ti if isinstance(ti, dict) else {}
    if tool == "Bash":
        return _s(ti, "command") or _s(ti, "description")
    if tool in _SHELLS:
        return _command(ti) or _s(ti, "justification")
    if tool in ("Write", "Edit", "MultiEdit", "Read", "NotebookEdit"):
        return _s(ti, "file_path") or _s(ti, "notebook_path")
    if tool == "TaskUpdate":
        subject, status, task_id = _s(ti, "subject"), _s(ti, "status"), _s(ti, "taskId")
        if subject and status:
            return f"{subject}  →  {status}"
        if subject:
            return subject
        if status:
            return f"task {task_id} → {status}"
        return task_id
    if tool == "TaskCreate":
        return _s(ti, "subject") or _s(ti, "description")
    if tool == "WebFetch":
        return _s(ti, "url") or _s(ti, "prompt")
    if tool == "WebSearch":
        return _s(ti, "query")
    if tool == "Task":
        kind, desc = _s(ti, "subagent_type"), _s(ti, "description")
        if kind and desc:
            return f"{kind}: {desc}"
        return kind or desc
    if tool == "ExitPlanMode":
        return _s(ti, "plan")[:120]
    if tool == "TodoWrite":
        todos = ti.get("todos") if isinstance(ti.get("todos"), list) else []
        n = len(todos)
        if n == 0:
            return "no todos"
        doing = sum(1 for t in todos if isinstance(t, dict) and t.get("status") == "in_progress")
        return f"{n} todos  ·  {doing} in progress" if doing else f"{n} todos"
    if tool == "SlashCommand":
        return _s(ti, "command")
    if tool == "Skill":
        name, args = _s(ti, "skill"), _s(ti, "args")
        return f"{name} · {args}" if name and args else name
    return _command(ti) or _first(ti, ["file_path", "path", "query", "q", "url", "subject", "prompt",
                                       "description"])


@dataclass
class Hunk:
    old: list[str] = field(default_factory=list)
    new: list[str] = field(default_factory=list)
    cut_old: bool = False
    cut_new: bool = False

    @property
    def rows(self) -> int:
        """Rows the card budgets for it: each side and one per cut marker."""
        return len(self.old) + len(self.new) + (1 if self.cut_old or self.cut_new else 0)


@dataclass
class Preview:
    kind: str                      # "diff", "multi", "write"
    hunk: Hunk | None = None
    count: int = 0                 # multi: how many edits
    head: str = ""                 # write: the first lines
    total: int = 0                 # write: how many lines in all


def _hunk(old: str, new: str, limit: int) -> Hunk:
    o = old.split("\n") if old else []
    n = new.split("\n") if new else []
    return Hunk([redact(x) for x in o[:limit]], [redact(x) for x in n[:limit]], len(o) > limit, len(n) > limit)


def _head(text: str) -> tuple[str, int]:
    lines = text.split("\n")
    return redact("\n".join(lines[:MAX_WRITE_LINES])), len(lines)


def _checklist(items, key_text: tuple[str, ...]) -> tuple[str, int]:
    rows = []
    for item in items[:MAX_WRITE_LINES]:
        item = item if isinstance(item, dict) else {}
        icon = {"in_progress": "▣", "completed": "✓"}.get(item.get("status"), "□")
        text = ""
        for k in key_text:
            if isinstance(item.get(k), str):
                text = item[k]
                break
        rows.append(f"{icon} {text}")
    return redact("\n".join(rows)), len(items)


def preview(tool: str, ti: dict) -> Preview | None:
    ti = ti if isinstance(ti, dict) else {}
    if tool == "Edit":
        old, new = _s(ti, "old_string"), _s(ti, "new_string")
        if not old and not new:
            return None
        return Preview("diff", _hunk(old, new, MAX_DIFF_LINES))
    if tool == "MultiEdit":
        edits = ti.get("edits") if isinstance(ti.get("edits"), list) else []
        if not edits:
            return None
        first = edits[0] if isinstance(edits[0], dict) else {}
        return Preview("multi", _hunk(_s(first, "old_string"), _s(first, "new_string"), MULTI_DIFF_LINES),
                       count=len(edits))
    if tool in ("Write", "NotebookEdit", "ExitPlanMode"):
        text = _s(ti, {"Write": "content", "NotebookEdit": "new_source", "ExitPlanMode": "plan"}[tool])
        if not text:
            return None
        head, total = _head(text)
        return Preview("write", head=head, total=total)
    if tool == "TodoWrite":
        todos = ti.get("todos") if isinstance(ti.get("todos"), list) else []
        if not todos:
            return None
        head, total = _checklist(todos, ("content", "activeForm"))
        return Preview("write", head=head, total=total)
    if tool == "update_plan":
        plan = ti.get("plan") if isinstance(ti.get("plan"), list) else []
        if not plan:
            return None
        head, total = _checklist(plan, ("step", "content"))
        return Preview("write", head=head, total=total)
    return None


def preview_budget(p: Preview | None) -> dict:
    """The keyword arguments notchgeom.permission_size needs for a preview."""
    if p is None:
        return {}
    if p.kind == "diff":
        return {"diff_rows": min(MAX_DIFF_LINES, len(p.hunk.old)) + min(MAX_DIFF_LINES, len(p.hunk.new))
                + (1 if p.hunk.cut_old or p.hunk.cut_new else 0)}
    if p.kind == "multi":
        return {"diff_rows": min(8, len(p.hunk.old)) + min(8, len(p.hunk.new)) + 1, "multi": True}
    return {"write_rows": min(MAX_WRITE_LINES, p.total)}


def more_lines_text(total: int) -> str:
    more = total - MAX_WRITE_LINES
    return "…and 1 more line" if more == 1 else f"…and {more} more lines"


@dataclass
class CardText:
    source: str
    tool: str
    title: str
    detail: str
    project: str
    preview: Preview | None


def card_text(card) -> CardText:
    """Everything the permission card prints, from a core PermissionCard."""
    return CardText(
        source="Claude Code",
        tool=card.tool,
        title=human_title(card.tool),
        detail=redact(human_detail(card.tool, card.tool_input)),
        project=card.project,
        preview=preview(card.tool, card.tool_input),
    )


# --- notification, completed and failure cards ----------------------------------

_FAILURE_TITLES = {
    "rate_limit": "Rate limited, session stopped",
    "overloaded": "Servers overloaded, session stopped",
    "authentication_failed": "Authentication failed",
    "oauth_org_not_allowed": "Org not allowed, auth error",
    "billing_error": "Billing error, session stopped",
    "invalid_request": "Invalid request, session stopped",
    "model_not_found": "Model not found",
    "server_error": "Server error, session stopped",
    "max_output_tokens": "Hit max output tokens",
}
_FAILURE_DETAILS = {
    "rate_limit": "You have hit the usage limit. It will lift on its own.",
    "overloaded": "Anthropic's servers are busy. Try the turn again in a moment.",
    "authentication_failed": "Your login is no longer valid. Run /login in the terminal.",
    "oauth_org_not_allowed": "Your organisation does not allow this account here.",
    "billing_error": "The account cannot be billed right now. Check your plan or credits.",
    "invalid_request": "Claude Code sent a request the API refused. Usually the conversation outgrew the "
                       "context window.",
    "model_not_found": "That model is not available on your account.",
    "server_error": "Something went wrong on Anthropic's side. The turn did not finish.",
    "max_output_tokens": "The reply hit its length limit and was cut off.",
}


def failure_title(reason: str) -> str:
    return _FAILURE_TITLES.get(reason, "Session stopped on an error")


def failure_detail(reason: str, message: str) -> str:
    """EventServer.failureDetail: the hook's message when it is a sentence;
    a bare reason code is no message, so say what it means instead."""
    import re
    t = message.strip()
    bare = (not t or t.lower() == reason.lower() or (" " not in t and re.fullmatch(r"[a-z_]+", t) is not None))
    if not bare:
        return t
    return _FAILURE_DETAILS.get(reason, "The turn stopped before it finished.")


@dataclass
class NoticeText:
    card: str          # "notification" or "completed"
    source: str
    title: str
    detail: str


def notice_text(toast) -> NoticeText:
    """What the Mac's NotificationCard or CompletedCard prints for a core
    toast. The core's own titles stay as they are for Linux."""
    from claudenotch.state import project_name
    project = project_name(toast.cwd)
    kind = getattr(toast, "kind", "")
    if kind == "done":
        return NoticeText("completed", "Claude Code", "Claude finished", project)
    if kind == "failure":
        reason = getattr(toast, "reason", "") or "unknown"
        return NoticeText("notification", "Claude Code", f"⚠️ {failure_title(reason)}",
                          failure_detail(reason, toast.body))
    if kind == "notice":
        # The Mac's title is the hook's message, else its title.
        default = "Claude needs your attention"
        title = toast.body if toast.body and toast.body != default else (
            toast.title if toast.title != "Claude Code" else default)
        return NoticeText("notification", "Claude Code", title, project)
    # The app's own note (hello, update): a notification card, worded by the app.
    return NoticeText("notification", "ClaudeNotch", toast.title, toast.body)


def build_answers(multi: list[bool], selections: list[set], others: list[str]) -> list[list[str]]:
    """QuestionCard.buildAnswers: each question's picks, sorted; a typed
    "something else" answer replaces the pick on a single-choice question
    and is added to the picks on a multiple-choice one."""
    out = []
    for i, is_multi in enumerate(multi):
        picks = sorted(selections[i]) if i < len(selections) else []
        custom = (others[i] if i < len(others) else "").strip()
        if custom:
            picks = picks + [custom] if is_multi else [custom]
        out.append(picks)
    return out


def question_count_text(n: int) -> str:
    return "1 question" if n == 1 else f"{n} questions"


# --- the hover card's second row (IdlePill row 2) -----------------------------------------


@dataclass
class IdleMeter:
    model_name: str = ""
    model_version: str = ""
    effort: str = ""
    branch: str = ""
    branch_short: str = ""
    context_pct: float = 0.0
    tokens: int = 0
    window: int = 0
    cost: float = 0.0

    @property
    def meter_label(self) -> str:
        """What ContextCostBar prints beside its capsule."""
        from . import notchgeom
        if self.tokens > 0:
            return f"{notchgeom.fmt_k(self.tokens)}/{notchgeom.fmt_k(self.window or self.tokens)}"
        if self.context_pct > 0:
            return f"{round(self.context_pct * 100)}%"
        return "no usage yet"

    @property
    def cost_label(self) -> str:
        from claudenotch.statusline import fmt_money
        return fmt_money(self.cost) if self.cost > 0 else ""


def idle_meter(session, branch: str = "") -> IdleMeter:
    """Row 2 from the top session alone, so the model, context, cost and
    branch always belong to the same session. Branch names are elided from
    the middle at 12 characters, as NotchView.elide does."""
    from claudenotch.statusline import capitalized, model_name_version
    from . import notchgeom
    if session is None:
        return IdleMeter(branch=branch, branch_short=notchgeom.elide(branch, 12))
    name, version = model_name_version(getattr(session, "model", "") or "")
    return IdleMeter(
        model_name=name, model_version=version,
        effort=capitalized(getattr(session, "effort", "") or ""),
        branch=branch, branch_short=notchgeom.elide(branch, 12),
        context_pct=getattr(session, "context_pct", None) or 0.0,
        tokens=getattr(session, "context_tokens", None) or 0,
        window=getattr(session, "context_window", None) or 0,
        cost=getattr(session, "cost_usd", None) or 0.0,
    )
