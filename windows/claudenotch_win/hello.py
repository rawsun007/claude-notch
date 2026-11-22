"""Windows Hello for destructive commands: the Mac's Touch ID gate.

Ports DestructiveGate and BiometricAuth. A destructive card asks for a
deliberate gesture before Allow: Windows Hello (face, fingerprint or PIN)
when this PC has it and the setting is on, which it is by default, and
press-and-hold otherwise. "Skip confirmation for destructive commands"
drops the gesture, and switching it on takes Windows Hello every time.

Windows Hello is reached through Windows' own WinRT API,
Windows.Security.Credentials.UI.UserConsentVerifier, called with ctypes:
no extra packages. The prompt is parented to the notch's window through
IUserConsentVerifierInterop, so it comes up in front of the terminal
rather than behind it. Everything that is not a COM call is pure and
tested; the COM calls run on a worker thread and never on the GUI thread.
"""

from __future__ import annotations

import ctypes
import hashlib
import sys
import threading
import time
import uuid

# --- the gate (DestructiveGate) -------------------------------------------------------

HELLO, HOLD, NONE = "hello", "hold", "none"


def gate(require_hello: bool, hello_available: bool, skip_confirmation: bool) -> str:
    """What stands between a destructive command and Allow."""
    if skip_confirmation:
        return NONE
    return HELLO if require_hello and hello_available else HOLD


def return_allows(dangerous: bool, skip_confirmation: bool) -> bool:
    """May Return allow this card? A destructive one only with no gesture."""
    return not dangerous or skip_confirmation


def needs_authentication(current: bool, nxt: bool) -> bool:
    """Only switching "skip confirmation" ON needs Windows Hello."""
    return not current and nxt


# --- what Windows says --------------------------------------------------------------------

#: UserConsentVerifierAvailability
AVAILABLE, DEVICE_NOT_PRESENT, NOT_CONFIGURED, DISABLED_BY_POLICY, DEVICE_BUSY = range(5)
#: UserConsentVerificationResult
VERIFIED, R_DEVICE_NOT_PRESENT, R_NOT_CONFIGURED, R_DISABLED, R_BUSY, RETRIES_EXHAUSTED, CANCELED = range(7)


def failure_message(result: int | None) -> str | None:
    """BiometricAuth.failureMessage, for Windows Hello. Cancelling is an
    answer, not a failure, so it says nothing; everything else must say
    why the button seemed to do nothing."""
    if result in (VERIFIED, CANCELED):
        return None
    if result == RETRIES_EXHAUSTED:
        return "Too many attempts. Unlock Windows with your PIN or password, then try again."
    if result in (R_DEVICE_NOT_PRESENT, R_NOT_CONFIGURED, R_DISABLED):
        return "Windows Hello is unavailable right now. Use the hold-to-confirm button instead."
    return "That was not confirmed, so nothing was allowed."


# --- WinRT interface ids --------------------------------------------------------------------

_PINTERFACE_NAMESPACE = uuid.UUID("11f47ad5-7b73-42c0-abae-878b1e16adee")
IASYNC_OPERATION = "{9fc2b0bb-e446-44e2-aa61-9cab8f636af2}"


def pinterface_iid(signature: str) -> uuid.UUID:
    """The IID of a parameterized WinRT interface: a SHA-1 name-based UUID
    of its type signature in the WinRT pinterface namespace."""
    h = hashlib.sha1(_PINTERFACE_NAMESPACE.bytes + signature.encode("utf-8")).digest()
    b = bytearray(h[:16])
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    return uuid.UUID(bytes=bytes(b))


RESULT_ASYNC_IID = pinterface_iid(
    f"pinterface({IASYNC_OPERATION};enum(Windows.Security.Credentials.UI.UserConsentVerificationResult;i4))")
STATICS_IID = uuid.UUID("af4f3f91-564c-4ddc-b8b5-973447627c65")      # IUserConsentVerifierStatics
INTEROP_IID = uuid.UUID("39e050c3-4e74-441a-8dc0-b81104df949c")      # IUserConsentVerifierInterop
ASYNC_INFO_IID = uuid.UUID("00000036-0000-0000-c000-000000000046")   # IAsyncInfo
CLASS_NAME = "Windows.Security.Credentials.UI.UserConsentVerifier"


# --- the COM calls ----------------------------------------------------------------------------

class _GUID(ctypes.Structure):
    _fields_ = [("Data1", ctypes.c_uint32), ("Data2", ctypes.c_uint16), ("Data3", ctypes.c_uint16),
                ("Data4", ctypes.c_ubyte * 8)]

    @classmethod
    def of(cls, u: uuid.UUID) -> "_GUID":
        g = cls()
        g.Data1, g.Data2, g.Data3 = u.fields[0], u.fields[1], u.fields[2]
        for i, byte in enumerate(u.bytes[8:]):
            g.Data4[i] = byte
        return g


def _method(obj: ctypes.c_void_p, index: int, *argtypes, restype=ctypes.c_long):
    vtbl = ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    proto = ctypes.WINFUNCTYPE(restype, ctypes.c_void_p, *argtypes)
    fn = proto(vtbl[index])
    return lambda *args: fn(obj, *args)


def _release(obj) -> None:
    if obj:
        _method(obj, 2, restype=ctypes.c_ulong)()


