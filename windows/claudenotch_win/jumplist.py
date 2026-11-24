"""The taskbar jump list: right-click ClaudeNotch on the taskbar (pinned, or
while Settings is open) or in Start, and its tasks are there: Open the
Notch, Settings, Usage, History. The Mac reaches the same places from its
menu bar item and Dock menu.

Each task starts the app with a claudenotch:// link, which the running copy
turns into the page (a second launch only forwards it). Built with the
shell's ICustomDestinationList through ctypes; pywin32 is not needed.
Only for the installed app: a checkout has no single exe to point at.
"""

from __future__ import annotations

import ctypes
import sys

from . import paths

#: (title, link, description), in the order the jump list shows them.
TASKS = (
    ("Open the Notch", "claudenotch://open", "Show the notch and your sessions"),
    ("Settings", "claudenotch://settings", "Open ClaudeNotch Settings (Ctrl+Alt+,)"),
    ("Usage", "claudenotch://settings/usage", "Tokens, cost and limits"),
    ("History", "claudenotch://history", "Past sessions and activity (Ctrl+Alt+H)"),
)


def task_lines(exe: str) -> list[tuple[str, str, str, str]]:
    """(title, program, arguments, description) for each task. Pure."""
    return [(title, exe, f'--url "{link}"', desc) for title, link, desc in TASKS]


# --- COM through ctypes ------------------------------------------------------------------------

class _GUID(ctypes.Structure):
    _fields_ = [("a", ctypes.c_uint32), ("b", ctypes.c_uint16), ("c", ctypes.c_uint16), ("d", ctypes.c_ubyte * 8)]

    def __init__(self, text: str):
        super().__init__()
        ctypes.oledll.ole32.CLSIDFromString(ctypes.c_wchar_p("{" + text + "}"), ctypes.byref(self))


class _PROPERTYKEY(ctypes.Structure):
    _fields_ = [("fmtid", _GUID), ("pid", ctypes.c_uint32)]


class _PROPVARIANT(ctypes.Structure):
    _fields_ = [("vt", ctypes.c_ushort), ("r1", ctypes.c_ushort), ("r2", ctypes.c_ushort), ("r3", ctypes.c_ushort),
                ("value", ctypes.c_void_p), ("pad", ctypes.c_void_p)]


VT_LPWSTR = 31


def _method(ptr, index: int, *argtypes):
    """The vtable entry `index` of COM object `ptr`, ready to call."""
    vtbl = ctypes.cast(ptr, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    proto = ctypes.WINFUNCTYPE(ctypes.HRESULT, ctypes.c_void_p, *argtypes)
    fn = proto(vtbl[index])
    return lambda *args: fn(ptr, *args)


def _create(clsid: str, iid: str) -> ctypes.c_void_p:
    out = ctypes.c_void_p()
    ctypes.oledll.ole32.CoCreateInstance(ctypes.byref(_GUID(clsid)), None, 1, ctypes.byref(_GUID(iid)),
                                         ctypes.byref(out))
    return out


def _query(ptr, iid: str) -> ctypes.c_void_p:
    out = ctypes.c_void_p()
    _method(ptr, 0, ctypes.c_void_p, ctypes.c_void_p)(ctypes.byref(_GUID(iid)), ctypes.byref(out))
    return out


def _release(ptr) -> None:
    if ptr:
        ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(
            ctypes.cast(ptr, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents[2])(ptr)


CLSID_DestinationList = "77f10cf0-3db5-4966-b520-b7c54fd35ed6"
IID_ICustomDestinationList = "6332debf-87b5-4670-90c0-5e57b408a49e"
CLSID_EnumerableObjectCollection = "2d3468c1-36a7-43b6-ac24-d3f02fd9607a"
IID_IObjectCollection = "5632b1a4-e38a-400a-928a-d4cd63230295"
IID_IObjectArray = "92ca9dcd-5622-4bba-a805-5e9f541bd8c9"
CLSID_ShellLink = "00021401-0000-0000-C000-000000000046"
IID_IShellLinkW = "000214F9-0000-0000-C000-000000000046"
IID_IPropertyStore = "886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"
FMTID_Title = "F29F85E0-4FF9-1068-AB91-08002B27B3D9"


def _link(title: str, exe: str, args: str, desc: str) -> ctypes.c_void_p:
    link = _create(CLSID_ShellLink, IID_IShellLinkW)
    _method(link, 20, ctypes.c_wchar_p)(exe)                          # SetPath
    _method(link, 11, ctypes.c_wchar_p)(args)                         # SetArguments
    _method(link, 7, ctypes.c_wchar_p)(desc)                          # SetDescription
    _method(link, 17, ctypes.c_wchar_p, ctypes.c_int)(exe, 0)         # SetIconLocation
    store = _query(link, IID_IPropertyStore)
    key = _PROPERTYKEY(_GUID(FMTID_Title), 2)
    text = ctypes.create_unicode_buffer(title)
    pv = _PROPVARIANT(VT_LPWSTR, 0, 0, 0, ctypes.cast(text, ctypes.c_void_p), None)
    _method(store, 6, ctypes.c_void_p, ctypes.c_void_p)(ctypes.byref(key), ctypes.byref(pv))   # SetValue
    _method(store, 7)()                                                                         # Commit
    _release(store)
    return link


def _com_init() -> None:
    """COM for this thread. Already set up (Qt's GUI thread is, as an
    apartment; another library may have chosen the other mode) is fine: the
    objects used here work in either, so the answer is not checked."""
    ctypes.windll.ole32.CoInitializeEx(None, 2)


def install(app_id: str = paths.AUMID, exe: str | None = None) -> bool:
    """Write the jump list's tasks for `app_id`. False where it cannot be
    done (not Windows, not the installed exe, or the shell said no)."""
    if sys.platform != "win32":
        return False
    exe = exe or (sys.executable if paths.frozen() else None)
    if not exe:
        return False
    _com_init()
    dest = coll = arr = None
    links = []
    try:
        dest = _create(CLSID_DestinationList, IID_ICustomDestinationList)
        _method(dest, 3, ctypes.c_wchar_p)(app_id)                                  # SetAppID
        slots, removed = ctypes.c_uint(), ctypes.c_void_p()
        _method(dest, 4, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(       # BeginList
            ctypes.byref(slots), ctypes.byref(_GUID(IID_IObjectArray)), ctypes.byref(removed))
        _release(removed)
        coll = _create(CLSID_EnumerableObjectCollection, IID_IObjectCollection)
        for title, program, args, desc in task_lines(exe):
            link = _link(title, program, args, desc)
            links.append(link)
            _method(coll, 5, ctypes.c_void_p)(link)                                  # AddObject
        arr = _query(coll, IID_IObjectArray)
        _method(dest, 7, ctypes.c_void_p)(arr)                                       # AddUserTasks
        _method(dest, 8)()                                                           # CommitList
        return True
    except OSError:
        return False
    finally:
        for p in [*links, arr, coll, dest]:
            _release(p)


def remove(app_id: str = paths.AUMID) -> bool:
    if sys.platform != "win32":
        return False
    try:
        _com_init()
        dest = _create(CLSID_DestinationList, IID_ICustomDestinationList)
        try:
            _method(dest, 10, ctypes.c_wchar_p)(app_id)                              # DeleteList
        finally:
            _release(dest)
        return True
    except OSError:
        return False
