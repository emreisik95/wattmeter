#!/bin/bash
# Build pretty DMG with custom background and forced Applications icon.
# Uses RW mount + AppleScript to copy /Applications system icon onto the symlink.
set -euo pipefail

cd "$(dirname "$0")/.."

VOL="Wattmeter"
APP="Wattmeter.app"
BG="dmg_bg.png"
TMP_DMG="$(mktemp -t wm_dmg).dmg"
OUT="Wattmeter.dmg"

if [[ ! -d "$APP" ]]; then echo "missing $APP"; exit 1; fi
if [[ ! -f "$BG"  ]]; then echo "missing $BG";  exit 1; fi

# Detach if mounted
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true

# Stage: src dir with app + symlink
SRC="$(mktemp -d)/dmg_src"
mkdir -p "$SRC/.background"
cp -R "$APP" "$SRC/"
ln -s /Applications "$SRC/Applications"
cp "$BG" "$SRC/.background/bg.png"

# Create RW DMG
rm -f "$TMP_DMG"
hdiutil create -srcfolder "$SRC" -volname "$VOL" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size 80m "$TMP_DMG" >/dev/null

# Mount RW
hdiutil attach "$TMP_DMG" -noautoopen >/dev/null

# Make .background hidden
chflags hidden "/Volumes/$VOL/.background" || true

# Configure view + force Applications icon via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 920, 600}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file ".background:bg.png"
    delay 0.5
    set position of item "Wattmeter.app" of container window to {210, 259}
    set position of item "Applications" of container window to {516, 259}
    delay 0.5
    update without registering applications
    delay 0.5
    close
    delay 0.5
  end tell
end tell
APPLESCRIPT

# Copy system /Applications folder icon onto the symlink (PyObjC reliable path)
/tmp/dmgvenv/bin/python3 "$(dirname "$0")/set_app_icon.py" "/Volumes/$VOL/Applications" || true

# Reopen window to refresh
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

sync
sleep 2

# Detach
hdiutil detach "/Volumes/$VOL" >/dev/null

# Convert to compressed RO
rm -f "$OUT"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$TMP_DMG"

echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
