"""Start or resume Claude Code in a terminal, the Mac's TerminalAutomator:
Windows Terminal when it is installed, else a PowerShell window.

Safety: the folder is only ever the new window's working directory, never
part of a command line, and must exist; a session id comes from a hook
payload, so it is accepted only as a plain id (letters, digits, - and _).
The one command run is `claude`, or `claude --resume <id>`.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess

_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")


def claude_command(session_id: str | None = None) -> str | None:
    """The PowerShell command to run, or None for an id we will not pass."""
    if session_id is None:
        return "claude"
    return f"claude --resume {session_id}" if _ID.match(session_id or "") else None


def plan(folder: str, session_id: str | None = None, wt: str | None = None) -> tuple[list[str], str] | None:
    """(argv, working directory) to launch, or None. Pure but for the
    folder check."""
    cmd = claude_command(session_id)
    if cmd is None or not folder or not os.path.isdir(folder):
        return None
    folder = os.path.abspath(folder)
    shell = ["powershell.exe", "-NoExit", "-NoLogo", "-Command", cmd]
    # Windows Terminal reads ";" as "next command" anywhere in its arguments.
    if wt and ";" not in folder:
        return [wt, "-d", folder, *shell], folder
    return shell, folder


def launch(folder: str, session_id: str | None = None) -> bool:
    p = plan(folder, session_id, shutil.which("wt.exe") or shutil.which("wt"))
    if p is None:
        return False
    argv, cwd = p
    try:
        flags = 0 if argv[0].lower().endswith("wt.exe") or argv[0].lower().endswith("wt") \
            else getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
        subprocess.Popen(argv, cwd=cwd, creationflags=flags, close_fds=True)
        return True
    except OSError:
        return False
