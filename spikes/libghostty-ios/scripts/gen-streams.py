#!/usr/bin/env python3 -I
"""Generates the replayed byte streams for the renderer spike.

Writes into .build/spikes/streams/ (never committed):

- seq.bin    real `seq 1 100000` output, LF -> CRLF as a PTY's ONLCR would.
- ls.bin     real `ls -laR` of /usr/share with ls colors forced, capped at 4 MiB.
- htop.frames 600 synthesized htop-like full-screen frames (45x40, 256-color).
- vim.frames  600 synthesized vim-like redraws on the alternate screen.
- cjk.bin    CJK, emoji (ZWJ, flags, skin tones), combining marks, box drawing.

*.frames files are a sequence of [u32 little-endian length][bytes] records,
one per display frame. Everything is deterministic except ls.bin, whose
content depends on the macOS version's /usr/share.
"""
import hashlib
import json
import os
import random
import struct
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, ".build", "spikes", "streams")
COLS, ROWS = 45, 40
ESC = "\x1b"


def crlf(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


def write(name: str, data: bytes) -> None:
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)


def write_frames(name: str, frames) -> None:
    with open(os.path.join(OUT, name), "wb") as f:
        for frame in frames:
            b = frame.encode("utf-8")
            f.write(struct.pack("<I", len(b)))
            f.write(b)


def seq_stream() -> bytes:
    return crlf(subprocess.run(["/usr/bin/seq", "1", "100000"], check=True,
                               capture_output=True).stdout)


def ls_stream() -> bytes:
    env = {"PATH": "/usr/bin:/bin", "CLICOLOR": "1", "CLICOLOR_FORCE": "1",
           "LSCOLORS": "ExGxFxdxCxDxDxhbadExEx", "LANG": "en_US.UTF-8",
           "TERM": "xterm-256color"}
    out = subprocess.run(["/bin/ls", "-laRG", "/usr/share"], env=env,
                         capture_output=True).stdout
    out = out[: 4 * 1024 * 1024]
    out = out[: out.rfind(b"\n") + 1]
    return crlf(out)


def sgr(*codes) -> str:
    return f"{ESC}[{';'.join(str(c) for c in codes)}m"


def at(row: int, col: int) -> str:
    return f"{ESC}[{row};{col}H"


