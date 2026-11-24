"""Claude's last reply in a session, the Mac's EventServer.lastAssistantText.

The transcript path comes from a hook payload, which any local process can
send, so it is read only when it resolves (symlinks first, then "..") to a
file inside Claude Code's own folder (CLAUDE_CONFIG_DIR or ~/.claude) or
Codex's (~/.codex), and only its last 512 KB. Whatever comes back is
redacted and capped before anything shows it.
"""

from __future__ import annotations

import json
import os

from .redact import redact

TAIL_BYTES = 512 * 1024
MAX_REPLY = 8000


def roots(home: str | None = None, env: dict | None = None) -> list[str]:
    home = home or os.path.expanduser("~")
    env = os.environ if env is None else env
    claude = env.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    return [claude, os.path.join(home, ".codex")]


def is_allowed(path: str, allowed: list[str] | None = None) -> bool:
    """isAllowedTranscriptPath: inside one of `allowed`, after resolving."""
    if not path or not isinstance(path, str):
        return False
    real = os.path.normcase(os.path.realpath(path))
    for root in allowed if allowed is not None else roots():
        base = os.path.normcase(os.path.realpath(root)).rstrip("\\/") + os.sep
        if real.startswith(base):
            return True
    return False


def _text(entry: dict) -> str | None:
    inner = entry.get("message") if isinstance(entry.get("message"), dict) else entry
    role = inner.get("role") or entry.get("type") or ""
    if role != "assistant":
        return None
    content = inner.get("content")
    if isinstance(content, str) and content.strip():
        return content
    if isinstance(content, list):
        texts = [b.get("text") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str)
                 and b.get("text").strip()]
        if texts:
            return "\n\n".join(texts)
    return None


def last_assistant_text(path: str, allowed: list[str] | None = None) -> str | None:
    """The newest assistant text in the transcript, or None."""
    if not is_allowed(path, allowed):
        return None
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            body = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    for line in reversed(body.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            text = _text(entry)
            if text:
                return clean(text)
    return None


def clean(text: str) -> str:
    return redact(text.strip())[:MAX_REPLY]


def reply_from(payload: dict) -> str | None:
    """A Stop payload's reply: its own last_assistant_message when it has
    one (newer Claude Code sends it), else the transcript's."""
    own = payload.get("last_assistant_message")
    if isinstance(own, str) and own.strip():
        return clean(own)
    path = payload.get("transcript_path")
    return last_assistant_text(path) if isinstance(path, str) else None
