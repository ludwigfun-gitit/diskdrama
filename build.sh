#!/bin/bash
# build.sh — compile and optionally run DiskSentinel
# Usage:
#   ./build.sh          → build only
#   ./build.sh run      → build + launch
#   ./build.sh install  → build + copy to /Applications

set -e

APP_NAME="DiskSentinel"
SWIFT_FILE="DiskSentinel.swift"
BUILD_DIR=".build"
BINARY="$BUILD_DIR/$APP_NAME"

mkdir -p "$BUILD_DIR"

echo "▶ Compiling $APP_NAME…"
swiftc "$SWIFT_FILE" \
  -o "$BINARY" \
  -framework Cocoa \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macosx13.0

echo "✓ Built: $BINARY"

if [[ "$1" == "install" ]]; then
    INSTALL_PATH="/Applications/$APP_NAME.app/Contents/MacOS"
    mkdir -p "$INSTALL_PATH"
    cp "$BINARY" "$INSTALL_PATH/$APP_NAME"
    echo "✓ Installed to /Applications/$APP_NAME.app"
    echo "  Note: you may need to right-click → Open to bypass Gatekeeper on first launch."

elif [[ "$1" == "run" ]]; then
    echo "▶ Launching…"
    exec "$BINARY"
fi