def htop_frames(count=600):
    rnd = random.Random(42)
    procs = [f"/usr/bin/{w}" for w in
             ["sshd", "tmux", "zsh", "vim", "python3", "node", "postgres",
              "nginx", "go", "swift-frontend", "clang", "make", "git",
              "launchd", "mds_stores", "WindowServer", "kernel_task",
              "cloudd", "bird", "rapportd", "witerm-agent", "ghostty",
              "cargo", "rustc", "docker", "containerd", "redis-server",
              "mysqld", "java", "gradle", "xcodebuild", "lldb", "top",
              "htop", "less", "man", "ssh", "scp", "rsync", "curl"]]
    frames = []
    for n in range(count):
        s = [f"{ESC}[?25l", at(1, 1)]
        for cpu in range(4):
            pct = rnd.uniform(2, 99)
            filled = int(pct / 100 * 30)
            low = filled * 2 // 3
            bar = sgr(32) + "|" * low + sgr(31) + "|" * (filled - low) + sgr(0) + " " * (30 - filled)
            s.append(at(1 + cpu, 1) + f"{sgr(36)}{cpu:>2}{sgr(0)}[{bar}{sgr(90)}{pct:5.1f}%{sgr(0)}]{ESC}[K")
        mem = rnd.uniform(40, 80)
        filled = int(mem / 100 * 30)
        s.append(at(5, 1) + f"{sgr(36)}Mem{sgr(0)}[{sgr(32)}{'|' * filled}{sgr(34)}{'|' * 3}{sgr(0)}"
                 f"{' ' * (27 - filled)}{sgr(90)}{mem:4.1f}G{sgr(0)}]{ESC}[K")
        s.append(at(6, 1) + f"{sgr(36)}Tasks: {sgr(1)}{rnd.randint(300, 400)}{sgr(0)}, "
                 f"{sgr(32)}{rnd.randint(1, 9)} running{sgr(0)}  Load: {rnd.uniform(0, 8):.2f}{ESC}[K")
        s.append(at(8, 1) + sgr(30, 42) + f"{'  PID USER     CPU% MEM% Command':<{COLS}}" + sgr(0))
        sel = n % 30
        for i in range(ROWS - 9):
            pid = 100 + (i * 37 + n) % 9000
            cpu = rnd.uniform(0, 100)
            color = 31 if cpu > 80 else (33 if cpu > 40 else 0)
            name = procs[(i + n // 10) % len(procs)]
            line = f"{pid:5} nigelli {sgr(color)}{cpu:5.1f}{sgr(0)} {rnd.uniform(0, 9):4.1f} {sgr(38, 5, 75)}{name}{sgr(0)}"
            if i == sel:
                line = sgr(30, 46) + f"{pid:5} nigelli {cpu:5.1f} {0.5:4.1f} {name}"[:COLS].ljust(COLS) + sgr(0)
            s.append(at(9 + i, 1) + line + f"{ESC}[K")
        s.append(at(ROWS, 1) + sgr(30, 46) + "F1" + sgr(0) + "Help " + sgr(30, 46) + "F2" + sgr(0)
                 + "Setup " + sgr(30, 46) + "F10" + sgr(0) + f"Quit{ESC}[K")
        frames.append("".join(s))
    return frames


KEYWORDS = ["func", "let", "var", "if", "else", "return", "guard", "for", "in", "struct", "final", "class"]
TYPES = ["Int", "String", "UIView", "Terminal", "CGFloat", "Data", "Bool", "[UInt8]"]


def code_line(rnd: random.Random, i: int) -> str:
    indent = "    " * rnd.randint(0, 3)
    parts = [indent]
    for _ in range(rnd.randint(2, 6)):
        r = rnd.random()
        if r < 0.25:
            parts.append(sgr(38, 5, 170) + rnd.choice(KEYWORDS) + sgr(0) + " ")
        elif r < 0.45:
            parts.append(sgr(38, 5, 37) + rnd.choice(TYPES) + sgr(0) + " ")
        elif r < 0.6:
            parts.append(sgr(38, 5, 179) + f'"str{i}"' + sgr(0) + " ")
        elif r < 0.7:
            parts.append(sgr(38, 5, 244, 3) + f"// note {i}" + sgr(0) + " ")
        else:
            parts.append(f"name{rnd.randint(0, 99)} ")
    return "".join(parts)


def vim_frames(count=600):
    rnd = random.Random(7)
    lines = [code_line(rnd, i) for i in range(2000)]
    frames = [f"{ESC}[?1049h{ESC}[?25l{ESC}[H{ESC}[2J"]
    top = 0
    for n in range(count):
        s = []
        if n % 3 == 2:
            # Scroll one line with a scroll region, like vim's Ctrl-E.
            top += 1
            s.append(f"{ESC}[1;{ROWS - 1}r{ESC}[{ROWS - 1};1H{ESC}[S{ESC}[r")
            row = ROWS - 1
            s.append(at(row, 1) + sgr(38, 5, 242) + f"{top + row:4} " + sgr(0) + lines[(top + row) % len(lines)] + f"{ESC}[K")
        else:
            # Full redraw (page jump / :redraw).
            top += rnd.randint(0, 30)
            for row in range(1, ROWS):
                s.append(at(row, 1) + sgr(38, 5, 242) + f"{top + row:4} " + sgr(0) + lines[(top + row) % len(lines)] + f"{ESC}[K")
        s.append(at(ROWS, 1) + sgr(7) + f" NORMAL  main.swift  {top + 1},1  {(top * 100 // 2000) % 100}% ".ljust(COLS) + sgr(0))
        s.append(at(1 + n % (ROWS - 1), 6) + f"{ESC}[?25h")
        frames.append("".join(s))
    frames.append(f"{ESC}[?1049l")
    return frames


def cjk_stream() -> bytes:
    rows = [
        "English: The quick brown fox jumps over the lazy dog.",
        "中文：终端渲染器评估，宽字符占两列。",
        "日本語：ターミナルのレンダリング。かな漢字",
        "한국어: 터미널 렌더러 평가",
        "Emoji: 😀 👍🏽 👩‍💻 🇨🇳 🇺🇸 ❤️ ✅ 🚀",
        "Combining: é ä ñ (café)",
        "Box: ┌──┬──┐ │ab│cd│ └──┴──┘ ░▒▓█",
        sgr(1) + "Bold 粗体" + sgr(0) + " " + sgr(3) + "Italic 斜体" + sgr(0) + " " + sgr(4) + "Under" + sgr(0),
        sgr(38, 2, 255, 128, 0) + "TrueColor" + sgr(0) + " " + sgr(48, 5, 21) + sgr(97) + " 256-bg " + sgr(0),
    ]
    return ("\r\n".join(rows) + "\r\n").encode("utf-8")


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    write("seq.bin", seq_stream())
    write("ls.bin", ls_stream())
    write_frames("htop.frames", htop_frames())
    write_frames("vim.frames", vim_frames())
    write("cjk.bin", cjk_stream())
    manifest = {}
    for name in sorted(os.listdir(OUT)):
        if name == "manifest.json":
            continue
        with open(os.path.join(OUT, name), "rb") as f:
            data = f.read()
        manifest[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    json.dump(manifest, sys.stdout, indent=2, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
