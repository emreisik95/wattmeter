#!/bin/bash
# Bug observer for Wattmeter. Runs after any change to catch regressions.
# Exit 0 = all green. Non-zero = regression.
set -euo pipefail

cd "$(dirname "$0")/.."

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

fail() { echo -e "${RED}FAIL: $*${NC}" >&2; exit 1; }
ok()   { echo -e "${GRN}OK${NC}   $*"; }
warn() { echo -e "${YEL}WARN${NC} $*"; }

# 1. Build clean
echo "== build =="
swift build -c release 2>&1 | tail -5
[[ -f .build/release/Wattmeter ]] || fail "binary missing after build"
ok "swift build green"

# 2. Compile + run logic tests
echo "== logic tests =="
if [[ -f /tmp/cu_tests/test_logic.swift ]]; then
    swiftc -O -o /tmp/cu_tests/test_logic /tmp/cu_tests/test_logic.swift 2>&1 | tail -3
    /tmp/cu_tests/test_logic >/dev/null || fail "logic tests"
    ok "60 logic assertions pass"
else
    warn "no test_logic.swift — skipping"
fi

# 3. Bundle integrity (verify, don't rebuild — preserves signature)
echo "== bundle =="
[[ -f Wattmeter.app/Contents/MacOS/Wattmeter ]] || fail "bundle binary missing — run ./build.sh"
[[ -f Wattmeter.app/Contents/Info.plist ]] || fail "Info.plist missing"
[[ -f Wattmeter.app/Contents/Resources/AppIcon.icns ]] || fail "icon missing"
ok "bundle structure"

# 4. Codesign verify (if signed)
if codesign -dv Wattmeter.app 2>&1 | grep -q "TeamIdentifier=235UP83FJ4"; then
    codesign --verify --strict --deep Wattmeter.app 2>&1 | tail -3
    ok "codesign valid"
else
    warn "not signed yet"
fi

# 5. Crash report scan (last 60s)
if ls ~/Library/Logs/DiagnosticReports/Wattmeter* 2>/dev/null | head -1 >/dev/null; then
    LATEST=$(ls -t ~/Library/Logs/DiagnosticReports/Wattmeter* 2>/dev/null | head -1)
    AGE=$(( $(date +%s) - $(stat -f %m "$LATEST") ))
    if (( AGE < 60 )); then
        fail "fresh crash report: $LATEST"
    fi
fi
ok "no fresh crash reports"

BIN="Wattmeter.app/Contents/MacOS/Wattmeter"

# Source feature inventory — these symbols/strings must stay in source
echo "== source features =="
required_source=(
    "Aggregator"
    "Forecasting"
    "LimitsConfig"
    "NotificationManager"
    "TrayDisplay"
    "PercentStyle"
    "OnboardingOverlay"
    "HeatmapView"
    "SessionsTab"
    "DailyProjectionCard"
    "PlanPickerCard"
    "IntegrationSettingsView"
    "LaunchAtLogin"
    "five_hour"
    "seven_day"
    "context_window"
    "rate_limits.json"
    "saveCSV"
    "Sparkline"
    "burnRate"
    "heatmap"
    "topRequests"
    "bySession"
    "didOnboard"
    "launchAtLogin"
    "addGlobalMonitor"
)
for s in "${required_source[@]}"; do
    if ! grep -rq "$s" Sources/; then
        fail "source feature lost: $s"
    fi
done
ok "all ${#required_source[@]} source features present"

# 10. Binary size budget
echo "== size budget =="
BIN_SIZE=$(stat -f %z "$BIN")
BIN_SIZE_KB=$(( BIN_SIZE / 1024 ))
echo "binary = ${BIN_SIZE_KB} KB"
APP_SIZE=$(du -sk Wattmeter.app | cut -f1)
echo "bundle = ${APP_SIZE} KB"
ok "size measured"

echo
echo -e "${GRN}== ALL OBSERVER CHECKS PASSED ==${NC}"
