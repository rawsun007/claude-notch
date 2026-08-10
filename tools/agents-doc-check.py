#!/usr/bin/env python3
"""Keep AGENTS.md honest.

AGENTS.md is read by somebody else's coding agent, unattended, and acted on. A
stale command there is worse than a stale line in the README: nobody eyeballs it
before it runs, and when it fails the app looks broken rather than the document.
It also drifts silently, because nothing else in the build touches it.

So this checks the few things that actually go stale:

  - the copy the website serves is identical to the one in the repo
  - the Homebrew cask it names is the one release.sh publishes
  - the port it tells an agent to poke is the port the app listens on
  - the uninstall script it names exists in bin/
  - the version it claims to be written for is not ahead of the shipped app

Exits non-zero with one line per problem. Run with no arguments.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "AGENTS.md")
SERVED = os.path.abspath(
    os.path.join(ROOT, os.pardir, "claude mac app website", "public", "AGENTS.md")
)

problems = []


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def main():
    if not os.path.exists(DOC):
        print("AGENTS.md is missing")
        return 1
    doc = read(DOC)

    # The served copy is what agents actually fetch, so a repo-only edit is the
    # same as no edit at all.
    if os.path.exists(SERVED):
        if read(SERVED) != doc:
            problems.append(
                "website/public/AGENTS.md differs from AGENTS.md — copy it across"
            )
    else:
        # Only a problem when the website checkout is present; CI may not have it.
        if os.path.isdir(os.path.dirname(SERVED)):
            problems.append("website/public/AGENTS.md is missing")

    # The install line has to match what we actually publish.
    cask = re.search(r"brew install --cask (\S+)", doc)
    if not cask:
        problems.append("AGENTS.md no longer contains a 'brew install --cask' line")
    else:
        # The tap name is written by the script that pushes the cask, and
        # repeated in the README; either naming it is proof it is current.
        sources = ""
        for rel in [("tools", "push-cask-to-tap.sh"), ("tools", "release.sh"), ("README.md",)]:
            path = os.path.join(ROOT, *rel)
            if os.path.exists(path):
                sources += read(path)
        if cask.group(1) not in sources:
            problems.append(
                f"AGENTS.md installs '{cask.group(1)}', which nothing else in the repo publishes"
            )

    # The port an agent is told to check must be the one the app binds.
    delegate = os.path.join(ROOT, "Sources", "ClaudeNotch", "AppDelegate.swift")
    port = re.search(r"EventServer\(port:\s*(\d+)", read(delegate))
    if port and f":{port.group(1)}" not in doc:
        problems.append(
            f"AGENTS.md does not mention port {port.group(1)}, which is the one the app listens on"
        )

    # Anything it tells someone to run has to exist.
    for script in re.findall(r"~/\.claudenotch/bin/([\w.-]+\.sh)", doc):
        if not os.path.exists(os.path.join(ROOT, "bin", script)):
            problems.append(f"AGENTS.md points at bin/{script}, which does not exist")

    # "Written for x.y.z and later" must not be ahead of what we ship.
    claimed = re.search(r"written for ClaudeNotch (\d+\.\d+\.\d+)", doc, re.I)
    shipped = re.search(
        r"CFBundleShortVersionString</key><string>([\d.]+)",
        read(os.path.join(ROOT, "build.sh")),
    )
    if claimed and shipped:
        def parts(v):
            return [int(n) for n in v.split(".")]

        if parts(claimed.group(1)) > parts(shipped.group(1)):
            problems.append(
                f"AGENTS.md claims {claimed.group(1)} but the build ships {shipped.group(1)}"
            )

    for p in problems:
        print(p)
    if problems:
        print(f"\n{len(problems)} problem(s).")
        return 1
    print("AGENTS.md checks out.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
