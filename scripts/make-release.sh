#!/usr/bin/env bash
#
# Builds the release .app and zips it for a GitHub release.
#
#   ./scripts/make-release.sh
#
# Output:  build/simple-camera-remote.app.zip, with its size and SHA-256.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/Simple Camera Remote.app"
ZIP_PATH="$REPO_ROOT/build/simple-camera-remote.app.zip"

"$REPO_ROOT/scripts/make-app.sh"

# ditto keeps the bundle's extended attributes and signature intact.
echo "→ Zipping → $(basename "$ZIP_PATH")"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

size_kb=$(($(stat -f '%z' "$ZIP_PATH") / 1024))
hash=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

echo
echo "✓ $ZIP_PATH"
echo "  size:   ${size_kb} KB"
echo "  sha256: $hash"
