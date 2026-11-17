"""Start at login, as an XDG autostart entry.

The .deb ships /etc/xdg/autostart/claudenotch.desktop for every user and
install.sh writes ~/.config/autostart/claudenotch.desktop. Per the XDG
autostart spec a user entry with the same name overrides the system one,
and Hidden=true in it turns the program off, so turning it off for one user
never needs root and turning it back on just removes that override.
"""

from __future__ import annotations

import os

NAME = "claudenotch.desktop"
SYSTEM_DIRS = [d for d in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":") if d]


def user_dir() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "autostart")


def _read(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as f:
            section = ""
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    section = line
                elif section == "[Desktop Entry]" and "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    out.setdefault(k.strip(), v.strip())
    except OSError:
        pass
    return out


def _system_entry() -> str | None:
    for d in SYSTEM_DIRS:
        p = os.path.join(d, "autostart", NAME)
        if os.path.exists(p):
            return p
    return None


def enabled() -> bool:
    user = os.path.join(user_dir(), NAME)
    if os.path.exists(user):
        e = _read(user)
        return e.get("Hidden", "false").lower() != "true" and \
            e.get("X-GNOME-Autostart-enabled", "true").lower() != "false"
    return _system_entry() is not None


def set_enabled(on: bool, exec_path: str = "claudenotch") -> None:
    user = os.path.join(user_dir(), NAME)
    if not on:
        _write(user, exec_path, hidden=True)
        return
    if _system_entry() is not None:
        # The system entry starts it; all that can stop it is our override.
        if os.path.exists(user):
            os.remove(user)
        return
    _write(user, exec_path, hidden=False)


def _write(path: str, exec_path: str, hidden: bool) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        "Name=ClaudeNotch",
        "Comment=Answer Claude Code permission prompts and questions from the top of your screen",
        f"Exec={exec_path}",
        "Icon=claudenotch",
        "Terminal=false",
        f"Hidden={'true' if hidden else 'false'}",
        f"X-GNOME-Autostart-enabled={'false' if hidden else 'true'}",
    ]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)
