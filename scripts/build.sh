#!/bin/bash
# Builds dist/BarTap.app (universal) and dist/BarTap-<version>.dmg.
# Gates: localization complete, unit tests pass, and the binary links none of the APIs that can
# fake input, move the pointer or swallow clicks.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
DIST=dist
APP="$DIST/BarTap.app"
WORK=.build/package

echo "==> Localization"
python3 -I scripts/check_l10n.py

# Runs a build step, shows only diagnostics, and aborts the whole build if it fails.
run_build() {
    local log
    log="$(mktemp)"
    if ! "$@" >"$log" 2>&1; then
        grep -E "error|warning: " "$log" || tail -20 "$log"
        rm -f "$log"
        echo "FAIL: $*"; exit 1
    fi
    grep -E "warning: " "$log" || true
    rm -f "$log"
}

echo "==> Unit tests"
run_build swift build --product BarTapTests
.build/debug/BarTapTests | tail -1

echo "==> Release build"
BINS=()
for arch in arm64 x86_64; do
    run_build swift build -c release --product BarTap --triple "$arch-apple-macosx13.0" --build-path ".build/$arch"
    BINS+=("$(swift build -c release --triple "$arch-apple-macosx13.0" --build-path ".build/$arch" --show-bin-path)/BarTap")
done
mkdir -p "$WORK"
lipo -create -output "$WORK/BarTap" "${BINS[@]}"
lipo -info "$WORK/BarTap"

echo "==> Safety check: no input-synthesis / pointer / event-tap APIs"
FORBIDDEN='_CGEventPost|_CGEventPostToPid|_CGEventPostToPSN|_CGEventTapCreate|_CGEventTapCreateForPid|_CGEventTapCreateForPSN|_CGWarpMouseCursorPosition|_CGAssociateMouseAndMouseCursorPosition|_CGEventSourceSetLocalEventsSuppressionInterval|_CGEventSourceSetLocalEventsFilterDuringSuppressionState|_CGSetLocalEventsSuppressionInterval|_CGEventCreateMouseEvent|_CGEventCreateKeyboardEvent|_CGEventCreateScrollWheelEvent|_CGEventCreateScrollWheelEvent2|_CGPostMouseEvent|_CGPostKeyboardEvent|_CGPostScrollWheelEvent|_CGDisplayHideCursor|_CGDisplayMoveCursorToPoint|_AXUIElementPostKeyboardEvent|_SLSPostEvent|_CGSPostEvent'
for arch in arm64 x86_64; do
    if nm -u -arch "$arch" "$WORK/BarTap" | grep -E "^($FORBIDDEN)\$"; then
        echo "FAIL: forbidden symbol linked ($arch)"; exit 1
    fi
done
# No sneaking them in through dlsym either.
if strings -a "$WORK/BarTap" | grep -E "CGEventPost|CGWarpMouse|CGEventTapCreate|CGAssociateMouse|SuppressionInterval"; then
    echo "FAIL: forbidden API name found in binary strings"; exit 1
fi
echo "    ok"

echo "==> Icon"
if [ ! -f "$WORK/AppIcon.icns" ] || [ assets/logo/bartap-icon.svg -nt "$WORK/AppIcon.icns" ] || [ scripts/make_icon.swift -nt "$WORK/AppIcon.icns" ]; then
    rm -rf "$WORK/AppIcon.iconset"
    swift scripts/make_icon.swift assets/logo/bartap-icon.svg "$WORK/AppIcon.iconset" >/dev/null
    iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"
fi

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$WORK/BarTap" "$APP/Contents/MacOS/BarTap"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
echo '"CFBundleDisplayName" = "BarTap";' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
echo '"CFBundleDisplayName" = "BarTap";' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

echo "==> Sign (ad-hoc, hardened runtime)"
codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [ "${SKIP_DMG:-0}" != "1" ]; then
    echo "==> DMG"
    STAGE="$WORK/dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp docs/INSTALL.txt "$STAGE/安装说明 - Install.txt"
    DMG="$DIST/BarTap-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -quiet -volname "BarTap $VERSION" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG"
    hdiutil verify -quiet "$DMG"
    echo "    $DMG ($(du -h "$DMG" | cut -f1))"
fi
du -sh "$APP"
echo "==> Done"
