"""Which tool calls are dangerous enough to need a deliberate confirm.

A port of ToolPreviewParser.dangerReasons from the macOS app, with the paths
that matter on Linux added (autostart entries, systemd user units). The rules
and their wording match the Mac's on purpose, so a command reads the same on
either machine.

`danger_reasons` is the single gate: a non-empty result means the card asks
for a second confirm, and an always-allow rule never applies.
"""

from __future__ import annotations

import os
import posixpath
import re

from . import danger_windows as win

# Where a quoted string is a script to run rather than free text: the argument
# to `sh -c`, an `eval`, or the remote command of an `ssh`. One capture group
# each, the script. Deliberately narrow: scanning every quoted segment would
# put `git commit -m "drop the rm -rf helper"` back on the warning path.
_NESTED_SCRIPT = [
    r"""(?:^|[\s;|&(])(?:/[\w./-]+/)?(?:sh|bash|zsh|dash|ksh|fish)\s+(?:-[\w-]+\s+)*-[a-zA-Z]*c[a-zA-Z]*\s+'([^']*)'""",
    r"""(?:^|[\s;|&(])(?:/[\w./-]+/)?(?:sh|bash|zsh|dash|ksh|fish)\s+(?:-[\w-]+\s+)*-[a-zA-Z]*c[a-zA-Z]*\s+"([^"]*)\"""",
    r"""\beval\s+'([^']*)'""",
    r"""\beval\s+"([^"]*)\"""",
    r"""\bssh\b[^'"|;&]*'([^']*)'""",
    r"""\bssh\b[^'"|;&]*"([^"]*)\"""",
]

# Inline programs handed to an interpreter: `python3 -c "..."`, `node -e '...'`.
_INLINE_INTERPRETER = [
    r"""(?:^|[\s;|&(])(?:/[\w./-]+/)?(?:python3?|node|nodejs|deno|bun|perl|ruby|php)\s+(?:-[\w-]+\s+)*-[cerp]\s+'([^']*)'""",
    r"""(?:^|[\s;|&(])(?:/[\w./-]+/)?(?:python3?|node|nodejs|deno|bun|perl|ruby|php)\s+(?:-[\w-]+\s+)*-[cerp]\s+"([^"]*)\"""",
]

# What an inline program destroys in its own language, without naming a shell
# command. Applied only to an extracted script, never to a whole command line.
_INTERPRETER_RULES = [
    (r"\.(rmtree|rmSync|rmdirSync|unlinkSync|removedirs)\s*\(", 0, "the script deletes a directory tree"),
    (r"\bos\.(remove|unlink|rmdir)\b", 0, "the script deletes files"),
    (r"\brimraf\b", 0, "rimraf, deletes a directory tree"),
    (r"\b(system|popen|exec|execSync|spawn|spawnSync|execFile)\s*\(", 0,
     "the script shells out, so what it runs is not visible here"),
    (r"\bsubprocess\.(run|call|Popen|check_output|check_call)\b", 0,
     "the script shells out, so what it runs is not visible here"),
    (r"\bchild_process\b", 0, "the script shells out, so what it runs is not visible here"),
]

# In rough order of severity: (pattern, flags, reason).
_BASH_RULES = [
    (r"\bsudo\b", 0, "sudo, runs with root privileges"),
    (r"\bpkexec\b", 0, "pkexec, runs with root privileges"),
    (r"\bgit\s+push\b.*(--force\b|--force-with-lease\b|\s-f\b)", 0,
     "git push --force, can overwrite remote history"),
    (r"\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh|fish)\b", 0, "curl | sh, pipes remote code into a shell"),
    (r"\bchmod\s+-?R\s+777", 0, "chmod -R 777, makes files world-writable"),
    (r"\bdd\s+if=", 0, "dd, raw block-device write, can wipe disks"),
    (r"\bmkfs(\.\w+)?\b", 0, "mkfs, formats a filesystem"),
    (r":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:", 0, "fork bomb"),
    (r">\s*/dev/(sd|disk|hd|nvme|mmcblk)\w", 0, "writes raw bytes to a disk device"),
    (r"\bmv\s+/(etc|usr|var|bin|sbin|opt|boot|lib)\b", 0, "moves a system directory"),
    (r"\b(npm|yarn|pnpm)\s+publish\b", 0, "publishes a package to a registry, irrevocable"),
    (r"\btwine\s+upload\b", 0, "uploads to PyPI, irrevocable"),
    (r"\bcargo\s+publish\b", 0, "publishes to crates.io, irrevocable"),
    (r"\bgit\s+clean\s+-[a-zA-Z]*[fd][a-zA-Z]*x?", 0,
     "git clean -fd[x], deletes untracked files (incl. ignored)"),
    (r"\b(drop|truncate)\s+(table|database)\b", re.IGNORECASE, "drops a database table"),
    (r"\bdocker\s+system\s+prune\s+.*(-a|--all)", 0,
     "docker system prune -a, removes all images and containers"),
    (r"(>>?|\btee\b)[^|;&\n]*[/\s](\.ssh/|\.gnupg/|\.aws/|\.kube/|\.config/autostart/|\.config/systemd/"
     r"|\.claude/|\.codex/|\.claudenotch/|\.config/claudenotch/|\.git/hooks/"
     r"|\.(zshrc|zshenv|zprofile|zlogin|bashrc|bash_profile|profile|gitconfig|netrc)\b)", 0,
     "writes into a credential, shell-startup or agent-config file"),
    (r"\bsystemctl\s+(--user\s+)?(enable|link)\b", 0, "systemctl enable, installs a service that starts by itself"),
    (r"\bcrontab\s+[^-]", 0, "crontab, schedules a recurring command"),
]


