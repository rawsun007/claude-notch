"""Read an AIFF sound (the format macOS keeps its system sounds in) and
write it as a 16-bit PCM WAV, which is all winsound can play. Pure.

Handles plain AIFF and AIFF-C with uncompressed samples ("NONE", or
"sowt", little-endian), 8 to 32 bits, any channel count. Anything else
raises ValueError, and the caller plays nothing.
"""

from __future__ import annotations

import math
import struct

MAX_BYTES = 16 * 1024 * 1024


def _extended(b: bytes) -> float:
    """The 80-bit IEEE extended float AIFF stores its sample rate in."""
    exp, hi, lo = struct.unpack(">HII", b)
    sign = -1 if exp & 0x8000 else 1
    exp &= 0x7FFF
    if exp == 0 and hi == 0 and lo == 0:
        return 0.0
    mant = (hi << 32) | lo
    return sign * math.ldexp(mant, exp - 16383 - 63)


def read(data: bytes) -> tuple[int, int, int, bytes, bool]:
    """(channels, bits, rate, sample bytes, little-endian?)."""
    if len(data) > MAX_BYTES or len(data) < 12 or data[:4] != b"FORM" or data[8:12] not in (b"AIFF", b"AIFC"):
        raise ValueError("not an AIFF file")
    aifc = data[8:12] == b"AIFC"
    pos, comm, ssnd = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack(">I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"COMM":
            comm = body
        elif cid == b"SSND":
            ssnd = body
        pos += 8 + size + (size & 1)
    if comm is None or ssnd is None or len(comm) < 18 or len(ssnd) < 8:
        raise ValueError("AIFF without COMM or SSND")
    channels, frames, bits = struct.unpack(">hIh", comm[:8])
    rate = int(round(_extended(comm[8:18])))
    little = False
    if aifc:
        kind = comm[18:22]
        if kind == b"sowt":
            little = True
        elif kind != b"NONE":
            raise ValueError("compressed AIFF-C")
    if channels < 1 or not 1 <= bits <= 32 or not 1000 <= rate <= 384000:
        raise ValueError("unsupported AIFF format")
    offset = struct.unpack(">I", ssnd[:4])[0]
    width = (bits + 7) // 8
    samples = ssnd[8 + offset:8 + offset + frames * channels * width]
    return channels, bits, rate, samples[: len(samples) - len(samples) % (width * channels)], little


def to_wav(data: bytes) -> bytes:
    channels, bits, rate, raw, little = read(data)
    width = (bits + 7) // 8
    out = bytearray()
    for i in range(0, len(raw), width):
        s = raw[i:i + width]
        if little:
            s = s[::-1]
        if width == 1:
            v = (s[0] - 256 if s[0] > 127 else s[0]) << 8      # AIFF 8-bit is signed
        else:
            v = int.from_bytes(s[:2], "big", signed=True)        # the top 16 bits
        out += struct.pack("<h", v)
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(out), b"WAVE", b"fmt ", 16, 1, channels, rate,
                         rate * channels * 2, channels * 2, 16, b"data", len(out))
    return header + bytes(out)
