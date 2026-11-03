#!/bin/bash
# Installs one spike app on an existing simulator, runs scenarios, captures
# screenshots when the app logs SCREENSHOT_READY, and saves its results.
# Usage: scripts/run-sim.sh <SpikeTarget> <simulator-udid> <out-dir> <label> [app args...]
# Never creates, boots, or erases a simulator. Take any shared lock first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TARGET="$1"; UDID="$2"; OUT="$3"; LABEL="$4"; shift 4
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="$ROOT/.build/spikes/dd-simulator/Build/Products/${CONFIG:-Release}-iphonesimulator/$TARGET.app"
BUNDLE="com.witerm.spike.$(echo "${TARGET#Spike}" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$OUT"
LOGFILE="$OUT/$LABEL.log"

xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE" "$@" > "$LOGFILE" 2>&1 &
PID=$!
taken=""
while kill -0 "$PID" 2>/dev/null; do
  for shot in $(grep -o 'SCREENSHOT_READY [a-z]*' "$LOGFILE" 2>/dev/null | awk '{print $2}'); do
    case " $taken " in *" $shot "*) ;; *)
      xcrun simctl io "$UDID" screenshot "$OUT/$LABEL-$shot.png" >/dev/null 2>&1 || true
      taken="$taken $shot";;
    esac
  done
  sleep 1
done
wait "$PID" || true
grep '^RESULTS_JSON ' "$LOGFILE" | sed 's/^RESULTS_JSON //' > "$OUT/$LABEL.json" || true
echo "$LABEL: $(wc -c < "$OUT/$LABEL.json") bytes of results; screenshots:$taken"
