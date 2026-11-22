"""Which sound the notch plays for what: the Mac's SoundEvent,
ToolSoundCategory and SoundPreferences. Pure.

Every noise the app makes is an event with a default sound; the prompts
(permission, question) follow the alert sound, or with per-tool sounds on,
a sound per kind of tool. Any of them can be changed, or set to "None" to
silence just that one, and a mute switch silences them all.

The Mac uses macOS system sounds. Those are not ours to ship, so the
Windows edition names Windows' own sounds (C:\\Windows\\Media), chosen to
match each default's character: a light tick for confirmations, a chime
for a finished task, an attention sound for prompts.
"""

from __future__ import annotations

SILENT = "None"

#: (key, label, detail, default sound or None for "the alert sound")
EVENTS = (
    ("permission", "Permission prompt", "Claude is asking to run something", None),
    ("question", "Question prompt", "Claude is asking you to choose", None),
    ("completed", "Task finished", "A task finished and the card appeared", "Windows Notify Calendar"),
    ("autoApproved", "Auto-approved action", "An action matched an always-allow rule", "Windows Navigation Start"),
    ("approved", "You allowed or answered", "Confirming your own tap or keypress", "Windows Menu Command"),
    ("dismissed", "You denied or dismissed", "Confirming a deny or an Esc", "Windows Navigation Start"),
    ("limit", "Plan-limit warning", "You are near a 5-hour or weekly limit", "Windows Exclamation"),
)

#: (key, label, detail, default sound)
CATEGORIES = (
    ("bash", "Shell commands", "Bash, PowerShell", "Windows Notify System Generic"),
    ("edit", "Edits", "Edit, MultiEdit", "Windows Navigation Start"),
    ("write", "New files", "Write, NotebookEdit", "Windows Menu Command"),
    ("notification", "Notifications", "Notification prompts", "Windows Notify Messaging"),
    ("other", "Everything else", "All other tools", "Windows Notify System Generic"),
)

DEFAULT_ALERT = "Windows Notify System Generic"

#: Offered in the pickers; only names that exist in C:\\Windows\\Media are
#: shown on a given PC.
CHOICES = (
    "Windows Notify System Generic", "Windows Notify", "Windows Notify Calendar", "Windows Notify Email",
    "Windows Notify Messaging", "Windows Ding", "Windows Exclamation", "Windows Background",
    "Windows Navigation Start", "Windows Menu Command", "Windows Message Nudge", "Windows Balloon",
    "Windows Information Bar", "Windows Proximity Notification", "Speech On", "Speech Off",
    "Alarm01", "Ring01",
)


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
