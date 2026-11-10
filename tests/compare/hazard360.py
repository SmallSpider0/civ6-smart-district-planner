#!/usr/bin/env python3
"""Issue 360 experiment: what keeping disaster plots free costs a plan.

Reads a compare.mjs result file with the variants STANDARD and
STANDARD_HAZ<letters> (tests/compare/cmp_sdp.lua, KeepHazardsFree) on the
real scenes and prints, per variant, the judge's total gain, the districts
placed, and how many of STANDARD's districts sit on each kind of hazard plot.

  python3 -I tests/compare/hazard360.py logs/remote/haz360.jsonl
"""
import json
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
VOLCANOES = {"FEATURE_VOLCANO", "FEATURE_VESUVIUS", "FEATURE_KILIMANJARO", "FEATURE_EYJAFJALLAJOKULL"}
DIRECTIONS = [(1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1)]  # axial, as cmp_game.lua


def load_scene(scene_id):
    with open(os.path.join(HERE, "scenes", scene_id + ".json"), encoding="utf-8") as f:
        return json.load(f)


def hazards(scene, x, y):
    """The hazard kinds of plot (x, y): V, F, A (1 m lowland), L (any lowland)."""
    width, plots = scene["width"], scene["plots"]

    def plot(px, py):
        if px < 0 or py < 0 or px >= width:
            return None
        i = py * width + px
        return plots[i] if i < len(plots) else None

    p = plot(x, y) or {}
    kinds = set()
    if "FLOODPLAINS" in (p.get("f") or ""):
        kinds.add("F")
    if p.get("low") is not None and p.get("low") != -1:
        kinds.add("L")
        if p.get("low") == 0:
            kinds.add("A")
    q, r = x - (y - y % 2) // 2, y
    for dq, dr in DIRECTIONS:
        nq, nr = q + dq, r + dr
        n = plot(nq + (nr - nr % 2) // 2, nr)
        if n and n.get("f") in VOLCANOES:
            kinds.add("V")
    return kinds


def main(path):
    rows = defaultdict(dict)
    with open(path, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            if r.get("score") is None:
                continue
            rows[r["scenario"]][r["variant"]] = r
    variants = sorted({v for byv in rows.values() for v in byv}, key=lambda v: (v != "STANDARD", v))
    base = "STANDARD"
    on = defaultdict(int)  # STANDARD districts on each hazard kind
    affected = defaultdict(set)  # scenes where STANDARD used such a plot
    districts = 0
    for scene_id, byv in sorted(rows.items()):
        if base not in byv:
            continue
        scene = load_scene(scene_id)
        for item in byv[base]["score"]["items"]:
            districts += 1
            for k in hazards(scene, item["x"], item["y"]):
                on[k] += 1
                affected[k].add(scene_id)
    print(f"scenes {len(rows)}, STANDARD districts {districts}")
    for k, name in (("V", "next to a volcano"), ("F", "floodplains"), ("A", "1 m lowland"), ("L", "any lowland")):
        print(f"  {name}: {on[k]} districts in {len(affected[k])} scenes")
    print()
    print(f"{'variant':24} {'scenes':>6} {'gain':>7} {'placed':>7} {'missing':>7}  loss in the scenes it changed")
    for v in variants:
        common = [s for s, byv in rows.items() if v in byv and base in byv]
        gain = sum(rows[s][v]["score"]["gain"] for s in common)
        placed = sum(rows[s][v]["score"]["placed"] for s in common)
        missing = sum(rows[s][v]["score"]["missing"] for s in common)
        changed = [s for s in common if rows[s][v]["score"]["gain"] != rows[s][base]["score"]["gain"]
                   or rows[s][v]["score"]["placed"] != rows[s][base]["score"]["placed"]]
        g0 = sum(rows[s][base]["score"]["gain"] for s in changed)
        g1 = sum(rows[s][v]["score"]["gain"] for s in changed)
        rel = f"{(g1 - g0) / g0 * 100:+.1f}%" if g0 else "-"
        print(f"{v:24} {len(common):>6} {gain:>7.1f} {placed:>7} {missing:>7}  {len(changed)} scenes, {g1 - g0:+.1f} ({rel})")


if __name__ == "__main__":
    main(sys.argv[1])
