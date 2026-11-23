#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
ICONSET="$FERRY_ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$FERRY_ROOT/scripts/generate-icon.swift" "$FERRY_ROOT/.build/AppIcon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$FERRY_ROOT/.build/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$FERRY_ROOT/.build/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$FERRY_ROOT/Resources/AppIcon.icns"
