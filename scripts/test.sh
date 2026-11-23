#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
TEST_BUILD_DIR="${FERRY_TEST_BUILD_DIR:-$FERRY_ROOT/.build}"
mkdir -p "$TEST_BUILD_DIR"
"$FERRY_ROOT/scripts/prepare-deps.sh"
cd "$FERRY_ROOT/engine"
go test -mod=vendor -race ./...
go test -mod=vendor -race github.com/ganeshrvel/go-mtpfs/mtp
go vet -mod=vendor ./...
go build -mod=vendor -o "$TEST_BUILD_DIR/ferry-engine" ./cmd/ferry-engine
cd "$FERRY_ROOT"
swift_options=(--disable-sandbox)
if [[ -n "${FERRY_TEST_BUILD_DIR:-}" ]]; then
    swift_options+=(--scratch-path "$TEST_BUILD_DIR/swift")
fi
FERRY_TEST_ENGINE="$TEST_BUILD_DIR/ferry-engine" swift test "${swift_options[@]}"
python3 scripts/smoke.py "$TEST_BUILD_DIR/ferry-engine"
