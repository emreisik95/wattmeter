#!/bin/bash
# Build Wattmeter.app bundle
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Wattmeter.app"
BIN="$APP/Contents/MacOS/Wattmeter"
mkdir -p "$APP/Contents/MacOS"
cp -f .build/release/Wattmeter "$BIN"

# Refresh resources
if [[ -f AppIcon.icns ]]; then
    mkdir -p "$APP/Contents/Resources"
    cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Strip symbols from final binary for smaller distribution
strip -x -S "$BIN" 2>/dev/null || true

echo "Built: $(pwd)/$APP ($(du -h "$BIN" | cut -f1))"
echo "Open with: open $(pwd)/$APP"
