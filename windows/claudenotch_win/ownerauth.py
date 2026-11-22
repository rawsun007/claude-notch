"""Prove the person at the PC is its owner: the Mac's
`.deviceOwnerAuthentication` (Touch ID, or the Mac password without it).

Used before a setting that lets destructive commands run with less
friction: "Skip confirmation for destructive commands", and Auto-Approve's
"Approve them too". Windows Hello when this PC has it; otherwise Windows'
own credential prompt for the signed-in account (CredUIPromptForWindows-
Credentials), checked with LogonUser. The password goes straight from
Windows' prompt to Windows' check: it is never shown, stored or logged,
and its buffer is wiped as soon as the check is done. Only the signed-in
account counts; typing another account's password does not.
"""

from __future__ import annotations

import ctypes
import getpass
import os
import sys
import threading
from ctypes import wintypes

from . import hello

ERROR_CANCELLED = 1223
CREDUIWIN_ENUMERATE_CURRENT_USER = 0x200
CRED_PACK_PROTECTED_CREDENTIALS = 0x1
LOGON32_LOGON_INTERACTIVE = 2
LOGON32_PROVIDER_DEFAULT = 0

NOT_CONFIRMED = "That was not confirmed, so nothing was changed."


def same_account(entered: str, current_user: str, current_domain: str = "") -> bool:
    """Is `entered` ("name", "DOMAIN\\name" or "name@domain") the signed-in
    account? Case-insensitive, as Windows account names are. Pure."""
    entered = (entered or "").strip()
    if not entered or not current_user:
        return False
    name = entered
    domain = ""
    if "\\" in entered:
        domain, name = entered.split("\\", 1)
    elif "@" in entered and not entered.lower().startswith("microsoftaccount"):
        # A Microsoft account signs in by e-mail; its local name differs, so
        # only accept it when it is literally the current user name.
        return entered.lower() == current_user.lower()
    if domain and current_domain and domain.lower() not in (current_domain.lower(), "."):
        if domain.lower() != "microsoftaccount":
            return False
    return name.lower() == current_user.lower()


class _CREDUI_INFOW(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("hwndParent", wintypes.HWND),
                ("pszMessageText", wintypes.LPCWSTR), ("pszCaptionText", wintypes.LPCWSTR),
                ("hbmBanner", wintypes.HBITMAP)]


def _password_prompt(hwnd: int, reason: str) -> tuple[bool, str | None]:
    """Windows' credential prompt, verified with LogonUser. Blocking."""
    credui = ctypes.WinDLL("credui")
    advapi = ctypes.WinDLL("advapi32")
    kernel = ctypes.WinDLL("kernel32")
    ole = ctypes.WinDLL("ole32")
    credui.CredUIPromptForWindowsCredentialsW.argtypes = [
        ctypes.POINTER(_CREDUI_INFOW), wintypes.DWORD, ctypes.POINTER(wintypes.ULONG), ctypes.c_void_p,
        wintypes.ULONG, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.ULONG),
        ctypes.POINTER(wintypes.BOOL), wintypes.DWORD]
    credui.CredUIPromptForWindowsCredentialsW.restype = wintypes.DWORD
    credui.CredUnPackAuthenticationBufferW.argtypes = [
        wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD),
        wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD), wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    credui.CredUnPackAuthenticationBufferW.restype = wintypes.BOOL
    advapi.LogonUserW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
                                  wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.LogonUserW.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    ole.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    info = _CREDUI_INFOW(ctypes.sizeof(_CREDUI_INFOW), hwnd, reason, "ClaudeNotch", None)
    package = wintypes.ULONG(0)
    out_buf = ctypes.c_void_p()
    out_size = wintypes.ULONG(0)
    save = wintypes.BOOL(False)
    rc = credui.CredUIPromptForWindowsCredentialsW(
        ctypes.byref(info), 0, ctypes.byref(package), None, 0, ctypes.byref(out_buf), ctypes.byref(out_size),
        ctypes.byref(save), CREDUIWIN_ENUMERATE_CURRENT_USER)
    if rc == ERROR_CANCELLED:
        return False, None                       # an answer, not a failure
    if rc != 0:
        return False, NOT_CONFIRMED
    user = ctypes.create_unicode_buffer(514)
    domain = ctypes.create_unicode_buffer(338)
    pwd = ctypes.create_unicode_buffer(514)
    nu, nd, npw = wintypes.DWORD(514), wintypes.DWORD(338), wintypes.DWORD(514)
    try:
        ok = credui.CredUnPackAuthenticationBufferW(CRED_PACK_PROTECTED_CREDENTIALS, out_buf, out_size,
                                                    user, ctypes.byref(nu), domain, ctypes.byref(nd),
                                                    pwd, ctypes.byref(npw))
        if not ok:
            return False, NOT_CONFIRMED
        if not same_account(user.value, getpass.getuser(), os.environ.get("USERDOMAIN", "")):
            return False, "That is not the account signed in to this PC, so nothing was changed."
        token = wintypes.HANDLE()
        name, dom = user.value, (domain.value or None)
        if "\\" in name:
            dom, name = name.split("\\", 1)
        good = advapi.LogonUserW(name, dom, pwd, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT,
                                 ctypes.byref(token))
        if good:
            kernel.CloseHandle(token)
            return True, None
        return False, NOT_CONFIRMED
    finally:
        ctypes.memset(pwd, 0, ctypes.sizeof(pwd))
        if out_buf:
            ctypes.memset(out_buf, 0, out_size.value)
            ole.CoTaskMemFree(out_buf)


def confirm_owner(hwnd: int, reason: str, done, hello_available: bool | None = None) -> None:
    """Ask the owner to confirm on a worker thread; `done(ok, message)` is
    called on that thread. Cancelling gives (False, None)."""
    if sys.platform != "win32":
        done(False, NOT_CONFIRMED)
        return
    if hello_available is None:
        hello_available = hello.check_availability() == hello.AVAILABLE
    if hello_available:
        hello.confirm_async(hwnd, reason, done)
        return

    def run():
        try:
            ok, msg = _password_prompt(hwnd, reason)
        except OSError:
            ok, msg = False, NOT_CONFIRMED
        done(ok, msg)
    threading.Thread(target=run, daemon=True, name="owner-auth").start()
