#!/usr/bin/env bash
# Boots an iPhone simulator, installs the Debug build and captures each demo scene in light and dark mode.
# Usage: tools/screenshots.sh <path to OTtracker.app> <output dir>
set -euo pipefail
APP="$1"; OUT="$2"
BUNDLE=com.diakonindustries.ottracker
mkdir -p "$OUT"
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
cands = [d for rt, l in devs.items() if "iOS" in rt for d in l if d["name"].startswith("iPhone")]
pro = [d for d in cands if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or cands)[-1]["udid"])')
echo "Simulator: $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance "$mode"
  for scene in home timer log day inbox timeoff settings; do
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE" -OTDemo "$scene" >/dev/null
    sleep 5
    xcrun simctl io "$UDID" screenshot "$OUT/$mode-$scene.png" >/dev/null
    echo "captured $mode-$scene"
  done
done
