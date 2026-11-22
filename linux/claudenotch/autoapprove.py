"""Auto-Approve: what the app answers for you without a card. Pure.

A port of the Mac's AutoApprovePolicy. Chosen when Auto-Approve is switched
on: a scope (everything, commands only, or file reads and edits only) and
what to do with a destructive command inside that scope (show the red
card, confirm with the OS's own prompt at once, or approve it too).
Switching to "approve them too" needs the owner's authentication first.

Windows' Claude Code runs commands through a PowerShell tool as well as
Bash, so PowerShell counts as a command tool here; the Mac never sees it.
"""

from __future__ import annotations

EVERYTHING, COMMANDS, FILES = "everything", "commands", "files"
SCOPES = (EVERYTHING, COMMANDS, FILES)

ASK, CONFIRM, ALLOW_TOO = "ask", "confirm", "allow"
DANGEROUS_CHOICES = (ASK, CONFIRM, ALLOW_TOO)

#: Verdicts: allow without a card, show the card and bring the OS prompt up
#: at once, or the ordinary card.
ALLOW, CONFIRM_NOW, SHOW_CARD = "allow", "confirm_now", "card"

COMMAND_TOOLS = frozenset({
    "Bash", "BashOutput", "KillShell", "KillBash",
    "shell", "local_shell", "exec", "exec_command", "unified_exec",
    "PowerShell",
})
FILE_TOOLS = frozenset({
    "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead",
    "Glob", "Grep", "LS", "apply_patch",
})

SCOPE_LABELS = {
    EVERYTHING: ("Everything", "Every tool request is allowed without a card."),
    COMMANDS: ("Commands only",
               "Terminal commands are allowed without a card. File edits and everything else still ask."),
    FILES: ("File reads and edits only",
            "Reading, searching and editing files is allowed without a card. Terminal commands still ask."),
}
DANGEROUS_LABELS = {
    ASK: ("Show the card", "Destructive commands still wait on the red card for you."),
    CONFIRM: ("Confirm with Windows Hello",
              "The Windows Hello prompt comes up on its own, so a glance or a finger allows it with no click. "
              "Cancel it and the card stays."),
    ALLOW_TOO: ("Approve them too",
                "Destructive commands run with no prompt at all, including deleting files and force pushes. "
                "Each one is still logged in History. Turning this on asks for Windows Hello or your Windows "
                "password."),
}


def covers(scope: str, tool: str) -> bool:
    if scope == EVERYTHING:
        return True
    if scope == COMMANDS:
        return tool in COMMAND_TOOLS
    if scope == FILES:
        return tool in FILE_TOOLS
    return False


def verdict(enabled: bool, scope: str, dangerous_choice: str, tool: str, is_dangerous: bool,
            strict_blocks: bool = False) -> str:
    """AutoApprovePolicy.verdict. Strict mode wins over every choice."""
    if not enabled or not covers(scope, tool) or strict_blocks:
        return SHOW_CARD
    if not is_dangerous:
        return ALLOW
    if dangerous_choice == ALLOW_TOO:
        return ALLOW
    if dangerous_choice == CONFIRM:
        return CONFIRM_NOW
    return SHOW_CARD


def needs_authentication(current: str, nxt: str) -> bool:
    """Only starting to allow destructive commands with no prompt needs it."""
    return nxt == ALLOW_TOO and current != ALLOW_TOO


def active(enabled: bool, until: float | None, now: float) -> bool:
    """On, and not past the end of an "Auto-approve for a while" window."""
    return enabled and (until is None or now < until)
