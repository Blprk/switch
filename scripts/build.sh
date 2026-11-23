#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Switch Everywhere"
EXECUTABLE="SwitchEverywhere"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
SRC="src/main.swift"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -Osize -o "$APP_DIR/Contents/MacOS/$EXECUTABLE" "$SRC" \
  -framework Cocoa -framework IOKit -Xlinker -dead_strip
strip -x "$APP_DIR/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp SwitchEverywhere.sdef "$APP_DIR/Contents/Resources/SwitchEverywhere.sdef"

echo "Built $APP_DIR"
