#!/usr/bin/env python3
"""refresh_results - rerun this mod's rows of stored comparison results with the current code.

    python3 -I tools/refresh_results.py [-j N] tests/compare/results/FILE.jsonl ...
    python3 -I tools/refresh_results.py --check [-j N] [FILE ...]   # rerun and compare, change nothing

--check is the check before a release after solver changes: it reruns the
same rows (default the development set, full_rejudged.jsonl: 84 scenes in
three tiers plus a few multi-city variants, about 270 runs; no oracle, no
weight profiles) and reports, against the stored rows, plans that changed,
gains that went down and violations other than "no legal tile" that are new.
Exit 1 when a gain went down or a violation is new.

For each file: the rows of planner sdp are grouped by variant and rerun with
tools/compare.mjs on exactly their scenarios; the new rows replace the old
ones in place (other planners' rows stay as they are); then every row is
rejudged with the current judge (--rejudge), and cross-scored again when the
file has cross scores (--crossscore with the same scorers). The file is
replaced only when all of that worked and no row was lost. Work files go to
logs/refresh/. Heavy: run it on the second machine when there is one
(tools/remote.py), and say in the PR which files and this command.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "logs", "refresh")


def compare(args, jobs):
    subprocess.run(["node", "tools/compare.mjs"] + args + ["-j", str(jobs)], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)


def count(path):
    with open(path, encoding="utf-8") as fh:
        return sum(1 for line in fh if line.strip())


def violations(row):
    """Violations other than no_plot (a district with no legal tile in range is not a fault)."""
    out = []
    for v in (row.get("score") or {}).get("violations") or []:
        if v.get("detail") != "no_plot":
            out.append(json.dumps(v, sort_keys=True))
    return set(out)


def gain(row):
    return (row.get("score") or {}).get("gain")


def check(path, new):
    old = {}
    for l in open(path, encoding="utf-8"):
        if l.strip():
            r = json.loads(l)
            if r["planner"] == "sdp":
                old[(r["scenario"], "sdp", r.get("variant") or "")] = r
    same = changed = up = 0
    down, fresh = [], []
    for k, r in sorted(new.items()):
        o = old.get(k)
        if o is None:
            continue
        g0, g1 = gain(o), gain(r)
        # The plan also carries timing stats: compare where things go only.
        if (json.dumps((o.get("plan") or {}).get("placements"), sort_keys=True)
                == json.dumps((r.get("plan") or {}).get("placements"), sort_keys=True)):
            same += 1
        else:
            changed += 1
        if g0 is not None and g1 is not None:
            if g1 < g0 - 1e-9:
                down.append((k, g0, g1))
            elif g1 > g0 + 1e-9:
                up += 1
        added = violations(r) - violations(o)
        if added:
            fresh.append((k, sorted(added)))
    print("%s: %d rows rerun; plan the same %d, changed %d; gain higher %d, lower %d; new violations %d"
          % (os.path.basename(path), len(new), same, changed, up, len(down), len(fresh)))
    for k, g0, g1 in down:
        print("  LOWER %s %s: %s -> %s" % (k[0], k[2], g0, g1))
    for k, v in fresh:
        print("  NEW VIOLATION %s %s: %s" % (k[0], k[2], "; ".join(v)))
    return 1 if down or fresh else 0


def rerun(path, jobs):
    """This mod's rows of `path`, rerun with the current code: {(scenario, planner, variant): row}."""
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    want = collections.defaultdict(set)  # variant -> scenarios
    for r in rows:
        if r["planner"] == "sdp":
            want[r.get("variant") or ""].add(r["scenario"])
    new = {}
    for variant, scenes in sorted(want.items()):
        rx = "^(" + "|".join(re.escape(s) for s in sorted(scenes)) + ")$"
        out = os.path.join(WORK, os.path.basename(path) + "." + (variant.replace("#", "_r") or "default") + ".jsonl")
        key = "sdp:" + variant
        print("%s: %s, %d scenes" % (os.path.basename(path), key, len(scenes)), flush=True)
        compare(["-s", rx, "--add", key, "--only", key, "--out", out], jobs)
        for l in open(out, encoding="utf-8"):
            if l.strip():
                r = json.loads(l)
                new[(r["scenario"], "sdp", r.get("variant") or "")] = r
    return rows, new


def refresh(path, jobs):
    rows, new = rerun(path, jobs)
    merged, replaced = [], 0
    for r in rows:
        k = (r["scenario"], r["planner"], r.get("variant") or "")
        if r["planner"] == "sdp" and k in new:
            merged.append(new[k])
            replaced += 1
        else:
            merged.append(r)
    base = os.path.join(WORK, os.path.basename(path))
    staged, rejudged = base + ".new", base + ".rejudged"
    with open(staged, "w", encoding="utf-8") as fh:
        for r in merged:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    compare(["--rejudge", staged, "--out", rejudged], jobs)
    if count(rejudged) != count(staged):
        raise SystemExit("%s: rejudge lost rows (%d of %d)" % (path, count(rejudged), count(staged)))
    scorers = sorted({k for r in rows for k in (r.get("cross") or {})})
    if scorers:
        crossed = base + ".crossed"
        compare(["--crossscore", rejudged, "--scorers", ",".join(scorers), "--out", crossed], jobs)
        if count(crossed) != count(rejudged):
            raise SystemExit("%s: cross-scoring lost rows" % path)
        os.replace(crossed, rejudged)
    os.replace(rejudged, path)
    os.remove(staged)
    print("%s: %d rows, %d of this mod's rerun" % (path, len(rows), replaced), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("-j", "--jobs", type=int, default=int(os.environ.get("SDP_JOBS") or 4),
                    help="compare.mjs workers (default $SDP_JOBS, set by remote.py and sdplock.py heavy, else 4)")
    ap.add_argument("--check", action="store_true", help="rerun and compare with the stored rows; change nothing")
    args = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)
    if args.check:
        files = args.files or [os.path.join(ROOT, "tests", "compare", "results", "full_rejudged.jsonl")]
        worst = 0
        for path in files:
            _, new = rerun(os.path.abspath(path), args.jobs)
            worst = max(worst, check(os.path.abspath(path), new))
        return worst
    if not args.files:
        ap.error("give the result files to refresh")
    for path in args.files:
        refresh(os.path.abspath(path), args.jobs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
