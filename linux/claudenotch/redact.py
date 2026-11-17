"""Strip credentials out of text before it is drawn, notified or stored.

A port of SecretRedactor from the macOS app. A command is shown on the card,
mirrored to the desktop's notification server and kept in history, and none
of those need the API key an agent pasted into it. Where the secret is a
value, the name in front of it is kept so the card still says what it is.
"""

from __future__ import annotations

import re

PLACEHOLDER = "[redacted]"

# Formats unmistakable on sight: the whole match goes.
_TOKENS = [
    r"\bsk-ant-[A-Za-z0-9_\-]{20,}",
    r"\bsk-proj-[A-Za-z0-9_\-]{20,}",
    r"\bsk-[A-Za-z0-9]{32,}",
    r"\bgh[pousr]_[A-Za-z0-9]{20,}",
    r"\bgithub_pat_[A-Za-z0-9_]{20,}",
    r"\bgl(?:pat|dt|rt|oas|ptt|agent|imt|soat|cbt|ft|ffct)-[A-Za-z0-9_\-]{16,}",
    r"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}",
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    r"\bxox[baprs]-[A-Za-z0-9\-]{10,}",
    r"\bAIza[0-9A-Za-z_\-]{35}",
    r"\bnpm_[A-Za-z0-9]{36}",
    r"\bhf_[A-Za-z0-9]{34,}",
    r"\bdop_v1_[A-Za-z0-9]{60,}",
    r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}",
]

_PRIVATE_KEY = r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"

_SECRET_WORDS = "SECRET|TOKEN|PASSWORD|PASSWD|APIKEY|API_KEY|ACCESSKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|CREDENTIALS"
_SECRET_FLAGS = "token|password|passwd|api-?key|access-?key|secret"

# (pattern, replacement, flags). Group 1 is the name, kept; the rest goes.
_VALUES = [
    (rf"""\b([A-Za-z0-9_]*(?:{_SECRET_WORDS})[A-Za-z0-9_]*\s*=\s*)(['"])([^'"]*)\2""",
     rf"\1\2{PLACEHOLDER}\2", re.IGNORECASE),
    (rf"""\b([A-Za-z0-9_]*(?:{_SECRET_WORDS})[A-Za-z0-9_]*\s*=\s*)([^\s'"]+)""",
     rf"\1{PLACEHOLDER}", re.IGNORECASE),
    (rf"((?:^|[\s;|&(])--?(?:[A-Za-z0-9]+-)?(?:{_SECRET_FLAGS})(?:=|\s+))(\S+)",
     rf"\1{PLACEHOLDER}", re.IGNORECASE),
    (r"\b((?:Bearer|Basic|Token)\s+)([A-Za-z0-9\-._~+/=]{12,})", rf"\1{PLACEHOLDER}", 0),
    (r"(://[^/\s:@]+:)([^/\s@]+)(@)", rf"\1{PLACEHOLDER}\3", 0),
]


def redact(text: str) -> str:
    if not text:
        return text
    out = re.sub(_PRIVATE_KEY, PLACEHOLDER, text)
    for pattern in _TOKENS:
        out = re.sub(pattern, PLACEHOLDER, out)
    for pattern, repl, flags in _VALUES:
        out = re.sub(pattern, repl, out, flags=flags)
    return out


def contains_secret(text: str) -> bool:
    return redact(text) != text
