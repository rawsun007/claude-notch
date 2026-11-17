#!/usr/bin/env bash
# Build dist/claudenotch-<version>-linux.tar.gz: the app plus install.sh, for
# distributions without dpkg (Fedora, Arch, openSUSE, ...).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(python3 -c 'import claudenotch; print(claudenotch.__version__)')"
NAME="claudenotch-${VERSION}-linux"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME/claudenotch" "$STAGE/$NAME/bin"
cp claudenotch/*.py "$STAGE/$NAME/claudenotch/"
cp bin/claudenotch "$STAGE/$NAME/bin/"
cp packaging/install.sh packaging/claudenotch.desktop packaging/claudenotch.png README.md "$STAGE/$NAME/"
mkdir -p dist
tar -C "$STAGE" --owner=0 --group=0 -czf "dist/$NAME.tar.gz" "$NAME"
echo "dist/$NAME.tar.gz"
