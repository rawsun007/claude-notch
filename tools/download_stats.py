#!/usr/bin/env python3
"""Format `gh api repos/<repo>/releases` into a per-release download table.

Reads the JSON on stdin, prints one line per release oldest first, then the
grand total on the last line for the calling shell to pick up. Kept out of
download-stats.sh because the quoting for an inline heredoc of this is a trap.
"""

from __future__ import annotations

import json
import sys


def load(text: str) -> list[dict]:
    """Accept either a JSON array or the NDJSON that `gh api --paginate --jq`
    emits once the release list runs past one page."""
    text = text.strip()
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def main() -> int:
    releases = load(sys.stdin.read())
    total = 0
    rows = []
    for r in releases:
        n = sum(a["download_count"] for a in r["assets"])
        total += n
        rows.append(f'  {r["tag_name"]:<10} {n:>6}  {r["published_at"][:10]}')
    print("\n".join(reversed(rows)))
    print(total)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
