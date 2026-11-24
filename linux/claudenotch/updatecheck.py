"""Is a newer ClaudeNotch out? The Mac's UpdateChecker: GitHub Releases,
checked at start and then once a day, with its version rules ("v" stripped,
each part read up to its first non-digit, missing parts are 0).

Each edition has its own tag prefix (the Mac "v", Linux "linux-v", Windows
"windows-v"), and the Windows and Linux releases are never marked latest,
so the newest matching tag is picked from the list. Drafts and pre-releases
are skipped. Only a github.com page of this repository is ever handed back
to be opened; the response is otherwise data.
"""

from __future__ import annotations

import json
import re
import urllib.request

REPO = "rawsun007/claude-notch"
API = f"https://api.github.com/repos/{REPO}/releases?per_page=30"
PAGE_PREFIX = f"https://github.com/{REPO}/releases/"
DAY = 86_400


def version_from_tag(tag: str, prefix: str = "v") -> str | None:
    tag = (tag or "").strip()
    if not tag.startswith(prefix):
        return None
    rest = tag[len(prefix):]
    return rest if re.match(r"^\d", rest) else None


def parts(v: str) -> list[int]:
    v = v.strip()
    v = v[1:] if v.startswith("v") else v
    out = []
    for p in v.split("."):
        m = re.match(r"\d+", p)
        out.append(int(m.group()) if m else 0)
    return out


def is_newer(a: str, b: str) -> bool:
    pa, pb = parts(a), parts(b)
    n = max(len(pa), len(pb))
    pa, pb = pa + [0] * (n - len(pa)), pb + [0] * (n - len(pb))
    return pa > pb


def newest(releases, prefix: str) -> tuple[str, str] | None:
    """(version, release page) of the newest published release for the
    edition, from the API's list. Pure."""
    best = None
    if not isinstance(releases, list):
        return None
    for r in releases:
        if not isinstance(r, dict) or r.get("draft") or r.get("prerelease"):
            continue
        v = version_from_tag(str(r.get("tag_name", "")), prefix)
        if v is None:
            continue
        page = str(r.get("html_url") or "")
        if not page.startswith(PAGE_PREFIX):
            page = PAGE_PREFIX + "tag/" + prefix + v
        if best is None or is_newer(v, best[0]):
            best = (v, page)
    return best


def available(current: str, releases, prefix: str) -> tuple[str, str] | None:
    """The newer release, if there is one."""
    n = newest(releases, prefix)
    return n if n and is_newer(n[0], current) else None


def fetch(timeout: float = 15.0):
    """The release list, or None if GitHub could not be reached."""
    req = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "ClaudeNotch-update-check"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read(2_000_000).decode("utf-8"))
    except (OSError, ValueError):
        return None
