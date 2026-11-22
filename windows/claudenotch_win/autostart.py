"""Start at login, through the per-user Run key.

    HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run
        ClaudeNotch = "<install dir>\\ClaudeNotch.exe" --background

Windows lets people switch a Run entry off in Task Manager > Startup apps
without deleting it; that writes a flag under
...\\Explorer\\StartupApproved\\Run. `enabled()` reads both, so the Settings
toggle shows what will really happen at the next login, and `set_enabled`
clears a "disabled" flag when the user turns it back on here.

The registry access goes through a tiny `Registry` interface so the logic
is testable without Windows.
"""

from __future__ import annotations

from . import paths

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
APPROVED_KEY = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
VALUE = "ClaudeNotch"

# StartupApproved data is 12 bytes: a flag, then a FILETIME of the change.
# An even first byte (02) means enabled, odd (03) disabled.
APPROVED_ON = bytes([2]) + bytes(11)


def approved(data: bytes | None) -> bool:
    """Whether a StartupApproved value allows the entry. No value: allowed."""
    if not data:
        return True
    return data[0] % 2 == 0


class Registry:
    """HKCU access through winreg."""

    def get(self, key: str, name: str):
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as k:
                return winreg.QueryValueEx(k, name)[0]
        except OSError:
            return None

    def set_string(self, key: str, name: str, value: str) -> None:
        import winreg
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, key, 0, winreg.KEY_SET_VALUE) as k:
            winreg.SetValueEx(k, name, 0, winreg.REG_SZ, value)

    def set_binary(self, key: str, name: str, value: bytes) -> None:
        import winreg
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, key, 0, winreg.KEY_SET_VALUE) as k:
            winreg.SetValueEx(k, name, 0, winreg.REG_BINARY, value)

    def delete(self, key: str, name: str) -> None:
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key, 0, winreg.KEY_SET_VALUE) as k:
                winreg.DeleteValue(k, name)
        except OSError:
            pass


_registry: Registry | None = None


def registry() -> Registry:
    global _registry
    if _registry is None:
        _registry = Registry()
    return _registry


def command() -> str:
    return paths.executable_command("--background")


def enabled(reg: Registry | None = None) -> bool:
    reg = reg or registry()
    if not reg.get(RUN_KEY, VALUE):
        return False
    return approved(reg.get(APPROVED_KEY, VALUE))


def set_enabled(on: bool, reg: Registry | None = None) -> None:
    reg = reg or registry()
    if on:
        reg.set_string(RUN_KEY, VALUE, command())
        if not approved(reg.get(APPROVED_KEY, VALUE)):
            reg.set_binary(APPROVED_KEY, VALUE, APPROVED_ON)
    else:
        reg.delete(RUN_KEY, VALUE)


def refresh(reg: Registry | None = None) -> None:
    """At start: an entry that is on but points at an older install path (the
    user moved from a checkout to the installed app) is rewritten."""
    reg = reg or registry()
    current = reg.get(RUN_KEY, VALUE)
    if current and current != command():
        reg.set_string(RUN_KEY, VALUE, command())
