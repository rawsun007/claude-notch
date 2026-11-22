"""The checked-out branch of a session's folder, read from .git/HEAD.

A port of the Mac's Git.branch(forCwd:): no git process, just the HEAD file.
Walks up from the folder to the first ".git"; follows a worktree's or
submodule's "gitdir:" pointer; a detached HEAD shows its short hash.
Reads at most a few KB, so a hostile repo cannot make it read much.
"""

from __future__ import annotations

import os

MAX_POINTER_BYTES = 4096


def _head(path: str) -> str | None:
    try:
        with open(path, "rb") as f:
            return f.read(MAX_POINTER_BYTES).decode("utf-8", "replace")
    except OSError:
        return None


def _at(folder: str) -> str | None:
    """None when there is no .git here (keep walking); "" when there is one
    but its HEAD cannot be read as a branch (stop)."""
    git = os.path.join(folder, ".git")
    if not os.path.exists(git):
        return None
    git_dir = git
    if not os.path.isdir(git):
        content = _head(git) or ""
        line = content.split("\n", 1)[0].replace("gitdir:", "").strip()
        if not line:
            return ""
        git_dir = line if os.path.isabs(line) else os.path.join(folder, line)
    head = _head(os.path.join(git_dir, "HEAD"))
    if head is None:
        return ""
    head = head.strip()
    prefix = "ref: refs/heads/"
    if head.startswith(prefix):
        return head[len(prefix):]
    return head[:7] if len(head) >= 7 else head


def branch(cwd: str) -> str:
    if not cwd:
        return ""
    folder = cwd
    for _ in range(64):
        b = _at(folder)
        if b is not None:
            return b
        parent = os.path.dirname(folder.rstrip("\\/")) if len(folder) > 3 else os.path.dirname(folder)
        if not parent or parent == folder:
            break
        folder = parent
    return ""
