#!/bin/bash
# Builds the Maziar SwiftUI app via Swift Package Manager and packages it
# into a real double-clickable Maziar.app bundle. No Xcode project needed.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Maziar"
BUNDLE_ID="com.farhadshad.maziar"
BIN_NAME="Maziar"
CONFIG="${1:-release}"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/$BIN_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "Build output not found at $BIN_PATH" >&2
  exit 1
fi

APP_DIR="dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"

RESOURCE_BUNDLE=".build/$CONFIG/${BIN_NAME}_${BIN_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Stamped into Info.plist so the running app can tell which commit it was built from (to compare
# against GitHub for the in-app updater) and which checkout to pull/rebuild when updating itself.
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
REPO_PATH="$(pwd)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>3.0.3</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0.3</string>
    <key>MaziarGitCommit</key>
    <string>$GIT_COMMIT</string>
    <key>MaziarRepoPath</key>
    <string>$REPO_PATH</string>
    <key>MaziarBuildDate</key>
    <string>$BUILD_DATE</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Farhad Shadmand. MIT License.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSAppleEventsUsageDescription</key>
    <string>Maziar opens links in Safari (e.g. a saved video, GitHub repo, or paper) as a new browser window.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "Built: $APP_DIR"
