#!/bin/bash
# Builds Vendor/IDevice.xcframework, the bridge the iOS app uses to talk to the
# device's own developer services.
#
# The framework is not committed: it weighs about 170 MB, and it is entirely
# reproducible from source. Run this once after cloning.
#
# Requires Rust. Install it with:  brew install rustup && rustup default stable
set -euo pipefail

REPO="https://github.com/jkcoxson/idevice.git"
WORK="${TMPDIR:-/tmp}/anole-idevice"
cd "$(dirname "$0")/.."
ROOT="$PWD"

command -v cargo >/dev/null 2>&1 || {
    echo "cargo not found. Install Rust: brew install rustup && rustup default stable"
    exit 1
}

echo "==> Fetching idevice"
rm -rf "$WORK"
git clone --depth 1 "$REPO" "$WORK"

echo "==> Adding the iOS target"
rustup target add aarch64-apple-ios

echo "==> Building for arm64 iOS (a few minutes)"
cd "$WORK/ffi"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
IPHONEOS_DEPLOYMENT_TARGET=17.0 \
cargo build --release --target aarch64-apple-ios

echo "==> Assembling the xcframework"
HEADERS="$WORK/headers"
mkdir -p "$HEADERS"
cp "$WORK/ffi/idevice.h" "$HEADERS/"
cp "$WORK/ffi/plist.h" "$HEADERS/" 2>/dev/null || true
cat > "$HEADERS/module.modulemap" <<'MODULEMAP'
module IDeviceFFI {
    header "idevice.h"
    export *
}
MODULEMAP

rm -rf "$ROOT/Vendor/IDevice.xcframework"
mkdir -p "$ROOT/Vendor"
xcodebuild -create-xcframework \
    -library "$WORK/target/aarch64-apple-ios/release/libidevice_ffi.a" \
    -headers "$HEADERS" \
    -output "$ROOT/Vendor/IDevice.xcframework"

echo "==> Done: Vendor/IDevice.xcframework"
