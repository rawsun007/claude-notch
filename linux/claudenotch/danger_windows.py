"""Danger rules for Windows: PowerShell, cmd and Windows paths.

The Windows half of danger.py, written from
plans/windows-linux-weekend/WINDOWS-DANGER-RULES.md. Same shape as the Bash
rules, `(pattern, reason)`, with reasons written for a person reading the
card. PowerShell and cmd are case-insensitive, so every rule here is
matched with re.IGNORECASE.

Two entry points:

- `powershell_danger(command)` for Claude Code's `PowerShell` tool, and for
  the script inside `powershell -Command "..."` / `cmd /c "..."` wherever it
  shows up;
- `windows_path_danger(path)` for Write/Edit targets and for the
  destinations of PowerShell's write cmdlets.
"""

from __future__ import annotations

import re

_I = re.IGNORECASE

# Where Windows people put the thing being destroyed, killed or changed.
_SEG = r"[^;|&\n]*"          # the rest of one command in a chain
_CORE_PROCS = r"(?:explorer|csrss|winlogon|lsass|wininit|smss|services|svchost)"

# (pattern, reason). Each is tried on one command of a chain at a time, after
# quoted free text is blanked out (see _scrub), so a commit message that
# mentions Remove-Item does not fire.
_RULES: list[tuple[str, str]] = [
    (r"\b(?:rd|rmdir)\b" + _SEG + r"\s/s\b", "rmdir /s, deletes a directory tree"),
    (r"\b(?:format-volume|clear-disk|initialize-disk|diskpart)\b", "formats or wipes a disk"),
    (r"\bformat(?:\.com)?\s+[a-z]:", "formats or wipes a disk"),
    (r"\b(?:start-process|saps|start)\b" + _SEG + r"-verb\s+runas\b", "runs with administrator rights"),
    (r"\brunas(?:\.exe)?\s", "runs with administrator rights"),
    (r"\bgsudo\b|(?:^|[\s;|&(])sudo(?:\.exe)?\s", "runs with administrator rights"),
    (r"\breg(?:\.exe)?\s+(?:add|delete|import|restore|load)\b",
     "changes the registry (startup entries or machine settings)"),
    (r"\b(?:new-itemproperty|set-itemproperty|remove-itemproperty|new-item|set-item|remove-item)\b" + _SEG
     + r"(?:\bhklm:|\bhkey_local_machine\b|\bhkcu:[\\/]*software[\\/]+microsoft[\\/]+windows[\\/]+"
       r"currentversion[\\/]+run(?:once)?\b)",
     "changes the registry (startup entries or machine settings)"),
    (r"\bschtasks(?:\.exe)?\s+/create\b", "schedules a recurring command"),
    (r"\b(?:register-scheduledtask|new-scheduledtask)\b", "schedules a recurring command"),
    (r"\bsc(?:\.exe)?\s+(?:create|config|delete)\b", "installs or changes a Windows service"),
    (r"\bnew-service\b", "installs or changes a Windows service"),
    (r"\bset-service\b" + _SEG + r"-startuptype\s+automatic\b", "installs or changes a Windows service"),
    (r"\bbcdedit\b", "changes how Windows boots"),
    (r"\bvssadmin(?:\.exe)?\s+delete\s+shadows\b", "deletes backups and restore points"),
    (r"\bwmic\b" + _SEG + r"\bshadowcopy\s+delete\b", "deletes backups and restore points"),
    (r"\bwbadmin(?:\.exe)?\s+delete\b", "deletes backups and restore points"),
    (r"\bcipher(?:\.exe)?\s" + _SEG + r"/w\b", "wipes free disk space, unrecoverable"),
    (r"\btakeown(?:\.exe)?\b", "takes ownership or opens permissions to everyone"),
    (r"\bicacls\b" + _SEG + r"/grant\b" + _SEG + r"(?:\beveryone\b|\*s-1-1-0\b)",
     "takes ownership or opens permissions to everyone"),
    (r"\bset-mppreference\b" + _SEG + r"-disable", "turns off or carves holes in Microsoft Defender"),
    (r"\badd-mppreference\b" + _SEG + r"-exclusion", "turns off or carves holes in Microsoft Defender"),
    (r"\bnetsh\s+advfirewall\s+set\b" + _SEG + r"\bstate\s+off\b", "turns off the firewall"),
    (r"\bset-netfirewallprofile\b" + _SEG + r"-enabled\s+(?:\$?false|0)\b", "turns off the firewall"),
    (r"\b(?:stop-computer|restart-computer)\b", "shuts down or restarts the machine"),
    (r"\bshutdown(?:\.exe)?\s" + _SEG + r"[/-][srp]\b", "shuts down or restarts the machine"),
    (r"\b(?:stop-process|spps|kill)\b" + _SEG + r"-name\s+" + _CORE_PROCS + r"\b",
     "kills a core Windows process"),
    (r"\btaskkill(?:\.exe)?\b" + _SEG + r"/im\s+" + _CORE_PROCS + r"(?:\.exe)?\b", "kills a core Windows process"),
    (r"\bwsl(?:\.exe)?\s" + _SEG + r"--unregister\b", "deletes a WSL distro and everything in it"),
    (r"\bremove-appxpackage\b", "uninstalls software"),
    (r"\bwinget(?:\.exe)?\s+(?:uninstall|remove|rm)\b", "uninstalls software"),
]

