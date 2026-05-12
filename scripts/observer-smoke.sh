#!/bin/bash
# Full smoke test: rebuilds bundle, launches, samples RSS. DESTRUCTIVE — breaks code signature.
# Run after structural changes, before re-signing.
set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'
fail() { echo -e "${RED}FAIL: $*${NC}" >&2; exit 1; }
ok()   { echo -e "${GRN}OK${NC}   $*"; }

./scripts/observer.sh || fail "static checks failed"

echo "== rebuild + launch =="
./build.sh >/dev/null
pkill -f Wattmeter.app/Contents/MacOS/Wattmeter 2>/dev/null || true
sleep 1
open /Volumes/External/Projects/Wattmeter/Wattmeter.app
sleep 3
PID=$(pgrep -f "Wattmeter.app/Contents/MacOS/Wattmeter" | head -1 || true)
[[ -n "$PID" ]] || fail "app did not launch"
sleep 5
kill -0 "$PID" 2>/dev/null || fail "app crashed within 8s"
RSS=$(ps -o rss= -p "$PID" | tr -d ' ')
RSS_MB=$(( RSS / 1024 ))
echo "RSS = ${RSS_MB} MB"
(( RSS_MB > 400 )) && fail "RSS ${RSS_MB} MB exceeds 400 MB ceiling"
ok "smoke pass (PID $PID, RSS ${RSS_MB}MB)"
echo
echo -e "${GRN}== SMOKE OK — remember to re-sign before redistributing ==${NC}"
