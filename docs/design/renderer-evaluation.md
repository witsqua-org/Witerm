# Renderer evaluation: libghostty-vt vs SwiftTerm on iOS

A time-boxed spike, on 2026-11-04, into whether Witerm's iOS terminal should move from SwiftTerm 1.19.0 to libghostty, the Ghostty terminal engine (Termius adopted it in its 8.0.2 renderer). It produced evidence and a recommendation, not a migration. No Witerm target, source or string changed. The harness, pinned versions and exact reproduce steps are in [spikes/libghostty-ios](../../spikes/libghostty-ios/README.md).

## Answer

- **It builds and embeds on iOS with modest effort.** libghostty-vt from Ghostty v1.4.0 builds with Zig 0.17.0 into an xcframework with `ios-arm64` and `ios-arm64-simulator` slices. It linked into a SwiftUI-free UIKit app for both the simulator and the device (unsigned build). From a clean checkout to a first rendered frame took about an hour.
- **On iOS it's an engine, not a renderer.** The full libghostty (`ghostty.h`, with the Metal renderer the macOS app uses) refuses iOS targets in 1.4.0. libghostty-vt gives terminal state, a render state built for GPU renderers, selection, search, formatting, and key/mouse/paste encoding. Drawing, text input, IME and accessibility are the embedder's job.
- **The engine is much faster and smaller.** It parses 7–10× faster than SwiftTerm. With a minimal Metal renderer written for this spike, it needs 6–8× less main-thread time per frame while flinging or replaying full-screen programs, and has no hitches under heavy output where SwiftTerm has 3–6. It also uses a quarter of the memory and adds less binary size.
- **Recommendation: don't migrate now.** The cost is roughly 10–16 engineer-weeks for iOS alone: our own renderer, the `UITextInput`/IME layer SwiftTerm gives us today, selection UI, the reading view and tests. The API it rests on first shipped in a tagged release eight days ago, and its README still calls the signatures "in flux". Measure SwiftTerm on the iPhone 17 Pro at 120 Hz first (handoff open item 3). If it hitches there, plan libghostty-vt rather than SwiftTerm's Metal path, behind a renderer seam added first. See [Recommendation](#recommendation).

## Method

**Harness.** One small UIKit app (`spikes/libghostty-ios/`, its own generated Xcode project) built three ways from the same sources:

- `SpikeSwiftTerm`: SwiftTerm's `TerminalView`, the Core Graphics renderer, or `setUseMetal(true)` with `-metal`.
- `SpikeGhostty`: libghostty-vt with a spike renderer of about 450 lines. That renderer is a CoreText glyph atlas in one BGRA texture, two instanced draws (backgrounds/decorations and glyphs) into a `CAMetalLayer`, and overscan rows for pixel-smooth scrolling under a transparent `UIScrollView` that supplies touch physics. It runs on the main thread and rebuilds every visible cell each frame, with no dirty-row caching.
- `SpikeBaseline`: no engine, for size and memory baselines.

**Kept equal.** Same view (402 × 778 pt, @3x), same font (`monospacedSystemFont` 14 pt), same cell size (computed as SwiftTerm does), and the same 46 × 45 grid. Scrollback was 10,000 lines in both; libghostty prunes by whole pages and kept 9,310–9,434 rows, SwiftTerm 10,040. Same byte streams, same chunking (16 KiB headless, 64 KiB per frame on screen), and Release builds (`-O`) of both engines. Both engines ended every stream at the same cursor position.

**Streams** (generated locally, no SSH): real `seq 1 100000` (689 KB), real colored `ls -laRG /usr/share` (24,595 lines, 1.66 MB), 600 synthesized htop-like frames (1.7 MB, 16/256 colors, cursor addressing), 600 synthesized vim-like frames on the alternate screen (1.7 MB, full redraws and scroll-region scrolls), and a CJK/emoji/combining-mark sample.

**Scenarios.**

| Scenario | What it does |
|---|---|
| parse | Headless, 45 × 40 grid, best of 5. |
| fling | 3 flings up and 3 down through `seq` scrollback from 16,000 pt/s with UIScrollView's normal deceleration (0.998/ms), driven per display frame. |
| ingest | ls + 3 × seq (3.6 MB) at 64 KiB per frame, on screen. |
| replay | One recorded full-screen frame per display frame. |
| pinch | The view scaled live for 10 frames (as Witerm does), then one font commit 14 → 21 pt (46 × 45 → 30 × 29, reflowing the scrollback) and back. |
| memory | Physical footprint delta. |

**Measures.** An in-app display-link probe records frame intervals and main-thread CPU time per frame (from `thread_info`). A hitch is an interval over 1.5 frames. Time Profiler (`xctrace`) gave the main-thread split. The Animation Hitches instrument doesn't run on the simulator ("Hitches is not supported on this platform"), so hitch counts come from the probe. The probe sees main-thread stalls, not render-server or GPU stalls.

**Where.** The iPhone 18 Pro simulator (iOS 27.2, 60 Hz) on an M4 Mac with Xcode 27.2, run twice per renderer. Ranges below are min–max over the two rounds. The physical iPhone wasn't used.

**Caveats.** The simulator runs on the Mac's CPU and GPU at 60 Hz, so absolute numbers aren't a phone's. The ratios between engines on the same machine are the evidence. The spike renderer lacks a production renderer's features (custom box-drawing glyphs, ligatures, cursor blink, images, underline styles) but also has no optimizations (no dirty-row reuse, no render thread).

## Numbers

### Throughput and frames

| Measure | libghostty-vt + spike Metal | SwiftTerm Core Graphics (Witerm today) | SwiftTerm Metal |
|---|---|---|---|
| Parse `seq` (10k scrollback), MB/s | **154–170** | 16–17 | same parser |
| Parse `ls -laR` colored, MB/s | **481–528** | 62–64 | same parser |
| Parse htop-like frames, MB/s | **324–325** | 48–50 | same parser |
| Parse vim-like frames, MB/s | **233–236** | 41–42 | same parser |
| Fling: frames, hitches, worst frame | 1,205, 0, 16.7 ms | 1,205, 0, 16.7 ms | 1,205, 0, 16.7 ms |
| Fling: main-thread CPU per frame, mean / p95 / max | **0.43–0.55 / 0.55–0.74 / 1.05–1.23 ms** | 3.41–3.54 / 4.41–4.42 / 4.70–4.75 ms | 1.74–1.76 / 4.75–4.76 / 7.18–7.77 ms |
| Ingest 3.6 MB: hitches, worst frame | **0, 16.7 ms** | 3, 37.1–37.3 ms | 5–6, 45.0–56.9 ms |
| Ingest: main-thread CPU per frame, mean / p95 / max | **0.97–2.49 / 1.36–3.49 / 2.63–5.43 ms** | 6.81–6.86 / 17.06–17.45 / 19.91–20.19 ms | 6.95–7.35 / 17.22–17.44 / 23.88–34.77 ms |
| Replay htop: hitches, worst frame | 0, 16.7 ms | 0, 16.7 ms | 1–2, 36.3–39.3 ms |
| Replay htop: main-thread CPU per frame, mean / p95 | **0.35–0.43 / 0.44–0.62 ms** | 3.32–3.36 / 7.81–7.98 ms | 3.56–4.06 / 8.72–9.35 ms |
| Replay vim: hitches, worst frame | 1–2, 34.0–71.1 ms | 1, 33.3–42.8 ms | 1–2, 40.2–43.2 ms |
| Replay vim: main-thread CPU per frame, mean / p95 | **0.36–0.45 / 0.51–0.62 ms** | 3.11–3.38 / 7.80–8.05 ms | 3.26–3.61 / 7.94–8.99 ms |
| Pinch, live steps: main-thread CPU p95 (14 → 21 pt) | 0.66–1.02 ms | 3.21–5.80 ms | 4.78–5.08 ms |
| Pinch commit 14 → 21 pt (font, refit, reflow, first draw) | 5.6–16.2 ms | 8.1–8.3 ms | 8.3–10.1 ms |
| Pinch commit 21 → 14 pt | 1.3–3.4 ms | 3.6–6.9 ms | 7.7–10.2 ms |
| Pinch: worst frame after lifting | 16.7 ms | 16.7 ms | 16.7 ms |

In practice:

- **Parsing.** SwiftTerm parses `seq` at about 2.5 million lines/s; libghostty-vt manages about 24 million. That is the cost Witerm pays on the main thread during heavy output (handoff: "Heavy output is still parsed on the main thread").
- **Ingest.** SwiftTerm's p95 frame needs 17 ms of main thread, a whole 60 Hz frame and two 120 Hz frames. That's where its hitches come from. libghostty's p95 stays under 3.5 ms.
- **Flinging.** All three are hitch-free at 60 Hz. SwiftTerm Core Graphics uses 3.4–3.5 ms per frame, 41–42% of a 120 Hz budget. SwiftTerm Metal halves the mean but not the p95, and is worse under heavy output and in the htop replay.
- **Pinch.** All three commit within a frame here. The libghostty 14 → 21 pt commit includes rasterizing a fresh glyph atlas at the new size, which a production renderer could do ahead of time. Witerm's measured 53–62 ms lifting frame (Round 14) includes SwiftUI, UserDefaults observers and the reading view, which the harness doesn't have.
- **vim replay.** The 1–2 hitches appear for every renderer, so they aren't specific to any one.

### Main-thread split (Time Profiler)

Same scenarios (ingest, fling, replay; about 60 s), main-thread samples only, idle excluded (`scripts/profile-split.py`). Recorded with the first harness build, before `ls` output was colored and grapheme clustering was turned on; neither change touches the paths profiled here.

| Bucket | libghostty-vt + spike Metal | SwiftTerm Core Graphics |
|---|---|---|
| Main thread busy | **2.05 s** | 8.82 s |
| Parse (feed) | 0.12 s (6%) | 0.66 s (7%) |
| Build cells from render state (our loop + libghostty) | 0.82 s (40%) | n/a |
| SwiftTerm `draw(_:)` (records a CG display list) | n/a | 2.12 s (24%) |
| Glyph rasterization | (inside the above, cached) | 0.75 s (8%) |
| Core Animation commit | 0.17 s (8%) | 4.35 s (49%), of which 3.26 s replays the display list into the layer's backing store and about 0.9 s is backing-store fills |
| Layout / scroll bookkeeping | 0.42 s (21%) | 0.17 s (2%) |
| Metal encode/present | under 0.01 s | n/a |
| Other (UIKit, run loop, system) | 0.47 s | 0.69 s |

With Core Graphics, SwiftTerm's `draw(_:)` only records drawing commands. The rasterization happens later, inside the Core Animation commit, on the main thread. Timing `draw(_:)` alone therefore understates its cost by more than half; main-thread CPU per frame is the fair comparison. Round 14's "2.5–2.8 ms drawing per frame" was timed the same way (around `draw(_:in:)` in `TerminalInputView`), so it measured only the recording.

### Memory and size

| Measure | libghostty-vt | SwiftTerm CG | SwiftTerm Metal |
|---|---|---|---|
| Footprint added: empty engine | 0.3–0.5 MB | 12.3–13.7 MB | 6.7 MB |
| After `seq` (about 10k rows of scrollback) | **4.4–4.5 MB** | 12.4–33.5 MB | 21.3 MB |
| After `seq` + `ls` | **4.5–4.6 MB** | 18.0–33.7 MB | 21.5 MB |
| Binary added (device arm64 Release, stripped) | **+1.33 MB** executable (libghostty-vt + spike renderer) + 21 KB metallib | +1.79 MB executable + 29 KB bundle (metallib) | same as CG |

The baseline app's stripped executable is 177 KB. SwiftTerm's footprint is noisy between runs (allocator reuse); libghostty's is stable.

## Capabilities

What libghostty-vt 1.4.0 provides, what Witerm would build on top, and what SwiftTerm gives Witerm today.

| Need | libghostty-vt 1.4.0 | SwiftTerm 1.19.0 today | Evidence |
|---|---|---|---|
| Drawing | **None on iOS.** Render state only: rows, cells, styles, resolved colors, cursor, selection ranges, dirty rows, overscan rows, row ids, Kitty image placements. Ghostty's Metal renderer and the `ghostty.h` surface API are macOS/Linux only. Building it for iOS without `-Demit-lib-vt` fails with "iOS is not a supported target for the full Ghostty build". | Core Graphics (default) and opt-in Metal, both in the package | `src/build/Config.zig`, `include/ghostty/vt/render.h`, spike `GhosttyRenderer.swift` |
| Smooth pixel scrolling | Overscan rows (`GHOSTTY_RENDER_STATE_OPTION_OVERSCAN`) and `GHOSTTY_SCROLL_VIEWPORT_ROW`; the scroll offset and physics are ours (a transparent `UIScrollView` worked) | Built in (`TerminalView` is a `UIScrollView`) | spike `GhosttyTerminalView`; fling numbers |
| Text selection | The logic is there: grid refs, select word/line/all/output, word-between for drags, a gesture state machine (click count, drag, autoscroll), rectangle selection, and formatting to plain, VT or HTML. Handles, edit menu and hit-testing are ours. | Long-press, double/triple tap and `getSelection()`; handles are Witerm's own; no public select-at-cell | `selection.h`; spike `selectWord(row: 1, col: 3)` returned `dog.` and drew the highlight |
| Reading view (VoiceOver) | Cells with full grapheme codepoints and width flags (wide, spacer head/tail), a formatter for plain text, grid refs for point ↔ cell mapping. No accessibility objects, which matches Witerm's design: `TerminalReadingTextView` and `TerminalAXDocument` build their own text. The spike rebuilt the visible rows exactly, including CJK, ZWJ emoji and combining marks. | Witerm reads SwiftTerm buffer lines into `TerminalAXDocument` | spike `visibleRows()`, `formatter.h`, `grid_ref.h` |
| IME / marked text (Chinese input) | **Nothing.** No preedit in the render state. We'd implement `UITextInput` (marked text, `firstRect(for:)`, `caretRect`, selection affinity) and draw the preedit ourselves; the key encoder only has a "composing" flag. Ghostty's macOS app does the same with `NSTextInputClient`. | SwiftTerm's `iOSTextInput.swift`/`iOSTextStorage.swift` implement `UITextInput`; Witerm's `TerminalInputView` builds on it | no "preedit" anywhere in `include/ghostty/vt` |
| Hardware keyboard | Key encoder: legacy xterm, modifyOtherKeys and the Kitty keyboard protocol, configured from the terminal's modes. We'd map `UIPress`/`UIKey` to `GhosttyKey`. | SwiftTerm handles `pressesBegan`; no Kitty protocol | `key/encoder.h`, `key/event.h` |
| Mouse, paste, focus | Mouse encoder (X10 to any-event tracking, SGR/URXVT/SGR-pixels), bracketed paste with unsafe-control checks, focus reports | Built in | `mouse/encoder.h`, `paste.h`, `focus.h` |
| Fixed authoritative grid (watch mode) | The terminal stays at the Mac's cols × rows and the renderer scales the cells with one uniform. Shown: a 120 × 40 grid drawn crisply into the 402 pt view (`libghostty-watch-120x40.png`). | Witerm keeps the grid at its own cell size and pans; scaling would mean a transform over rasterized Core Graphics output (blurry) or a smaller font | spike `fixedGrid` |
| Geometry changes | `ghostty_terminal_resize` reflows the primary screen and scrollback (not the alternate screen), with optional pull-from-scrollback, in-band size reports (mode 2048) and a size-query callback. It has no font-path soft reset to work around. | Resize through layout; Witerm works around the font setter's soft reset | `terminal.h`; pinch numbers |
| Light/dark, Increase Contrast | Default foreground, background, cursor and the 256-color palette are settable at any time; the color-scheme query (`CSI ? 996 n`) goes to a callback; the render state resolves colors, so a scheme change is one full redraw. Contrast policy stays Witerm's palettes. | `installColors`, native colors | `terminal.h` |
| CJK, emoji, combining marks | Correct widths and grapheme clustering (uucode tables). **Mode 2027 is off by default**: without it, ZWJ emoji, skin tones and flags split. Font fallback is ours; CoreText (`CTLine`) fell back to PingFang, Hiragino, Apple SD Gothic Neo and Apple Color Emoji with no extra code. | Grapheme clustering and fallback built in, plus custom box-drawing/block glyphs | `libghostty-cjk.png` vs `swiftterm-cjk.png` |
| Search | Incremental search over scrollback and the alternate screen that survives resize, reflow and pruning | Witerm's find bar uses SwiftTerm's search | `search.h` |
| Synchronized output (2026) | A render-hold callback the renderer must honor | Built in | `render.h` |
| Threading | The terminal isn't thread-safe, but the render state supports a two-phase update, so parsing can move off the main thread behind a short lock | Main thread only | `render.h`, "Two-Phase Updates" |

Screenshots: [libghostty CJK/emoji](screenshots/renderer-evaluation/libghostty-cjk.png), [SwiftTerm CJK/emoji](screenshots/renderer-evaluation/swiftterm-cjk.png), [libghostty 120 × 40 watch grid](screenshots/renderer-evaluation/libghostty-watch-120x40.png). The spike renderer draws block shades (`░▒▓`) from the font and so shows them as dots, while SwiftTerm draws them as solid tones. That's a gap in the spike, not in the library.

Not exercised on a device or with real users: VoiceOver speech, Chinese IME and hardware keyboard input. Those layers would be new code either way, and the table says what each library offers for them.

## Licensing

| Component | License | Linked into the app? |
|---|---|---|
| Ghostty / libghostty-vt | MIT ("Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors") | yes |
| uucode (Unicode tables) | MIT | yes |
| simdutf | Apache-2.0 or MIT upstream; Ghostty's vendored amalgamation (`pkg/simdutf/vendor`) carries no license file, so we'd add the notice ourselves | yes |
| Highway | Apache-2.0 or BSD-3-Clause | yes |
| Wuffs (image decoding) | Apache-2.0 or MIT | yes |
| Zig `compiler_rt` | MIT (Zig) | yes |
| zlib, pixels (CC0), iterm2 themes | various | fetched, not linked |
| translate-c, Aro | MIT | build tools only |

All are permissive and compatible with Witerm. Shipping needs the notices for MIT, Apache-2.0 (with its NOTICE handling) and BSD-3-Clause. SwiftTerm is MIT.

## Risks

1. **API churn.** In v1.3.1 (2026-03-13), the public libghostty-vt headers covered only key encoding, OSC, paste, SGR and colors. Everything a renderer needs (terminal, render state, selection, search, formatter, grid refs: 35 headers, +13,794 / −397 lines) first shipped in v1.4.0, tagged 2026-10-27. The README says "the API signatures are still in flux", libghostty has no version of its own yet, and the dylib is versioned 0.1.0. The sized-struct ABI pattern helps, but expect source changes per release.
2. **Platform direction.** v1.4.0 dropped iOS from the full Ghostty build. lib-vt is explicitly kept for iOS (its own deployment target, iOS 13), but Ghostty's own Metal renderer won't come to iOS for us; the renderer is ours to maintain indefinitely.
3. **A Zig toolchain in the build.** A 54 MB download (macOS arm64), pinned to the exact version each Ghostty release requires (0.17.0 now; Zig still breaks between minor versions). A clean build takes about 2.5 minutes at `-j4` and peaks around 750 MB per compile. It fetches 7 hash-pinned packages from `deps.files.ghostty.org` and one (Aro) from `codeberg.org`. AGENTS.md forbids committing build products, so either every build machine bootstraps Zig (as `fetch-toolchain.sh` does, with checksum and minisign verification) or we host a verified prebuilt xcframework somewhere outside git.
4. **Defaults that bite.** The default scrollback limit is 10,000 *bytes* (almost no history), and grapheme clustering is off. Both are one-line fixes once known; both are in the spike README.
5. **The simulator slice targets the A17 CPU model.** That's fine on M-series hosts and the current phones, but it's a build-time assumption worth knowing.
6. **We'd own correctness that SwiftTerm gives us today:** text input and IME, custom glyphs (box drawing, powerline, block elements), cursor rendering, images, and the accessibility plumbing. Each is a regression risk at switch-over.

## Migration cost for Witerm (rough)

iOS only; the Mac keeps SwiftTerm, since libghostty's surface API there is app-oriented with its own I/O and wasn't evaluated. The estimates are for one engineer familiar with the codebase.

| Work | Estimate | Notes |
|---|---|---|
| Renderer seam in `RemoteNativeTerminalView.TerminalSurface` (engine behind a protocol: feed, geometry, scroll, font, colors, selection, rows) | 1–2 weeks | Worth doing first whatever happens; it also isolates SwiftTerm |
| Production Metal renderer: atlas eviction, custom box-drawing/block/powerline glyphs, underline styles, cursor styles and blink, dim/inverse/invisible, selection and find highlights, wide-gamut color, synchronized output, 120 Hz pacing, dirty-row reuse, optional render thread | 3–5 weeks | The spike's 450 lines cover the core path |
| Input: `UITextInput` with marked text and candidate placement (Chinese IME), the hardware keyboard through the key encoder, Witerm's key row, paste review, mouse reporting from touch | 2–4 weeks | The riskiest part: it replaces what SwiftTerm's iOS input layer does for us today |
| Selection UI: long-press, double/triple tap, Witerm's handles and edit menu on libghostty's selection API | 1–1.5 weeks | The logic exists in the library |
| Reading view: source `TerminalAXDocument` from the render state and formatter; rect ↔ cell mapping; real VoiceOver acceptance | 1–1.5 weeks | Maps closely onto Witerm's current model |
| Pinch, watch-mode scaling, wide-grid panning, `geometry` events and followed/frozen grids, the find bar on `ghostty_search` | 1–2 weeks | Watch-mode scaling becomes simpler |
| Build integration: verified Zig bootstrap, xcframework build, CI, license notices | 0.5–1 week | |
| Tests: port `WitermiOSTerminalTests` and the VoiceOver UI tests | 1–2 weeks | |
| **Total** | **about 10–16 weeks**, plus follow-up on each libghostty release | |

## Recommendation

**Don't migrate now; decide with numbers from the iPhone 17 Pro, and prepare the seam.**

1. **Measure SwiftTerm at 120 Hz on the phone** (handoff open item 3), with Witerm's own probe or this harness. These numbers predict where it shows first: heavy output, where SwiftTerm's p95 frame already needs 17 ms of main thread (two ProMotion frames), and fast flings, where it uses 41–42% of an 8.3 ms frame. This harness can run on a phone with a development signature; it wasn't run on one here.
2. **If the phone is smooth enough, stay on SwiftTerm.** The remaining cost is concentrated in parsing heavy output, and options like batching output before feeding it cost far less than a new engine.
3. **If it isn't, go to libghostty-vt rather than SwiftTerm's Metal renderer.** SwiftTerm Metal halves mean fling cost but not its p95, has more hitches under heavy output, and leaves the 10× slower parser in place. libghostty-vt fixes both and adds a smaller footprint, Kitty keyboard support and clean watch-mode scaling. Start with the renderer seam (useful regardless), pin Ghostty and Zig as this spike does, and wait for one more libghostty release without breaking changes to the render-state and selection APIs before building on them.
