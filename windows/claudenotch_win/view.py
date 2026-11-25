"""What the overlay shows, as pure functions: no Qt, so it is tested on any
machine. overlay.py turns these into widgets. The wording matches the Linux
edition's ui.py, which matches the Mac.
"""

from __future__ import annotations

PILL_WIDTH = 240
CARD_WIDTH = 600
SESSIONS_WIDTH = 380
TOAST_WIDTH = 360
MARGIN = 12            # gap from the taskbar and screen edge for bottom-right

TOAST_SECONDS = 4.0
CONFIRM_SECONDS = 4.0
COLLAPSE_DELAY_MS = 350
DIFF_LINES = 12
DETAIL_LINES = 10

PILL, SESSIONS, TOAST, PERMISSION, QUESTION, HIDDEN = "pill", "sessions", "toast", "perm", "question", "hidden"
AUTO = "auto"            # the button-less "Auto-allowed" card
HISTORY = "history"      # the history drawer (NotchHistoryCard)
COMPOSE = "compose"      # the compose card (ComposeCard)
DETAIL = "detail"        # Claude's last reply in full (ResponseDetailCard)
DROP = "drop"            # a file is being dragged over the notch (dropZone)
AUTO_INFO_SECONDS = 4.0  # an approval is a receipt; the Mac shows it 4 s


def place(position: str, avail: tuple[int, int, int, int], width: int, height: int) -> tuple[int, int]:
    """Top-left corner for a window `width` x `height` in the work area
    `avail` (x, y, w, h: the screen minus the taskbar).

    "top": centred, hung from the top of the work area, so a taskbar docked
    at the top does not cover it. "bottom-right": above the tray, wherever
    the taskbar is, kept inside the work area.
    """
    ax, ay, aw, ah = avail
    if position == "bottom-right":
        x = ax + aw - width - MARGIN
        y = ay + ah - height - MARGIN
        return max(ax, x), max(ay, y)
    return ax + (aw - width) // 2, ay


def summary(sessions) -> tuple[str, str]:
    """The pill's one line and its dot colour: "ready", "working", "waiting"."""
    if not sessions:
        return "ClaudeNotch", "ready"
    working = sum(1 for s in sessions if s.status == "working")
    waiting = sum(1 for s in sessions if s.status == "waiting")
    if waiting:
        return f"{waiting} waiting on you", "waiting"
    if working:
        return (f"{sessions[0].project} working" if len(sessions) == 1
                else f"{working} of {len(sessions)} working"), "working"
    return (f"{sessions[0].project} ready" if len(sessions) == 1 else f"{len(sessions)} sessions ready"), "ready"


def session_note(session) -> str:
    note = {"working": "working", "waiting": "waiting on you", "ready": "ready"}.get(session.status, session.status)
    if session.agents:
        note += f" · {session.agents} agent{'s' if session.agents != 1 else ''}"
    return note


def permission_heading(card) -> str:
    verb = "run" if card.tool in ("Bash", "PowerShell", "Shell", "shell") else "use"
    return f"Claude wants to {verb} {card.title}"


def tail(project: str, more: int) -> str:
    return " · ".join(x for x in (project, f"+{more} more" if more else "") if x)


def trim_lines(text: str, limit: int) -> tuple[list[str], bool]:
    lines = text.splitlines() or [""]
    return lines[:limit], len(lines) > limit


def diff_rows(old: str, new: str, limit: int = DIFF_LINES) -> list[tuple[str, str]]:
    """(kind, text) rows for the red/green preview: kind is "del", "add" or
    "more" for the cut marker."""
    rows: list[tuple[str, str]] = []
    for text, kind, sign in ((old, "del", "-"), (new, "add", "+")):
        if not text:
            continue
        lines, cut = trim_lines(text, limit)
        rows.extend((kind, f"{sign} {line}") for line in lines)
        if cut:
            rows.append(("more", "  …"))
    return rows


def allow_label(dangerous: bool, confirming: bool) -> str:
    if dangerous:
        return "Click again to allow" if confirming else "Allow anyway"
    return "Allow  ⏎"


def choose(perms, questions, toasts, hovering: bool, hover_sessions: bool, auto_info=None,
           history: bool = False, compose: bool = False, detail: bool = False, drop: bool = False) -> str:
    """Which card wins, in AppState.recompute's order: the history drawer
    while it is open (you asked for it), a question, then a permission,
    then a notification or done card, and only then the open card on
    hover. A card that is waiting for you is not hidden by pointing at
    the notch."""
    if drop:
        # A drag over the notch takes over the whole card while it lasts.
        return DROP
    if history:
        return HISTORY
    if detail:
        return DETAIL
    if compose:
        return COMPOSE
    if questions:
        return QUESTION
    if perms:
        return PERMISSION
    if toasts:
        return TOAST
    if auto_info is not None:
        return AUTO
    if hovering and hover_sessions:
        return SESSIONS
    return PILL


def visible(view: str, show_pill: bool, fullscreen: bool, hide_in_fullscreen: bool) -> bool:
    """Whether the window is on screen at all. Only the idle pill ever hides:
    a card that needs an answer shows over a fullscreen app, since the user
    would rather see it than have Claude Code wait 285 s."""
    if view != PILL:
        return True
    if not show_pill:
        return False
    return not (fullscreen and hide_in_fullscreen)
