"""The hook wire protocol, as pure functions.

Mirrors EventServer.swift in the macOS app: which events block on the user,
what each one is answered with, and how a payload is read. Kept free of any
I/O so every byte a Claude Code session receives can be pinned by a test.

Answering "ask" (or a bare OK where the event has no ask) always means "no
opinion": Claude Code then prompts in its own terminal exactly as it would
without this app. Every path that cannot decide faithfully answers that.
"""

from __future__ import annotations

import hmac
import json
import re
from dataclasses import dataclass, field
from urllib.parse import parse_qs

OK_BODY = '{"ok":true}'

# How long a card may wait. Must stay under the 290 s timeout the installed
# hook entry gives Claude Code, or it gives up and asks in the terminal while
# the card is still on screen.
DECISION_WINDOW = 285.0

# Read-only tools Claude Code never needs approval for; answered "ask" at once
# so its own rules decide without a card.
PASS_THROUGH_TOOLS = {"Grep", "Glob", "LS", "BashOutput", "KillShell"}

ALLOW, DENY, ASK = "allow", "deny", "ask"


def body(obj: dict) -> str:
    return json.dumps(obj, separators=(",", ":"))


def pretool_body(decision: str, reason: str | None = None) -> str:
    inner = {"hookEventName": "PreToolUse", "permissionDecision": decision}
    if decision == DENY and reason:
        inner["permissionDecisionReason"] = reason[:200]
    return body({"hookSpecificOutput": inner})


def permreq_body(decision: str) -> str:
    # PermissionRequest has no "ask": no opinion is a bare OK.
    if decision == ASK:
        return OK_BODY
    return body({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                        "decision": {"behavior": "allow" if decision == ALLOW else "deny"}}})


@dataclass
class Question:
    header: str
    text: str
    multi_select: bool
    options: list[tuple[str, str]]  # (label, description)


def parse_questions(payload: dict) -> list[Question]:
    raw = payload.get("questions")
    if not isinstance(raw, list):
        ti = payload.get("tool_input")
        raw = ti.get("questions") if isinstance(ti, dict) else None
    out: list[Question] = []
    for q in raw if isinstance(raw, list) else []:
        if not isinstance(q, dict) or not isinstance(q.get("question"), str):
            continue
        opts = [(o["label"], str(o.get("description") or "")) for o in q.get("options") or []
                if isinstance(o, dict) and isinstance(o.get("label"), str)]
        if not opts:
            continue
        out.append(Question(header=str(q.get("header") or ""), text=q["question"],
                            multi_select=bool(q.get("multiSelect")), options=opts))
    return out


def answers_body(questions: list[Question], answers: list[list[str]]) -> str:
    """The answers, in the deny-with-reason form Claude Code reads them from."""
    lines = []
    for q, picks in zip(questions, answers):
        h = q.header or q.text
        picked = [p for p in picks if p]
        lines.append(f"  - {h}: {', '.join(picked)}" if picked else f"  - {h}: (no preference)")
    reason = "[ClaudeNotch, user replied via the notch]\n" + "\n".join(lines) + "\n\nUse these answers and continue."
    return body({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                        "permissionDecisionReason": reason[:2000]}})


# What a hook asks of the app.
PERMISSION = "permission"      # card with Allow / Deny, answered with pretool_body
PERM_REQUEST = "permreq"       # same card, answered with permreq_body
QUESTION = "question"          # AskUserQuestion card, answered with answers_body
PASS = "pass"                  # answer "ask" straight away
EVENT = "event"                # informational: answer OK, update state


def classify(payload: dict) -> str:
    event = payload.get("hook_event_name") or ""
    tool = payload.get("tool_name") or ""
    if event == "PreToolUse":
        if tool in PASS_THROUGH_TOOLS:
            return PASS
        if tool == "AskUserQuestion":
            return QUESTION
        return PERMISSION
    if event == "PermissionRequest":
        return PERM_REQUEST
    return EVENT


def timeout_body(kind: str) -> str:
    """What a card that nobody answered replies with: no opinion."""
    if kind == PERMISSION:
        return pretool_body(ASK)
    return OK_BODY


@dataclass
class Preview:
    title: str            # e.g. "Bash", "Edit main.py"
    detail: str           # the command, path or URL, redacted by the caller
    old: str = ""         # for an edit: the text being replaced
    new: str = ""         # and what replaces it
    extra: list[str] = field(default_factory=list)


def preview(tool: str, tool_input: dict) -> Preview:
    ti = tool_input if isinstance(tool_input, dict) else {}
    path = str(ti.get("file_path") or ti.get("notebook_path") or "")
    # Either slash: Claude Code on Windows sends C:\\proj\\main.py.
    name = re.split(r"[\\/]", path)[-1] if path else ""
    if tool in ("Bash", "PowerShell"):
        # Claude Code on Windows runs commands through a PowerShell tool with
        # the same input; without this its cards, rules and history showed
        # "command: npm test" instead of the command.
        return Preview(tool, str(ti.get("command") or ""), extra=[str(ti.get("description") or "")] if ti.get("description") else [])
    if tool in ("Edit", "MultiEdit"):
        if tool == "MultiEdit" and isinstance(ti.get("edits"), list) and ti["edits"]:
            first = ti["edits"][0] if isinstance(ti["edits"][0], dict) else {}
            return Preview(f"Edit {name}", path, str(first.get("old_string") or ""), str(first.get("new_string") or ""),
                           extra=[f"{len(ti['edits'])} edits"])
        return Preview(f"Edit {name}", path, str(ti.get("old_string") or ""), str(ti.get("new_string") or ""))
    if tool == "Write":
        return Preview(f"Write {name}", path, "", str(ti.get("content") or ""))
    if tool == "NotebookEdit":
        return Preview(f"Edit {name}", path, "", str(ti.get("new_source") or ""))
    if tool in ("WebFetch", "WebSearch"):
        return Preview(tool, str(ti.get("url") or ti.get("query") or ""))
    if tool in ("shell", "local_shell", "exec", "exec_command", "unified_exec"):
        cmd = ti.get("command")
        return Preview("Shell", " ".join(map(str, cmd)) if isinstance(cmd, list) else str(cmd or ""))
    # Anything else (MCP tools and the like): show its arguments.
    detail = ", ".join(f"{k}: {v}" for k, v in list(ti.items())[:4])
    return Preview(tool or "tool", detail)


# --- request checks ------------------------------------------------------------

def is_local_request(headers: dict) -> bool:
    """Our hooks are curl/HTTP from Claude Code on loopback and never carry an
    Origin. Refusing anything with one, or with a Host that is not loopback,
    closes the drive-by and DNS-rebinding path from a page in a browser."""
    lower = {k.lower(): v for k, v in headers.items()}
    if lower.get("origin"):
        return False
    host = (lower.get("host") or "").split(":")[0].strip("[]").lower()
    return host in ("", "127.0.0.1", "localhost", "::1")


def token_allows(query: str, expected: str | None) -> bool:
    """Require the hook token only once this install has one."""
    if not expected:
        return True
    offered = (parse_qs(query).get("t") or [""])[0]
    return bool(offered) and hmac.compare_digest(offered, expected)
