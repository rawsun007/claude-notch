"""Type a message into a terminal window, the Mac's TerminalAutomator.
sendText, with guards the Mac does not need to spell out:

- only a terminal (terminal.is_terminal on the window's program), never an
  editor, where keystrokes could land in a source file;
- the window must really be in front before a single key is sent; if
  Windows keeps another window in front, nothing is typed;
- Ctrl, Alt, Shift and Win must be up (Ctrl+Enter sends, and a held Ctrl
  would turn the text into shortcuts);
- the text is one line (terminal.one_line), then Enter.

Characters go as KEYEVENTF_UNICODE input, so any keyboard layout types
them exactly, with no shortcut meaning.
"""

from __future__ import annotations

import ctypes
import sys
import time

from . import terminal

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x0002, 0x0004
VK_RETURN = 0x0D
MODIFIERS = (0x10, 0x11, 0x12, 0x5B, 0x5C)          # Shift, Ctrl, Alt, left and right Win


def key_events(text: str) -> list[tuple[int, int, int]]:
    """(virtual key, scan code, flags) for every event: each UTF-16 unit
    down and up as a unicode key, then Enter. Pure."""
    out = []
    data = text.encode("utf-16-le")
    for i in range(0, len(data), 2):
        unit = int.from_bytes(data[i:i + 2], "little")
        out.append((0, unit, KEYEVENTF_UNICODE))
        out.append((0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP))
    out.append((VK_RETURN, 0, 0))
    out.append((VK_RETURN, 0, KEYEVENTF_KEYUP))
    return out


if sys.platform == "win32":
    import ctypes.wintypes as wt

    class _KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                    ("dwExtraInfo", ctypes.c_size_t)]

    class _MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD), ("dwFlags", wt.DWORD),
                    ("time", wt.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

    class _U(ctypes.Union):
        _fields_ = [("ki", _KEYBDINPUT), ("mi", _MOUSEINPUT)]

    class _INPUT(ctypes.Structure):
        _fields_ = [("type", wt.DWORD), ("u", _U)]


def window_program(hwnd: int) -> str:
    """The full path of the program that owns `hwnd`, or ""."""
    if sys.platform != "win32" or not hwnd:
        return ""
    import ctypes.wintypes as wt
    pid = wt.DWORD()
    ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid.value)          # QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wt.DWORD(len(buf))
        if ctypes.windll.kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return buf.value
        return ""
    finally:
        ctypes.windll.kernel32.CloseHandle(h)


def usable(hwnd: int) -> bool:
    """A live, visible terminal window."""
    if sys.platform != "win32" or not hwnd:
        return False
    u = ctypes.windll.user32
    return bool(u.IsWindow(hwnd)) and bool(u.IsWindowVisible(hwnd)) and terminal.is_terminal(window_program(hwnd))


def type_into(hwnd: int, text: str, settle: float = 1.0) -> str | None:
    """Type `text` and Enter into terminal window `hwnd`. None on success,
    else why nothing was typed."""
    line = terminal.one_line(text)
    if not line:
        return "Nothing to send."
    if not usable(hwnd):
        return "That terminal is gone. Pick a project instead to open a fresh one."
    u = ctypes.windll.user32
    deadline = time.monotonic() + settle
    while any(u.GetAsyncKeyState(k) & 0x8000 for k in MODIFIERS) and time.monotonic() < deadline:
        time.sleep(0.02)
    if any(u.GetAsyncKeyState(k) & 0x8000 for k in MODIFIERS):
        return "Let go of Ctrl, Alt and Shift, then send again."
    if u.IsIconic(hwnd):
        u.ShowWindow(hwnd, 9)                                                   # SW_RESTORE
    u.SetForegroundWindow(hwnd)
    while u.GetForegroundWindow() != hwnd and time.monotonic() < deadline:
        time.sleep(0.02)
    if u.GetForegroundWindow() != hwnd:
        return "Windows kept another window in front, so nothing was typed. Click the terminal and send again."
    time.sleep(0.08)
    events = key_events(line)
    arr = (_INPUT * len(events))()
    for i, (vk, scan, flags) in enumerate(events):
        arr[i].type = INPUT_KEYBOARD
        arr[i].u.ki = _KEYBDINPUT(vk, scan, flags, 0, 0)
    # One call, so nothing typed elsewhere can land in the middle.
    sent = u.SendInput(len(events), arr, ctypes.sizeof(_INPUT))
    return None if sent == len(events) else "Windows refused part of the input."
