#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
VERSION=1.0.29
SHA256=5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
ARCHIVE="$FERRY_ROOT/.cache/libusb-$VERSION.tar.bz2"
PREFIX="$FERRY_ROOT/.build/deps"
if [[ -f "$PREFIX/lib/pkgconfig/libusb-1.0.pc" ]] && pkg-config --exists libusb-1.0; then
    actual_prefix="$(pkg-config --variable=prefix libusb-1.0)"
    if [[ "$actual_prefix" == "$PREFIX" && -f "$PREFIX/lib/libusb-1.0.0.dylib" ]]; then
        exit 0
    fi
fi
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 "https://github.com/libusb/libusb/releases/download/v$VERSION/libusb-$VERSION.tar.bz2" -o "$ARCHIVE"
fi
actual_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$SHA256" ]] || { echo 'libusb 源码校验失败' >&2; exit 1; }
tar -xjf "$ARCHIVE" -C "$FERRY_ROOT/.cache"
cd "$FERRY_ROOT/.cache/libusb-$VERSION"
./configure --prefix="$PREFIX" --disable-static --disable-tests-build --disable-examples-build CFLAGS="-O2 -mmacosx-version-min=14.0"
make -j4
make install