class _WinRT:
    def __init__(self):
        self.combase = ctypes.WinDLL("combase")
        self.combase.WindowsCreateString.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
        self.combase.WindowsDeleteString.argtypes = [ctypes.c_void_p]
        self.combase.RoGetActivationFactory.argtypes = [ctypes.c_void_p, ctypes.POINTER(_GUID),
                                                        ctypes.POINTER(ctypes.c_void_p)]
        self.combase.RoInitialize.argtypes = [ctypes.c_int]

    def init_thread(self) -> None:
        self.combase.RoInitialize(1)      # multithreaded apartment; S_FALSE when already so

    def hstring(self, s: str) -> ctypes.c_void_p:
        h = ctypes.c_void_p()
        hr = self.combase.WindowsCreateString(s, len(s), ctypes.byref(h))
        if hr < 0:
            raise OSError(hr, "WindowsCreateString")
        return h

    def factory(self, iid: uuid.UUID) -> ctypes.c_void_p:
        name = self.hstring(CLASS_NAME)
        out = ctypes.c_void_p()
        try:
            hr = self.combase.RoGetActivationFactory(name, ctypes.byref(_GUID.of(iid)), ctypes.byref(out))
        finally:
            self.combase.WindowsDeleteString(name)
        if hr < 0:
            raise OSError(hr, "RoGetActivationFactory")
        return out

    @staticmethod
    def wait(op: ctypes.c_void_p, timeout: float) -> int:
        """Poll the operation's IAsyncInfo until it ends, then GetResults."""
        info = ctypes.c_void_p()
        hr = _method(op, 0, ctypes.POINTER(_GUID), ctypes.POINTER(ctypes.c_void_p))(
            ctypes.byref(_GUID.of(ASYNC_INFO_IID)), ctypes.byref(info))
        if hr < 0:
            raise OSError(hr, "QueryInterface(IAsyncInfo)")
        try:
            status = ctypes.c_int()
            deadline = time.monotonic() + timeout
            while True:
                _method(info, 7, ctypes.POINTER(ctypes.c_int))(ctypes.byref(status))   # get_Status
                if status.value != 0:
                    break
                if time.monotonic() > deadline:
                    _method(info, 9)()                                                 # Cancel
                    raise TimeoutError("Windows Hello did not answer")
                time.sleep(0.05)
            if status.value != 1:          # 2 canceled, 3 error
                raise OSError(status.value, "the Windows Hello request did not complete")
        finally:
            _release(info)
        result = ctypes.c_int()
        hr = _method(op, 8, ctypes.POINTER(ctypes.c_int))(ctypes.byref(result))       # GetResults
        if hr < 0:
            raise OSError(hr, "GetResults")
        return result.value


_rt: _WinRT | None = None


def _winrt() -> _WinRT:
    global _rt
    if _rt is None:
        _rt = _WinRT()
    return _rt


def check_availability(timeout: float = 5.0) -> int:
    """UserConsentVerifier.CheckAvailabilityAsync, blocking. DEVICE_NOT_PRESENT
    when anything goes wrong or this is not Windows."""
    if sys.platform != "win32":
        return DEVICE_NOT_PRESENT
    try:
        rt = _winrt()
        rt.init_thread()
        statics = rt.factory(STATICS_IID)
        try:
            op = ctypes.c_void_p()
            hr = _method(statics, 6, ctypes.POINTER(ctypes.c_void_p))(ctypes.byref(op))
            if hr < 0:
                return DEVICE_NOT_PRESENT
            try:
                return rt.wait(op, timeout)
            finally:
                _release(op)
        finally:
            _release(statics)
    except (OSError, TimeoutError, AttributeError):
        return DEVICE_NOT_PRESENT


def request(hwnd: int, message: str, timeout: float = 120.0) -> int:
    """Show the Windows Hello prompt over `hwnd` and wait for the answer.
    Blocking: call it from a worker thread."""
    if sys.platform != "win32":
        return R_DEVICE_NOT_PRESENT
    rt = _winrt()
    rt.init_thread()
    interop = rt.factory(INTEROP_IID)
    msg = rt.hstring(message[:200])
    try:
        op = ctypes.c_void_p()
        call = _method(interop, 6, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(_GUID),
                       ctypes.POINTER(ctypes.c_void_p))
        hr = call(ctypes.c_void_p(hwnd), msg, ctypes.byref(_GUID.of(RESULT_ASYNC_IID)), ctypes.byref(op))
        if hr < 0:
            raise OSError(hr, "RequestVerificationForWindowAsync")
        try:
            return rt.wait(op, timeout)
        finally:
            _release(op)
    finally:
        rt.combase.WindowsDeleteString(msg)
        _release(interop)


class Availability:
    """Whether Windows Hello can be asked, checked off the GUI thread and
    remembered for a minute (it changes when the user sets Hello up)."""

    def __init__(self, check=check_availability, ttl: float = 60.0):
        self._check, self._ttl = check, ttl
        self._value: int | None = None
        self._at = 0.0
        self._lock = threading.Lock()

    def refresh(self) -> None:
        def run():
            v = self._check()
            with self._lock:
                self._value, self._at = v, time.monotonic()
        threading.Thread(target=run, daemon=True, name="hello-availability").start()

    @property
    def available(self) -> bool:
        with self._lock:
            value, at = self._value, self._at
        if value is None or time.monotonic() - at > self._ttl:
            self.refresh()
        return value == AVAILABLE


def confirm_async(hwnd: int, message: str, done) -> None:
    """Ask Windows Hello on a worker thread; `done(ok, message_or_None)` is
    called on that thread, so the caller hops back to the GUI thread."""
    def run():
        try:
            result = request(hwnd, message)
        except (OSError, TimeoutError):
            result = None
        done(result == VERIFIED, failure_message(result) if result is not None else
             "That was not confirmed, so nothing was allowed.")
    threading.Thread(target=run, daemon=True, name="hello-request").start()
