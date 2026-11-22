"""Wire ClaudeNotch into Claude Code's settings, and take it out again.

The same merge the macOS HookInstaller does, and the same entries, so a
settings file moved between machines reads correctly on both:

- every event gets one HTTP hook pointing at the loopback server, carrying
  the hook token, with a 290 s timeout (just over the app's 285 s window);
- the user's own hooks at each event are kept; only entries that are ours
  (an http URL on port 53127, or the old claudenotch-hook.sh command) are
  replaced;
- the file is backed up first, the newest few backups are kept, 0600;
- a settings file that exists but does not parse is never written.
"""

from __future__ import annotations

import json
import os
import secrets
import time

PORT = 53127
HOOK_TIMEOUT = 290
BACKUPS_KEPT = 5

# (event, matcher). The events this app answers or shows. The blocking ones
# carry ".*" so every tool reaches the card.
EVENTS: list[tuple[str, str | None]] = [
    ("PreToolUse", ".*"),
    ("PermissionRequest", ".*"),
    ("PostToolUse", ".*"),
    ("UserPromptSubmit", None),
    ("Notification", None),
    ("Stop", None),
    ("StopFailure", None),
    ("SessionStart", None),
    ("SessionEnd", ".*"),
    ("SubagentStart", None),
    ("SubagentStop", None),
]


def claude_dir() -> str:
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def settings_path() -> str:
    return os.path.join(claude_dir(), "settings.json")


def token_path() -> str:
    """The hook token. Linux and Mac: ~/.claudenotch/hook-token. Windows:
    %APPDATA%\\ClaudeNotch\\hook-token. On Windows the 0600/0700 modes below are
    a no-op; files under the user profile are already ACL'd to that user,
    which is the protection we want, so no icacls."""
    from .state import config_dir, is_windows
    if is_windows():
        return os.path.join(config_dir(), "hook-token")
    return os.path.expanduser("~/.claudenotch/hook-token")


def read_token() -> str | None:
    try:
        with open(token_path(), encoding="utf-8") as f:
            t = f.read().strip()
        return t or None
    except OSError:
        return None


def ensure_token() -> str:
    """The shared secret, created on first use. Its folder is 0700 and the file
    0600 from the moment it exists, never readable in between."""
    existing = read_token()
    if existing:
        return existing
    d = os.path.dirname(token_path())
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    token = secrets.token_hex(32)
    fd = os.open(token_path(), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(token)
    return token


def hook_url(token: str | None) -> str:
    base = f"http://127.0.0.1:{PORT}/hook"
    return f"{base}?t={token}" if token else base


def _is_ours(entry: dict) -> bool:
    t = entry.get("type")
    if t == "command":
        return "claudenotch-hook.sh" in str(entry.get("command") or "")
    if t == "http":
        return str(PORT) in str(entry.get("url") or "")
    return False


def remove_ours(hooks: dict, event: str) -> None:
    rules = hooks.get(event)
    if not isinstance(rules, list):
        return
    kept = [r for r in rules
            if not (isinstance(r, dict) and any(_is_ours(h) for h in r.get("hooks") or [] if isinstance(h, dict)))]
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)


def merged(settings: dict, token: str | None) -> dict:
    """`settings` with our hooks in it. Pure: the caller decides about disk."""
    out = dict(settings)
    hooks = dict(out.get("hooks") or {}) if isinstance(out.get("hooks"), dict) else {}
    for event, matcher in EVENTS:
        remove_ours(hooks, event)
        rule: dict = {"hooks": [{"type": "http", "url": hook_url(token), "timeout": HOOK_TIMEOUT}]}
        if matcher is not None:
            rule["matcher"] = matcher
        hooks[event] = list(hooks.get(event) or []) + [rule]
    out["hooks"] = hooks
    return out


def unmerged(settings: dict) -> dict:
    """`settings` with every one of our hooks gone, at every event, the user's kept."""
    out = dict(settings)
    hooks = out.get("hooks")
    if not isinstance(hooks, dict):
        return out
    hooks = dict(hooks)
    for event in list(hooks):
        remove_ours(hooks, event)
    if hooks:
        out["hooks"] = hooks
    else:
        out.pop("hooks", None)
    return out


def is_installed(settings: dict, token: str | None) -> bool:
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    want = hook_url(token)
    for event, _ in EVENTS:
        rules = hooks.get(event) or []
        if not any(isinstance(h, dict) and h.get("url") == want
                   for r in rules if isinstance(r, dict) for h in r.get("hooks") or []):
            return False
    return True


class UnreadableSettings(Exception):
    """settings.json exists but is not a JSON object; it is left untouched."""


def _load() -> dict:
    path = settings_path()
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise UnreadableSettings(f"{path} is not valid JSON, so ClaudeNotch left it alone") from e
    if not isinstance(data, dict):
        raise UnreadableSettings(f"{path} is not a JSON object, so ClaudeNotch left it alone")
    return data


def _backup(path: str) -> None:
    if not os.path.exists(path):
        return
    dest = f"{path}.before-claudenotch.{int(time.time() * 1000)}"
    with open(path, "rb") as src:
        data = src.read()
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    prefix = os.path.basename(path) + ".before-claudenotch."
    folder = os.path.dirname(path)
    olds = sorted((n for n in os.listdir(folder) if n.startswith(prefix)), reverse=True)
    for name in olds[BACKUPS_KEPT:]:
        try:
            os.remove(os.path.join(folder, name))
        except OSError:
            pass


def _write(data: dict) -> None:
    path = settings_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _backup(path)
    tmp = path + ".claudenotch-tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def install() -> str:
    """Install or refresh our hooks. Returns the settings path."""
    settings = _load()
    token = ensure_token()
    if not is_installed(settings, token):
        _write(merged(settings, token))
    return settings_path()


def uninstall() -> str:
    settings = _load()
    cleaned = unmerged(settings)
    if cleaned != settings:
        _write(cleaned)
    return settings_path()


def installed() -> bool:
    try:
        return is_installed(_load(), read_token())
    except UnreadableSettings:
        return False


def expected_token() -> str | None:
    """The token the installed hook URLs carry, if any.

    Read from settings.json rather than the token file, as on the Mac: the
    server requires a token only because the URL Claude Code posts to has
    one, so the two can never disagree and an install that predates the
    token keeps working instead of going deaf.
    """
    try:
        settings = _load()
    except UnreadableSettings:
        return None
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    for rules in hooks.values():
        for rule in rules if isinstance(rules, list) else []:
            for entry in (rule.get("hooks") or []) if isinstance(rule, dict) else []:
                url = str(entry.get("url") or "") if isinstance(entry, dict) else ""
                if str(PORT) in url and "?t=" in url:
                    return url.split("?t=", 1)[1].split("&", 1)[0] or None
    return None
