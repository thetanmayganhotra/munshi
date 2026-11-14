#!/bin/zsh
# Builds Munshi.app into ./build (no Xcode needed, just Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Munshi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Munshi"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Munshi.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
