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

A --check of the development set that ran to the end writes CHECK_STAMP
(tests/compare/results/check_stamp.json): a digest of the files the plans
depend on (SOLVED_BY: the solver and legality scripts, the comparison harness,
its scenes and the stored rows) and what the check found. Commit it with the
PR that ran the check. --check --if-changed (the release step) skips the run
when those files are still the same as at the last recorded check (#302): a
solver PR has run it already, and nothing it depends on changed since.

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
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "logs", "refresh")
DEV_SET = os.path.join(ROOT, "tests", "compare", "results", "full_rejudged.jsonl")
CHECK_STAMP = os.path.join(ROOT, "tests", "compare", "results", "check_stamp.json")
# The files the development set's plans and their judging depend on (repository paths, fnmatch patterns;
# `*` also crosses `/`). The interface-only scripts are left out, as for the stress test (sdp-release §1).
SOLVED_BY = ["SmartDistrictPlanner/Scripts/*.lua", "tools/compare.mjs", "tests/compare/cmp_*.lua",
             "tests/compare/scenes/*", "tests/compare/results/full_rejudged.jsonl"]
NOT_SOLVED_BY = ["SmartDistrictPlanner/Scripts/SDP_Page*.lua", "SmartDistrictPlanner/Scripts/SDP_Preview.lua"]


def solved_by(paths):
    """The repository paths among `paths` that the plans depend on, sorted."""
    def hit(path, patterns):
        return any(fnmatch.fnmatch(path, p) for p in patterns)
    return sorted(p for p in paths if hit(p, SOLVED_BY) and not hit(p, NOT_SOLVED_BY))


def present(root=None):
    """Repository paths of the files under SOLVED_BY's folders, read from the disk: the second machine's
    copy of the worktree has no git (tools/remote.py sync copies the tracked and new files)."""
    root, out = root or ROOT, []
    for top in ("SmartDistrictPlanner/Scripts", "tests/compare", "tools"):  # SOLVED_BY's folders
        for here, dirs, names in os.walk(os.path.join(root, *top.split("/"))):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != "node_modules")
            out += [os.path.relpath(os.path.join(here, n), root).replace(os.sep, "/") for n in names]
    return out


def digest(root=None):
    """(sha256 over SOLVED_BY's files as they are on disk, number of files). Line ends are made the same
    first, so a checkout with CRLF gives the same digest."""
    root = root or ROOT
    h, files = hashlib.sha256(), solved_by(present(root))
    for path in files:
        with open(os.path.join(root, *path.split("/")), "rb") as fh:
            data = fh.read().replace(b"\r\n", b"\n")
        h.update(path.encode("utf-8") + b"\0" + hashlib.sha256(data).hexdigest().encode() + b"\n")
    return h.hexdigest(), len(files)


def read_stamp(path=None):
    try:
        with open(path or CHECK_STAMP, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def write_stamp(found, root=None, path=None):
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root or ROOT, capture_output=True,
                          text=True).stdout.strip()
    value, files = digest(root)
    stamp = {"digest": value, "files": files, "commit": head, "date": time.strftime("%Y-%m-%d %H:%M")}
    stamp.update(found)
    with open(path or CHECK_STAMP, "w", encoding="utf-8") as fh:
        json.dump(stamp, fh, indent=1, sort_keys=True)
        fh.write("\n")
    return stamp


def stamp_exit(stamp):
    """The exit code a skipped check keeps: that of the stamped check (1 when it found lower gains or new
    violations), so a retried release check does not pass a regression it skipped."""
    return 1 if stamp.get("lower") or stamp.get("new_violations") else 0


def unchanged_since_check(root=None, path=None):
    """The stamp of the last check when nothing SOLVED_BY covers changed since it, else None."""
    stamp = read_stamp(path)
    if not stamp or stamp.get("digest") != digest(root)[0]:
        return None
    return stamp


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
    return {"rows": len(new), "changed": changed, "higher": up, "lower": len(down), "new_violations": len(fresh)}


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
    ap.add_argument("--check", action="store_true",
                    help="rerun and compare with the stored rows; change nothing but the check stamp")
    ap.add_argument("--if-changed", action="store_true",
                    help="with --check: skip it when nothing the plans depend on changed since the stamped check")
    args = ap.parse_args()
    if args.if_changed and (not args.check or args.files):
        ap.error("--if-changed goes with --check of the development set (no files)")
    os.makedirs(WORK, exist_ok=True)
    if args.check:
        if args.if_changed:
            stamp = unchanged_since_check()
            if stamp:
                print("refresh_results: skipped: no solver, legality or comparison file changed since the check "
                      "at %s (%s): %s rows, %s lower, %s new violations"
                      % (stamp.get("commit"), stamp.get("date"), stamp.get("rows"), stamp.get("lower"),
                         stamp.get("new_violations")))
                return stamp_exit(stamp)
            print("refresh_results: files the plans depend on changed since the last stamped check: running it",
                  flush=True)
        files = args.files or [DEV_SET]
        worst = 0
        for path in files:
            _, new = rerun(os.path.abspath(path), args.jobs)
            found = check(os.path.abspath(path), new)
            worst = max(worst, 1 if found["lower"] or found["new_violations"] else 0)
            if not args.files and found["rows"]:
                write_stamp(found)
                print("refresh_results: wrote %s (commit it with the PR)" % os.path.relpath(CHECK_STAMP, ROOT))
        return worst
    if not args.files:
        ap.error("give the result files to refresh")
    for path in args.files:
        refresh(os.path.abspath(path), args.jobs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
