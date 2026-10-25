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
reports them as the "real" group. RC.. (coverage, issue 61) is one city
planned with the several-cities solver (a multi scene whose `only` is that
city), exported with a wider window so the own cities its regional
districts can reach, and the districts already covering them, are in it.

  python3 -I tools/snapshot.py export RS01-pangaea-japan-kyoto --save pangaea-gs --cities 65536
  python3 -I tools/snapshot.py export RM01-pangaea-japan-3c --save pangaea-gs --cities 65536,65537,65538
  python3 -I tools/snapshot.py export RC01-pangaea-japan-kyoto --save pangaea-gs --cities 65536 --radius 15
  python3 -I tools/snapshot.py check RS01-pangaea-japan-kyoto     # offline DMT vs the game's sample
  python3 -I tools/snapshot.py list
  python3 -I tools/snapshot.py ref REF04-bh-japan-okayama --from bh-hojo-276 --cities 131073,262147 \
      --source URL --author NAME --date 2019-04 --title "..."   # a reference scene (issue 53)

`ref` exports a reference scene (set REF, tools/refscene.py) from a loaded
community save (tools/game.py load): the real map, and as the reference
layout the author's built districts of the chosen cities (--reference
built, the default), their district map tacks (--reference pins), or
both (--reference both; a tack's placement is marked "pin": true). Those
districts leave the cities (the tacks leave the pin list), so the optimum
may put them anywhere; every other district, wonder and tack stays. For
each built reference district the game's adjacency is kept as
reference.claimed, to compare with the judge: the placement lens's value
(plot:GetAdjacencyYield) and, as withPolicies, the district's own, which
policy cards double. A Rise and Fall save can be judged under --ruleset
RULESET_EXPANSION_2: the save's ruleset is kept as meta.savedRuleset, and
techs, civics or a pantheon the comparison's rules lack are dropped
(meta.dropped).

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
    if not args.id[:2] in ("RS", "RM", "RC"):
        print("the id must start with RS (one city), RM (several cities) or RC (one city, several-cities solver)")
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
    if args.id[:2] in ("RS", "RC") and len(chosen) != 1:
        print("an %s scene takes one city (--cities ID)" % args.id[:2])
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


# What a reference layout is made of by default: the districts with
# adjacency yields (base types; a civilization's own counts as its base).
REF_TYPES = ["DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
             "DISTRICT_HARBOR", "DISTRICT_INDUSTRIAL_ZONE"]
# The engine's adjacency of each built district of the chosen cities, in
# game coordinates (a UI state: districts and their yields as the player
# sees them).
CLAIMED = """
local pid, chosen = Game.GetLocalPlayer(), %s
for _, city in Players[pid]:GetCities():Members() do
  if chosen[city:GetID()] then
    for _, d in city:GetDistricts():Members() do
      local row = GameInfo.Districts[d:GetType()]
      if not row.CityCenter then
        -- The plot's value (the placement lens) is the adjacency alone; the
        -- district's own includes policy cards that double it.
        local plot, parts, total = Map.GetPlot(d:GetX(), d:GetY()), {}, 0
        for y in GameInfo.Yields() do
          local v = plot:GetAdjacencyYield(pid, city:GetID(), row.Index, y.Index) or 0
          if v ~= 0 then parts[#parts + 1] = y.YieldType .. "=" .. v end
          total = total + (d:GetAdjacencyYield(y.Index) or 0)
        end
        print("SDP_CLAIM " .. city:GetID() .. " " .. row.DistrictType .. " " .. d:GetX() .. " " .. d:GetY() .. " "
          .. tostring(d:IsComplete()) .. " " .. total .. " " .. table.concat(parts, ","))
      end
    end
  end
end
"""


def claimed_adjacency(lua_cities, meta):
    """{(city, local x, local y): {"type", "complete", "yields", "district"}} from
    the game: yields as the placement lens shows them (plot:GetAdjacencyYield),
    "district" the district's own total, policy cards included."""
    out = {}
    for line in exec_lua("InGame", CLAIMED % lua_cities, 60):
        if not line.startswith("SDP_CLAIM "):
            continue
        parts = line.split(" ")
        cid, dtype, gx, gy, complete = int(parts[1]), parts[2], int(parts[3]), int(parts[4]), parts[5] == "true"
        yields = {}
        for kv in (parts[7] if len(parts) > 7 else "").split(","):
            if kv:
                k, v = kv.split("=")
                yields[k] = float(v)
        lx, ly = (gx - meta["x0"]) % meta["mapWidth"], gy - meta["y0"]
        out[(cid, lx, ly)] = {"type": dtype, "complete": complete, "yields": yields, "district": float(parts[6])}
    return out


GAMEINFO = os.path.join(ROOT, "tests", "compare", ".cache", "gameinfo.lua")


def fit_ruleset(spec):
    """A save judged under another ruleset: drop the local player's techs,
    civics and pantheon the comparison's rules lack (recorded in
    meta.dropped); a map type they lack is an error (returned)."""
    if not os.path.exists(GAMEINFO):
        return "no %s (tools/compare.mjs exports it); cannot check the names" % os.path.relpath(GAMEINFO, ROOT)
    with open(GAMEINFO, encoding="utf-8") as f:
        text = f.read()
    known = lambda name: ('"%s"' % name) in text  # noqa: E731
    dropped = []
    for p in spec["players"]:
        for key in ("techs", "civics"):
            if isinstance(p.get(key), list):
                dropped += [n for n in p[key] if not known(n)]
                p[key] = [n for n in p[key] if known(n)]
        if p.get("pantheon") and not known(p["pantheon"]):
            dropped.append(p.pop("pantheon"))
    if dropped:
        spec["meta"]["dropped"] = sorted(set(dropped))
        print("not in the comparison's rules, dropped: %s" % ", ".join(sorted(set(dropped))))
    names = {v for plot in spec["plots"] for k, v in plot.items() if k in ("t", "f", "r", "imp")}
    names |= {d["type"] for c in spec["cities"] for d in c["districts"]} | {w["building"] for w in spec["wonders"]}
    missing = sorted(n for n in names if not known(n))
    return "not in the comparison's rules: %s" % ", ".join(missing) if missing else None


def settle_reference(spec):
    """A layout of built districts, taken out of the cities: the game's DMT
    sample was taken with them in place (a Japanese district next to them
    shows more), so it does not describe the scene and is dropped; a
    resource under one appeared after it was built (strategic resources are
    revealed late) and is dropped too, with a note, so the reference stays
    legal as the game let it stand."""
    ref = spec["reference"]
    if ref.get("from") not in ("built", "both"):
        return
    spec["sample"] = []
    width = spec["width"]
    for p in ref["placements"]:
        if p.get("pin"):
            continue
        plot = spec["plots"][p["y"] * width + p["x"]]
        if plot.get("r"):
            note = "%s under the built %s at %d,%d left out (revealed after it was built)" % (
                plot["r"], p["type"], p["x"], p["y"])
            if note not in ref["notes"]:
                ref["notes"].append(note)
            plot.pop("r")
            plot.pop("rc", None)


def cmd_ref(args):
    if not args.id.startswith("REF") or not args.id[3:5].isdigit():
        print("the id must look like REF04-some-name")
        return 2
    if args.save and stress.cmd_load(argparse.Namespace(name=args.save)) != 0:
        return 2
    with open(EXPORTER, encoding="utf-8") as f:
        exec_lua("SDP_Panel", f.read(), 60)
    cities = [int(c) for c in args.cities.split(",")]
    lua_cities = "{ %s }" % ", ".join("[%d] = true" % c for c in cities)
    lines = exec_lua("SDP_Panel", "SDP_Export.Scene({ Cities = %s, Radius = %d, Sample = %s })"
                     % (lua_cities, args.radius, "false" if args.no_sample else "true"), 900)
    spec = parse_scene(lines)
    chosen = sorted(spec["meta"]["chosen"])
    if sorted(cities) != chosen:
        print("cities not found: %s" % sorted(set(cities) - set(chosen)))
        return 2
    me = next(p for p in spec["players"] if p["id"] == 0)
    width = spec["width"]
    types = [t.upper() if t.upper().startswith("DISTRICT_") else "DISTRICT_" + t.upper()
             for t in args.types.split(",")] if args.types else REF_TYPES
    base = lambda t: UNIQUE_BASE.get(t, t)  # noqa: E731
    by_id = {c["id"]: c for c in spec["cities"] if c["owner"] == 0}
    claims = claimed_adjacency(lua_cities, spec["meta"])
    placements, claimed = [], []
    if args.reference in ("built", "both"):
        for cid in chosen:
            city, keep = by_id[cid], []
            for d in city["districts"]:
                if base(d["type"]) in types:
                    placements.append({"city": cid, "type": base(d["type"]), "x": d["x"], "y": d["y"]})
                    claim = claims.get((cid, d["x"], d["y"]), {})
                    claimed.append({"city": cid, "type": d["type"], "x": d["x"], "y": d["y"],
                                    "complete": claim.get("complete"), "yields": claim.get("yields", {}),
                                    "adj": sum(claim.get("yields", {}).values()),
                                    "withPolicies": claim.get("district")})
                else:
                    keep.append(d)
            city["districts"] = keep
    if args.reference in ("pins", "both"):
        # District tacks within 3 of a chosen city, not on a city or a built
        # district: to the chosen city owning the plot, else the nearest one
        # (lower ID on a tie), skipping a city that has that district
        # already (a city has one of each); a tack no city can take stays a
        # tack.
        built = {(d["x"], d["y"]) for c in spec["cities"] for d in c["districts"]}
        built |= {(p["x"], p["y"]) for p in placements}
        built |= {(c["x"], c["y"]) for c in spec["cities"]}
        owner = {i: c["id"] for c in spec["cities"] if c["owner"] == 0 for i in c["plots"]}
        kept = []
        for pin in spec["pins"]:
            icon = pin.get("icon") or ""
            dtype = base(icon[5:]) if icon.startswith("ICON_DISTRICT_") else None
            near = sorted((hex_distance(pin["x"], pin["y"], by_id[c]["x"], by_id[c]["y"]), c) for c in chosen)
            near = [(dist, c) for dist, c in near if dist <= 3]
            if dtype in types and near and (pin["x"], pin["y"]) not in built:
                first = owner.get(pin["y"] * width + pin["x"])
                order = ([first] if first in chosen else []) + [c for _, c in near if c != first]
                has = lambda c: any(p["city"] == c and p["type"] == dtype for p in placements)  # noqa: E731
                cid = next((c for c in order if not has(c)), None)
                if cid is None:
                    kept.append(pin)
                    print("tack %s at %d,%d left as a tack: every city in reach has one" % (dtype, pin["x"], pin["y"]))
                    continue
                placements.append({"city": cid, "type": dtype, "x": pin["x"], "y": pin["y"], "pin": True})
            else:
                kept.append(pin)
        spec["pins"] = kept
    if not placements:
        print("no reference districts found (%s)" % args.reference)
        return 2
    plans = [[p["type"] for p in placements if p["city"] == cid] for cid in chosen]
    union = []
    for plan in plans:
        for t in plan:
            if t not in union:
                union.append(t)
    kind = "single" if len(chosen) == 1 else "multi"
    saved_ruleset = spec.get("ruleset")
    ruleset = args.ruleset or saved_ruleset
    scenario = {
        "id": args.id, "kind": kind, "set": "REF", "civ": me["civ"], "leader": me["leader"],
        "title": args.title or args.id, "districts": union, "only": chosen, "target": chosen[0],
        "file": args.id + ".json", "save": args.save or args.from_save, "turn": spec["turn"], "ruleset": ruleset,
        "source": args.source or "", "author": args.author or "", "date": args.date or "",
    }
    if kind == "multi":
        scenario["plans"] = plans
    spec["ruleset"] = ruleset
    if ruleset != saved_ruleset:
        spec["meta"]["savedRuleset"] = saved_ruleset
        problem = fit_ruleset(spec)
        if problem:
            print(problem)
            return 2
    spec["reference"] = {"placements": placements, "guessed": [], "guessAll": False, "from": args.reference,
                         "claimed": claimed, "notes": list(args.note or [])}
    settle_reference(spec)
    spec["scenario"] = scenario
    path = os.path.join(SCENES, scenario["file"])
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(spec, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    write_index([e for e in read_index() if e["id"] != args.id] + [scenario])
    print("%s: %dx%d window, %d cities chosen, ruleset %s%s; reference (%s): %s" % (
        path, spec["width"], spec["height"], len(chosen), ruleset,
        " (save: %s)" % saved_ruleset if ruleset != saved_ruleset else "", args.reference,
        ", ".join("%s@%d,%d%s" % (p["type"][9:], p["x"], p["y"], "" if kind == "single" else "/%d" % p["city"])
                  for p in placements)))
    for c in claimed:
        print("  claimed %s @%d,%d city %d: %s (with policies %s)%s" % (
            c["type"][9:], c["x"], c["y"], c["city"], c["adj"], c["withPolicies"], "" if c["complete"] else " (not complete)"))
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
    ep.add_argument("id", help="RS01-... (one city), RM01-... (several cities) or RC01-... (one city, several-cities solver)")
    ep.add_argument("--save", help="load this stress-test save first (name as in tools/stress.py)")
    ep.add_argument("--from", dest="from_save", help="record this save name without loading it (already loaded)")
    ep.add_argument("--cities", help="city IDs, comma-separated (default: all of the player's)")
    ep.add_argument("--target", type=int, help="the city a single scene plans (default: the lowest ID)")
    ep.add_argument("--districts", help="base district types to ask for (default: the dev set's five minus built)")
    ep.add_argument("--radius", type=int, default=6, help="plots around each chosen city (default 6)")
    ep.add_argument("--title", help="scenario title")
    ep.add_argument("--no-sample", action="store_true", help="skip the in-game DMT sample")
    rp = sub.add_parser("ref", help="export a reference scene (set REF) from a loaded community save")
    rp.add_argument("id", help="REF04-...")
    rp.add_argument("--cities", required=True, help="city IDs, comma-separated")
    rp.add_argument("--save", help="load this stress-test save first (name as in tools/stress.py)")
    rp.add_argument("--from", dest="from_save", help="record this save name (already loaded)")
    rp.add_argument("--reference", choices=("built", "pins", "both"), default="built",
                    help="the author's built districts (default), district map tacks, or both")
    rp.add_argument("--types", help="base district types in the reference (default: %s)"
                    % ",".join(t[9:] for t in REF_TYPES).lower())
    rp.add_argument("--ruleset", help="judge under this ruleset (default the save's)")
    rp.add_argument("--radius", type=int, default=6, help="plots around each chosen city (default 6)")
    rp.add_argument("--title")
    rp.add_argument("--source")
    rp.add_argument("--author")
    rp.add_argument("--date")
    rp.add_argument("--note", action="append", help="a note (repeatable)")
    rp.add_argument("--no-sample", action="store_true", help="skip the in-game DMT sample")
    cp = sub.add_parser("check", help="compare the offline world's DMT with the game's sample")
    cp.add_argument("ids", nargs="*")
    sub.add_parser("list")
    args = ap.parse_args(argv)
    return {"export": cmd_export, "ref": cmd_ref, "check": cmd_check, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
