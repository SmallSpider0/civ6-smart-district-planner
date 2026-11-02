"""Several cities tab: wait and plan by the number of cities (issue 63).

On the loaded game (a stress save, tools/stress.py load NAME): place
city-center pins with the sites tab's solver when asked (--sites K), order
the capital, the other cities and the pins by distance from the capital, then

  grid   for each tier and n = 2..max: the n nearest take part, the tab's
         request solved at once (timed per Tuner request, as tools/stress.py
         does); --frames solves over frames instead and polls every 0.1 s
         (slower when other programs keep the machine busy; see
         docs/multicity-design.md section 30);
  groups the max nearest planned at once, in groups of 4, of 2 and city by
         city (each group's plan tacked before the next, as a player who
         plans a few cities at a time would); the tacks are undone after.

  many   (--many, issue 142) for each n in --sizes (e.g. 8,12,16) the n
         nearest, solved at once with each of --variants: ALL (one search,
         no groups), G<size>[P<passes>] (groups of nearby cities; plain G4 is
         the default GROUP_SIZE and GROUP_PASSES); written to
         multi_size-NAME-many.json. Also times setting up the search alone
         (the scans before the first slice of a solve over frames).

Every city picks `--count` districts from the default pool (all specialty
districts without an empire limit), land part on, reminder pins off.
Changes the game in memory only (pins; do not save). Results are written to
tests/bench/results/multi_size-NAME.json.

    python3 -I tests/bench/multi_size.py NAME [--sites 3] [--max 8] [--count 3] [--tiers FAST,STANDARD,FINE]
    python3 -I tests/bench/multi_size.py NAME --many --sizes 8,12,16 --variants ALL,G4 --tiers STANDARD
"""
import argparse
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402

RESULTS = os.path.join(ROOT, "tests", "bench", "results")


