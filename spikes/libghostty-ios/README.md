# libghostty-vt on iOS: renderer spike

A throwaway harness comparing libghostty-vt (Ghostty's terminal engine) with Witerm's SwiftTerm 1.19.0 renderer on iOS. It's not part of Witerm, and no Witerm target links it. The findings are in [docs/design/renderer-evaluation.md](../../docs/design/renderer-evaluation.md).

## What's here

| Path | Contents |
|---|---|
| `Harness/Shared/` | App shell, scenario runner, frame probe (display-link intervals and main-thread CPU per frame), stream loader |
| `Harness/Ghostty/` | libghostty-vt wrapper, a minimal Metal renderer (CoreText glyph atlas, instanced cell quads, overscan for smooth scrolling), the view, word selection, row text |
| `Harness/SwiftTerm/` | SwiftTerm `TerminalView` with draw timing, CoreGraphics or `-metal` |
| `Harness/Baseline/` | No engine, for size and memory baselines |
| `scripts/` | Fetch and verify the toolchain, build libghostty-vt, generate streams, generate the Xcode project, build, run, measure, sizes |

Nothing downloaded or built is committed. Everything external lives in the repo's `.build/`.

## Pinned versions

| Item | Version | Verification |
|---|---|---|
| Ghostty | tag `v1.4.0`, commit `83fb95624b0439ee660c2679b43b38c8b63769cd` (2026-10-27) | `git rev-parse HEAD` in the scripts |
| Zig | 0.17.0 (`minimum_zig_version` of Ghostty 1.4.0), `zig-aarch64-macos-0.17.0.tar.xz` | SHA-256 `b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a` (ziglang.org index), minisign signature valid for key `RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U` (file and trusted-comment signatures; a corrupted hash fails) |
| SwiftTerm | 1.19.0, `464df5207fc2432e16c9a23abe538187196daf5f` | Same pin as Witerm, resolved from a copy of Witerm's SwiftPM cache |
| Xcode | 27.2 (27B52), iOS simulator 27.2 | |

Packages Zig fetched for the libghostty-vt build. All are declared, with content hashes, in Ghostty's `build.zig.zon` / `build.zig.zon.json`, and Zig checks each hash:

| Package | Hash (Zig package id) | Source | Linked into libghostty-vt? |
|---|---|---|---|
| uucode | `uucode-0.2.0-ZZjBPoGFVgCiflJNFc6Io8xzC67B6PA5bUkk4LT0kCxg` | deps.files.ghostty.org | yes (Unicode tables), MIT |
| highway | `N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE` | deps.files.ghostty.org | yes, Apache-2.0 or BSD-3-Clause |
| wuffs | `N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI` | deps.files.ghostty.org | yes (image decoding), Apache-2.0 or MIT |
| simdutf | vendored in `pkg/simdutf` | in the repository | yes, Apache-2.0 or MIT upstream (the vendored amalgamation has no license file) |
| zlib | `N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o` | deps.files.ghostty.org | no (not in the archive) |
| pixels | `N-V-__8AADYiAAB_80AWnH1AxXC0tql9thT-R-DYO1gBqTLc` | deps.files.ghostty.org | no, CC0 |
| iterm2_themes | `N-V-__8AAJ3vBQAq1fLMh5J8uWLkeDLS6WAdR2x5KcrmEyz6` | deps.files.ghostty.org | no |
| translate_c | `translate_c-2.0.0-Q_BUWltOBwBYABF84EUL208pIFeUIwbBs29FmVBaafN5` | deps.files.ghostty.org | build tool, MIT |
| aro | `aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa` | codeberg.org/ziglang/arocc @ `d0c8c4d9` | build tool, MIT |

The archive members of the iOS slice are `ghostty-vt-static_zcu.o`, `vt.o`, `simdutf.o`, `highway_zcu.o`, `per_target.o`, `targets.o`, `wuffs-v0.4.o`, `codepoint_width.o`, `index_of.o`, `base64.o`, `abort.o`, and Zig's `compiler_rt.o`.

## Reproduce

From the repo root, on Apple silicon with Xcode at `/Applications/Xcode.app`:

```sh
bash spikes/libghostty-ios/scripts/fetch-toolchain.sh    # Zig + Ghostty into .build/, verified
JOBS=4 bash spikes/libghostty-ios/scripts/build-libghostty-vt.sh
# -> .build/spikes/ghostty/zig-out/lib/ghostty-vt.xcframework
#    (macos-arm64_x86_64, ios-arm64, ios-arm64-simulator)
python3 -I spikes/libghostty-ios/scripts/gen-streams.py   # -> .build/spikes/streams/
```

Zig's caches are redirected into `.build/zig-cache/` (its default global cache is `~/.cache/zig`). A clean libghostty-vt build (including fetching) took about 2.5 minutes on an M4 with `-j4`; the largest compile step peaked at about 750 MB of memory.

SwiftTerm resolves offline from a copy of Witerm's package cache:

```sh
mkdir -p .build/spikes/sp
cp -R .build/apple-ios/SourcePackages/{repositories,checkouts} .build/spikes/sp/
bash spikes/libghostty-ios/scripts/build-harness.sh Release simulator   # all three apps
bash spikes/libghostty-ios/scripts/build-harness.sh Release device      # for sizes, unsigned
bash spikes/libghostty-ios/scripts/sizes.sh
```

Time Profiler traces and the main-thread split: `xctrace record --template 'Time Profiler' --device <udid> --launch -- <app> -scenarios ingest,fling,replay`, export the `time-profile` table, then `scripts/profile-split.py <xml> <process>`. The Animation Hitches template isn't supported on the simulator ("Hitches is not supported on this platform"), so hitches come from the in-app display-link probe. `scripts/summarize.py <results-dir> <labels...>` prints the comparison table.

Measure on an existing, already-booted simulator (never create or erase one; take any shared simulator lock first):

```sh
bash spikes/libghostty-ios/scripts/measure.sh <udid> .build/spikes/results 1
```

This runs, per renderer: `parse` (headless, 16 KiB chunks, best of 5, 45×40 grid, scrollback 500 and 10,000 lines), `memory`, `ingest` (64 KiB per frame of about 3.6 MB), `fling` (3 flings up and 3 down from 16,000 pt/s with UIScrollView's normal deceleration, through `seq 1 100000`), `pinch` (10-frame live scale to 1.5×, then a font commit 14 → 21 pt and back), `replay` (600 htop-like and 600 vim-like full-screen frames, one per display frame), and `evidence` (CJK/emoji screenshot, row text, word selection; libghostty only: a fixed 120×40 grid scaled to the view). Each run writes `<label>.json`, `<label>.log`, and screenshots, and the apps are uninstalled at the end.

Run a harness interactively (drag to scroll, pinch to zoom, long-press to select a word) by launching it without `-scenarios`, optionally with `-stream ls.bin` or `-metal` (SwiftTerm).

## Streams

`gen-streams.py` writes, deterministically except `ls.bin`:

| File | Bytes | Contents |
|---|---|---|
| `seq.bin` | 688,895 | real `seq 1 100000`, LF → CRLF |
| `ls.bin` | 1,663,420 | real `ls -laRG /usr/share` (24,595 lines) with colors forced via `CLICOLOR_FORCE` and `TERM` (depends on the macOS version) |
| `htop.frames` | 1,717,420 | 600 htop-like frames, 45×40, 16/256 colors, cursor addressing |
| `vim.frames` | 1,738,160 | 600 vim-like frames on the alternate screen: full redraws and scroll-region scrolls |
| `cjk.bin` | 510 | Chinese, Japanese, Korean, emoji (ZWJ, flags, skin tones), combining marks, box drawing, SGR |

## Gotchas found

- The full Ghostty build (the `ghostty.h` embedding API and its Metal renderer, used by the macOS app) refuses iOS targets in 1.4.0: "iOS is not a supported target for the full Ghostty build; only libghostty-vt supports iOS". On iOS you get parsing, state, render state, selection, search, formatting and input encoding, and you write the renderer.
- libghostty-vt's default scrollback limit is 10,000 *bytes*, about one page, so a default terminal keeps almost no history. Clear `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` (pass NULL) or set it explicitly. Line limits are page-granular and approximate.
- Grapheme clustering (mode 2027) is off by default, so ZWJ emoji, skin tones and flags split across cells. The harness sets it as the reset default with `GHOSTTY_TERMINAL_OPT_MODE_DEFAULT`.
- The static library bundles C++ (simdutf, Highway): link `-lc++`.
- The simulator slice targets the A17 CPU model. It runs on M-series hosts with those features (this M4 is fine).
