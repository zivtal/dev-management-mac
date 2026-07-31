#!/usr/bin/env bash
# Builds an ad-hoc signed DMG, replaces /Applications/Development Management.app,
# stops the old process, and launches the newly installed version.
set -euo pipefail

PROJECT_NAME="DevReinstaller"
APP_NAME="Development Management"
DISPLAY_NAME="Development Management"
SCHEME="DevReinstaller"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build-dmg"
DERIVED="$BUILD_DIR/DerivedData"
STAGING="$BUILD_DIR/dmg-staging"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/${PROJECT_NAME}.dmg"
INSTALL_PATH="/Applications/${APP_NAME}.app"
INSTALL_TMP="/Applications/.${APP_NAME}.installing-$$.app"
LEGACY_INSTALL_PATH="/Applications/DevReinstaller.app"
MOUNT_POINT=""
DMG_ATTACHED=0

cleanup() {
  local exit_code=$?
  if [[ "$DMG_ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  [[ -z "$MOUNT_POINT" ]] || rm -rf "$MOUNT_POINT"
  rm -rf "$INSTALL_TMP"
  exit "$exit_code"
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: '$1' not found${2:+ — $2}" >&2
    exit 1
  }
}

stop_process() {
  local process_name="$1"
  local attempt
  pgrep -x "$process_name" >/dev/null 2>&1 || return 0
  killall "$process_name" 2>/dev/null || true
  for ((attempt = 0; attempt < 30; attempt++)); do
    pgrep -x "$process_name" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  echo "warning: $process_name did not exit; forcing it to stop" >&2
  killall -9 "$process_name"
}

require xcodegen "install with: brew install xcodegen"
require xcodebuild "install Xcode command line tools"
require hdiutil
require codesign
require ditto
require killall
require open
require pgrep

cd "$ROOT"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Clean Release build"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$ROOT/${PROJECT_NAME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  clean build

APP_PATH="$DERIVED/Build/Products/Release/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || { echo "error: built app not found at $APP_PATH" >&2; exit 1; }

echo "==> Staging DMG contents"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST_DIR"
ditto "$APP_PATH" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating compressed DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ ! -x "$LSREGISTER" ]] || "$LSREGISTER" -u "$APP_PATH" 2>/dev/null || true
rm -rf "$BUILD_DIR"

echo "==> Verifying DMG"
hdiutil verify "$DMG_PATH" >/dev/null

echo "==> Closing running ${DISPLAY_NAME}"
stop_process "$APP_NAME"
stop_process "$PROJECT_NAME"

echo "==> Installing into /Applications"
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-dmg.XXXXXX")"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=1

rm -rf "$INSTALL_TMP"
ditto "$MOUNT_POINT/${APP_NAME}.app" "$INSTALL_TMP"
codesign --verify --deep --strict "$INSTALL_TMP"
[[ ! -d "$LEGACY_INSTALL_PATH" ]] || "$LSREGISTER" -u "$LEGACY_INSTALL_PATH" 2>/dev/null || true
rm -rf "$INSTALL_PATH" "$LEGACY_INSTALL_PATH"
mv "$INSTALL_TMP" "$INSTALL_PATH"
[[ ! -x "$LSREGISTER" ]] || "$LSREGISTER" -f "$INSTALL_PATH" 2>/dev/null || true

hdiutil detach "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=0
rm -rf "$MOUNT_POINT"
MOUNT_POINT=""

echo "==> Launching ${DISPLAY_NAME}"
open "$INSTALL_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_PATH/Contents/Info.plist")"
SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "✅ Built $DMG_PATH ($SIZE)"
echo "✅ Installed and launched ${DISPLAY_NAME} $VERSION (build $BUILD)"
