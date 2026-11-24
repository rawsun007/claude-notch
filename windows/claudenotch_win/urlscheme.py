"""claudenotch:// links: the Mac's NotchURL.parse, for the verbs that do
something on Windows. Pure; this is an untrusted-input boundary.

    claudenotch://open                 bring the notch open, as hovering would
    claudenotch://settings             Settings
    claudenotch://settings/privacy     Settings on one page (a known page only)
    claudenotch://history              Settings > History

The verb may sit in the host or the first path segment, as on the Mac.
Anything else, and any page the sidebar does not know, opens nothing
unusual: an unknown verb is rejected, an unknown page opens Settings.

Registered per user under HKCU\\Software\\Classes\\claudenotch by the
installer, so no administrator rights are needed.
"""

from __future__ import annotations

from urllib.parse import urlsplit

SCHEME = "claudenotch"
PAGES = ("general", "notch", "session", "alerts", "budget", "plan", "usage", "history", "privacy", "about",
         "rules", "developer")


def parse(url: str) -> tuple[str, str] | None:
    """(action, page) for one of our links, else None. action is "open"
    or "settings"; page is "" or one of PAGES."""
    if not isinstance(url, str) or len(url) > 512:
        return None
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return None
    if parts.scheme.lower() != SCHEME:
        return None
    segments = [s for s in parts.path.split("/") if s]
    verb = parts.netloc
    if not verb:
        if not segments:
            return None
        verb = segments.pop(0)
    verb = verb.lower()
    if verb == "open":
        return ("open", "")
    if verb == "history":
        return ("history", "")         # the notch's history drawer, as on the Mac
    if verb == "standup":
        return ("standup", "")
    if verb == "settings":
        page = segments[0].lower() if segments else ""
        return ("settings", page if page in PAGES else "")
    return None


def command_line(exe: str) -> str:
    """What Windows runs for a link: the app, told which link it got."""
    return f'"{exe}" --url "%1"'
