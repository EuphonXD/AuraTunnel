#!/usr/bin/env sh

set -eu

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi
IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-16.0}
export IPHONEOS_DEPLOYMENT_TARGET

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CARGO_BIN=${CARGO_BIN:-/Users/silas/.cargo/bin/cargo}
ARTIFACT_DIR="$ROOT_DIR/Artifacts"
HEADER_DIR="$ROOT_DIR/include"
DEVICE_LIB="$ROOT_DIR/target/aarch64-apple-ios/release/libleaf.a"
SIMULATOR_LIB="$ROOT_DIR/target/aarch64-apple-ios-sim/release/libleaf.a"
OUTPUT="$ARTIFACT_DIR/leaf.xcframework"

cd "$ROOT_DIR"

"$CARGO_BIN" build \
    -p leaf-ffi \
    --release \
    --no-default-features \
    --features auratunnel-ios \
    --target aarch64-apple-ios

"$CARGO_BIN" build \
    -p leaf-ffi \
    --release \
    --no-default-features \
    --features auratunnel-ios \
    --target aarch64-apple-ios-sim

mkdir -p "$ARTIFACT_DIR"
if [ -d "$OUTPUT" ]; then
    rm -rf "$OUTPUT"
fi

xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" \
    -headers "$HEADER_DIR" \
    -library "$SIMULATOR_LIB" \
    -headers "$HEADER_DIR" \
    -output "$OUTPUT"
