#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="NotionMenuBar"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.notionmenubar.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"

# Keep the installed copy in /Applications up to date (it's the login item).
if [ -d "/Applications/$APP_BUNDLE" ]; then
    rm -rf "/Applications/$APP_BUNDLE"
fi
cp -R "$APP_BUNDLE" "/Applications/$APP_BUNDLE"

echo "Built ${APP_BUNDLE} and installed to /Applications."
