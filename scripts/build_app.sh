#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building PikminSend..."
swift build --disable-sandbox -c debug

BIN_PATH=".build/debug/PikminSend"
APP_DIR="build/PikminSend.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/PikminSend"
cp "Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -d "Resources" ]; then
    cp -R Resources/. "$APP_DIR/Contents/Resources/"
fi

codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run with: open $APP_DIR"
