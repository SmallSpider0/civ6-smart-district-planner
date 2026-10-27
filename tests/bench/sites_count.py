"""City sites tab: solve time by Districts count (issue 124).

On the loaded game (tools/stress.py load NAME, or tools/game.py load SAVE
--state SDP_Panel): the tab at its defaults (Standard tier, 3 new cities,
distance 5, Balanced, default district grid) is solved at once with each
Districts count, `--reps` times, the counts in a rotated order each round,
after one discarded warm-up solve. Each solve is one Tuner request, timed
from here as tools/stress.py times its steps (Lua timers are whole seconds;
about 0.02 s of round trip). Reports the median wall seconds per count and
the ratios to count 0, and whether every round chose the same sites.

Changes the tab's settings in memory only (do not save the game). Results
go to tests/bench/results/sites_count-NAME.json.

    python3 -I tests/bench/sites_count.py NAME [--counts 0,3,6] [--reps 3]
"""
import argparse
import json
import os
import statistics
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402
import sdplock  # noqa: E402

RESULTS = os.path.join(ROOT, "tests", "bench", "results")


def run(code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("SDP_Panel: %s" % resp.get("error"))
    return resp.get("output") or []


def report(lines, prefix):
    for line in lines:
        if line.startswith(prefix + " "):
            return json.loads(line[len(prefix) + 1:])
    return None


def timed(code, timeout):
    started = time.monotonic()
    lines = run(code, timeout)
    return time.monotonic() - started, report(lines, "SDP_SCOUNT")


def summarize(runs, counts):
    rows = {}
    for n in counts:
        mine = [r for r in runs if r["Count"] == n]
        secs = [r["Seconds"] for r in mine]
        rows[n] = {"Median": round(statistics.median(secs), 3) if secs else None,
                   "Min": round(min(secs), 3) if secs else None, "Max": round(max(secs), 3) if secs else None,
                   "Found": sorted({r["Found"] for r in mine}), "Ok": all(r["Ok"] for r in mine),
                   "Errors": sorted({r["Error"] for r in mine if r["Error"]}),
                   "SameSites": len({r["Sites"] for r in mine}) <= 1}
    base = rows.get(0, {}).get("Median") if 0 in rows else None
    for n, row in rows.items():
        row["VsZero"] = round(row["Median"] / base, 2) if base and row["Median"] is not None else None
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("name", help="label for the loaded game (the results file name)")
    ap.add_argument("--counts", default="0,3,6", help="Districts counts (default 0,3,6)")
    ap.add_argument("--reps", type=int, default=3, help="solves per count (default 3)")
    ap.add_argument("--timeout", type=float, default=1200, help="seconds allowed per solve")
    args = ap.parse_args(argv)
    counts = [int(x) for x in args.counts.split(",")]
    sdplock.claim_or_exit(ROOT, "sites_count %s" % args.name)
    for name in ("stress.lua", "sites_count.lua"):
        with open(os.path.join(ROOT, "tests", "bench", name), encoding="utf-8") as fh:
            run(fh.read())
    census = report(run("SDP_Stress.Census()"), "SDP_STRESS") or {}
    cities = census.get("Cities") or []
    print("%s: turn %s, %d cities, %s districts, %s foreign cities" % (
        args.name, census.get("Turn"), len(cities), census.get("Districts"), census.get("OtherCities")), flush=True)
    setups, runs = {}, []
    warm = report(run("SDP_SitesCount.Setup(%d)" % counts[0]), "SDP_SCOUNT")
    seconds, _ = timed("SDP_SitesCount.Solve()", args.timeout)
    print("  warm-up count %d %7.2fs (discarded)" % (counts[0], seconds), flush=True)
    for rep in range(args.reps):
        order = counts[rep % len(counts):] + counts[:rep % len(counts)]
        for n in order:
            setup = report(run("SDP_SitesCount.Setup(%d)" % n), "SDP_SCOUNT")
            setups[n] = setup
            seconds, data = timed("SDP_SitesCount.Solve()", args.timeout)
            data = data or {"Ok": False, "Error": "no report"}
            entry = {"Count": n, "Round": rep + 1, "Seconds": round(seconds, 3), "Ok": data.get("Ok"),
                     "Error": data.get("Error"), "Found": data.get("Found"), "Calls": data.get("Calls"),
                     "Sites": data.get("Sites")}
            runs.append(entry)
            print("  round %d count %d (pick %s of %d) %7.2fs  ok=%s found=%s %s" % (
                rep + 1, n, setup and setup.get("Pick"), len((setup or {}).get("Pool") or []), seconds,
                entry["Ok"], entry["Found"], entry["Error"] or ""), flush=True)
    run("SDP_SitesCount.Restore()")
    rows = summarize(runs, counts)
    print("\n| Districts count | median s | min–max s | vs count 0 | sites found | same sites every round |")
    print("|---|---|---|---|---|---|")
    for n in counts:
        r = rows[n]
        print("| %d | %s | %s–%s | %s | %s | %s |" % (n, r["Median"], r["Min"], r["Max"], r["VsZero"],
                                                    ",".join(str(x) for x in r["Found"]), r["SameSites"]))
    os.makedirs(RESULTS, exist_ok=True)
    out = os.path.join(RESULTS, "sites_count-%s.json" % args.name)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"Name": args.name, "Census": {k: census.get(k) for k in ("Turn", "Districts", "Wonders", "OtherCities")},
                   "Cities": len(cities), "Setups": {str(k): v for k, v in setups.items()}, "WarmUp": warm,
                   "Runs": runs, "Summary": {str(k): v for k, v in rows.items()},
                   "When": time.strftime("%Y-%m-%d %H:%M")}, fh, ensure_ascii=False, indent=1)
    print("wrote %s" % out)
    return 0 if all(r["Ok"] or r["Error"] == "NO_SITE" for r in runs) else 1


if __name__ == "__main__":
    sys.exit(main())
