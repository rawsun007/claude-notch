"""Which sound the notch plays for what: the Mac's SoundEvent,
ToolSoundCategory and SoundPreferences. Pure.

Every noise the app makes is an event with a default sound; the prompts
(permission, question) follow the alert sound, or with per-tool sounds on,
a sound per kind of tool. Any of them can be changed, or set to "None" to
silence just that one, and a mute switch silences them all.

Same names and defaults as the Mac (Funk for prompts, Glass for a finished
task, Pop, Tink, Submarine...). Apple's recordings are not ours to ship, so
the Windows edition plays its own sounds made under those names
(windows/tools/make_sounds.py), or the user's own copies if they put them
in %APPDATA%\\ClaudeNotch\\Sounds.
"""

from __future__ import annotations

SILENT = "None"

#: (key, label, detail, default sound or None for "the alert sound"), the
#: Mac's SoundEvent with its defaults, plus the plan-limit warning.
EVENTS = (
    ("permission", "Permission prompt", "Claude is asking to run something", None),
    ("question", "Question prompt", "Claude is asking you to choose", None),
    ("completed", "Task finished", "A task finished and the card appeared", "Glass"),
    ("autoApproved", "Auto-approved action", "An action matched an always-allow rule", "Pop"),
    ("approved", "You allowed or answered", "Confirming your own tap or keypress", "Tink"),
    ("dismissed", "You denied or dismissed", "Confirming a deny or an Esc", "Pop"),
    ("limit", "Plan-limit warning", "You are near a 5-hour or weekly limit", "Submarine"),
)

#: (key, label, detail, default sound), the Mac's ToolSoundCategory.
CATEGORIES = (
    ("bash", "Shell commands", "Bash, PowerShell", "Funk"),
    ("edit", "Edits", "Edit, MultiEdit", "Pop"),
    ("write", "New files", "Write, NotebookEdit", "Tink"),
    ("notification", "Notifications", "Notification prompts", "Submarine"),
    ("other", "Everything else", "All other tools", "Funk"),
)

DEFAULT_ALERT = "Funk"

#: The Mac's picker (AppState.availableSounds), in its order.
CHOICES = ("Funk", "Pop", "Tink", "Glass", "Submarine", "Hero", "Blow", "Bottle", "Frog", "Morse", "Ping", "Purr",
           "Sosumi")


def category(tool: str) -> str:
    if tool in ("Bash", "PowerShell"):
        return "bash"
    if tool in ("Edit", "MultiEdit"):
        return "edit"
    if tool in ("Write", "NotebookEdit"):
        return "write"
    if tool == "Notification":
        return "notification"
    return "other"


def event_default(event: str) -> str | None:
    return next((d for k, _, _, d in EVENTS if k == event), None)


def category_default(cat: str) -> str:
    return next((d for k, _, _, d in CATEGORIES if k == cat), DEFAULT_ALERT)


def sound_for(event: str, tool: str | None, *, muted: bool, per_tool: bool, alert: str,
              per_event: dict, per_category: dict) -> str | None:
    """The sound to play for `event` (and the tool that raised it), or None.
    AppState.play: an event with its own sound, or its own override, plays
    that; the prompts follow the alert sound, or the tool's category sound
    with per-tool sounds on."""
    if muted:
        return None
    override = per_event.get(event)
    if override is not None:
        name = override
    elif event_default(event) is not None:
        name = event_default(event)
    elif per_tool and tool:
        cat = category(tool)
        name = per_category.get(cat, category_default(cat))
    else:
        name = alert or DEFAULT_ALERT
    return None if not name or name == SILENT else name


def set_override(overrides: dict, key: str, sound: str, default: str | None) -> dict:
    """SoundPreferences.set: choosing the default removes the override."""
    out = dict(overrides)
    if default is not None and sound == default:
        out.pop(key, None)
    else:
        out[key] = sound
    return out
