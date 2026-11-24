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


def ps_quote(text: str) -> str:
    """A PowerShell single-quoted string: nothing inside is expanded, and a
    quote is written twice. PowerShell also takes the curly quotes as
    single quotes, so each of those is doubled too."""
    for q in ("'", "‘", "’", "‚", "‛"):
        text = text.replace(q, q + q)
    return "'" + text + "'"


#: Windows whose keyboard goes to a shell, the only kind compose will type
#: into (the Mac's terminal bundle ids). Never an editor such as VS Code,
#: where keystrokes could land in a source file.
TERMINAL_EXES = frozenset({
    "windowsterminal.exe", "openconsole.exe", "conhost.exe", "powershell.exe", "pwsh.exe", "cmd.exe",
    "wezterm-gui.exe", "alacritty.exe", "mintty.exe", "tabby.exe", "hyper.exe", "conemu.exe", "conemu64.exe",
    "kitty.exe", "wsl.exe", "bash.exe", "warp.exe",
})


def is_terminal(exe_path: str) -> bool:
    return os.path.basename(exe_path or "").lower() in TERMINAL_EXES


def terminal_name(exe_path: str) -> str:
    """How the compose card names a terminal: "Windows Terminal", "PowerShell"."""
    base = os.path.basename(exe_path or "").lower()
    return {"windowsterminal.exe": "Windows Terminal", "powershell.exe": "PowerShell", "pwsh.exe": "PowerShell",
            "cmd.exe": "Command Prompt", "mintty.exe": "Git Bash", "conhost.exe": "Console",
            "openconsole.exe": "Windows Terminal", "wezterm-gui.exe": "WezTerm", "alacritty.exe": "Alacritty",
            "wsl.exe": "WSL", "bash.exe": "Bash"}.get(base, os.path.splitext(os.path.basename(exe_path or ""))[0])


def one_line(text: str, limit: int = 4000) -> str:
    """A message as one line, the way it is typed or passed: whitespace and
    line breaks folded to single spaces (a typed line break would send half
    of it early), control characters dropped."""
    clean = "".join(ch if ch.isprintable() else " " for ch in (text or ""))
    return " ".join(clean.split())[:limit]


def claude_command(session_id: str | None = None, message: str | None = None) -> str | None:
    """The PowerShell command to run, or None for an id we will not pass.
    `message` is a first prompt (a dropped file's "@name", or a reply),
    single-quoted so nothing in it is expanded."""
    if session_id is not None and not _ID.match(session_id or ""):
        return None
    cmd = f"claude --resume {session_id}" if session_id is not None else "claude"
    clean = one_line(message or "")
    return f"{cmd} {ps_quote(clean)}" if clean else cmd


def drop_launch(path: str) -> tuple[str, str | None] | None:
    """AppState.dropLaunch: a folder starts Claude there; a file starts it
    in the file's folder with "@file" as the first message."""
    if not path:
        return None
    path = os.path.abspath(path)
    if os.path.isdir(path):
        return path, None
    if os.path.isfile(path):
        return os.path.dirname(path), "@" + os.path.basename(path)
    return None


def plan(folder: str, session_id: str | None = None, wt: str | None = None,
         message: str | None = None) -> tuple[list[str], str] | None:
    """(argv, working directory) to launch, or None. Pure but for the
    folder check."""
    cmd = claude_command(session_id, message)
    if cmd is None or not folder or not os.path.isdir(folder):
        return None
    folder = os.path.abspath(folder)
    shell = ["powershell.exe", "-NoExit", "-NoLogo", "-Command", cmd]
    # Windows Terminal reads ";" as "next command" anywhere in its arguments.
    if wt and ";" not in folder and ";" not in cmd:
        return [wt, "-d", folder, *shell], folder
    return shell, folder


def launch(folder: str, session_id: str | None = None, message: str | None = None) -> bool:
    p = plan(folder, session_id, shutil.which("wt.exe") or shutil.which("wt"), message)
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
