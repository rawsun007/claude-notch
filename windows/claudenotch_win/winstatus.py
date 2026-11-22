"""The Windows status line forwarder: where it lives and how Claude Code runs it.

The script (resources/claudenotch-statusline.ps1) is copied next to the hook
token, in %APPDATA%\\ClaudeNotch, on every start, so an update reaches it.
It reads the token and the user's previous status line (statusline-inner.cmd,
saved by the installer) from that same folder.

Claude Code runs a status line command through its shell, which on Windows
is Git Bash, so the command uses forward slashes and double quotes, which
bash, cmd and PowerShell all read the same way.
"""

from __future__ import annotations

import os
import shutil

from claudenotch import hooks

from . import paths

SCRIPT = "claudenotch-statusline.ps1"


def installed_path() -> str:
    return os.path.join(os.path.dirname(hooks.token_path()), SCRIPT)


def command(script_path: str) -> str:
    p = script_path.replace("\\", "/")
    return f'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{p}"'


def prepare() -> str:
    """Put the current script in place (only when it changed) and return
    the statusLine command for it."""
    src = paths.resource(SCRIPT)
    dest = installed_path()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        with open(src, "rb") as a, open(dest, "rb") as b:
            same = a.read() == b.read()
    except OSError:
        same = False
    if not same:
        shutil.copyfile(src, dest)
    return command(dest)


def install_hooks() -> str:
    """hooks.install with the status line forwarder, as the Mac's installer
    always wires both. If the script cannot be put in place, the hooks still
    go in: cards matter more than meters."""
    try:
        cmd = prepare()
    except OSError:
        cmd = None
    return hooks.install(status_command=cmd)
