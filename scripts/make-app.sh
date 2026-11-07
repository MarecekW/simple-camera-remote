#!/usr/bin/env bash
#
# Assembles a macOS .app bundle around the Swift Package executable.
# Run from anywhere:
#
#   ./scripts/make-app.sh          (release build)
#   ./scripts/make-app.sh --debug  (debug build)
#
# Output:  build/Simple Camera Remote.app

set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build"
APP_NAME="Simple Camera Remote"
APP_DIR="$BUILD_ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
# The same identity as the bare executable's embedded Info.plist, so
# settings (UserDefaults) carry over between `swift run` and the .app.
BUNDLE_ID="dev.marekkramar.SimpleCameraRemote"
EXE_NAME="SimpleCameraRemote"
# The version shown in About and recorded with every capture: the release
# tag when given (APP_VERSION), else from git ("0.1.0-6-ga258ff3-dirty", or
# "0.1.0" on an exact tag), else "dev".  A leading "v" is dropped.
if [[ -z "${APP_VERSION:-}" ]]; then
  APP_VERSION="$(git -C "$REPO_ROOT" describe --tags --dirty --match 'v[0-9]*' 2>/dev/null || echo dev)"
fi
APP_VERSION="${APP_VERSION#v}"
# Build number: the commit count, increasing along main.
APP_BUILD="${APP_BUILD:-$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)}"
ICON_SRC="$REPO_ROOT/Sources/CameraRemoteApp/Resources/AppIcon.png"
ICONSET_DIR="$BUILD_ROOT/AppIcon.iconset"

echo "→ Version $APP_VERSION ($APP_BUILD)"
echo "→ Building camera-remote-app ($CONFIG)…"
swift build --package-path "$REPO_ROOT" -c "$CONFIG" --product camera-remote-app
BIN_DIR="$(swift build --package-path "$REPO_ROOT" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "→ Copying the executable"
cp "$BIN_DIR/camera-remote-app" "$MACOS_DIR/$EXE_NAME"

# The SwiftPM resource bundle isn't copied: in the .app the icon comes from
# AppIcon.icns (AppInfo.isAssembledApp), and nothing else is a resource.
echo "→ Making AppIcon.icns"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET_DIR" --output "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "→ Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>            <string>$EXE_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>               <string>$APP_BUILD</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.photography</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc: fine on this Mac; another Mac needs Gatekeeper's "Open Anyway"
# (README), or a Developer ID signature.
echo "→ Ad-hoc code signing"
codesign --force --sign - "$APP_DIR"

echo
echo "✓ $APP_DIR"
echo "  open \"$APP_DIR\""
