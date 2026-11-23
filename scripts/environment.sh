#!/bin/bash
# Sourced by build/test scripts; cache only inside this project.
set -euo pipefail
FERRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GOMODCACHE="$FERRY_ROOT/.cache/gomod"
export GOCACHE="$FERRY_ROOT/.cache/go-build"
export SWIFTPM_MODULECACHE_OVERRIDE="$FERRY_ROOT/.cache/swift-module"
export CLANG_MODULE_CACHE_PATH="$FERRY_ROOT/.cache/clang"
export PKG_CONFIG_PATH="$FERRY_ROOT/.build/deps/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CGO_ENABLED=1
export CGO_CFLAGS="-mmacosx-version-min=14.0"
export CGO_LDFLAGS="-mmacosx-version-min=14.0"
mkdir -p "$FERRY_ROOT/.cache" "$FERRY_ROOT/.build"
