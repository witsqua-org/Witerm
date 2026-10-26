#!/usr/bin/env python3
"""Check authored UI color pairs; this does not certify arbitrary terminal RGB."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "apps/apple/Sources/Assets.xcassets"
PAIRS = [("Ink", "Canvas"), ("SecondaryInk", "Canvas"), ("Ink", "Surface"),
         ("SecondaryInk", "Surface"), ("AccentColor", "Surface"),
         ("Warning", "Surface"), ("ActionLabel", "AccentColor")]


def color(name, mode, contrast):
    candidates = []
    for entry in json.loads((ASSETS / (name + ".colorset") / "Contents.json").read_text())["colors"]:
        appearance = {item["appearance"]: item["value"] for item in entry.get("appearances", [])}
        if appearance.get("luminosity", "light") != mode or appearance.get("contrast", "normal") != contrast:
            continue
        values = entry["color"]["components"]
        candidates.append([int(values[k], 16) / 255 if values[k].startswith("0x") else float(values[k])
                           for k in ("red", "green", "blue")])
    assert len(candidates) == 1, (name, mode, contrast)
    return candidates[0]


def luminance(rgb):
    return sum(weight * (v / 12.92 if v <= 0.04045 else ((v + .055) / 1.055) ** 2.4)
               for weight, v in zip((.2126, .7152, .0722), rgb))


minimum = 100.0
for mode in ("light", "dark"):
    for contrast, threshold in (("normal", 4.5), ("high", 7.0)):
        ratios = []
        for fg, bg in PAIRS:
            a, b = sorted((luminance(color(fg, mode, contrast)), luminance(color(bg, mode, contrast))))
            ratio = (b + .05) / (a + .05)
            assert ratio >= threshold, (mode, contrast, fg, bg, ratio)
            ratios.append(ratio)
        print(f"PASS {mode}/{contrast}: {len(ratios)} color pairs, minimum {min(ratios):.2f}:1")
