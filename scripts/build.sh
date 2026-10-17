#!/bin/bash
# Build Claude Notch into a signed app bundle at build/ClaudeNotch.app.
# Plain swiftc on purpose: it works even when a Command Line Tools install ships a
# PackageDescription that is out of sync with its compiler (swift build fails there).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ClaudeNotch.app"
BIN="build/ClaudeNotch"

mkdir -p build
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.0 -sdk "$(xcrun --show-sdk-path)" \
  Sources/ClaudeNotch/*.swift -o "$BIN"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
cp Support/Info.plist "$APP/Contents/Info.plist"

"$BIN" --iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"
