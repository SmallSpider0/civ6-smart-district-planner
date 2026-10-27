#!/usr/bin/env python3
"""Coverage scenes from players' layouts (issue 61).

A reference scene (set REF, tools/snapshot.py ref on branch mac/baseline2)
cuts the map 6 plots around its cities, so the own cities 7-9 plots away
that an Industrial Zone or Entertainment Complex on the third ring reaches,
and the districts already covering them, are missing. This exports one
scene per reference city from the same save with a wide window (RP..):
the several-cities solver plans that city alone (`only`), the other cities
stay as they are in the save, and the city's districts of the reference
layout (built ones and tacks, as the REF scene lists them) are taken out of
it and kept as `reference`, so the judge can score the author's layout and
the planner can put the districts anywhere.

  python3 -I tools/covscene.py export RP01-bh-japan-okayama --save SDP_ref_bh-hojo-276 \\
      --ref /path/REF04-bh-japan-okayama-osaka.json --city 131073
  python3 -I tools/covscene.py export RP02-... --from SDP_ref_bh-hojo-276 --ref ... --city 262147

--save loads Saves/Single/<name>.Civ6Save first (tools/game.py load on
mac/baseline2 does the same); --from records the name of the save already
loaded. A save of another ruleset is judged under --ruleset (default
Gathering Storm): techs, civics and a pantheon those rules lack are dropped
(meta.dropped), as snapshot.py ref does. The game must be running with the
Tuner on (civ6tuner.py serve).
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import game  # noqa: E402
import snapshot  # noqa: E402

GAMEINFO = os.path.join(snapshot.ROOT, "tests", "compare", ".cache", "gameinfo.lua")
LOAD_SAVE = """
Automation.SetAutoStartEnabled(true)
Network.LoadGame({ Name = "%s", Location = SaveLocations.LOCAL_STORAGE, Type = SaveTypes.SINGLE_PLAYER,
  IsAutosave = false, IsQuicksave = false, Directory = SaveDirectories.DEFAULT }, ServerType.SERVER_TYPE_NONE)
