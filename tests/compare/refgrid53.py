#!/usr/bin/env python3
"""refgrid53.py - which yield weights and land coefficient the reference
layouts point to (issue 53, step 2 of the experiment plan).

Reads compare.mjs --refscore rows run with land and a land coefficient
(weight vectors with "lambda", tests/compare/refscenes/grid53.jsonl): per
reference scene and vector theta = (weights, lambda), the proven optimum of
the mod's whole objective V*(theta) (sdp:ORACLE_LAND<nnn>) and the reference
layout L valued by the same search, V(theta, L).

  gap = (V*(theta) - V(theta, L)) / A(L)

A(L) is the judge's adjacency gain of the reference layout under the same
yield weights; it does not change with lambda (so the ratio does not blow
up when a large lambda brings the totals near 0) and it keeps the scale of
the weights (halving gold does not shrink the gaps by itself). The gap with
A(L) at all weights 1 is reported too (--unweighted uses it for the rule).

Selection rule (written down before the runs, issue 53 plan):
  1. on the development group, the theta with the smallest mean gap;
  2. every theta within 1 percentage point of it counts as equally good;
     among those, the one closest to the default (all weights 1, lambda 1):
     distance = sum over yields |w - 1| + |lambda - 1|, ties by mean gap;
  3. on the check group, its mean gap must not exceed the default's, else
     the default stays.
Groups: by author, no author in both, about 2:1, over the scenes REF04 on
(REF01-REF03 have guessed terrain). Authors are taken in the order of the
SHA-1 of their names; the check group takes them in that order while it
stays within a third of the scenes (+1).

A scene the oracle did not finish (node limit) has V* in [best, upper]:
its gap is an interval, and the means are reported for both ends.

Usage (Python 3.8, -I):
  python3 -I tests/compare/refgrid53.py [--unweighted] [--sanity REFSCORE.jsonl] RESULTS.jsonl ...
Later files win for the same scene and vector.
"""

import glob
import hashlib
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = ("all1", 1.0)


def authors():
    out = {}
    for path in sorted(glob.glob(os.path.join(HERE, "scenes", "REF*.json"))):
        with open(path, encoding="utf-8") as f:
            s = json.load(f)["scenario"]
        out[s["id"]] = s.get("author", "?")
    return out


def split(scenes, author_of):
    count = {}
    for s in scenes:
        count[author_of[s]] = count.get(author_of[s], 0) + 1
    order = sorted(count, key=lambda a: hashlib.sha1(a.encode("utf-8")).hexdigest())
    total, n, check = sum(count.values()), 0, set()
    for a in order:
        if n >= total / 3:
            break
        if n + count[a] <= round(total / 3) + 1:
            check.add(a)
            n += count[a]
    return check


def load(paths):
    rows = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                r = json.loads(line)
                if r.get("mode") != "refscore" or r.get("objective") != "sdp":
                    continue
                rows[(r["scenario"], r["weights"]["name"])] = r
    return rows


def family(name):
    return name.rsplit("-L", 1)[0]


def distance(row):
    w = row["weights"]
    return sum(abs(v - 1) for v in w["yields"].values()) + abs(w["lambda"] - 1)