_DOWNLOAD = r"(?:iwr|irm|invoke-webrequest|invoke-restmethod|curl|wget|downloadstring|downloadfile|start-bitstransfer)"
_IEX = r"(?:iex|invoke-expression)"


def _unquote_words(command: str) -> str:
    """`-Verb "RunAs"` reads as `-Verb RunAs`: a quoted single word is an
    argument, not free text, so the rules should see it."""
    return re.sub(r"""(['"])([\w.:\\/*$+=-]+)\1""", r"\2", command)


def _scrub(command: str, unquote: bool = True) -> str:
    """Blank out quoted strings, here-strings and comments, as the Bash side
    does, so free text cannot fire a rule. PowerShell here-strings are
    @' ... '@ and @" ... "@; block comments are <# ... #>."""
    s = re.sub(r"""@(['"])\n[\s\S]*?\n\1@""", "@''@", command)
    s = re.sub(r"<#[\s\S]*?#>", "", s)
    if unquote:
        s = _unquote_words(s)
    s = re.sub(r"'[^']*'", "''", s)
    s = re.sub(r'"[^"]*"', '""', s)
    s = re.sub(r"(?:^|\s)#[^\n]*", "", s)
    return s


def _segments(scrubbed: str) -> list[str]:
    return [p for p in re.split(r"[;&\n]|\|\|", scrubbed) if p.strip()]


def _search(pattern: str, text: str) -> bool:
    return re.search(pattern, text, _I) is not None


# --- scripts nested in a command line --------------------------------------------

# powershell -Command "...", pwsh -c '...', cmd /c "...". One capture group,
# the script. The -Command spellings are any unambiguous prefix PowerShell
# accepts (-c, -co, -com, ... -command).
_PS_EXE = r"(?:^|[\s;|&(\"'])(?:[\w.:\\/ -]*[\\/])?(?:powershell|pwsh)(?:\.exe)?"
_NESTED = [
    _PS_EXE + r"""\s+(?:-[\w]+\s+)*?-c(?:o(?:m(?:m(?:a(?:n(?:d)?)?)?)?)?)?\s+'([^']*)'""",
    _PS_EXE + r"""\s+(?:-[\w]+\s+)*?-c(?:o(?:m(?:m(?:a(?:n(?:d)?)?)?)?)?)?\s+"([^"]*)\"""",
    r"""(?:^|[\s;|&(])cmd(?:\.exe)?\s+(?:/[a-z]\s+)*?/[ck]\s+"([^"]*)\"""",
    r"""(?:^|[\s;|&(])cmd(?:\.exe)?\s+(?:/[a-z]\s+)*?/[ck]\s+'([^']*)'""",
]
# The unquoted form runs to the end of the line: `powershell -c Remove-Item ...`.
_NESTED_BARE = [
    _PS_EXE + r"""\s+(?:-[\w]+\s+)*?-c(?:o(?:m(?:m(?:a(?:n(?:d)?)?)?)?)?)?\s+([^'"\s][^\n]*)""",
    r"""(?:^|[\s;|&(])cmd(?:\.exe)?\s+(?:/[a-z]\s+)*?/[ck]\s+([^'"\s][^\n]*)""",
]

_ENCODED = (_PS_EXE + r"\s+(?:-[\w]+\s+)*?-(?:e|ec|en|enc|enco|encod|encode|encoded|encodedc\w*)\s+"
            r"['\"]?[A-Za-z0-9+/=]{8,}")


def nested_scripts(command: str) -> list[str]:
    """The scripts handed to powershell / pwsh / cmd inside a command line."""
    out: list[str] = []
    for pattern in _NESTED + _NESTED_BARE:
        for m in re.finditer(pattern, command, _I):
            inner = m.group(1).strip()
            if inner and inner not in out:
                out.append(inner)
    return out


def encoded_command(command: str) -> bool:
    """`powershell -EncodedCommand <base64>`: what it runs cannot be read here."""
    return _search(_ENCODED, command)


# --- the command rules --------------------------------------------------------------

