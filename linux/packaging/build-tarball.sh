#!/usr/bin/env bash
# Build dist/claudenotch-<version>-linux.tar.gz: the app plus install.sh, for
# distributions without dpkg (Fedora, Arch, openSUSE, ...).
set -euo pipefail
cd "$(dirname "$0")/.."
# Read from the source, not by importing it: a stale __pycache__ can report
# the previous version when the file was edited within the same second.
VERSION="$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' claudenotch/__init__.py)"
NAME="claudenotch-${VERSION}-linux"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME/claudenotch" "$STAGE/$NAME/bin"
cp claudenotch/*.py "$STAGE/$NAME/claudenotch/"
cp bin/claudenotch "$STAGE/$NAME/bin/"
cp packaging/install.sh packaging/claudenotch.desktop packaging/claudenotch.png README.md "$STAGE/$NAME/"
mkdir -p dist
tar -C "$STAGE" --owner=0 --group=0 -czf "dist/$NAME.tar.gz" "$NAME"
echo "dist/$NAME.tar.gz"
