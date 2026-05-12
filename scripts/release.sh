#!/bin/bash
# One-shot release pipeline.
# Usage: ./scripts/release.sh 0.2.0
#
# Bumps version in Info.plist, builds, signs (including embedded
# Sparkle.framework), notarizes (via Keychain profile "wattmeter"),
# staples, creates a git tag, publishes a GitHub release with the DMG,
# signs the DMG with Sparkle EdDSA key (from Keychain), updates
# appcast.xml, and commits + pushes the appcast.
#
# Requires:
#   - Developer ID Application: Emre Isik (235UP83FJ4) cert in login Keychain
#   - notarytool Keychain profile "wattmeter"
#   - Sparkle EdDSA private key in Keychain (from generate_keys)
#   - gh CLI authenticated
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_MODE=0
if [[ "${1:-}" == "--dev" ]]; then
    DEV_MODE=1
    shift
fi

VERSION="${1:-}"
if [[ $DEV_MODE -eq 1 && -z "$VERSION" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Wattmeter.app/Contents/Info.plist")
fi
[[ -z "$VERSION" ]] && { echo "usage: $0 [--dev] <version>  (e.g. 0.2.0)"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }

TAG="v${VERSION}"
PROFILE="wattmeter"
IDENTITY="Developer ID Application: Emre Isik (235UP83FJ4)"
INFO_PLIST="Wattmeter.app/Contents/Info.plist"
SPARKLE_FW="Wattmeter.app/Contents/Frameworks/Sparkle.framework"
SIGN_UPDATE="vendor/sparkle/bin/sign_update"
DOWNLOAD_BASE="https://github.com/emreisik95/wattmeter/releases/download"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
fail() { echo -e "${RED}FAIL: $*${NC}" >&2; exit 1; }
ok()   { echo -e "${GRN}OK${NC}   $*"; }
step() { echo -e "${YEL}== $* ==${NC}"; }

# Preflight
if [[ $DEV_MODE -eq 0 ]]; then
    [[ -z "$(git status --porcelain)" ]] || fail "working tree dirty — commit/stash first"
    git rev-parse "$TAG" >/dev/null 2>&1 && fail "tag $TAG already exists"
    gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists on GitHub"
fi
[[ -x "$SIGN_UPDATE" ]] || fail "missing $SIGN_UPDATE"

# 1. Bump version (skip in dev mode — keep current)
if [[ $DEV_MODE -eq 0 ]]; then
    step "bump to $VERSION"
    BUILD_NUM=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST") + 1 ))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$INFO_PLIST"
    ok "version $VERSION build $BUILD_NUM"
else
    BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
    step "DEV build at $VERSION ($BUILD_NUM)"
fi

# 2. Build
step "build"
./build.sh >/dev/null
ok "bundle built"

# 3. Sign Sparkle framework (nested bottom-up) then app
step "sign Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW"
ok "framework signed"

step "sign app"
codesign --force --options runtime --timestamp --entitlements Wattmeter.entitlements \
    --sign "$IDENTITY" Wattmeter.app
codesign --verify --strict --deep Wattmeter.app
ok "app signed"

if [[ $DEV_MODE -eq 1 ]]; then
    step "DEV mode: app signed; skipping dmg/notarize/tag/release/appcast"
    echo
    echo -e "${GRN}== DEV BUILD COMPLETE ==${NC}"
    echo "Wattmeter.app ready for local smoke test."
    exit 0
fi

# 4. Build DMG
step "build dmg"
rm -f Wattmeter.dmg
bash scripts/build_dmg.sh >/dev/null
codesign --force --sign "$IDENTITY" --timestamp Wattmeter.dmg
ok "dmg signed"

# 5. Notarize via stored profile
step "notarize"
NOTARIZE_LOG=$(mktemp)
xcrun notarytool submit Wattmeter.dmg --keychain-profile "$PROFILE" --wait \
    | tee "$NOTARIZE_LOG"
grep -q "status: Accepted" "$NOTARIZE_LOG" || fail "notarization rejected"
rm -f "$NOTARIZE_LOG"
xcrun stapler staple Wattmeter.dmg
spctl -a -t open --context context:primary-signature -vv Wattmeter.dmg
ok "notarized + stapled"

# 6. Sparkle EdDSA-sign the DMG
step "Sparkle sign_update"
SIGN_OUTPUT=$("$SIGN_UPDATE" Wattmeter.dmg)
ED_SIG=$(echo "$SIGN_OUTPUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
LENGTH=$(echo "$SIGN_OUTPUT" | sed -E 's/.*length="([0-9]+)".*/\1/')
[[ -n "$ED_SIG" && -n "$LENGTH" ]] || fail "sign_update output unparseable: $SIGN_OUTPUT"
ok "EdDSA sig $ED_SIG"

# 7. Commit version bump + tag + push
step "commit + tag"
git add "$INFO_PLIST"
git commit -m "Release $TAG" >/dev/null
git tag "$TAG"
git push origin main "$TAG"
ok "pushed $TAG"

# 8. GitHub release
step "publish release"
NOTES_FILE=$(mktemp)
cat > "$NOTES_FILE" <<EOF
Wattmeter $TAG

Drag the DMG into /Applications. First launch: click **Connect to Claude limits**.

See full feature list and screenshots at the [README](https://github.com/emreisik95/wattmeter#readme).

**Signed + notarized.** Gatekeeper will accept it directly — no right-click bypass needed.

**Auto-updates** via Sparkle — Wattmeter checks once a day and prompts you to install.
EOF
gh release create "$TAG" Wattmeter.dmg --title "Wattmeter $TAG" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"
ok "release $TAG published"

# 9. Update appcast.xml + push
step "update appcast"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${TAG}/Wattmeter.dmg"
PUB_DATE=$(LC_ALL=en_US.UTF-8 date "+%a, %d %b %Y %H:%M:%S %z")

ITEM=$(cat <<EOF
        <item>
            <title>Wattmeter ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUM}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<p>See <a href="https://github.com/emreisik95/wattmeter/releases/tag/${TAG}">release notes</a>.</p>]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                sparkle:edSignature="${ED_SIG}"
                length="${LENGTH}"
                type="application/octet-stream" />
        </item>
EOF
)

if [[ ! -f appcast.xml ]]; then
cat > appcast.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Wattmeter</title>
        <link>https://github.com/emreisik95/wattmeter</link>
        <description>Wattmeter auto-update feed</description>
        <language>en</language>
${ITEM}
    </channel>
</rss>
EOF
else
    # Insert new item right after <channel> opening tag's description line.
    python3 - "$ITEM" <<'PY'
import sys, re, pathlib
item = sys.argv[1]
p = pathlib.Path("appcast.xml")
xml = p.read_text()
xml = re.sub(r"(<description>Wattmeter auto-update feed</description>\n)",
             r"\1" + item + "\n", xml, count=1)
p.write_text(xml)
PY
fi
git add appcast.xml
git commit -m "appcast: ${TAG}" >/dev/null
git push origin main
ok "appcast pushed"

echo
echo -e "${GRN}== RELEASE $TAG SHIPPED ==${NC}"
echo "https://github.com/emreisik95/wattmeter/releases/tag/$TAG"
echo "https://raw.githubusercontent.com/emreisik95/wattmeter/main/appcast.xml"
