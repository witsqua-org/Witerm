#!/usr/bin/env python3 -I
"""Prints Markdown tables from the harness result files.

Usage: summarize.py <results-dir> <label> [<label> ...]
Labels are result file stems, e.g. ghostty-r1 swiftterm-cg-r1. Several
labels with the same prefix before "-r" are reported as min..max.
"""
import json
import os
import sys


def load(d, label):
    with open(os.path.join(d, label + ".json")) as f:
        return json.load(f)


def fmt(vals, digits=1):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "n/a"
    lo, hi = min(vals), max(vals)
    if round(lo, digits) == round(hi, digits):
        return f"{lo:.{digits}f}"
    return f"{lo:.{digits}f}–{hi:.{digits}f}"


def get(d, *path):
    for p in path:
        if d is None:
            return None
        d = d[p] if isinstance(d, dict) and p in d else (d[p] if isinstance(d, list) and isinstance(p, int) and p < len(d) else None)
    return d


def main():
    d = sys.argv[1]
    groups = {}
    for label in sys.argv[2:]:
        groups.setdefault(label.rsplit("-r", 1)[0], []).append(load(d, label))
    names = list(groups)
    rows = []

    def row(title, fn, digits=1):
        rows.append([title] + [fmt([fn(r) for r in groups[n]], digits) for n in names])

    for s in ["seq.bin", "ls.bin", "htop.frames", "vim.frames"]:
        row(f"Parse {s} @10k, MB/s", lambda r, s=s: get(r, "parse", f"{s}@10000", "MBps"), 0)
        row(f"Parse {s} @500, MB/s", lambda r, s=s: get(r, "parse", f"{s}@500", "MBps"), 0)
    for sc, label in [("fling", "Fling"), ("ingest", "Ingest 3.6 MB")]:
        row(f"{label}: frames", lambda r, sc=sc: get(r, sc, "frames", "frames"), 0)
        row(f"{label}: hitches (>1.5 frames)", lambda r, sc=sc: get(r, sc, "frames", "hitches"), 0)
        row(f"{label}: worst frame, ms", lambda r, sc=sc: get(r, sc, "frames", "intervalMs", "max"))
        row(f"{label}: main-thread CPU/frame mean, ms", lambda r, sc=sc: get(r, sc, "frames", "mainCPUms", "mean"), 2)
        row(f"{label}: main-thread CPU/frame p95, ms", lambda r, sc=sc: get(r, sc, "frames", "mainCPUms", "p95"), 2)
        row(f"{label}: main-thread CPU/frame max, ms", lambda r, sc=sc: get(r, sc, "frames", "mainCPUms", "max"), 2)
        row(f"{label}: renderer draw call/frame, ms", lambda r, sc=sc: get(r, sc, "frames", "drawMs"), 2)
    row("Ingest: wall time, ms", lambda r: get(r, "ingest", "wallMs"), 0)
    for s in ["htop.frames", "vim.frames"]:
        row(f"Replay {s}: hitches", lambda r, s=s: get(r, "replay", s, "hitches"), 0)
        row(f"Replay {s}: worst frame, ms", lambda r, s=s: get(r, "replay", s, "intervalMs", "max"))
        row(f"Replay {s}: main CPU/frame mean, ms", lambda r, s=s: get(r, "replay", s, "mainCPUms", "mean"), 2)
        row(f"Replay {s}: main CPU/frame p95, ms", lambda r, s=s: get(r, "replay", s, "mainCPUms", "p95"), 2)
    for i, t in [(0, "14→21 pt"), (1, "21→14 pt")]:
        row(f"Pinch {t}: live step main CPU p95, ms", lambda r, i=i: get(r, "pinch", i, "steps", "mainCPUms", "p95"), 2)
        row(f"Pinch {t}: commit (font + reflow), ms", lambda r, i=i: get(r, "pinch", i, "commitMs"))
        row(f"Pinch {t}: worst frame after lift, ms", lambda r, i=i: get(r, "pinch", i, "liftFrames", "intervalMs", "max"))
    row("Memory: empty engine, MB", lambda r: get(r, "memory", "emptyEngineMB"))
    row("Memory: + seq (10k scrollback), MB", lambda r: get(r, "memory", "afterSeqMB"))
    row("Memory: + seq + ls, MB", lambda r: get(r, "memory", "afterSeqAndLsMB"))
    print("| Measure | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for r in rows:
        if all(c == "n/a" for c in r[1:]):
            continue
        print("| " + " | ".join(r) + " |")


if __name__ == "__main__":
    main()
