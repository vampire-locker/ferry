#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
BUILD_DIR="${FERRY_BUILD_DIR:-$FERRY_ROOT/.build}"
DIST_DIR="${FERRY_DIST_DIR:-$FERRY_ROOT/dist}"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
swift_options=(-c release --disable-sandbox)
if [[ -n "${FERRY_BUILD_DIR:-}" ]]; then
    swift_options+=(--scratch-path "$BUILD_DIR/swift")
fi
"$FERRY_ROOT/scripts/prepare-deps.sh"
cd "$FERRY_ROOT/engine"
go build -mod=vendor -trimpath -ldflags="-s -w" -o "$BUILD_DIR/ferry-engine" ./cmd/ferry-engine
cd "$FERRY_ROOT"
swift build "${swift_options[@]}"
BIN_DIR="$(swift build "${swift_options[@]}" --show-bin-path)"
APP="$DIST_DIR/Ferry.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
# Replace executable inodes instead of modifying previously signed files in
# place, which can leave macOS validating against cached code-signing pages.
replace_binary() {
    local source="$1" target="$2"
    cp "$source" "$target.new"
    chmod 755 "$target.new"
    mv -f "$target.new" "$target"
}
replace_binary "$BIN_DIR/Ferry" "$APP/Contents/MacOS/Ferry"
replace_binary "$BUILD_DIR/ferry-engine" "$APP/Contents/Helpers/ferry-engine"
replace_binary "$FERRY_ROOT/.build/deps/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cp "$FERRY_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
ditto "$BIN_DIR/Ferry_FerryCore.bundle" "$APP/Contents/Resources/Ferry_FerryCore.bundle"
for locale in "$FERRY_ROOT/Resources/Localizations/"*.lproj; do
    ditto "$locale" "$APP/Contents/Resources/$(basename "$locale")"
done
install -m 644 "$FERRY_ROOT/LICENSE" "$FERRY_ROOT/ThirdPartyNotices/"* "$APP/Contents/Resources/Licenses/"
if [[ -f "$FERRY_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$FERRY_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change "$FERRY_ROOT/.build/deps/lib/libusb-1.0.0.dylib" '@executable_path/../Frameworks/libusb-1.0.0.dylib' "$APP/Contents/Helpers/ferry-engine"
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
# com.apple.vm.device-access is restricted: an ad-hoc signature can pass
# codesign --verify yet be killed by AMFI before main. Keep local builds free
# of restricted entitlements; an approved signing/provisioning flow is needed
# before device capture can be enabled in a distributable build.
codesign --force --sign - --identifier local.ferry.app.engine "$APP/Contents/Helpers/ferry-engine"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ARCH="$(uname -m)"
ARCH_LABEL=apple-silicon
[[ "$ARCH" == arm64 ]] || ARCH_LABEL=intel
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$DIST_DIR/Ferry-$VERSION-macos-$ARCH_LABEL-local.zip"
# Source and notices accompany the dynamically linked LGPL library.
cp "$FERRY_ROOT/.cache/libusb-1.0.29.tar.bz2" "$DIST_DIR/libusb-1.0.29-source.tar.bz2"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP")" libusb-1.0.29-source.tar.bz2 > SHA256SUMS)
echo "已生成 $APP"
echo "已生成 ${ZIP}（本地签名，未公证）"
