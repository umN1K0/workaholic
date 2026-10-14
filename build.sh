#!/usr/bin/env bash
# Builds Workaholic.app with the Command Line Tools only: swiftc plus a hand-assembled,
# ad-hoc signed bundle. Never touches sudo or sleep settings.
#
#   ./build.sh                 # -> ./build/Workaholic.app
#   ./build.sh /Applications   # -> /Applications/Workaholic.app
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-build}"
APP="$DEST/Workaholic.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  Workaholic.swift -o "$APP/Contents/MacOS/Workaholic"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