def _search(pattern: str, text: str, flags: int = 0) -> bool:
    return re.search(pattern, text, flags) is not None


def _captures(patterns: list[str], command: str) -> list[str]:
    out: list[str] = []
    for pattern in patterns:
        for m in re.finditer(pattern, command):
            inner = m.group(1)
            if inner and inner not in out:
                out.append(inner)
    return out


def nested_scripts(command: str) -> list[str]:
    """The scripts nested inside a command (sh -c, eval, ssh), unquoted."""
    return _captures(_NESTED_SCRIPT, command)


def inline_interpreter_scripts(command: str) -> list[str]:
    """The inline programs in a command (python3 -c, node -e, ...)."""
    return _captures(_INLINE_INTERPRETER, command)


def _strip_quoted_and_heredocs(command: str) -> str:
    """Blank out quoted strings, heredoc bodies and comments.

    Free text (commit messages, echo arguments) must not fire a rule just
    because the words appear in it; only the shell tokens around it count.
    """
    s = re.sub(r"""<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\s*\1\b""", "<<HEREDOC>>", command)
    s = re.sub(r"'[^']*'", "''", s)
    s = re.sub(r'"[^"]*"', '""', s)
    s = re.sub(r"\s+#[^\n]*", "", s)
    return s


def bash_danger(command: str, depth: int = 0) -> list[str]:
    if not command:
        return []
    scrubbed = _strip_quoted_and_heredocs(command)
    reasons: list[str] = []

    # rm with recursive and force flags in any spelling, judged per command in
    # a chain so `git push -f && rm -r foo` does not count as rm -rf.
    if _search(r"\brm\s+", scrubbed):
        for part in re.split(r"[;|&]", scrubbed):
            if not _search(r"\brm\s+", part):
                continue
            has_r = _search(r"\s-[a-zA-Z]*[rR]", part) or _search(r"\s--recursive\b", part)
            has_f = _search(r"\s-[a-zA-Z]*[fF]", part) or _search(r"\s--force\b", part)
            if has_r and has_f:
                reasons.append("rm -rf, deletes files recursively without prompting")
                break

    for pattern, flags, reason in _BASH_RULES:
        if _search(pattern, scrubbed, flags):
            reasons.append(reason)

    # The quote strip hides `bash -c 'sudo rm -rf ~'`; where a quoted string is
    # a script rather than free text, scan the script as well.
    if depth < 2:
        for inner in nested_scripts(command):
            for reason in bash_danger(inner, depth + 1):
                if reason not in reasons:
                    reasons.append(reason)
        for inner in inline_interpreter_scripts(command):
            for reason in bash_danger(inner, depth + 1):
                if reason not in reasons:
                    reasons.append(reason)
            for pattern, flags, reason in _INTERPRETER_RULES:
                if _search(pattern, inner, flags) and reason not in reasons:
                    reasons.append(reason)
    return reasons