def run(code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("SDP_Panel: %s" % resp.get("error"))
    return resp.get("output") or []


def emitted(lines, tag="SDP_MSIZE "):
    for line in lines:
        if line.startswith(tag):
            return json.loads(line[len(tag):])
    return None


def solve(label, timeout=900, at_once=True):
    if at_once:
        started = time.monotonic()
        out = run('SDP_MultiSize.SolveNow("%s")' % label, timeout=timeout)
        seconds = time.monotonic() - started
        data = emitted(run('SDP_MultiSize.Report("%s")' % label))
        data["Wait"] = round(seconds, 2)
        data["AtOnce"] = True
        print("  %-28s %6.2fs at once  est %5.1fs  ok=%s adj=%s gain=%s placed=%s cross=%d calls=%s" % (
            label, seconds, data["Estimate"]["Seconds"], data.get("Ok"), data.get("Adjacency"), data.get("Gain"),
            data.get("Placed"), len(data.get("Cross") or []), data.get("Calls")), flush=True)
        return data
    started = time.monotonic()
    out = run('SDP_MultiSize.Start("%s")' % label)
    if not any(line.startswith("STARTED true") for line in out):
        raise SystemExit("did not start: %s %s" % (label, out))
    while True:
        lines = run("SDP_MultiSize.Running()")
        if any(line.startswith("RUNNING 0") for line in lines):
            break
        if time.monotonic() - started > timeout:
            raise SystemExit("timeout: " + label)
        time.sleep(0.1)
    seconds = time.monotonic() - started
    data = emitted(run('SDP_MultiSize.Report("%s")' % label))
    data["Wait"] = round(seconds, 2)
    print("  %-28s %6.1fs  est %5.1fs  ok=%s adj=%s gain=%s placed=%s cross=%d" % (
        label, seconds, data["Estimate"]["Seconds"], data.get("Ok"), data.get("Adjacency"), data.get("Gain"),
        data.get("Placed"), len(data.get("Cross") or [])), flush=True)
    return data


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--sites", default="0", help="place this many city-center pins first (rounds: 12,12)")
    ap.add_argument("--dense", action="store_true", help="the pins packed as densely as they fit (issue 87)")
    ap.add_argument("--site-distance", type=int, default=8, help="the pins at most this far from a city")
    ap.add_argument("--max", type=int, default=8)
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--tiers", default="FAST,STANDARD,FINE")
    ap.add_argument("--group-tiers", default="STANDARD")
    ap.add_argument("--skip-grid", action="store_true")
    ap.add_argument("--frames", action="store_true")
    ap.add_argument("--many", action="store_true", help="issue 142: groups against one search")
    ap.add_argument("--sizes", default="8,12,16")
    ap.add_argument("--variants", default="ALL,G4")
    args = ap.parse_args(argv)

    with open(os.path.join(ROOT, "tests", "bench", "stress.lua"), encoding="utf-8") as fh:
        run(fh.read())
    with open(os.path.join(ROOT, "tests", "bench", "multi_size.lua"), encoding="utf-8") as fh:
        run(fh.read())
    run('SDP_Panel.Open(); SDP_Panel.SelectTab("MULTI")')
    for k in [int(x) for x in args.sites.split(",") if int(x) > 0]:
        print(run('SDP_Stress.Sites(%d, %d, "STANDARD", %s); SDP_Stress.PlaceSites()'
                  % (k, args.site_distance, "true" if args.dense else "false"), timeout=900))
    order = emitted(run("SDP_MultiSize.Order()"))
    n_max = min(args.max, len(order["List"]))
    print("order:", [(e["Kind"], e["Name"], e["Distance"]) for e in order["List"]])
    record = {"Name": args.name, "Count": args.count, "Order": order, "Grid": [], "Groups": []}
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, "multi_size-%s.json" % args.name)
    if args.many:
        many(args, order, os.path.join(RESULTS, "multi_size-%s-many.json" % args.name))
        return

    def save():
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(record, fh, ensure_ascii=False, indent=1)

    if not args.skip_grid:
        for tier in args.tiers.split(","):
            for n in range(2, n_max + 1):
                run('SDP_MultiSize.Setup("%s", %d); SDP_MultiSize.Select(1, %d)' % (tier, args.count, n))
                data = solve("%s n=%d" % (tier, n), at_once=not args.frames)
                data.update({"Tier": tier, "N": n})
                record["Grid"].append(data)
                save()
    for tier in args.group_tiers.split(","):
        for size in (n_max, 4, 2, 1):
            if size > n_max:
                continue
            groups, a = [], 1
            while a <= n_max:
                b = min(n_max, a + size - 1)
                run('SDP_MultiSize.Setup("%s", %d); SDP_MultiSize.Select(%d, %d)' % (tier, args.count, a, b))
                data = solve("%s g=%d %d-%d" % (tier, size, a, b), at_once=not args.frames)
                data.update({"Tier": tier, "Size": size, "From": a, "To": b})
                groups.append(data)
                if data.get("Ok") and data.get("Placed", 0) > 0:
                    run("SDP_MultiSize.Place()")
                    data["Tacked"] = True
                a = b + 1
            tacked = sum(1 for g in groups if g.get("Tacked"))
            if tacked:
                print("  ", run("SDP_MultiSize.Undo(%d)" % tacked))
            total = {k: sum((g.get(k) or 0) for g in groups) for k in ("Adjacency", "Gain", "Land", "Placed", "Wait")}
            print("  %s groups of %d: %s" % (tier, size, total), flush=True)
            record["Groups"].append({"Tier": tier, "Size": size, "N": n_max, "Total": total, "Runs": groups})
            save()
    print("written", path)


def many(args, order, path):
    """Issue 142: the n nearest cities in one search or in groups."""
    record = {"Name": args.name, "Count": args.count, "Order": order, "Many": []}
    for tier in args.tiers.split(","):
        for n in [int(x) for x in args.sizes.split(",")]:
            if n > len(order["List"]):
                print("  only %d cities and pins: skip n=%d" % (len(order["List"]), n))
                continue
            for variant in args.variants.split(","):
                if variant == "ALL":
                    params = "{ GroupAbove = 9999 }"
                else:
                    size, _, passes = variant[1:].partition("P")
                    params = "{ GroupAbove = %d, GroupSize = %d%s }" % (int(size), int(size), ", GroupPasses = %d" % int(passes) if passes else "")
                run('SDP_MultiSize.Setup("%s", %d); SDP_MultiSize.Select(1, %d); SDP_MultiSize.Params = %s'
                    % (tier, args.count, n, params))
                started = time.monotonic()
                setup = run("SDP_MultiSize.SetupOnly()", timeout=600)
                setup_seconds = time.monotonic() - started
                data = solve("%s n=%d %s" % (tier, n, variant), timeout=3600)
                data.update({"Tier": tier, "N": n, "Variant": variant, "SetupSeconds": round(setup_seconds, 2),
                             "Groups": emitted(setup, "SDP_MSETUP ")})
                print("    setup alone %.2fs" % setup_seconds, flush=True)
                record["Many"].append(data)
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(record, fh, ensure_ascii=False, indent=1)
    run("SDP_MultiSize.Params = nil")
    print("written", path)


if __name__ == "__main__":
    main()
