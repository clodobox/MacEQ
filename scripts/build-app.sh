#!/bin/bash
# Builds the MacEQ SwiftPM executable and assembles a signed .app bundle.
#
# Usage: scripts/build-app.sh [debug|release]
#
# Ad-hoc signing note: the signature changes on every rebuild, so macOS re-asks
# for the system-audio-capture permission after each build. Reset a stuck grant
# with: tccutil reset SystemAudioCaptureRequests com.jatingrewal.maceq
set -euo pipefail

CONFIGURATION="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/MacEQ.app"

cd "$PROJECT_DIR"
# Universal (Apple Silicon + Intel) binary. `swift build --arch a --arch b`
# needs full Xcode's xcbuild; with Command Line Tools only, build each slice
# via its triple and merge with lipo.
swift build -c "$CONFIGURATION" --triple arm64-apple-macosx
swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create \
    "$PROJECT_DIR/.build/arm64-apple-macosx/$CONFIGURATION/MacEQ" \
    "$PROJECT_DIR/.build/x86_64-apple-macosx/$CONFIGURATION/MacEQ" \
    -output "$APP_DIR/Contents/MacOS/MacEQ"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP_DIR"

echo "Built and ad-hoc signed: $APP_DIR"
echo "Run with: open '$APP_DIR'"
