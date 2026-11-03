#!/usr/bin/env python3 -I
"""Splits main-thread Time Profiler samples of a spike app into buckets.

Usage: xctrace export --input X.trace --xpath \
  '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output X.xml
       profile-split.py X.xml <process-name>

A sample counts toward the first bucket whose pattern matches any frame of
its backtrace, checked in the order listed (leaf-most work wins only through
that order, so parse and draw are checked before Core Animation).
"""
import re
import sys
import xml.etree.ElementTree as ET

BUCKETS = [
    ("parse (feed)", re.compile(r"ghostty_terminal_vt_write|Terminal\.feed|EscapeSequenceParser|TerminalView\.feed")),
    ("render: build cells (libghostty render state / our loop)", re.compile(r"ghostty_render_state|GhosttyMetalRenderer\.draw")),
    ("render: glyph rasterization", re.compile(r"GlyphAtlas|CTLineDraw|CTFontDrawGlyphs")),
    ("render: Metal encode/present", re.compile(r"GhosttyMetalRenderer\.encode|MetalTerminalRenderer|nextDrawable|MTLCommand")),
    ("render: SwiftTerm draw (CoreGraphics)", re.compile(r"drawTerminalContents|TerminalView\.draw|TimedTerminalView\.draw")),
    ("layout / scroll bookkeeping", re.compile(r"layoutSubviews|scrollViewDidScroll|updateScroller|setContentOffset")),
    ("Core Animation commit", re.compile(r"CA::Transaction::commit|CA::Context::commit")),
    ("harness probe / driver", re.compile(r"FrameProbe|FrameDriver|threadCPUSeconds")),
]


def main(path, process):
    root = ET.parse(path).getroot()
    by_id = {}
    for el in root.iter():
        i = el.get("id")
        if i is not None:
            by_id[i] = el

    def resolve(el):
        r = el.get("ref")
        return by_id.get(r, el) if r is not None else el

    totals = {}
    main_total = 0
    for row in root.iter("row"):
        thread = resolve(row.find("thread"))
        tfmt = thread.get("fmt", "")
        proc = row.find("process")
        pfmt = resolve(proc).get("fmt", "") if proc is not None else ""
        if process not in pfmt or "Main Thread" not in tfmt:
            continue
        weight = resolve(row.find("weight"))
        w = int(weight.text) if weight is not None and weight.text else 1_000_000
        bt = row.find("tagged-backtrace")
        if bt is None:
            bt = row.find("backtrace")
        frames = []
        if bt is not None:
            bt = resolve(bt)
            for f in bt.iter("frame"):
                frames.append(resolve(f).get("name", ""))
        # Idle main thread (waiting in mach_msg) is not work.
        if frames and re.search(r"mach_msg2_trap|mach_msg_trap", frames[0]) and not any("commit" in x for x in frames[:12]):
            continue
        main_total += w
        name = "other (UIKit, SwiftUI-free run loop, system)"
        for label, pat in BUCKETS:
            if any(pat.search(x) for x in frames):
                name = label
                break
        totals[name] = totals.get(name, 0) + w
    print(f"main-thread busy samples: {main_total / 1e6:.0f} ms")
    for k, v in sorted(totals.items(), key=lambda kv: -kv[1]):
        print(f"  {v / 1e6:8.0f} ms  {100 * v / max(1, main_total):5.1f}%  {k}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
