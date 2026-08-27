#!/bin/bash
# Generate the Xcode project from project.yml and open it.
#
# The .xcodeproj is deliberately NOT committed. XcodeGen lists every source
# file individually, so a checked-in project goes stale the moment a file is
# added: Xcode would build without it and fail in ways that look like a code
# problem rather than a stale project. project.yml points at the directory
# instead, so regenerating always matches what is on disk.
#
# build.sh remains the way releases are built. This is for editing, debugging
# and running tests inside Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is needed to build the project file."
    if command -v brew >/dev/null 2>&1; then
        echo "→ brew install xcodegen"
        brew install xcodegen
    else
        echo "Install Homebrew first, then: brew install xcodegen" >&2
        exit 1
    fi
fi

xcodegen generate
echo "→ ClaudeNotch.xcodeproj regenerated from project.yml"
open ClaudeNotch.xcodeproj
