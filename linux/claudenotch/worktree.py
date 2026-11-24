"""Two sessions working in the same checkout, the Mac's WorktreeAdvice.

Running several sessions at once is the most recommended way to get more
out of Claude Code, and it goes wrong in one specific way: two sessions in
the same folder edit the same files underneath each other, and nothing
reports an error. A worktree (`claude --worktree`) gives a session its own
checkout. The card also says the honest limit: a worktree separates files,
not ports, databases or environment. Pure.
"""

from __future__ import annotations

import os

ADVICE_CAP = 32


def colliding_directories(sessions) -> list[str]:
    """Folders with more than one live session in them. A session already in
    a linked worktree took the advice and does not count; an unknown folder
    is not a collision. `sessions` are (cwd, worktree) pairs."""
    counts: dict[str, int] = {}
    shown: dict[str, str] = {}
    for cwd, worktree in sessions:
        cwd = (cwd or "").strip()
        if not cwd or (worktree or "").strip():
            continue
        key = os.path.normcase(os.path.normpath(cwd))
        counts[key] = counts.get(key, 0) + 1
        shown.setdefault(key, cwd)
    return sorted(shown[k] for k, n in counts.items() if n > 1)


def card_title(project: str) -> str:
    return f"Two sessions are working in {project} at once"


CARD_DETAIL = ("They will edit the same files underneath each other, and neither will report an error when it "
               "happens. claude --worktree gives a session its own checkout. It separates files, though not "
               "ports, databases, or environment.")
