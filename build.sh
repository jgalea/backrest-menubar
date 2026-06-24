#!/bin/bash
# Build Backrest Status.app — a native SwiftUI menu bar app.
set -euo pipefail
cd "$(dirname "$0")"

APP="Backrest Status.app"
BIN="BackrestStatus"

echo "compiling…"
swiftc -parse-as-library -O main.swift -o "$BIN" \
  -framework SwiftUI -framework AppKit -target arm64-apple-macos14.0

echo "assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -f "$BIN"

# ad-hoc sign so it runs locally
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
