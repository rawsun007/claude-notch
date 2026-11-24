"""System-wide shortcuts, the Mac's GlobalHotkey.

The Mac opens Settings with Option-Command-Comma and the notch with
Option-Command-N from any app. Here Ctrl+Alt stands in for Option-Command:
Ctrl+Alt+, opens Settings and Ctrl+Alt+N opens the notch. Both can be
changed in Settings > General.

RegisterHotKey with no window posts WM_HOTKEY to the thread that registered
it, which is Qt's GUI thread, so a native event filter picks it up there.
A combination another program already holds cannot be registered; register()
says so and the Settings page shows it.
"""

from __future__ import annotations

import sys

MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, MOD_NOREPEAT = 0x1, 0x2, 0x4, 0x8, 0x4000
WM_HOTKEY = 0x0312

SETTINGS_DEFAULT = "Ctrl+Alt+,"
NOTCH_DEFAULT = "Ctrl+Alt+N"

_MODS = {"ctrl": MOD_CONTROL, "control": MOD_CONTROL, "alt": MOD_ALT, "shift": MOD_SHIFT,
         "win": MOD_WIN, "meta": MOD_WIN}
_PUNCT = {",": 0xBC, ".": 0xBE, "/": 0xBF, ";": 0xBA, "'": 0xDE, "[": 0xDB, "]": 0xDD, "\\": 0xDC,
          "-": 0xBD, "=": 0xBB, "`": 0xC0, "space": 0x20}


def parse(text: str) -> tuple[int, int] | None:
    """"Ctrl+Alt+," -> (modifiers, virtual key), or None if it is not a
    usable system-wide shortcut: it needs Ctrl, Alt or Win (Shift alone
    would steal ordinary typing) and exactly one key."""
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    # "Ctrl+Alt++" names the plus key; split on "+" except a trailing one.
    parts = raw[:-2].split("+") + ["+"] if raw.endswith("++") else raw.split("+")
    parts = [p.strip() for p in parts]
    if any(not p for p in parts):
        return None
    *mods, key = parts
    m = 0
    for name in mods:
        bit = _MODS.get(name.lower())
        if bit is None or m & bit:
            return None
        m |= bit
    if not m & (MOD_CONTROL | MOD_ALT | MOD_WIN):
        return None
    k = key.lower()
    if len(key) == 1 and key.isascii() and key.isalnum():
        vk = ord(key.upper())
    elif k in _PUNCT:
        vk = _PUNCT[k]
    elif key == "+":
        vk = 0xBB
    elif k[:1] == "f" and k[1:].isdigit() and 1 <= int(k[1:]) <= 24:
        vk = 0x70 + int(k[1:]) - 1
    else:
        return None
    return m, vk


def label(text: str) -> str:
    """How a shortcut reads in menus: "Ctrl+Alt+," stays as typed, but
    tidied ("ctrl+alt+n" -> "Ctrl+Alt+N")."""
    if parse(text) is None:
        return ""
    *mods, key = text.strip().split("+") if not text.strip().endswith("++") else (text.strip()[:-2].split("+") + ["+"])
    names = {"ctrl": "Ctrl", "control": "Ctrl", "alt": "Alt", "shift": "Shift", "win": "Win", "meta": "Win"}
    return "+".join([names[m.strip().lower()] for m in mods] + [key.strip().upper() if len(key.strip()) == 1
                                                                 else key.strip().capitalize()])


SETTINGS_ID, NOTCH_ID = 1, 2

#: The running app's shortcuts, for the Settings page to report on.
APP: "GlobalHotkeys | None" = None


class GlobalHotkeys:
    """Registers shortcuts on the GUI thread and calls back when pressed."""

    def __init__(self):
        self._callbacks: dict[int, object] = {}
        self._filter = None
        #: ident -> (text, registered?) for the last register() call.
        self.status: dict[int, tuple[str, bool]] = {}

    def register(self, ident: int, text: str, callback) -> bool:
        """(Re)bind shortcut `ident` to `text`. False if `text` is not a
        valid shortcut or another program already holds it."""
        self.unregister(ident)
        combo = parse(text)
        self.status[ident] = (text, False)
        if combo is None or sys.platform != "win32":
            return False
        import ctypes
        self._install_filter()
        mods, vk = combo
        if not ctypes.windll.user32.RegisterHotKey(None, ident, mods | MOD_NOREPEAT, vk):
            return False
        self._callbacks[ident] = callback
        self.status[ident] = (text, True)
        return True

    def unregister(self, ident: int) -> None:
        if ident in self._callbacks and sys.platform == "win32":
            import ctypes
            ctypes.windll.user32.UnregisterHotKey(None, ident)
        self._callbacks.pop(ident, None)

    def unregister_all(self) -> None:
        for ident in list(self._callbacks):
            self.unregister(ident)

    def fire(self, ident: int) -> bool:
        cb = self._callbacks.get(ident)
        if cb is None:
            return False
        cb()
        return True

    def _install_filter(self) -> None:
        if self._filter is not None:
            return
        import ctypes.wintypes as wt
        from PySide6.QtCore import QAbstractNativeEventFilter, QCoreApplication

        owner = self

        class _Filter(QAbstractNativeEventFilter):
            def nativeEventFilter(self, event_type, message):
                # Qt hands over a QByteArray, which never equals a bytes literal.
                if bytes(event_type) in (b"windows_generic_MSG", b"windows_dispatcher_MSG"):
                    msg = wt.MSG.from_address(int(message))
                    if msg.message == WM_HOTKEY and owner.fire(int(msg.wParam)):
                        return True, 0
                return False, 0

        self._filter = _Filter()
        QCoreApplication.instance().installNativeEventFilter(self._filter)