def main(argv):
    unweighted = "--unweighted" in argv
    argv = [a for a in argv if a != "--unweighted"]
    sanity = None
    if "--sanity" in argv:
        i = argv.index("--sanity")
        sanity = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        print(__doc__)
        return 2
    rows = load(argv)
    author_of = authors()
    scenes = sorted({s for s, _ in rows})
    thetas = sorted({n for _, n in rows}, key=lambda n: (family(n) != "all1", family(n), rows_lambda(rows, n)))
    errors = [(k, r.get("error")) for k, r in sorted(rows.items()) if r.get("error") or not r.get("summary")]
    for k, e in errors:
        print("ERROR", k, str(e)[:200])

    # gap per (scene, theta): (low, high) with high > low only when cut short.
    gap, meta = {}, {}
    for (s, n), r in rows.items():
        m = r.get("summary")
        if not m:
            continue
        denom = m["referenceGain1"] if unweighted else m["referenceGain"]
        if not denom:
            continue
        low = m["gap"] / denom
        high = m.get("gapUpper", m["gap"]) / denom
        gap[(s, n)] = (low, high)
        meta[n] = r
    open_scenes = sorted({s for (s, n), r in rows.items() if r.get("summary") and r["summary"].get("complete") is False})
    unproven = sorted({(s, n) for (s, n), r in rows.items()
                       if r.get("summary") and r["summary"].get("proven") is False and r["summary"].get("complete") is not False})

    def mean(theta, group):
        vals = [gap[(s, theta)] for s in group if (s, theta) in gap]
        if not vals:
            return None
        return (statistics.mean(v[0] for v in vals), statistics.mean(v[1] for v in vals), len(vals))

    def optimal(theta, group):
        return sum(1 for s in group if (s, theta) in rows and rows[(s, theta)].get("summary")
                   and rows[(s, theta)]["summary"]["referenceOptimal"])

    def fmt(m):
        if m is None:
            return "-"
        lo, hi, _ = m
        return "%.2f" % (100 * lo) if abs(hi - lo) < 5e-5 else "%.2f~%.2f" % (100 * lo, 100 * hi)

    print("scenes %d, vectors %d, denominator: reference adjacency %s" %
          (len(scenes), len(thetas), "with all weights 1" if unweighted else "under the same yield weights"))
    if open_scenes:
        print("cut short by the node limit (gap as an interval):", ", ".join(open_scenes))
    if unproven:
        print("not proven:", unproven)
    # The search's DMT adjacency against the judge's (both DMT): they agree
    # unless the search valued a layout wrongly.
    off = sorted((s, n, m.get("referenceAdjacencySearch"), m["referenceGain"], m.get("optimumAdjacencySearch"), m["optimumGain"])
                 for (s, n), r in rows.items() for m in [r.get("summary")] if m
                 and (abs((m.get("referenceAdjacencySearch") or 0) - m["referenceGain"]) > 1e-9
                      or abs((m.get("optimumAdjacencySearch") or 0) - m["optimumGain"]) > 1e-9))
    print("search adjacency = judge adjacency: %d of %d rows%s" %
          (len(gap) - len(off), len(gap), (", differ: %s" % off) if off else ""))

    # The split is over every reference scene from REF04 on (REF01-REF03:
    # guessed terrain), not only those with results, so it stays fixed.
    check_authors = split(sorted(s for s in author_of if s >= "REF04"), author_of)
    dev = [s for s in scenes if author_of[s] not in check_authors]
    chk = [s for s in scenes if author_of[s] in check_authors]
    lambdas = sorted({rows_lambda(rows, n) for n in thetas})
    fams = []
    for n in thetas:
        if family(n) not in fams:
            fams.append(family(n))

    def table(group, title):
        print("\n%s (%d scenes): mean gap %% / reference optimal" % (title, len(group)))
        print("| weights | " + " | ".join("λ = %g" % l for l in lambdas) + " |")
        print("|---|" + "---|" * len(lambdas))
        for f in fams:
            cells = []
            for l in lambdas:
                n = name_of(thetas, rows, f, l)
                m = mean(n, group) if n else None
                cells.append("%s / %d" % (fmt(m), optimal(n, group)) if m else "-")
            print("| %s | %s |" % (f, " | ".join(cells)))

    def choose(group):
        means = {n: mean(n, group) for n in thetas}
        means = {n: m for n, m in means.items() if m is not None}
        best = min(means.values(), key=lambda m: m[0])[0]
        near = [n for n, m in means.items() if m[0] <= best + 0.01 + 1e-12]
        pick = min(near, key=lambda n: (distance(meta[n]), means[n][0], n))
        return pick, best, near, means

    table(scenes, "All")
    table(dev, "Development group (" + ", ".join(sorted({author_of[s] for s in dev})) + ")")
    table(chk, "Check group (" + ", ".join(sorted(check_authors)) + ")")

    print("\nSelection rule")
    for label, group in (("all scenes", scenes), ("development group", dev)):
        pick, best, near, means = choose(group)
        print("  %s: smallest mean gap %.2f%%; within 1 point: %s; pick %s (%.2f%%)" %
              (label, 100 * best, ", ".join(sorted(near)), pick, 100 * means[pick][0]))
        if group is dev:
            d_name = name_of(thetas, rows, DEFAULT[0], DEFAULT[1])
            mp, md = mean(pick, chk), mean(d_name, chk)
            ok = mp is not None and md is not None and mp[0] <= md[0] + 1e-12
            print("  check group: %s %s%%, default %s %s%% -> %s" %
                  (pick, fmt(mp), d_name, fmt(md), "passes" if ok else "fails: the default stays"))

    print("\nPer author: mean gap % (scenes)")
    by_author = {}
    for s in scenes:
        by_author.setdefault(author_of[s], []).append(s)
    show = [name_of(thetas, rows, f, l) for f in fams for l in (0.0, 0.5, 1.0)]
    show = [n for n in show if n]
    print("| author | n | " + " | ".join(show) + " | smallest |")
    print("|---|---|" + "---|" * (len(show) + 1))
    for a in sorted(by_author, key=lambda a: (-len(by_author[a]), a)):
        group = by_author[a]
        means = {n: mean(n, group) for n in thetas}
        means = {n: m for n, m in means.items() if m}
        lo = min(means.values(), key=lambda m: m[0])[0]
        argmin = sorted(n for n, m in means.items() if m[0] <= lo + 1e-12)
        print("| %s | %d | %s | %s |" % (a, len(group), " | ".join(fmt(means.get(n)) for n in show),
                                        ", ".join(argmin) if len(argmin) <= 3 else "%d tied" % len(argmin)))

    print("\nPer scene: gap % per vector")
    print("| scene | " + " | ".join(thetas) + " |")
    for s in scenes:
        print("| %s | %s |" % (s[:5], " | ".join(fmt((gap[(s, n)][0], gap[(s, n)][1], 1)) if (s, n) in gap else "-" for n in thetas)))

    print("\nTimes (s, plan): total %.0f" % sum(r["optimum"].get("planSeconds", 0) for r in rows.values() if r.get("optimum")))
    per = {}
    for (s, n), r in rows.items():
        if r.get("optimum"):
            per[s] = per.get(s, 0) + r["optimum"].get("planSeconds", 0)
    print("  " + ", ".join("%s %.0f" % (s[:5], t) for s, t in sorted(per.items())))

    if sanity:
        # lambda = 0 against the stored adjacency-only rows (sdp:ORACLE).
        old = {}
        with open(sanity, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    if r.get("objective") == "gain" and r.get("summary"):
                        old[(r["scenario"], r["weights"]["name"])] = r["summary"]
        same, diff = 0, []
        pairs = {"all1": "all1", "gold-faith-half": "g05f05"}
        for (s, w), m in sorted(old.items()):
            n = name_of(thetas, rows, pairs.get(w, w), 0.0)
            if n is None or (s, n) not in rows or not rows[(s, n)].get("summary"):
                continue
            x = rows[(s, n)]["summary"]
            if abs(x["optimum"] - m["optimum"]) < 1e-9 and abs(x["reference"] - m["reference"]) < 1e-9:
                same += 1
            else:
                diff.append((s, w, m["reference"], m["optimum"], x["reference"], x["optimum"]))
        print("\nλ = 0 against the adjacency-only oracle rows: %d the same, %d differ %s" % (same, len(diff), diff))
    return 0


def rows_lambda(rows, name):
    for (_, n), r in rows.items():
        if n == name:
            return float(r["weights"]["lambda"])
    return None


def name_of(thetas, rows, fam, lam):
    for n in thetas:
        if family(n) == fam and abs(rows_lambda(rows, n) - lam) < 1e-9:
            return n
    return None


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
