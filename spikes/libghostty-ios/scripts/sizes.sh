#!/bin/bash
# Stripped executable and bundle sizes of the device Release builds, minus
# the shared stream resources. Run after scripts/build-harness.sh Release device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
P="$ROOT/.build/spikes/dd-device/Build/Products/Release-iphoneos"
T="$ROOT/.build/spikes/sizes"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
rm -rf "$T"; mkdir -p "$T"
for app in SpikeBaseline SpikeSwiftTerm SpikeGhostty; do
  cp "$P/$app.app/$app" "$T/$app"
  xcrun strip -S -x -o "$T/$app.stripped" "$T/$app"
  bin=$(stat -f %z "$T/$app.stripped")
  extra=$(cd "$P/$app.app" && find . -type f ! -path './streams/*' ! -name "$app" ! -path './_CodeSignature/*' -exec stat -f %z {} + | awk '{s+=$1} END {print s+0}')
  echo "$app stripped-executable=$bin other-bundle-files=$extra"
done
