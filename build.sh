#!/bin/bash
# Build Wattmeter.app bundle
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Wattmeter.app"
BIN="$APP/Contents/MacOS/Wattmeter"
FRAMEWORKS="$APP/Contents/Frameworks"

mkdir -p "$APP/Contents/MacOS" "$FRAMEWORKS"
cp -f .build/release/Wattmeter "$BIN"

# Embed Sparkle.framework
SPARKLE_SRC="vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
    echo "missing $SPARKLE_SRC — vendor checked out?"
    exit 1
fi
rm -rf "$FRAMEWORKS/Sparkle.framework"
cp -R "$SPARKLE_SRC" "$FRAMEWORKS/Sparkle.framework"

# Refresh resources
if [[ -f AppIcon.icns ]]; then
    mkdir -p "$APP/Contents/Resources"
    cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ship the SPM resource bundle (Bundle.module — contains pricing.json etc.)
SPM_BUNDLE=".build/release/Wattmeter_Wattmeter.bundle"
if [[ -d "$SPM_BUNDLE" ]]; then
    mkdir -p "$APP/Contents/Resources"
    rm -rf "$APP/Contents/Resources/Wattmeter_Wattmeter.bundle"
    cp -R "$SPM_BUNDLE" "$APP/Contents/Resources/Wattmeter_Wattmeter.bundle"
fi

# Strip symbols from final binary for smaller distribution
strip -x -S "$BIN" 2>/dev/null || true

echo "Built: $(pwd)/$APP ($(du -h "$BIN" | cut -f1))"
echo "Open with: open $(pwd)/$APP"