def _remove_tree(segment: str) -> bool:
    """Remove-Item (or an alias) with both -Recurse and -Force, any prefix
    spelling. Both, as on the Mac: `rm -rf` needs both flags too."""
    if not _search(r"(?:^|[\s(])(?:remove-item|rm|ri|del|erase|rmdir|rd)\b", segment):
        return False
    has_r = _search(r"\s-r(?:e(?:c(?:u(?:r(?:s(?:e)?)?)?)?)?)?\b", segment)
    has_f = _search(r"\s-f(?:o(?:r(?:c(?:e)?)?)?)?\b", segment)
    return has_r and has_f


def _del_files(segment: str) -> bool:
    return (_search(r"(?:^|[\s(])(?:del|erase)\b", segment) and _search(r"\s/[sq]\b", segment)
            and "*" in segment)


def _execution_policy(segment: str) -> bool:
    if not _search(r"\bset-executionpolicy\b", segment):
        return False
    if _search(r"-scope\s+process\b", segment):
        return False   # this shell only, gone when it exits
    return _search(r"\b(?:unrestricted|bypass)\b", segment)


def powershell_danger(command: str, depth: int = 0) -> list[str]:
    """Reasons a PowerShell (or cmd) command needs a deliberate confirm."""
    if not command:
        return []
    reasons: list[str] = []

    def add(reason: str) -> None:
        if reason not in reasons:
            reasons.append(reason)

    scrubbed = _scrub(command)
    whole = scrubbed.replace("\n", " ")

    # Download-and-run spans a pipe, so it is judged on the whole line.
    if (_search(r"\b" + _DOWNLOAD + r"\b[^;\n]*\|\s*" + _IEX + r"\b", whole)
            or _search(r"\b" + _IEX + r"\b[^;\n]*\b" + _DOWNLOAD + r"\b", whole)):
        add("downloads code and runs it straight away")
    elif _search(r"\|\s*" + _IEX + r"\b", whole) or _search(
            r"(?:^|[\s;(])" + _IEX + r"\b(?!\s*(?:''|\"\")?\s*(?:$|[;|&)]))",
            _scrub(command, unquote=False).replace("\n", " ")):
        add("runs text as code, so what it runs is not visible here")

    if encoded_command(command):
        add("runs an encoded command, so what it runs is not visible here")

    for seg in _segments(scrubbed.replace("|", "\n")):
        if _remove_tree(seg):
            add("Remove-Item -Recurse -Force, deletes a directory tree")
        if _del_files(seg):
            add("del /s, deletes files across folders")
        if _execution_policy(seg):
            add("lowers PowerShell's script policy for the whole machine or user")
        for pattern, reason in _RULES:
            if _search(pattern, seg):
                add(reason)

    for reason in write_target_danger(command):
        add(reason)

    if depth < 2:
        for inner in nested_scripts(command):
            for reason in powershell_danger(inner, depth + 1):
                add(reason)
    return reasons


# --- writes from PowerShell into sensitive places ------------------------------------

_WRITE_CMDLETS = r"(?:set-content|add-content|out-file|new-item|copy-item|move-item|sc|ac|ni|cp|copy|mv|move|tee-object|tee)"


def _tokens(segment: str) -> list[str]:
    out = []
    for a, b, c in re.findall(r"""'([^']*)'|"([^"]*)"|(\S+)""", segment):
        tok = a or b or c
        if tok:
            out.append(tok.lstrip(">").rstrip(",;"))
    return [t for t in out if t]


def write_target_danger(command: str) -> list[str]:
    """Destinations of Set-Content, Out-File, Copy-Item, `>` and friends that
    windows_path_danger flags. Read from the raw command so a quoted path
    still counts; a write verb or redirection must be in the same command."""
    reasons: list[str] = []
    for seg in re.split(r"[;&|\n]", command):
        if not (_search(r"(?:^|[\s(])" + _WRITE_CMDLETS + r"\b", seg) or ">" in seg):
            continue
        for tok in _tokens(seg):
            for reason in windows_path_danger(tok):
                if reason not in reasons:
                    reasons.append(reason)
    return reasons


# --- paths -------------------------------------------------------------------------

