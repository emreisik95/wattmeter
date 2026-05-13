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
mkdir -p "$APP/Contents/Resources"
if [[ -f AppIcon.icns ]]; then
    cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# pricing.json — loaded by PricingLoader via Bundle.main.
# Copied directly to Contents/Resources/ so it works in installed .app
# (avoids SPM's Bundle.module accessor which expects a bundle layout that
# doesn't survive being wrapped in a .app).
if [[ -f Sources/Wattmeter/Resources/pricing.json ]]; then
    cp -f Sources/Wattmeter/Resources/pricing.json "$APP/Contents/Resources/pricing.json"
fi

# Drop any stale SPM resource bundle from previous builds.
rm -rf "$APP/Contents/Resources/Wattmeter_Wattmeter.bundle" "$APP/Wattmeter_Wattmeter.bundle"

# Strip symbols from final binary for smaller distribution
strip -x -S "$BIN" 2>/dev/null || true

echo "Built: $(pwd)/$APP ($(du -h "$BIN" | cut -f1))"
echo "Open with: open $(pwd)/$APP"
