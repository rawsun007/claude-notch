"""Claude Code skills, for Settings > Skills: the Mac's SkillsReader,
SkillSettings and SkillTrash.

- scan: personal skills (~/.claude/skills), claude.ai-synced ones
  (~/.claude/skills/synced/<account>, newest copy of a name wins), each
  recent project's .claude/skills, and installed plugins' skills, read
  from their SKILL.md frontmatter, with the context each costs in the
  listing Claude reads every turn.
- visibility: Claude Code's own `skillOverrides` in settings.json (on,
  name-only, user-invocable-only, off) and `enabledPlugins`, merged into
  the file without touching any other key, and never over a file that is
  not valid JSON.
- trash: personal and project skills move into Claude Code's own
  ~/.claude/skills/.trash/<entry>/ (same entry names, so its 30-day sweep
  applies) and can be restored to where they came from.

Skill files are the user's own, but names are still checked: Claude Code
refuses names with control or invisible characters, and so does this.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import string
import time
import unicodedata
from dataclasses import dataclass

MAX_ENTRY_CHARS = 1536
RETENTION_DAYS = 30
ORIGIN_FILE = ".claudenotch-origin"
VISIBILITIES = ("on", "name-only", "user-invocable-only", "off")
VISIBILITY_LABELS = {
    "on": ("On", "Claude sees its name and description and can use it on its own."),
    "name-only": ("Name only", "Claude sees only its name: much less context, but it may be picked less often."),
    "user-invocable-only": ("Only when I type it",
                            "Hidden from Claude. You can still run it by typing its slash command."),
    "off": ("Off", "Hidden from Claude and from the slash menu."),
}


def claude_dir() -> str:
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def personal_dir() -> str:
    return os.path.join(claude_dir(), "skills")


# --- frontmatter ---------------------------------------------------------------------


def frontmatter(text: str) -> dict:
    """Flat key: value pairs between the first two --- lines; quotes stripped,
    > and | block values joined; lists and nested maps skipped."""
    if text.startswith("﻿"):
        text = text[1:]
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return {}
    out, i = {}, 1
    while i < len(lines):
        line = lines[i]
        if line.strip() == "---":
            break
        i += 1
        if line.startswith((" ", "\t", "-")) or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key, value = key.strip().lower(), value.strip()
        if value in (">", "|", ">-", "|-"):
            parts = []
            while i < len(lines) and (lines[i].startswith((" ", "\t")) or not lines[i].strip()):
                if lines[i].strip() == "---":
                    break
                parts.append(lines[i].strip())
                i += 1
            value = " ".join(p for p in parts if p)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out[key] = value
    return out


def is_refused_name(name: str) -> bool:
    """Claude Code refuses a skill whose name has these (CLI 2.1.299)."""
    blank = {0x00A0, 0x115F, 0x1160, 0x180E, 0x2800, 0x3164, 0xFFA0, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000}
    for ch in name:
        if ch in "<>":
            return True
        cat = unicodedata.category(ch)
        if cat in ("Cf", "Cc", "Zl", "Zp") or (cat == "Zs" and ch != " "):
            return True
        if ord(ch) in blank or 0x2000 <= ord(ch) <= 0x200F:
            return True
    return False


def is_reserved(folder: str) -> bool:
    f = folder.lower()
    return folder.startswith(".") or f == "synced" or f == "anthropic-skills" or f.startswith("anthropic-skills:")


@dataclass
class Skill:
    name: str
    source: str               # "personal", "project", "synced", "plugin"
    path: str
    description: str = ""
    when_to_use: str = ""
    model_invocation_disabled: bool = False
    project: str = ""
    plugin: str = ""
    bytes: int = 0
    modified: float = 0.0
    refused: bool = False

    @property
    def listing_chars(self) -> int:
        """What it adds to the listing Claude reads every turn when fully on."""
        if self.model_invocation_disabled or self.refused:
            return 0
        text = " ".join(t for t in (self.description, self.when_to_use) if t)
        return len(self.name) + 4 + min(MAX_ENTRY_CHARS, len(text))

    @property
    def listing_tokens(self) -> int:
        return (self.listing_chars + 3) // 4

    @property
    def can_trash(self) -> bool:
        return self.source in ("personal", "project")


def _children(d: str) -> list[str]:
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []


def folder_size(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def _skills_in(d: str, source: str, project: str = "", plugin: str = "", prefix: str = "",
               reserved: bool = True) -> list[Skill]:
    out = []
    for folder in _children(d):
        if folder.startswith(".") or (reserved and is_reserved(folder)):
            continue
        path = os.path.join(d, folder)
        md = os.path.join(path, "SKILL.md")
        try:
            with open(md, "rb") as f:
                text = f.read(64 * 1024).decode("utf-8", "replace")
            modified = os.path.getmtime(md)
        except OSError:
            continue
        fm = frontmatter(text)
        name = fm.get("name") or ""
        if not name or is_refused_name(name):
            name = folder
        out.append(Skill(prefix + name, source, path, fm.get("description", ""),
                         fm.get("when_to_use", fm.get("when-to-use", "")),
                         fm.get("disable-model-invocation", "").lower() == "true", project, plugin,
                         folder_size(path), modified, is_refused_name(folder)))
    return out


def dedupe_newest(skills: list[Skill]) -> list[Skill]:
    best: dict[str, Skill] = {}
    for s in skills:
        if s.name not in best or s.modified > best[s.name].modified:
            best[s.name] = s
    return [s for s in skills if best[s.name].path == s.path]


def installed_plugins(data: str | None = None) -> list[tuple[str, str]]:
    """(id, install path) from ~/.claude/plugins/installed_plugins.json."""
    if data is None:
        try:
            with open(os.path.join(claude_dir(), "plugins", "installed_plugins.json"), encoding="utf-8") as f:
                data = f.read()
        except OSError:
            return []
    try:
        root = json.loads(data)
    except ValueError:
        return []
    plugins = root.get("plugins") if isinstance(root, dict) else None
    out = []
    for pid in sorted(plugins) if isinstance(plugins, dict) else []:
        entries = plugins[pid]
        if isinstance(entries, list) and entries and isinstance(entries[-1], dict):
            p = entries[-1].get("installPath")
            if isinstance(p, str) and p:
                out.append((pid, p))
    return out


def scan(projects: list[str]) -> list[Skill]:
    out = _skills_in(personal_dir(), "personal")
    synced: list[Skill] = []
    sdir = os.path.join(personal_dir(), "synced")
    for account in _children(sdir):
        if not account.startswith("."):
            synced += _skills_in(os.path.join(sdir, account), "synced", prefix="anthropic-skills:", reserved=False)
    out += dedupe_newest(synced)
    seen = {os.path.normcase(os.path.realpath(personal_dir()))}
    for p in projects:
        d = os.path.join(p, ".claude", "skills")
        key = os.path.normcase(os.path.realpath(d))
        if key in seen:
            continue
        seen.add(key)
        out += _skills_in(d, "project", project=p)
    for pid, root in installed_plugins():
        out += _skills_in(os.path.join(root, "skills"), "plugin", plugin=pid, prefix=pid.split("@")[0] + ":",
                          reserved=False)
    paths, unique = set(), []
    for s in out:
        if s.path not in paths:
            paths.add(s.path)
            unique.append(s)
    return unique


# --- visibility (skillOverrides, enabledPlugins) ----------------------------------------------


class Unreadable(Exception):
    """The settings file is not valid JSON; it was left alone."""


def overrides(data: str | None) -> dict:
    try:
        root = json.loads(data) if data else {}
    except ValueError:
        return {}
    m = root.get("skillOverrides") if isinstance(root, dict) else None
    m = m if isinstance(m, dict) else {}
    return {k: v for k, v in m.items() if v in VISIBILITIES}


def enabled_plugins(data: str | None) -> dict:
    try:
        root = json.loads(data) if data else {}
    except ValueError:
        return {}
    m = root.get("enabledPlugins") if isinstance(root, dict) else None
    return {k: v for k, v in (m or {}).items() if isinstance(v, bool)} if isinstance(m, dict) else {}


def with_setting(data: str | None, map_key: str, key: str, value) -> str:
    """The file with root[map_key][key] = value (None removes it, and an
    empty map is removed). Every other key is kept as it was."""
    root = {}
    if data and data.strip():
        try:
            root = json.loads(data)
        except ValueError as e:
            raise Unreadable() from e
        if not isinstance(root, dict):
            raise Unreadable()
    inner = dict(root.get(map_key) or {}) if isinstance(root.get(map_key), dict) else {}
    if value is None:
        inner.pop(key, None)
    else:
        inner[key] = value
    if inner:
        root[map_key] = inner
    else:
        root.pop(map_key, None)
    return json.dumps(root, indent=2) + "\n"


def _read(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def _write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".claudenotch-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    from . import fsutil
    fsutil.replace(tmp, path)


def settings_path() -> str:
    return os.path.join(claude_dir(), "settings.json")


def set_visibility(name: str, vis: str, path: str | None = None) -> None:
    path = path or settings_path()
    _write(path, with_setting(_read(path), "skillOverrides", name, None if vis == "on" else vis))


def set_plugin_enabled(pid: str, on: bool) -> None:
    _write(settings_path(), with_setting(_read(settings_path()), "enabledPlugins", pid, on))


# --- trash ------------------------------------------------------------------------------------


def trash_dir() -> str:
    return os.path.join(personal_dir(), ".trash")


def entry_name(now: float | None = None) -> str:
    tail = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(6))
    return f"{int((now or time.time()) * 1000)}-{os.getpid()}-{tail}"


def trashed_at(name: str) -> float | None:
    head = name.split("-", 1)[0]
    try:
        ms = float(head)
    except ValueError:
        return None
    return ms / 1000 if ms > 1e12 else None


@dataclass
class TrashEntry:
    path: str
    name: str
    trashed: float | None
    origin: str | None

    @property
    def days_left(self) -> int | None:
        if self.trashed is None:
            return None
        return max(0, RETENTION_DAYS - int((time.time() - self.trashed) / 86400))


def trash(skill: Skill) -> None:
    if not skill.can_trash or not os.path.isfile(os.path.join(skill.path, "SKILL.md")):
        raise ValueError("That folder is not a skill ClaudeNotch can move.")
    entry = os.path.join(trash_dir(), entry_name())
    os.makedirs(entry)
    shutil.move(skill.path, os.path.join(entry, os.path.basename(skill.path)))
    parent = os.path.dirname(skill.path)
    if os.path.normcase(parent) != os.path.normcase(personal_dir()):
        with open(os.path.join(entry, ORIGIN_FILE), "w", encoding="utf-8") as f:
            f.write(parent)


def trash_list() -> list[TrashEntry]:
    out = []
    for e in _children(trash_dir()):
        if e.startswith("."):
            continue
        entry = os.path.join(trash_dir(), e)
        origin = _read(os.path.join(entry, ORIGIN_FILE))
        for f in _children(entry):
            if not f.startswith("."):
                out.append(TrashEntry(os.path.join(entry, f), f, trashed_at(e), origin.strip() if origin else None))
    return sorted(out, key=lambda t: -(t.trashed or 0))


def restore(entry: TrashEntry) -> str:
    parent = entry.origin or personal_dir()
    dest = os.path.join(parent, entry.name)
    if os.path.exists(dest):
        raise FileExistsError(f"A skill is already at {dest}, so it was not overwritten.")
    os.makedirs(parent, exist_ok=True)
    shutil.move(entry.path, dest)
    holder = os.path.dirname(entry.path)
    if not [x for x in _children(holder) if not x.startswith(".")]:
        shutil.rmtree(holder, ignore_errors=True)
    return dest
