#!/usr/bin/env bash
set -euo pipefail

APP_NAME="KeepAwake"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
SRC="src/main.swift"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -Osize -o "$APP_DIR/Contents/MacOS/$APP_NAME" "$SRC" \
  -framework Cocoa -framework IOKit -Xlinker -dead_strip
strip -x "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp KeepAwake.sdef "$APP_DIR/Contents/Resources/KeepAwake.sdef"

echo "Built $APP_DIR"
