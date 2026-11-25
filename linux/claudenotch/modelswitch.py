"""Model changes in a session: the Mac's AppState+ModelSwitch and ModelDrift.
Pure.

- PostModelSwitch (Claude Code 2.1.251+): the session changed model with
  /model; its model is updated and a "Model switched" card says so.
- PreModelSwitch: the same switch before it happens. Opt in, and only a
  move UP to a pricier family is held; everything else (and a card nobody
  answers) is a plain OK, so a user's own /model is never stopped by a
  notch nobody was looking at.
- Drift: a status line reporting a LOWER tier than the session was on
  (Opus falling back to Sonnet at a cap, say), said once, without claiming
  a cause, since Claude Code does not say whether you or your plan moved it.

Families, not versions: Anthropic prices by family, so a version bump is
never an upgrade or a drop. A model this does not know is never acted on.
"""

from __future__ import annotations

import json

from .statusline import short_model

GRACE = 5.0               # seconds: the same switch reported twice is one switch


def rank(model: str) -> int:
    """haiku 1 < sonnet 2 < opus 3 < fable/mythos 4; 0 = unknown."""
    m = (model or "").lower()
    if "fable" in m or "mythos" in m:
        return 4
    if "opus" in m:
        return 3
    if "sonnet" in m:
        return 2
    if "haiku" in m:
        return 1
    return 0


def family(model: str) -> str:
    m = (model or "").lower()
    r = rank(model)
    return {4: "Mythos" if "mythos" in m else "Fable", 3: "Opus", 2: "Sonnet", 1: "Haiku"}.get(r, "")


def is_upgrade(from_model: str, to_model: str) -> bool:
    """A move to a pricier family. False whenever it cannot tell: this gates
    a blocking card, and a wrong yes would stop someone's own /model."""
    a, b = rank(from_model), rank(to_model)
    return a > 0 and b > 0 and b > a


def switch_detail(from_model: str, to_model: str) -> str:
    """ "opus 5 to sonnet 4.6", or whichever side is known."""
    a = short_model(from_model) if from_model else ""
    b = short_model(to_model) if to_model else ""
    a = "" if a == "unknown" else a
    b = "" if b == "unknown" else b
    if not a:
        return b or to_model
    if not b:
        return a
    return f"{a} to {b}"


UPGRADE_TITLE = "Switch to a pricier model?"
SWITCHED_TITLE = "Model switched"


def reply(decision: str, reason: str | None = None) -> str:
    """PreModelSwitch's answer. Allow and deny are said; anything else is a
    plain OK, which Claude Code reads as no opinion: the switch goes on."""
    if decision not in ("allow", "deny"):
        return '{"ok":true}'
    inner = {"hookEventName": "PreModelSwitch", "permissionDecision": decision}
    if decision == "deny":
        inner["permissionDecisionReason"] = (reason or "Denied in ClaudeNotch")[:200]
    return json.dumps({"hookSpecificOutput": inner})


def drift(before: str, after: str) -> tuple[str, str] | None:
    """ModelDrift.change: (old family, new family) for a drop in tier only.
    Not a version bump, not a move up, not a model it cannot rank."""
    a, b = (before or "").strip(), (after or "").strip()
    if not a or not b or a == b:
        return None
    ra, rb = rank(a), rank(b)
    if not ra or not rb or rb >= ra:
        return None
    return family(a), family(b)


def drift_title(change: tuple[str, str]) -> str:
    return f"This session is now on {change[1]}, not {change[0]}"


def drift_detail(change: tuple[str, str]) -> str:
    return (f"It started on {change[0]}. Either you switched it, or your plan moved it. Claude Code does not say "
            "which, so this is only the change itself.")
