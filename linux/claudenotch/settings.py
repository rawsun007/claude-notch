"""User preferences, in ~/.config/claudenotch/settings.json.

Unknown keys are ignored and a value of the wrong type falls back to the
default, so a hand-edited or older file can never stop the app starting.
Written atomically at 0600.
"""

from __future__ import annotations

import json
import os
import threading
from dataclasses import field, asdict, dataclass, fields

from . import fsutil
from .state import config_dir


@dataclass
class Settings:
    # A desktop notification for every card. Off by default: the card is
    # already on screen, and on GNOME the notification banner lands at the
    # top centre right on top of it.
    desktop_notifications: bool = False
    # Only for dangerous calls, when the general switch is off.
    notify_dangerous_only: bool = False
    # "ClaudeNotch is running" for a few seconds at start.
    greeting: bool = True
    # Pointing at the pill opens the session list.
    hover_sessions: bool = True
    # A toast when a session finishes or Claude Code sends a notice.
    toasts: bool = True
    # Start with the desktop session (an autostart entry).
    start_at_login: bool = True
    # Windows edition only; other editions ignore them. Where the pill sits:
    # "top" (top centre, the default, as on Linux) or "bottom-right" (above
    # the tray, D3).
    position: str = "top"
    # The idle pill can be hidden; cards and the tray icon still show.
    show_pill: bool = True
    # Hide the idle pill while a fullscreen game, video or presentation is in
    # front. A card that needs an answer still shows.
    hide_in_fullscreen: bool = True
    # Windows edition: ask Windows Hello before a destructive command is
    # allowed, where this PC has it (the Mac's "Require Touch ID"; on there
    # by default whenever the hardware is). Without Hello it is press-and-hold.
    require_hello: bool = True
    # Give destructive commands a plain Allow. Switching it on needs Windows
    # Hello every time (the Mac asks for Touch ID or the password).
    skip_destructive_confirm: bool = False
    # Auto-Approve (the Mac's AutoApprovePolicy): off until switched on.
    # Scope: "everything", "commands" or "files". Destructive commands in
    # scope: "ask" (the red card), "confirm" (Windows Hello at once) or
    # "allow" (approved too; switching to it needs owner authentication).
    auto_approve: bool = False
    auto_approve_scope: str = "everything"
    auto_approve_dangerous: str = "ask"
    # Keep the notch open (the Mac's persistentNotchDisplay): the open card
    # with its meters stays out instead of waiting for the pointer.
    keep_open: bool = False
    # Keep the notch out of screen shares, recordings and screenshots. It
    # shows commands, paths and code, so it is on by default, as on the Mac.
    hide_from_capture: bool = True
    # Warn at 80 % and 95 % of the 5-hour and weekly plan limits.
    limit_warnings: bool = True
    # Spending caps in dollars (0 = off), and whether reaching one holds
    # tool requests on the card (the Mac's Hard-stop at the cap).
    daily_cost_cap: float = 0.0
    session_cost_cap: float = 0.0
    enforce_budget: bool = False
    # Sounds (sounds.py): mute, per-tool sounds, the alert sound, and
    # per-event / per-category overrides ("None" silences one).
    sound_muted: bool = False
    # Pet mode: the mascot lives in the closed notch (off until switched on).
    pet_enabled: bool = False
    per_tool_sounds: bool = False
    alert_sound: str = "Funk"
    sound_events: dict = field(default_factory=dict)
    sound_tools: dict = field(default_factory=dict)
    # Windows edition: system-wide shortcuts (the Mac's Option-Command-Comma
    # and Option-Command-N, with Ctrl+Alt for Option-Command). "" turns one off.
    settings_hotkey: str = "Ctrl+Alt+,"
    notch_hotkey: str = "Ctrl+Alt+N"
    # The history drawer, the Mac's Option-Command-Space. Not Ctrl+Alt+Space:
    # the Claude desktop app holds that for its quick entry.
    history_hotkey: str = "Ctrl+Alt+H"


POSITIONS = ("top", "bottom-right")


def path() -> str:
    return os.path.join(config_dir(), "settings.json")


def load() -> Settings:
    try:
        with open(path(), encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return Settings()
    if not isinstance(raw, dict):
        return Settings()
    out = Settings()
    for fld in fields(Settings):
        value = raw.get(fld.name)
        if isinstance(value, type(getattr(out, fld.name))):
            setattr(out, fld.name, value)
    if out.position not in POSITIONS:
        out.position = "top"
    return out


def save(settings: Settings) -> None:
    d = config_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = path() + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(asdict(settings), f, indent=2)
        f.write("\n")
    fsutil.replace(tmp, path())


class Store:
    """The live settings, shared by the UI, the notifier and the server."""

    def __init__(self, persist: bool = True):
        self._lock = threading.Lock()
        self._persist = persist
        self.value = load() if persist else Settings()
        self._listeners = []

    def subscribe(self, fn) -> None:
        self._listeners.append(fn)

    def update(self, **changes) -> Settings:
        with self._lock:
            for k, v in changes.items():
                if not hasattr(self.value, k):
                    raise KeyError(k)
                setattr(self.value, k, v)
            if self._persist:
                save(self.value)
            current = self.value
        for fn in list(self._listeners):
            try:
                fn(current)
            except Exception:
                pass
        return current
