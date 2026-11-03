#!/bin/bash
# Builds the libghostty-vt xcframework (macOS universal, iOS device, iOS
# simulator) from the pinned Ghostty checkout, entirely inside the repo's
# .build/ directory. Run scripts/fetch-toolchain.sh first.
set -euo pipefail
exec > >(tee "${LOG:-/dev/null}") 2>&1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="$ROOT/.build"
ZIG="$BUILD/tools/zig-aarch64-macos-0.17.0/zig"
GHOSTTY="$BUILD/spikes/ghostty"
JOBS="${JOBS:-4}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Zig's default global cache is ~/.cache/zig; keep everything in .build/.
export ZIG_GLOBAL_CACHE_DIR="$BUILD/zig-cache/global"
export ZIG_LOCAL_CACHE_DIR="$BUILD/zig-cache/local"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

test "$("$ZIG" version)" = "0.17.0"
test "$(git -C "$GHOSTTY" rev-parse HEAD)" = "83fb95624b0439ee660c2679b43b38c8b63769cd"

cd "$GHOSTTY"
"$ZIG" build \
  -Demit-lib-vt=true \
  -Demit-xcframework=true \
  -Doptimize="${OPTIMIZE:-ReleaseFast}" \
  -j"$JOBS" \
  --summary all

ls -la "$GHOSTTY/zig-out/lib" || true
find "$GHOSTTY/zig-out" -name '*.xcframework' -maxdepth 3
