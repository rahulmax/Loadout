#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Loadout"
APP_BUNDLE="$APP_NAME.app"

echo "→ swift build -c release"
swift build -c release

echo "→ assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp Info.plist "$APP_BUNDLE/Contents/"

echo "✓ Built $APP_BUNDLE"
echo "  Run:    open $APP_BUNDLE"
echo "  Install: cp -R $APP_BUNDLE /Applications/"
