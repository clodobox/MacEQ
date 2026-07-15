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
BUILD_DIR="$PROJECT_DIR/.build/$CONFIGURATION"
APP_DIR="$PROJECT_DIR/build/MacEQ.app"

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/MacEQ" "$APP_DIR/Contents/MacOS/MacEQ"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --sign - "$APP_DIR"

echo "Built and ad-hoc signed: $APP_DIR"
echo "Run with: open '$APP_DIR'"
