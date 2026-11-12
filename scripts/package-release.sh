#!/bin/zsh
# Builds a universal (Apple silicon + Intel) "EventKit MCP.app" and zips it for a GitHub release:
#   scripts/package-release.sh      -> build/EventKit-MCP-<version>.zip
# The app is ad-hoc signed and not notarized; see "Manual install" in README.md.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/EventKit MCP.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/build/EventKit-MCP-$VERSION.zip"

UNIVERSAL=1 "$ROOT/scripts/build-app.sh"
lipo -info "$APP/Contents/MacOS/EventKitMCP"
codesign --verify "$APP"

rm -f "$ZIP"
# ditto keeps the bundle structure and signature intact (plain zip can break both).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
