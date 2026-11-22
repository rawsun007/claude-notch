"""ctypes helpers for the Windows parts Qt does not cover.

Every function is safe to call off Windows (tests, a Linux dev box): it
does nothing and returns a neutral answer.
"""

from __future__ import annotations

import ctypes
import sys

GWL_EXSTYLE = -20
WS_EX_TOPMOST = 0x00000008
WS_EX_TOOLWINDOW = 0x00000080
WS_EX_NOACTIVATE = 0x08000000

SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE, SWP_FRAMECHANGED = 0x0001, 0x0002, 0x0010, 0x0020
HWND_TOPMOST = -1

# SHQueryUserNotificationState results.
QUNS_NOT_PRESENT = 1
QUNS_BUSY = 2                      # a fullscreen app (not D3D) is in front
QUNS_RUNNING_D3D_FULL_SCREEN = 3   # a fullscreen game
QUNS_PRESENTATION_MODE = 4
QUNS_ACCEPTS_NOTIFICATIONS = 5
QUNS_QUIET_TIME = 6
QUNS_APP = 7

FULLSCREEN_STATES = {QUNS_BUSY, QUNS_RUNNING_D3D_FULL_SCREEN, QUNS_PRESENTATION_MODE}

ON_WINDOWS = sys.platform == "win32"

if ON_WINDOWS:
    import ctypes
    from ctypes import wintypes

    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _shell32 = ctypes.WinDLL("shell32")
    # GetWindowLongPtrW only exists in 64-bit user32; 32-bit has GetWindowLongW.
    _get_long = getattr(_user32, "GetWindowLongPtrW", _user32.GetWindowLongW)
    _set_long = getattr(_user32, "SetWindowLongPtrW", _user32.SetWindowLongW)
    _get_long.restype = ctypes.c_ssize_t
    _get_long.argtypes = [wintypes.HWND, ctypes.c_int]
    _set_long.restype = ctypes.c_ssize_t
    _set_long.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]
    _user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                     ctypes.c_int, ctypes.c_int, ctypes.c_uint]
    _user32.GetForegroundWindow.restype = wintypes.HWND
    _user32.SetForegroundWindow.argtypes = [wintypes.HWND]


def set_no_activate(hwnd: int, on: bool = True) -> None:
    """WS_EX_NOACTIVATE (+ TOOLWINDOW, TOPMOST): the window takes clicks but
    never the keyboard, so a card appearing while you type in the terminal
    does not eat keystrokes. Qt's WindowDoesNotAcceptFocus alone still
    activates on some re-shows and resizes (WINDOWS.md section 3)."""
    if not ON_WINDOWS or not hwnd:
        return
    style = _get_long(hwnd, GWL_EXSTYLE)
    want = style | WS_EX_TOOLWINDOW | WS_EX_TOPMOST
    want = want | WS_EX_NOACTIVATE if on else want & ~WS_EX_NOACTIVATE
    if want != style:
        _set_long(hwnd, GWL_EXSTYLE, want)
        _user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                             SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED)


def keep_topmost(hwnd: int) -> None:
    """Re-assert topmost without activating: another topmost window (a
    screenshot tool, Teams) can land above us."""
    if ON_WINDOWS and hwnd:
        _user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)


def foreground_window() -> int:
    return int(_user32.GetForegroundWindow() or 0) if ON_WINDOWS else 0


def set_foreground(hwnd: int) -> None:
    if ON_WINDOWS and hwnd:
        _user32.SetForegroundWindow(hwnd)


def notification_state() -> int:
    """SHQueryUserNotificationState, or QUNS_ACCEPTS_NOTIFICATIONS when it
    cannot be read."""
    if not ON_WINDOWS:
        return QUNS_ACCEPTS_NOTIFICATIONS
    state = ctypes.c_int(0)
    try:
        if _shell32.SHQueryUserNotificationState(ctypes.byref(state)) != 0:
            return QUNS_ACCEPTS_NOTIFICATIONS
    except (AttributeError, OSError):
        return QUNS_ACCEPTS_NOTIFICATIONS
    return state.value


def fullscreen_in_front() -> bool:
    """A game, a fullscreen video or a presentation is in front: hide the idle
    pill (WINDOWS.md, Fullscreen). Cards that need an answer still show."""
    return notification_state() in FULLSCREEN_STATES


def system_uses_light_theme() -> bool:
    """The taskbar's theme, for picking the tray icon: light taskbar wants
    the dark mark. Defaults to dark (the Windows 11 default)."""
    if not ON_WINDOWS:
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            value, _ = winreg.QueryValueEx(k, "SystemUsesLightTheme")
            return bool(value)
    except OSError:
        return False


def set_app_user_model_id(aumid: str) -> None:
    """Toasts and the taskbar group under this id; it must match the Start
    Menu shortcut the installer writes."""
    if not ON_WINDOWS:
        return
    try:
        _shell32.SetCurrentProcessExplicitAppUserModelID(ctypes.c_wchar_p(aumid))
    except (AttributeError, OSError):
        pass


WDA_NONE = 0x0
WDA_EXCLUDEFROMCAPTURE = 0x11


def exclude_from_capture(hwnd: int, on: bool) -> bool:
    """Keep a window out of screen shares, recordings and screenshots (the
    Mac's sharingType = .none). Windows 10 2004 and later; returns False
    where it is not available, and the window then simply shows in them."""
    if sys.platform != "win32" or not hwnd:
        return False
    try:
        user32 = ctypes.windll.user32
        user32.SetWindowDisplayAffinity.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        return bool(user32.SetWindowDisplayAffinity(ctypes.c_void_p(hwnd), WDA_EXCLUDEFROMCAPTURE if on else WDA_NONE))
    except (AttributeError, OSError):
        return False
