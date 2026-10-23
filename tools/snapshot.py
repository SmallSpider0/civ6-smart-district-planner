#!/usr/bin/env python3
"""Scenes from real games for the offline comparison (issue 37).

A scene is a window of a running game exported through the Tuner
(tests/bench/export_scene.lua) into tests/compare/scenes/<id>.json: the map,
rivers, ownership, built districts and wonders, the player's techs and map
tacks, in the shape tests/compare/cmp_game.lua builds a world from, plus the
adjacency DMT reported in the game for every plannable district on every
owned plot, so the offline world can be checked against the game.
tests/compare/scenes/index.json lists the scenes; cmp_scenarios.lua adds
them to the scenario list (ids RS.. single, RM.. multi), summarize.py
reports them as the "real" group.

  python3 -I tools/snapshot.py export RS01-pangaea-japan-kyoto --save pangaea-gs --cities 65536
  python3 -I tools/snapshot.py export RM01-pangaea-japan-3c --save pangaea-gs --cities 65536,65537,65538
  python3 -I tools/snapshot.py check RS01-pangaea-japan-kyoto     # offline DMT vs the game's sample
  python3 -I tools/snapshot.py list

--save loads that stress-test save first (tools/stress.py load); without
it the game must already be in the wanted position. The game must be
running with the Tuner on (and civ6tuner.py serve, see tools/README.md).
"""

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import stress  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENES = os.path.join(ROOT, "tests", "compare", "scenes")
INDEX = os.path.join(SCENES, "index.json")
EXPORTER = os.path.join(ROOT, "tests", "bench", "export_scene.lua")

# What the dev set asks for (tests/compare/cmp_scenarios.lua) plus an
# Entertainment Complex and, for a city with sea within 3 rings, a Harbor;
# each city asks for what it has not built yet (a late city has built most).
DEFAULT_DISTRICTS = ["DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_THEATER",
                     "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_HARBOR"]
# A civilization's own district for a base one (the game's District.TraitType
# replacements): a built Seowon means the Campus is built.
UNIQUE_BASE = {
    "DISTRICT_SEOWON": "DISTRICT_CAMPUS", "DISTRICT_OBSERVATORY": "DISTRICT_CAMPUS",
    "DISTRICT_LAVRA": "DISTRICT_HOLY_SITE", "DISTRICT_HANSA": "DISTRICT_INDUSTRIAL_ZONE",
    "DISTRICT_OPPIDUM": "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ACROPOLIS": "DISTRICT_THEATER",
    "DISTRICT_SUGUBA": "DISTRICT_COMMERCIAL_HUB", "DISTRICT_ROYAL_NAVY_DOCKYARD": "DISTRICT_HARBOR",
    "DISTRICT_COTHON": "DISTRICT_HARBOR", "DISTRICT_IKANDA": "DISTRICT_ENCAMPMENT",
    "DISTRICT_THANH": "DISTRICT_ENCAMPMENT", "DISTRICT_MBANZA": "DISTRICT_NEIGHBORHOOD",
    "DISTRICT_STREET_CARNIVAL": "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_HIPPODROME": "DISTRICT_ENTERTAINMENT_COMPLEX",
    "DISTRICT_BATH": "DISTRICT_AQUEDUCT",
}


def exec_lua(state, code, timeout=30.0):
    resp = civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise RuntimeError("%s: %s" % (state, resp.get("error")))
    return resp.get("output") or []


def read_index():
    if not os.path.exists(INDEX):
        return []
    with open(INDEX, encoding="utf-8") as f:
        return json.load(f)


def write_index(entries):
    entries.sort(key=lambda e: e["id"])
    os.makedirs(SCENES, exist_ok=True)
    with open(INDEX, "w", encoding="utf-8", newline="\n") as f:
        json.dump(entries, f, ensure_ascii=False, indent=1)
        f.write("\n")


