#!/usr/bin/env python3
"""Validate the translated strings tables against English.

Two failures matter and neither is visible until someone runs the app in that
language:

  A missing key silently falls back to the English text, so a half-translated
  build looks fine to whoever shipped it.

  A format specifier that does not match is worse than cosmetic. "Raise to %@"
  translated without its %@ drops the amount, and a %@ where the code passes an
  integer reads unrelated memory as a pointer. Those crash rather than blur.

Run with no arguments, exits non-zero on any problem.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")
EN = "en.lproj"

ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";$')
# %@ %d %1$@ %.2f and friends, but not a bare "100%" or "%" alone.
# The space flag ("% d") is deliberately not accepted: no string here uses it,
# and allowing it made prose like "80% and once at 95%" read as a "%a".
SPECIFIER = re.compile(r'%(?:\d+\$)?[-+#0]*[\d.*]*(?:hh|h|ll|l|q|L|z|j|t)?[@diouxXeEfgGcsSpaA]')


def parse(path):
    """Read a .strings table. Comments span lines, so they are tracked as a
    state rather than matched per line."""
    table = {}
    in_comment = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.strip()
        if in_comment:
            if "*/" in line:
                in_comment = False
            continue
        if not line or line.startswith("//"):
            continue
        if line.startswith("/*"):
            if "*/" not in line:
                in_comment = True
            continue
        m = ENTRY.match(line)
        if not m:
            print(f"{os.path.relpath(path, ROOT)}:{n}: cannot parse: {line}", file=sys.stderr)
            return None
        table[m.group(1)] = m.group(2)
    return table


def specifiers(text):
    """Ordered specifiers, so %@ %d and %d %@ are not treated as equal."""
    return [m.group(0).replace(" ", "") for m in SPECIFIER.finditer(text)]


def main():
    en_path = os.path.join(RESOURCES, EN, "Localizable.strings")
    if not os.path.exists(en_path):
        print("No English table found.", file=sys.stderr)
        return 1
    english = parse(en_path)
    if english is None:
        return 1

    langs = sorted(d for d in os.listdir(RESOURCES)
                   if d.endswith(".lproj") and d != EN)
    if not langs:
        print(f"English only, {len(english)} keys. No translations to check.")
        return 0

    problems = 0
    for lang in langs:
        path = os.path.join(RESOURCES, lang, "Localizable.strings")
        table = parse(path)
        if table is None:
            problems += 1
            continue

        missing = sorted(set(english) - set(table))
        extra = sorted(set(table) - set(english))

        # A key that is not translated yet falls back to English at runtime, so
        # an incomplete language is a known state rather than a broken one. It
        # is reported as coverage instead of failing, because hard-failing would
        # mean no language could be started without finishing all of it at once.
        # A key that is NOT in English is different: it is a typo or a leftover
        # from a renamed string, and it will never be read.
        for key in extra:
            print(f"{lang}: key {key!r} is not in the English table", file=sys.stderr)
        problems += len(extra)

        for key, value in table.items():
            if key not in english:
                continue
            want, got = specifiers(english[key]), specifiers(value)
            if want != got:
                print(f"{lang}: {key!r} has specifiers {got}, English has {want}",
                      file=sys.stderr)
                problems += 1

        done = len(english) - len(missing)
        pct = (100 * done // len(english)) if english else 100
        flag = "" if not missing else f"  ({len(missing)} still English)"
        print(f"  {lang}: {done}/{len(english)} keys, {pct}%{flag}")

    if problems:
        print(f"\n{problems} problem(s).", file=sys.stderr)
        return 1
    print(f"\n{len(langs)} translations against {len(english)} English keys. "
          "Untranslated keys fall back to English.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