def normalize_windows_path(path: str) -> str:
    """Lower case, forward slashes, the user's profile as `~`, %APPDATA% as
    `~/appdata/roaming`. Any user's profile under C:\\Users counts as `~`: a
    write into someone else's .ssh is no safer than into yours."""
    p = path.strip().strip("'\"").replace("\\", "/").lower()
    p = re.sub(r"^\$profile\b.*", "$profile", p)
    for var in (r"%userprofile%", r"\$env:userprofile", r"\$home", r"\$\{env:userprofile\}"):
        p = re.sub("^" + var + r"(?=/|$)", "~", p)
    for var in (r"%appdata%", r"\$env:appdata", r"\$\{env:appdata\}"):
        p = re.sub("^" + var + r"(?=/|$)", "~/appdata/roaming", p)
    for var in (r"%localappdata%", r"\$env:localappdata"):
        p = re.sub("^" + var + r"(?=/|$)", "~/appdata/local", p)
    for var in (r"%programdata%", r"\$env:programdata"):
        p = re.sub("^" + var + r"(?=/|$)", "c:/programdata", p)
    for var in (r"%systemroot%", r"%windir%", r"\$env:systemroot", r"\$env:windir"):
        p = re.sub("^" + var + r"(?=/|$)", "c:/windows", p)
    p = re.sub(r"^[a-z]:/users/[^/]+(?=/|$)", "~", p)
    p = re.sub(r"/+", "/", p)
    # Resolve . and .. so `C:\proj\..\Windows\x` reads as what it is.
    parts: list[str] = []
    for part in p.split("/"):
        if part == "." or (part == "" and parts):
            continue
        if part == ".." and parts and parts[-1] not in ("", "~", "..") and not re.match(r"^[a-z]:$", parts[-1]):
            parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)


_HOME_DIRS = [
    (".ssh/", "writes inside ~\\.ssh, where your SSH keys live"),
    (".aws/", "writes inside ~\\.aws, your cloud credentials"),
    (".kube/", "writes inside ~\\.kube, your cluster credentials"),
    (".gnupg/", "writes inside ~\\.gnupg, your GPG keyring"),
    (".azure/", "writes inside ~\\.azure, your cloud credentials"),
    ("appdata/roaming/gcloud/", "writes inside gcloud's folder, your cloud credentials"),
    (".claude/", "writes inside ~\\.claude, the agent's own settings and hooks"),
    (".codex/", "writes inside ~\\.codex, the agent's own settings and hooks"),
    (".claudenotch/", "writes inside ~\\.claudenotch, this app's token and settings"),
    ("appdata/roaming/claudenotch/", "writes inside %APPDATA%\\ClaudeNotch, this app's token and allowlist"),
]

_HOME_FILES = [
    (".netrc", "writes ~\\.netrc, where saved passwords live"),
    ("_netrc", "writes ~\\_netrc, where saved passwords live"),
    (".git-credentials", "writes ~\\.git-credentials, your saved git passwords"),
    (".gitconfig", "writes ~\\.gitconfig, where an alias or hook path runs commands"),
    (".bashrc", "writes ~\\.bashrc, which Git Bash reads every time it starts"),
    (".bash_profile", "writes ~\\.bash_profile, which Git Bash reads every time it starts"),
    (".profile", "writes ~\\.profile, which Git Bash reads every time it starts"),
]

_PROFILE = "writes a PowerShell profile, which runs in every new PowerShell"
_STARTUP = "adds a Startup entry, which runs by itself at every login"


def windows_path_danger(path: str) -> list[str]:
    """Whether writing `path` can take a Windows machine over."""
    if not path:
        return []
    p = normalize_windows_path(path)
    if not p:
        return []
    if p == "$profile":
        return [_PROFILE]
    if re.search(r"(?:^|/)documents/(?:windows)?powershell/[^/]*profile[^/]*\.ps1$", p):
        return [_PROFILE]
    if "/start menu/programs/startup/" in p + "/" or p.endswith("/start menu/programs/startup"):
        return [_STARTUP]
    if "/.git/hooks/" in "/" + p or p.startswith(".git/hooks/"):
        return ["writes a git hook, which runs on the next commit or checkout"]
    if p.endswith("/.git/config") or p == ".git/config":
        return ["writes .git/config, where an alias or fsmonitor entry runs commands"]

    for name, reason in _HOME_DIRS:
        if p.startswith("~/" + name) or ("/" + name) in (p + "/") or p.startswith(name):
            return [reason]
    for name, reason in _HOME_FILES:
        if p == "~/" + name:
            return [reason]

    if p == "c:/windows/system32/drivers/etc/hosts":
        return ["writes the hosts file, which redirects network names"]
    for prefix, label in (("c:/windows/", "C:\\Windows"), ("c:/program files/", "C:\\Program Files"),
                          ("c:/program files (x86)/", "C:\\Program Files (x86)"),
                          ("c:/programdata/", "C:\\ProgramData")):
        if (p + "/").startswith(prefix):
            return [f"writes inside {label}, a system location"]
    return []


def looks_like_windows_path(path: str) -> bool:
    return bool(re.match(r"^(?:[a-zA-Z]:[\\/]|\\\\|%\w+%|\$env:|\$home\b|\$profile\b)", path, _I)) or "\\" in path