def parse_scene(lines):
    """Assemble the exporter's chunks into one spec."""
    spec, lists = None, {"plots": [], "cities": [], "sample": []}
    done = False
    for line in lines:
        if not line.startswith("SDP_SCENE "):
            continue
        kind, payload = line[len("SDP_SCENE "):].split(" ", 1)
        data = json.loads(payload)
        if kind == "head":
            spec = data
        elif kind in lists:
            lists[kind].extend(data["items"])
        elif kind == "end":
            done = True
            if data["plots"] != len(lists["plots"]) or data["cities"] != len(lists["cities"]):
                raise RuntimeError("scene output incomplete: %s vs %d plots, %d cities"
                                   % (data, len(lists["plots"]), len(lists["cities"])))
    if spec is None or not done:
        raise RuntimeError("no scene in the output (%d lines)" % len(lines))
    spec.update(lists)
    return spec


def hex_distance(x1, y1, x2, y2):
    """Distance on the odd-r hex grid cmp_game.lua uses (odd rows shifted right)."""
    def cube(x, y):
        q = x - (y - (y & 1)) // 2
        return q, y, -q - y
    a, b = cube(x1, y1), cube(x2, y2)
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def sea_near(spec, city, rings=3):
    width = spec["width"]
    for i, p in enumerate(spec["plots"]):
        if p["t"] in ("TERRAIN_COAST", "TERRAIN_OCEAN") and not p.get("lake"):
            if hex_distance(i % width, i // width, city["x"], city["y"]) <= rings:
                return True
    return False


def exclusive_pairs():
    """The game's MutuallyExclusiveDistricts (Gathering Storm: the
    Entertainment Complex and the Water Park), both ways."""
    pairs = set()
    code = ("if GameInfo.MutuallyExclusiveDistricts ~= nil then for r in GameInfo.MutuallyExclusiveDistricts() do "
            "print('SDP_EXCL ' .. r.District .. ' ' .. r.MutuallyExclusiveDistrict) end end")
    for line in exec_lua("SDP_Panel", code):
        if line.startswith("SDP_EXCL "):
            a, b = line.split()[1:3]
            pairs.add((a, b))
            pairs.add((b, a))
    return pairs


def wanted_for(spec, city, base_list, exclusive=frozenset()):
    built = {d["type"] for d in city["districts"]}
    built |= {UNIQUE_BASE.get(t, t) for t in built}
    return [d for d in base_list if d not in built and (d != "DISTRICT_HARBOR" or sea_near(spec, city))
            and not any((d, b) in exclusive for b in built)]


def cmd_export(args):
    if not args.id[:2] in ("RS", "RM"):
        print("the id must start with RS (one city) or RM (several cities)")
        return 2
    if args.save:
        if stress.cmd_load(argparse.Namespace(name=args.save)) != 0:
            return 2
    with open(EXPORTER, encoding="utf-8") as f:
        exec_lua("SDP_Panel", f.read(), 60)
    cities = [int(c) for c in args.cities.split(",")] if args.cities else None
    lua_cities = "{ %s }" % ", ".join("[%d] = true" % c for c in cities) if cities else "nil"
    lines = exec_lua("SDP_Panel", "SDP_Export.Scene({ Cities = %s, Radius = %d, Sample = %s })"
                     % (lua_cities, args.radius, "false" if args.no_sample else "true"), 900)
    spec = parse_scene(lines)
    chosen = spec["meta"]["chosen"]
    if cities and sorted(cities) != sorted(chosen):
        print("cities not found: %s" % sorted(set(cities) - set(chosen)))
        return 2
    kind = "single" if args.id.startswith("RS") else "multi"
    if kind == "single" and len(chosen) != 1:
        print("an RS scene takes one city (--cities ID)")
        return 2
    me = next(p for p in spec["players"] if p["id"] == 0)
    base_list = args.districts.split(",") if args.districts else DEFAULT_DISTRICTS
    chosen.sort()  # the order cmp_lib's Setup lists the cities in (by id)
    by_id = {c["id"]: c for c in spec["cities"] if c["owner"] == 0}
    exclusive = exclusive_pairs()
    plans = [wanted_for(spec, by_id[cid], base_list, exclusive) for cid in chosen]
    union = [d for d in base_list if any(d in plan for plan in plans)]
    scenario = {
        "id": args.id, "kind": kind, "set": "R", "civ": me["civ"], "leader": me["leader"],
        "title": args.title or "%s, %s" % (me["civ"].replace("CIVILIZATION_", "").title(), args.save or args.from_save or "game"),
        "districts": union, "only": chosen, "target": args.target or chosen[0], "file": args.id + ".json",
        "save": args.save or args.from_save, "turn": spec["turn"], "ruleset": spec.get("ruleset"),
    }
    if kind == "multi":
        scenario["plans"] = plans  # each city its own list, in city-id order (as the V scenarios)
    wanted = union
    spec["scenario"] = scenario
    os.makedirs(SCENES, exist_ok=True)
    path = os.path.join(SCENES, scenario["file"])
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(spec, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    entries = [e for e in read_index() if e["id"] != args.id] + [scenario]
    write_index(entries)
    meta = spec["meta"]
    print("%s: %dx%d window at %d,%d of the %dx%d map, %d cities, %d rivers, %d tacks, %d samples; "
          "owned plots dropped %d, river crossings missed %d; asks for %s"
          % (path, spec["width"], spec["height"], meta["x0"], meta["y0"], meta["mapWidth"], meta["mapHeight"],
             len(spec["cities"]), len(spec["rivers"]), len(spec["pins"]), len(spec["sample"]),
             meta["droppedOwned"], meta["riverMissed"],
             "; ".join(", ".join(d.replace("DISTRICT_", "") for d in plan) or "nothing" for plan in plans)))
    if meta["riverMissed"]:
        print("WARNING: %d river crossings are not in any river's edges" % meta["riverMissed"])
    return 0


def cmd_check(args):
    code = 0
    for sid in args.ids or [e["id"] for e in read_index()]:
        print("== " + sid)
        proc = subprocess.run(["node", os.path.join(ROOT, "tools", "compare.mjs"), "--probe",
                               os.path.join(ROOT, "tests", "compare", "cmp_scene_check.lua"), "--arg", sid],
                              cwd=ROOT, capture_output=True, text=True)
        out = [l for l in proc.stdout.splitlines() if not l.startswith("Loading ")]
        print("\n".join(out[-40:]))
        if proc.returncode != 0:
            print(proc.stderr[-2000:])
            code = 1
    return code


def cmd_list(_args):
    for e in read_index():
        print("%-32s %-6s %-26s turn %-4s %s" % (e["id"], e["kind"], e["civ"], e.get("turn"), ", ".join(e["districts"])))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ep = sub.add_parser("export", help="export a scene from the running game")
    ep.add_argument("id", help="RS01-... (one city) or RM01-... (several cities)")
    ep.add_argument("--save", help="load this stress-test save first (name as in tools/stress.py)")
    ep.add_argument("--from", dest="from_save", help="record this save name without loading it (already loaded)")
    ep.add_argument("--cities", help="city IDs, comma-separated (default: all of the player's)")
    ep.add_argument("--target", type=int, help="the city a single scene plans (default: the lowest ID)")
    ep.add_argument("--districts", help="base district types to ask for (default: the dev set's five minus built)")
    ep.add_argument("--radius", type=int, default=6, help="plots around each chosen city (default 6)")
    ep.add_argument("--title", help="scenario title")
    ep.add_argument("--no-sample", action="store_true", help="skip the in-game DMT sample")
    cp = sub.add_parser("check", help="compare the offline world's DMT with the game's sample")
    cp.add_argument("ids", nargs="*")
    sub.add_parser("list")
    args = ap.parse_args(argv)
    return {"export": cmd_export, "check": cmd_check, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
