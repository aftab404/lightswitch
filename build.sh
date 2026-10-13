#!/bin/bash
# Builds Lightswitch.app into ./build. `./build.sh install` also copies it to ~/Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lightswitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with: swift icon/make-icon.swift

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/Lightswitch" \
    Sources/*.swift

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time.
IDENTITY="-"
if security find-identity -p codesigning | grep -q '"Lightswitch Dev"'; then
    IDENTITY="Lightswitch Dev"
fi
codesign --force --sign "$IDENTITY" --identifier com.aftabkhan.lightswitch "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Lightswitch || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Lightswitch.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Lightswitch.app
    echo "Installed to ~/Applications/Lightswitch.app"
fi
