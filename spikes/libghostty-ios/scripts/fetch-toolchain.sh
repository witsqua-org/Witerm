#!/bin/bash
# Downloads Zig 0.17.0 (the version Ghostty v1.4.0 requires) into .build/tools
# after checking its SHA-256 against ziglang.org's index and its minisign
# signature against Zig's published key, then clones Ghostty v1.4.0 into
# .build/spikes/ghostty. Writes nothing outside the repo's .build/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TOOLS="$ROOT/.build/tools"
DL="$TOOLS/zig-dl"
ZIG_VERSION=0.17.0
ZIG_TARBALL="zig-aarch64-macos-$ZIG_VERSION.tar.xz"
ZIG_SHA256=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
# Zig's minisign public key, as published on https://ziglang.org/download/
ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
GHOSTTY_TAG=v1.4.0
GHOSTTY_COMMIT=83fb95624b0439ee660c2679b43b38c8b63769cd
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mkdir -p "$DL"
if [ ! -x "$TOOLS/zig-aarch64-macos-$ZIG_VERSION/zig" ]; then
  curl -sSfL -o "$DL/$ZIG_TARBALL" "https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
  curl -sSfL -o "$DL/$ZIG_TARBALL.minisig" "https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL.minisig"
  echo "$ZIG_SHA256  $DL/$ZIG_TARBALL" | shasum -a 256 -c -
  HASH="$(python3 -I "$HERE/blake2b.py" "$DL/$ZIG_TARBALL")"
  swift "$HERE/minisign_verify.swift" "$ZIG_PUBKEY" "$DL/$ZIG_TARBALL.minisig" "$HASH"
  tar -xJf "$DL/$ZIG_TARBALL" -C "$TOOLS"
fi
test "$("$TOOLS/zig-aarch64-macos-$ZIG_VERSION/zig" version)" = "$ZIG_VERSION"

if [ ! -d "$ROOT/.build/spikes/ghostty/.git" ]; then
  mkdir -p "$ROOT/.build/spikes"
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty "$ROOT/.build/spikes/ghostty"
fi
test "$(git -C "$ROOT/.build/spikes/ghostty" rev-parse HEAD)" = "$GHOSTTY_COMMIT"
echo "Zig $ZIG_VERSION and Ghostty $GHOSTTY_TAG ($GHOSTTY_COMMIT) ready."
