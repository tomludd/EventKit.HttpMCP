#!/bin/zsh
# Builds "EventKit MCP.app" into ./build.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --install  also copy to ~/Applications and (re)start it
#
# CODESIGN_IDENTITY selects the signing identity (default "-" = ad-hoc). With ad-hoc signing macOS
# may ask for calendar access again after each rebuild; a stable identity avoids that.
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="EventKit MCP"
APP="$ROOT/build/$APP_NAME.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

# SwiftUI macros need the full Xcode toolchain, not just the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT"
swift build -c release --product EventKitMCP
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EventKitMCP" "$APP/Contents/MacOS/EventKitMCP"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier local.eventkit.httpmcp "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  osascript -e "tell application id \"local.eventkit.httpmcp\" to quit" >/dev/null 2>&1 || true
  pkill -x EventKitMCP >/dev/null 2>&1 || true
  sleep 1
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and started $DEST"
fi
