#!/bin/bash
# Runs every scenario for each renderer on one existing simulator, then
# uninstalls the spike apps. Usage: scripts/measure.sh <udid> <out-dir> [round]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UDID="$1"; OUT="$2"; ROUND="${3:-1}"
S=parse,memory,ingest,fling,pinch,replay,evidence
bash "$HERE/run-sim.sh" SpikeBaseline "$UDID" "$OUT" "baseline-r$ROUND" -scenarios memory
bash "$HERE/run-sim.sh" SpikeGhostty "$UDID" "$OUT" "ghostty-r$ROUND" -scenarios "$S"
bash "$HERE/run-sim.sh" SpikeSwiftTerm "$UDID" "$OUT" "swiftterm-cg-r$ROUND" -scenarios "$S"
bash "$HERE/run-sim.sh" SpikeSwiftTerm "$UDID" "$OUT" "swiftterm-metal-r$ROUND" -scenarios "${S/parse,/}" -metal
if [ "${KEEP_INSTALLED:-0}" != 1 ]; then
  for b in baseline ghostty swiftterm; do
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun simctl uninstall "$UDID" "com.witerm.spike.$b" || true
  done
fi
