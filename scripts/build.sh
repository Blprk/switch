#!/usr/bin/env bash
set -euo pipefail

# Builds "Switch Everywhere" as a universal (x86_64 + arm64) macOS app bundle.
#
#   Default:     install to ~/Applications/Switch Everywhere.app
#   Distribute:  ./scripts/build.sh --no-install --zip
#   Notarized:   SIGN_IDENTITY="Developer ID Application: ..." \
#                APPLE_ID=you@example.com APPLE_TEAM_ID=TEAMID \
#                APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#                ./scripts/build.sh --no-install --notarize

APP_NAME="Switch Everywhere"
EXECUTABLE="SwitchEverywhere"
BUNDLE_ID="com.user.keepawakeapp"
SRC="src/main.swift"
PLIST="Info.plist"
SDEF="SwitchEverywhere.sdef"
ARCHS=(x86_64 arm64)
DEPLOY_TARGET="11.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_DIR="$ROOT/.build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

DO_INSTALL=1
DO_ZIP=0
DO_SIGN=0
DO_NOTARIZE=0
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

usage() {
  cat <<'EOF'
Usage: scripts/build.sh [options]

Options:
  --install      Install the built app to ~/Applications (default)
  --no-install   Skip installing to ~/Applications
  --zip          Create dist/Switch Everywhere-<version>.zip
  --sign         Sign with SIGN_IDENTITY (Developer ID + hardened runtime)
  --notarize     Notarize and staple the zip (implies --sign and --zip)
  -h, --help     Show this help

Environment variables for signing / notarization:
  SIGN_IDENTITY      e.g. "Developer ID Application: Your Name (TEAMID)"
  NOTARY_PROFILE     keychain profile made with:
                       xcrun notarytool store-credentials <profile> ...
                     (used instead of the three variables below)
  APPLE_ID           Apple ID used for notarization
  APPLE_TEAM_ID      Apple Developer Team ID
  APPLE_APP_PASSWORD app-specific password for that Apple ID
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    --zip) DO_ZIP=1; shift ;;
    --sign) DO_SIGN=1; shift ;;
    --notarize) DO_NOTARIZE=1; DO_SIGN=1; DO_ZIP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -f "$SRC" ]] || die "missing $SRC"
[[ -f "$PLIST" ]] || die "missing $PLIST"
[[ -f "$SDEF" ]] || die "missing $SDEF"

if [[ "$DO_SIGN" == 1 && -z "$SIGN_IDENTITY" ]]; then
  die "SIGN_IDENTITY is required for signing (try --help)"
fi
if [[ "$DO_NOTARIZE" == 1 && -z "$NOTARY_PROFILE" ]]; then
  : "${APPLE_ID:?APPLE_ID is required for notarization (try --help)}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization (try --help)}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required for notarization (try --help)}"
fi

echo "==> Building universal binary (${ARCHS[*]})"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

for arch in "${ARCHS[@]}"; do
  echo "    compiling $arch"
  xcrun swiftc -Osize \
    -target "${arch}-apple-macosx${DEPLOY_TARGET}" \
    -sdk "$SDK" \
    -framework Cocoa -framework IOKit \
    -Xlinker -dead_strip \
    -o "$BUILD_DIR/${EXECUTABLE}-${arch}" "$SRC"
  strip -x "$BUILD_DIR/${EXECUTABLE}-${arch}" 2>/dev/null || true
done

lipo -create -output "$APP_DIR/Contents/MacOS/$EXECUTABLE" \
  "$BUILD_DIR/${EXECUTABLE}-x86_64" \
  "$BUILD_DIR/${EXECUTABLE}-arm64"

cp "$PLIST" "$APP_DIR/Contents/Info.plist"
cp "$SDEF" "$APP_DIR/Contents/Resources/SwitchEverywhere.sdef"

echo "    built ($(lipo -archs "$APP_DIR/Contents/MacOS/$EXECUTABLE"))"

if [[ "$DO_SIGN" == 1 ]]; then
  echo "==> Signing with $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

if [[ "$DO_ZIP" == 1 ]]; then
  echo "==> Creating $ZIP_PATH"
  mkdir -p "$DIST_DIR"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_DIR" "$ZIP_PATH"
fi

if [[ "$DO_NOTARIZE" == 1 ]]; then
  echo "==> Submitting for notarization (this can take a few minutes)"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
  fi
  echo "==> Stapling ticket and rebuilding zip"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_DIR" "$ZIP_PATH"
fi

if [[ "$DO_INSTALL" == 1 ]]; then
  DEST="$HOME/Applications/${APP_NAME}.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP_DIR" "$DEST"
  echo "==> Installed $DEST"
fi

echo "==> Done"
[[ "$DO_ZIP" == 1 ]] && echo "    Distribution zip: $ZIP_PATH"
