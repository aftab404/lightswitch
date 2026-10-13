#!/bin/bash
# Builds Lightswitch.app into ./build.
#   ./build.sh           build for this Mac
#   ./build.sh install   build, copy to ~/Applications and (re)launch
#   ./build.sh dmg       build a universal (Apple silicon + Intel) app and package build/Lightswitch.dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/Lightswitch.app
if [[ "$MODE" == "dmg" ]]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with: swift icon/make-icon.swift

SLICES=()
for ARCH in "${ARCHS[@]}"; do
    swiftc -O -swift-version 5 \
        -target "$ARCH-apple-macos14.0" \
        -o "build/Lightswitch-$ARCH" \
        Sources/*.swift
    SLICES+=("build/Lightswitch-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Lightswitch"
rm -f "${SLICES[@]}"

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time.
# Release builds are always ad-hoc: a self-signed certificate means nothing on other Macs.
IDENTITY="-"
if [[ "$MODE" != "dmg" ]] && security find-identity -p codesigning | grep -q '"Lightswitch Dev"'; then
    IDENTITY="Lightswitch Dev"
fi
codesign --force --sign "$IDENTITY" --identifier com.aftabkhan.lightswitch "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Lightswitch"))"

case "$MODE" in
install)
    pkill -x Lightswitch || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Lightswitch.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Lightswitch.app
    echo "Installed to ~/Applications/Lightswitch.app"
    ;;
dmg)
    DMG="build/Lightswitch.dmg" # fixed name so releases/latest/download/Lightswitch.dmg always works
    STAGING=$(mktemp -d)
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    cp icon/AppIcon.icns "$STAGING/.VolumeIcon.icns"
    SetFile -a C "$STAGING" # use .VolumeIcon.icns as the mounted disk's icon
    rm -f "$DMG"
    hdiutil create -volname "Lightswitch" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGING"
    echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
    ;;
esac