"""


def load(name):
    if game.has_state("InGame") and game.cmd_menu(argparse.Namespace()) != 0:
        return False
    if not game.wait_for("main menu", lambda: game.has_state("MainMenu"), 300):
        return False
    if not game.check_mod_enabled():
        return False
    resp = game.exec_lua("MainMenu", game.MUTE + "; " + LOAD_SAVE % name)
    if not resp.get("ok"):
        print("could not load %s: %s" % (name, resp.get("error")))
        return False
    ready = lambda: game.has_state("SDP_Panel") and game.exec_lua("SDP_Panel", "print(1)").get("ok")  # noqa: E731
    if not game.wait_for("loaded", ready, 600, 5):
        return False
    game.exec_lua("InGame", game.MUTE)
    time.sleep(5)
    game.close_popups()
    return True


def fit_ruleset(spec):
    """Drop the local player's techs, civics and pantheon the comparison's
    rules lack (meta.dropped); return an error when map or district names
    are missing from them."""
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
    names = {v for plot in spec["plots"] for k, v in plot.items() if k in ("t", "f", "r", "imp")}
    names |= {d["type"] for c in spec["cities"] for d in c["districts"]} | {w["building"] for w in spec["wonders"]}
    missing = sorted(n for n in names if not known(n))
    return "not in the comparison's rules: %s" % ", ".join(missing) if missing else None


def cmd_export(args):
    if not args.id.startswith("RP") or not args.id[2:4].isdigit():
        print("the id must look like RP01-some-name")
        return 2
    with open(args.ref, encoding="utf-8") as f:
        ref = json.load(f)
    rmeta = ref["meta"]
    mine = [p for p in ref["reference"]["placements"] if p["city"] == args.city]
    if not mine:
        print("%s has no reference districts for city %d" % (ref["scenario"]["id"], args.city))
        return 2
    if args.save and not load(args.save):
        return 2
    with open(snapshot.EXPORTER, encoding="utf-8") as f:
        snapshot.exec_lua("SDP_Panel", f.read(), 60)
    lines = snapshot.exec_lua("SDP_Panel", "SDP_Export.Scene({ Cities = { [%d] = true }, Radius = %d, Sample = false })"
                              % (args.city, args.radius), 900)
    spec = snapshot.parse_scene(lines)
    meta = spec["meta"]
    if meta["chosen"] != [args.city]:
        print("city %d not found" % args.city)
        return 2
    if (meta["mapWidth"], meta["mapHeight"]) != (rmeta["mapWidth"], rmeta["mapHeight"]):
        print("not the reference scene's map")
        return 2
    # Reference coordinates (REF window) to this window's.
    W, width = meta["mapWidth"], spec["width"]

    def here(x, y):
        gx, gy = (x + rmeta["x0"]) % W, y + rmeta["y0"]
        return (gx - meta["x0"]) % W, gy - meta["y0"]

    base = lambda t: snapshot.UNIQUE_BASE.get(t, t)  # noqa: E731
    city = next(c for c in spec["cities"] if c["owner"] == 0 and c["id"] == args.city)
    placements, notes = [], []
    for p in mine:
        x, y = here(p["x"], p["y"])
        q = {"city": args.city, "type": p["type"], "x": x, "y": y}
        if p.get("pin"):
            q["pin"] = True
            n = len(spec["pins"])
            spec["pins"] = [t for t in spec["pins"] if not (t["x"] == x and t["y"] == y)]
            if len(spec["pins"]) == n:
                print("no tack at %d,%d for %s" % (x, y, p["type"]))
                return 2
        else:
            n = len(city["districts"])
            city["districts"] = [d for d in city["districts"]
                                 if not (d["x"] == x and d["y"] == y and base(d["type"]) == p["type"])]
            if len(city["districts"]) == n:
                print("no built %s at %d,%d" % (p["type"], x, y))
                return 2
            # As snapshot.py ref: a resource revealed under a built district
            # after it was built would make the reference illegal.
            plot = spec["plots"][y * width + x]
            if plot.get("r"):
                notes.append("%s under the built %s at %d,%d left out" % (plot["r"], p["type"], x, y))
                plot.pop("r")
                plot.pop("rc", None)
        placements.append(q)
    saved_ruleset = spec.get("ruleset")
    ruleset = args.ruleset
    spec["ruleset"] = ruleset
    if ruleset != saved_ruleset:
        meta["savedRuleset"] = saved_ruleset
        problem = fit_ruleset(spec)
        if problem:
            print(problem)
            return 2
    me = next(p for p in spec["players"] if p["id"] == 0)
    plan = [p["type"] for p in placements]
    rs = ref["scenario"]
    scenario = {
        "id": args.id, "kind": "multi", "set": "RP", "civ": me["civ"], "leader": me["leader"],
        "title": "%s: %s (coverage)" % (rs.get("author") or rs["id"], city["name"]),
        "districts": plan, "only": [args.city], "target": args.city, "plans": [plan], "file": args.id + ".json",
        "save": args.save or args.from_save, "turn": spec["turn"], "ruleset": ruleset, "ref": rs["id"],
        "source": rs.get("source", ""), "author": rs.get("author", ""), "date": rs.get("date", ""),
    }
    spec["reference"] = {"placements": placements, "from": ref["reference"].get("from"), "ref": rs["id"], "notes": notes}
    spec["scenario"] = scenario
    path = os.path.join(snapshot.SCENES, scenario["file"])
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(spec, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    snapshot.write_index([e for e in snapshot.read_index() if e["id"] != args.id] + [scenario])
    print("%s: %dx%d window, %d cities, %d tacks, ruleset %s%s; reference %s: %s%s" % (
        path, width, spec["height"], len(spec["cities"]), len(spec["pins"]), ruleset,
        " (save: %s)" % saved_ruleset if ruleset != saved_ruleset else "", rs["id"],
        ", ".join("%s@%d,%d%s" % (p["type"][9:], p["x"], p["y"], " (tack)" if p.get("pin") else "") for p in placements),
        "; " + "; ".join(notes) if notes else ""))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ep = sub.add_parser("export", help="export a coverage scene for one reference city")
    ep.add_argument("id", help="RP01-...")
    ep.add_argument("--ref", required=True, help="the REF scene file the layout comes from")
    ep.add_argument("--city", type=int, required=True, help="the reference city's ID")
    ep.add_argument("--save", help="load Saves/Single/<name>.Civ6Save first")
    ep.add_argument("--from", dest="from_save", help="record this save name (already loaded)")
    ep.add_argument("--ruleset", default="RULESET_EXPANSION_2", help="judge under this ruleset (default Gathering Storm)")
    ep.add_argument("--radius", type=int, default=15, help="plots around the city (default 15)")
    args = ap.parse_args(argv)
    return {"export": cmd_export}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
