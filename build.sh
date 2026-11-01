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
cp Resources/* "$APP_BUNDLE/Contents/Resources/"

echo "→ ad-hoc signing"
codesign --force --deep --sign - "$APP_BUNDLE"

if [[ "${1:-}" == "--zip" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
  ZIP="$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
  echo "✓ Built $ZIP"
fi

echo "✓ Built $APP_BUNDLE"
echo "  Run:    open $APP_BUNDLE"
echo "  Install: cp -R $APP_BUNDLE /Applications/"
