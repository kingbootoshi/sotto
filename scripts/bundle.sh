#!/bin/bash
# Builds Sotto.app from the SwiftPM binary and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP=".build/Sotto.app"
[ -e "$APP" ] && trash "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sotto "$APP/Contents/MacOS/Sotto"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Stable identity keeps TCC grants (Microphone/Accessibility) across
# rebuilds: macOS keys grants off the signature's designated requirement.
# Falls back to ad-hoc (grants reset every install) if the cert is gone.
if security find-identity -v -p codesigning | grep -q "Sotto Dev Signing"; then
  codesign --force --deep -s "Sotto Dev Signing" "$APP"
else
  echo "WARNING: 'Sotto Dev Signing' identity missing - ad-hoc signing, grants will reset"
  codesign --force --deep -s - "$APP"
fi

[ -e /Applications/Sotto.app ] && trash /Applications/Sotto.app
cp -R "$APP" /Applications/Sotto.app
echo "Installed /Applications/Sotto.app"
