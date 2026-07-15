#!/bin/bash
# Packages build/MacEQ.app into build/MacEQ.dmg — the drag-to-Applications
# installer window users expect on macOS.
#
# Run scripts/build-app.sh first. Requires Finder automation permission, since
# icon positions and the window backdrop live in the volume's .DS_Store and
# only Finder can write them.
#
# The backdrop is generated, not hand-drawn. To change it, edit
# scripts/generate-dmg-background.swift and regenerate:
#
#   swiftc -O scripts/generate-dmg-background.swift -o /tmp/dmgbg
#   /tmp/dmgbg /tmp/bg-1x.png 1
#   /tmp/dmgbg /tmp/bg-2x.png 2
#   tiffutil -cathidpicheck /tmp/bg-1x.png /tmp/bg-2x.png \
#       -out Resources/dmg-background.tiff
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_DIR/build/MacEQ.app"
VOLUME_NAME="MacEQ"
STAGING="$PROJECT_DIR/build/dmg-staging"
TEMP_DMG="$PROJECT_DIR/build/MacEQ-temp.dmg"
FINAL_DMG="$PROJECT_DIR/build/MacEQ.dmg"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/build-app.sh first" >&2
    exit 1
fi

# A stale mount from an interrupted run would silently poison the next build.
if [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi

rm -rf "$STAGING" "$TEMP_DMG" "$FINAL_DMG"
mkdir -p "$STAGING/.background"

cp -R "$APP" "$STAGING/MacEQ.app"
ln -s /Applications "$STAGING/Applications"
cp "$PROJECT_DIR/Resources/dmg-background.tiff" "$STAGING/.background/background.tiff"

# Read-write image first: Finder has to be able to write the .DS_Store into it.
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$TEMP_DMG" >/dev/null

hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen >/dev/null
trap 'hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true' EXIT

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 600x400 content area; the backdrop is drawn to match exactly.
        set the bounds of container window to {240, 140, 840, 540}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 12
        set background picture of options to file ".background:background.tiff"
        set position of item "MacEQ.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        -- Close and reopen before updating: Finder only flushes window bounds
        -- to the volume's .DS_Store on close, so updating a still-open window
        -- persists the icon layout but silently loses the size.
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
trap - EXIT

# Compress to a read-only image for distribution.
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -rf "$STAGING" "$TEMP_DMG"

echo "Built: $FINAL_DMG ($(du -h "$FINAL_DMG" | cut -f1))"
