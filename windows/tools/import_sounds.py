"""Put the app's sounds in windows/resources/sounds.

The sounds come from github.com/extratone/macOSsystemsounds, released
under The Unlicense, with the owner's permission to use them in
ClaudeNotch (see windows/resources/sounds/SOURCE.md). This fetches the 13
the app uses from one pinned commit and converts each AIFF to the 16-bit
WAV winsound plays, so the files can be rebuilt exactly:

    python windows/tools/import_sounds.py
"""

from __future__ import annotations

import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = os.path.dirname(HERE)
sys.path[:0] = [WIN, os.path.join(os.path.dirname(WIN), "linux")]

from claudenotch_win import aiffwav  # noqa: E402

COMMIT = "f3e8dcd8d2318d099ade479ad1b9778ce4e65cc7"
URL = "https://raw.githubusercontent.com/extratone/macOSsystemsounds/{commit}/aiff/{name}.aiff"
NAMES = ("Funk", "Pop", "Tink", "Glass", "Submarine", "Hero", "Blow", "Bottle", "Frog", "Morse", "Ping", "Purr",
         "Sosumi")
OUT = os.path.join(WIN, "resources", "sounds")


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    for name in NAMES:
        req = urllib.request.Request(URL.format(commit=COMMIT, name=name), headers={"User-Agent": "ClaudeNotch"})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read(aiffwav.MAX_BYTES + 1)
        wav = aiffwav.to_wav(data)
        with open(os.path.join(OUT, name + ".wav"), "wb") as f:
            f.write(wav)
        print(f"{name}.wav  {len(wav) / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
