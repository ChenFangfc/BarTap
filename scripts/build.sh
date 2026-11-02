#!/bin/bash
# Builds dist/BarTap.app (universal) and dist/BarTap-<version>.dmg.
# Gates: localization complete, unit tests pass, and the binary links none of the APIs that can
# fake input, move the pointer or swallow clicks.
#
#   scripts/build.sh             # dist/BarTap.app + DMG
#   scripts/build.sh --install   # ...then replace /Applications/BarTap.app and drop the dist copy,
#                                #    so exactly one BarTap exists on the Mac
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1
VERSION="${VERSION:-1.4.2}"
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

echo "==> Safety check: no event taps, pointer warps, input suppression or keyboard/scroll events"
# Mouse events are allowed for one job only: moving icons when the user clicks Apply in
# Settings › Layout (IconMover.swift). Everything that could take the mouse away from the user stays out.
FORBIDDEN='_CGWarpMouseCursorPosition|_CGEventPostToPSN|_CGEventTapCreate|_CGEventTapCreateForPid|_CGEventTapCreateForPSN|_CGAssociateMouseAndMouseCursorPosition|_CGEventSourceSetLocalEventsSuppressionInterval|_CGEventSourceSetLocalEventsFilterDuringSuppressionState|_CGSetLocalEventsSuppressionInterval|_CGEventCreateKeyboardEvent|_CGEventCreateScrollWheelEvent|_CGEventCreateScrollWheelEvent2|_CGPostMouseEvent|_CGPostKeyboardEvent|_CGPostScrollWheelEvent|_CGDisplayMoveCursorToPoint|_AXUIElementPostKeyboardEvent|_SLSPostEvent|_CGSPostEvent'
for arch in arm64 x86_64; do
    if nm -u -arch "$arch" "$WORK/BarTap" | grep -E "^($FORBIDDEN)\$"; then
        echo "FAIL: forbidden symbol linked ($arch)"; exit 1
    fi
done
# No sneaking them in through dlsym either.
if strings -a "$WORK/BarTap" | grep -E "CGEventTapCreate|CGAssociateMouse|CGWarpMouse|SuppressionInterval|CGPostKeyboard|CGEventCreateKeyboard"; then
    echo "FAIL: forbidden API name found in binary strings"; exit 1
fi
# Mouse events and pointer moves come from one file, used only by Apply.
if grep -rlE "CGEvent\(mouseEventSource|\.post\(tap|CGDisplayHideCursor" Sources | grep -v "Sources/BarTap/IconMover.swift"; then
    echo "FAIL: mouse events created outside IconMover.swift"; exit 1
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
cp Resources/ai-prices.json "$APP/Contents/Resources/ai-prices.json"   # bundled model prices (LiteLLM snapshot)
echo '"CFBundleDisplayName" = "BarTap";' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
echo '"CFBundleDisplayName" = "BarTap";' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
# The Bluetooth permission prompt (Connect / Disconnect in the Bluetooth stats menu), in Chinese.
echo '"NSBluetoothAlwaysUsageDescription" = "只有在你点按 BarTap 蓝牙菜单中的「连接」或「断开」时，BarTap 才会使用蓝牙来连接或断开那台已配对的设备。";' >> "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

# A stable identity keeps privacy grants (Accessibility, Screen Recording) across rebuilds: macOS
# ties them to the signature, and an ad-hoc signature is just this exact binary's hash.
KC="$HOME/Library/Keychains/bartap-signing.keychain-db"
if [ -f "$KC" ] && [ -f .signing/keychain-password ]; then
    echo "==> Sign (BarTap self-signed identity, hardened runtime)"
    security unlock-keychain -p "$(cat .signing/keychain-password)" "$KC"
    if ! security list-keychains -d user | grep -q bartap-signing; then
        # shellcheck disable=SC2046
        security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
    fi
    IDENTITY="$(security find-identity -p codesigning "$KC" | awk '/BarTap Self-Signed Code Signing/ {print $2; exit}')"
    codesign --force --options runtime --timestamp=none --keychain "$KC" --sign "$IDENTITY" "$APP"
else
    echo "==> Sign (ad-hoc, hardened runtime; run scripts/make_signing_identity.sh to keep privacy grants across builds)"
    codesign --force --options runtime --timestamp=none --sign - "$APP"
fi
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

if [ "$INSTALL" = "1" ]; then
    echo "==> Install"
    pkill -x BarTap 2>/dev/null || true
    for _ in $(seq 1 50); do pgrep -x BarTap >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/BarTap.app
    ditto "$APP" /Applications/BarTap.app
    # Exactly one BarTap on the Mac: drop the staged copy and its LaunchServices record.
    LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSR" -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
    "$LSR" -f /Applications/BarTap.app
    open -g /Applications/BarTap.app
    echo "    installed /Applications/BarTap.app"
fi
echo "==> Done"