def path_danger(path: str, home: str | None = None) -> list[str]:
    """Whether writing `path` can take the machine over. `home` is injectable
    so tests do not depend on whose machine they run on."""
    if not path:
        return []
    if win.looks_like_windows_path(path) or (home is None and _on_windows()):
        return win.windows_path_danger(path)
    home = home if home is not None else os.path.expanduser("~")
    # POSIX rules on a POSIX-style path: posixpath, so the same answer comes
    # back on a Windows machine (where os.path would turn / into \\).
    p = posixpath.normpath(os.path.expanduser(path) if path.startswith("~") and home is None
                           else path.replace("~", home, 1) if path.startswith("~") else path)
    h = home.rstrip("/") + "/"

    sensitive = [
        (".ssh/", "writes inside ~/.ssh, where your SSH keys and authorized_keys live"),
        (".gnupg/", "writes inside ~/.gnupg, your GPG keyring"),
        (".aws/", "writes inside ~/.aws, your cloud credentials"),
        (".kube/", "writes inside ~/.kube, your cluster credentials"),
        (".config/gcloud/", "writes inside ~/.config/gcloud, your cloud credentials"),
        (".config/autostart/", "adds an autostart entry, which runs at every login"),
        (".config/systemd/", "writes a systemd user unit, which can run at every login"),
        (".claude/", "writes inside ~/.claude, the agent's own settings and hooks"),
        (".codex/", "writes inside ~/.codex, the agent's own settings and hooks"),
        (".claudenotch/", "writes inside ~/.claudenotch, this app's token and settings"),
        (".config/claudenotch/", "writes inside ~/.config/claudenotch, this app's allowlist"),
    ]
    for name, reason in sensitive:
        if p.startswith(h + name) or p.startswith(name) or _contains_dir(p, name):
            return [reason]

    if "/.git/hooks/" in p or p.startswith(".git/hooks/"):
        return ["writes a git hook, which runs on the next commit or checkout"]
    if p.endswith("/.git/config") or p == ".git/config":
        return ["writes .git/config, where an alias or fsmonitor entry runs commands"]

    for name in (".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
                 ".bash_login", ".profile", ".gitconfig", ".netrc"):
        if p == h + name:
            return [f"writes ~/{name}, which is read every time a shell starts"]

    for d in ("/etc/", "/usr/", "/var/", "/bin/", "/sbin/", "/opt/", "/boot/", "/lib/"):
        if p.startswith(d):
            return [f"writes inside {d}, a system directory"]
    return []


def _contains_dir(p: str, name: str) -> bool:
    # `name` ends in "/"; match it as a directory somewhere in the path, so a
    # relative `.ssh/authorized_keys` and a repo's `sub/.claude/x` both count
    # while `notes.ssh/` does not.
    return ("/" + name) in (p + "/")


def _on_windows() -> bool:
    import sys
    return sys.platform == "win32"


def _merge(*lists: list[str]) -> list[str]:
    out: list[str] = []
    for lst in lists:
        for r in lst:
            if r not in out:
                out.append(r)
    return out


def windows_bash_danger(command: str) -> list[str]:
    """Bash on Windows is Git Bash: Linux-style commands, plus Windows
    binaries called from it (`cmd /c ...`, `powershell -c ...`, `reg add`)."""
    return _merge(bash_danger(command), win.powershell_danger(command))


def powershell_danger(command: str) -> list[str]:
    """Claude Code's PowerShell tool. Aliases such as rm, curl and
    `git push --force` mean the same there, so the Bash rules run too."""
    return _merge(win.powershell_danger(command), bash_danger(command))


def danger_reasons(tool: str, tool_input: dict) -> list[str]:
    if tool == "PowerShell":
        return powershell_danger(str(tool_input.get("command") or ""))
    if tool == "Bash":
        command = str(tool_input.get("command") or "")
        if _on_windows():
            return windows_bash_danger(command)
        # A Windows shell nested in a Bash command is judged by its own rules
        # on any platform: the command says what it runs.
        nested = win.nested_scripts(command) or win.encoded_command(command)
        return _merge(bash_danger(command), win.powershell_danger(command) if nested else [])
    if tool in ("shell", "local_shell", "exec", "exec_command", "unified_exec"):
        cmd = tool_input.get("command")
        if isinstance(cmd, list):
            cmd = " ".join(str(c) for c in cmd)
        return bash_danger(str(cmd or ""))
    if tool == "Write":
        return path_danger(str(tool_input.get("file_path") or ""))
    if tool in ("Edit", "MultiEdit", "NotebookEdit"):
        return path_danger(str(tool_input.get("file_path") or tool_input.get("notebook_path") or ""))
    return []
