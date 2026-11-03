#!/bin/bash
# Builds the spike apps for the iOS simulator (default) or device.
# Usage: scripts/build-harness.sh [Release|Debug] [simulator|device] [targets...]
# SwiftTerm resolves from .build/spikes/sp (a copy of Witerm's SwiftPM cache)
# without automatic resolution, so no package is fetched.
set -euo pipefail
exec > >(tee "${LOG:-/dev/null}") 2>&1

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CONFIG="${1:-Release}"
PLATFORM="${2:-simulator}"
shift $(( $# > 2 ? 2 : $# ))
TARGETS=("${@:-SpikeBaseline SpikeSwiftTerm SpikeGhostty}")
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "$PLATFORM" = device ]; then
  DEST='generic/platform=iOS'
  EXTRA=(CODE_SIGNING_ALLOWED=NO)
else
  DEST='generic/platform=iOS Simulator'
  EXTRA=()
fi

python3 -I "$HERE/scripts/gen-xcodeproj.py"
for target in ${TARGETS[@]}; do
  xcodebuild -project "$HERE/RendererSpike.xcodeproj" -scheme "$target" -configuration "$CONFIG" \
    -destination "$DEST" -derivedDataPath "$ROOT/.build/spikes/dd-$PLATFORM" \
    -clonedSourcePackagesDirPath "$ROOT/.build/spikes/sp" -disableAutomaticPackageResolution \
    -jobs 4 ${EXTRA[@]+"${EXTRA[@]}"} build | grep -E "error:|warning: .*Harness|BUILD (SUCCEEDED|FAILED)|\*\*"
done
