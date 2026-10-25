"""Summarize tools/compare.mjs results.

    python3 -I tests/compare/summarize.py RESULTS.jsonl [MORE.jsonl ...] [--json OUT]

For every scenario the reference is the proven optimum when the exact
solver (sdp:ORACLE, tests/compare/cmp_oracle.lua) proved one, else the best
gain any planner reached with a legal plan (no rule broken; leaving a
requested district out is not a broken rule, but it costs gain); the
oracle's upper bound is kept for those. Quality = gain / reference;
"optimal" counts plans that reach a proven optimum. A plan that breaks a
rule keeps its gain in the tables but is counted as illegal. The oracle's
own runs are left out of the per-planner tables.
Repeated runs ("#2" variants) only feed the determinism check.
"""
import argparse
import json
import statistics
import sys
from collections import defaultdict

HARD = {"off_map", "same_tile", "occupied", "overwrites_pin", "no_city", "out_of_range", "foreign_tile",
        "other_city_tile", "unreachable", "unknown_type", "dmt_illegal", "twice_in_city", "empire_limit", "slots",
        "on_resource",
        # city sites
        "bad_terrain", "unrevealed", "natural_wonder", "too_close"}

SITE_FIELDS = ("siteValue", "tileValue", "districtPotential", "freshWater", "coastal", "newLuxuries", "newStrategics",
               "overlap")


def group(sid):
    """(set, kind) of a scenario id: dev / heldout / sealed / real / smallmulti(/heldout, /sealed) /
    profile:SCI ... (profile:RND/heldout ...) / wonders (/improvement) / sites / coverage (/real)."""
    if "~" in sid:
        base, profile = sid.split("~", 1)
        part = group(base)[0]
        return "profile:" + profile + ("" if part == "dev" else "/" + part), "single"
    for prefix, name, kind in (("D3", "three", "single"), ("HD3", "three/heldout", "single"),
                               ("FD3", "three/sealed", "single"), ("DM", "twoeach", "multi"),
                               ("HDM", "twoeach/heldout", "multi"), ("FDM", "twoeach/sealed", "multi")):
        if sid.startswith(prefix) and sid[len(prefix):len(prefix) + 1].isdigit():
            return name, kind
    if sid.startswith("OM"):
        return "smallmulti", "multi"
    if sid.startswith("HOM"):
        return "smallmulti/heldout", "multi"
    if sid.startswith("FOM"):
        return "smallmulti/sealed", "multi"
    if sid.startswith("FS"):
        return "sealed", "single"
    if sid.startswith("FM"):
        return "sealed", "multi"
    if sid.startswith("RS"):
        return "real", "single"
    if sid.startswith("RM"):
        return "real", "multi"
    if sid.startswith("RC"):
        return "coverage/real", "multi"
    if sid.startswith("RP"):
        return "coverage/player", "multi"
    if sid.startswith("HS"):
        return "heldout", "single"
    if sid.startswith("HM"):
        return "heldout", "multi"
    if sid.startswith("WA"):
        return "wonders/improvement", "single"
    if sid.startswith("W"):
        return "wonders", "single"
    if sid.startswith("C"):
        return "sites", "sites"
    if sid.startswith("V"):
        return "coverage", "multi"
    if sid.startswith("S"):
        return "dev", "single"
    if sid.startswith("M"):
        return "dev", "multi"
    return "other", "other"


def metric(s):
    """The judge's main number: adjacency gain, or a site set's value."""
    if s is None:
        return None
    return s["gain"] if s.get("gain") is not None else s.get("siteValue")


# ---------------------------------------------------------------- statistics
def _rng(seed):
    state = [seed % 2147483647 or 1]

    def nxt(n):
        state[0] = (state[0] * 48271) % 2147483647
        return state[0] % n
    return nxt


def bootstrap_ci(values, rounds=2000, seed=20261020):
    """95% percentile interval of the mean (deterministic resampling)."""
    if not values:
        return None, None
    nxt = _rng(seed)
    n = len(values)
    means = []
    for _ in range(rounds):
        means.append(sum(values[nxt(n)] for _ in range(n)) / n)
    means.sort()
    return means[int(0.025 * rounds)], means[int(0.975 * rounds) - 1]


def sign_test(wins, losses):
    """Two-sided exact sign test over the scenarios that are not ties."""
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    from math import comb
    p = sum(comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * p)


def paired(scenarios, a, b, field="gain"):
    """Planner a against b over the scenarios both ran: wins/ties/losses of a,
    the mean difference a - b with its 95% bootstrap interval, sign test p."""
    diffs = []
    for sid in sorted(scenarios):
        e = scenarios[sid]
        ra, rb = e["runs"].get(a), e["runs"].get(b)
        if not ra or not rb or ra.get("error") or rb.get("error"):
            continue
        va, vb = ra.get(field), rb.get(field)
        if va is None or vb is None:
            continue
        diffs.append(va - vb)
    w = sum(1 for d in diffs if d > 1e-9)
    l = sum(1 for d in diffs if d < -1e-9)
    lo, hi = bootstrap_ci(diffs)
    return {"n": len(diffs), "wins": w, "ties": len(diffs) - w - l, "losses": l,
            "mean": (sum(diffs) / len(diffs)) if diffs else None, "ci": [lo, hi], "p": sign_test(w, l)}


def pareto(scenarios, a, b, fields=("gain", "coverage")):
    """a against b on several measures at once: a better (not worse on any,
    better on one), b better, the same, or a trade-off (each better on one)."""
    out = {"n": 0, "better": 0, "worse": 0, "same": 0, "tradeoff": 0}
    for sid in sorted(scenarios):
        ra, rb = scenarios[sid]["runs"].get(a), scenarios[sid]["runs"].get(b)
        if not ra or not rb or ra.get("error") or rb.get("error"):
            continue
        if any(ra.get(f) is None or rb.get(f) is None for f in fields):
            continue
        diffs = [ra[f] - rb[f] for f in fields]
        up = any(d > 1e-9 for d in diffs)
        down = any(d < -1e-9 for d in diffs)
        out["n"] += 1
        out["tradeoff" if up and down else "better" if up else "worse" if down else "same"] += 1
    return out


def key(r):
    return r["planner"] + (":" + r["variant"] if r.get("variant") else "")


ORACLE_KEYS = ("sdp:ORACLE", "sdp:ORACLE_CHECK")


def load(paths):
    rows = []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    # Later files win for the same (scenario, planner, variant).
    out = {}
    for r in rows:
        out[(r["scenario"], r["planner"], r.get("variant", ""))] = r
    return list(out.values())


def placements_sig(r):
    ps = (r.get("plan") or {}).get("placements") or []
    return sorted((p.get("city"), p.get("type"), p.get("x"), p.get("y")) for p in ps)


def summarize(rows):
    by_scn = defaultdict(dict)
    repeats = []
    for r in rows:
        k = key(r)
        if k.endswith("#2"):
            repeats.append(r)
            continue
        by_scn[r["scenario"]][k] = r
    scenarios = {}
    for sid, runs in sorted(by_scn.items()):
        best = None
        exact = False
        for k, r in runs.items():
            s = r.get("score")
            if not s or r.get("error"):
                continue
            hard = [v for v in s["violations"] if v["kind"] in HARD]
            if not hard and metric(s) is not None:
                best = metric(s) if best is None else max(best, metric(s))
            if (r.get("plan") or {}).get("stats", {}).get("method") == "exhaustive":
                exact = True
        # The same for city output (adjacency + worked tiles): a measure
        # that is no planner's objective.
        best_out = None
        for k, r in runs.items():
            s = r.get("score")
            if s and not r.get("error") and s.get("output") is not None:
                if not [v for v in s["violations"] if v["kind"] in HARD]:
                    best_out = s["output"] if best_out is None else max(best_out, s["output"])
        # The exact reference (issue 48): a proven optimum replaces the best
        # known gain; otherwise its upper bound gives the range.
        optimum, upper, optimumMissing = None, None, None
        for k in ORACLE_KEYS:
            o = ((runs.get(k) or {}).get("plan") or {}).get("stats", {}).get("oracle")
            if isinstance(o, dict) and not runs[k].get("error"):
                if o.get("proven"):
                    optimum = o["value"]
                    optimumMissing = ((runs[k].get("score") or {}).get("missing")) or 0
                else:
                    upper = o.get("upper")
        if optimum is not None:
            best, exact = optimum, True
        entry = {"reference": best, "exact": exact, "optimum": optimum, "upper": upper, "referenceOutput": best_out,
                 "optimumMissing": optimumMissing, "runs": {}}
        for k, r in runs.items():
            s = r.get("score")
            e = {"seconds": r.get("planSeconds"), "error": r.get("error")}
            if s:
                kinds = defaultdict(int)
                for v in s["violations"]:
                    kinds[v["kind"]] += 1
                hard = sum(n for kk, n in kinds.items() if kk in HARD)
                g = metric(s)
                e.update({
                    "gain": g, "legal": hard == 0, "violations": dict(kinds), "missing": s.get("missing", 0),
                    "missingPlaceable": s.get("missingPlaceable"),
                    "tileLoss": s.get("tileLoss"), "placed": s.get("placed"),
                    "quality": (g / best) if best and best > 0 else (1.0 if best == 0 and g is not None and g >= 0 else None),
                    "dmtCalls": (r.get("plan") or {}).get("stats", {}).get("dmtCalls"),
                    "output": s.get("output"), "worked": s.get("worked"),
                    "outputGap": (best_out - s["output"]) if (best_out is not None and s.get("output") is not None) else None,
                    "notes": (r.get("plan") or {}).get("notes"),
                    "wondersPlaced": s.get("wondersPlaced"), "wondersRequested": s.get("wondersRequested"),
                    # Coverage (design 19.5): (city, kind) pairs newly reached.
                    "coverage": s.get("coverageGain"),
                })
                # This mod's own quality indicators (design 7.4, issue 36):
                # exhaustive, the model's upper bound and the gap to it,
                # converged, truncated; and whether the reference (the best
                # legal plan of any planner) beats that bound.
                q = (r.get("plan") or {}).get("stats", {}).get("sdpQuality")
                if isinstance(q, dict):
                    e["sdpQuality"] = q
                    bound = q.get("Bound")
                    e["boundBeaten"] = bool(not q.get("Exhaustive") and bound is not None and best is not None
                                            and best > bound + 1e-9)
                for f in SITE_FIELDS:
                    if s.get(f) is not None:
                        e[f] = s[f]
            # The competitors' own objectives (compare.mjs --crossscore).
            for scorer, c in (r.get("cross") or {}).items():
                if isinstance(c, dict) and c.get("gain") is not None and not c.get("error"):
                    e["cross_" + scorer] = c["gain"]
            entry["runs"][k] = e
        scenarios[sid] = entry
    # Determinism: the repeated run must give the same placements.
    det = []
    for r in repeats:
        # "sdp:STANDARD#2" -> "sdp:STANDARD", "amt:#2" -> "amt"
        base_key = key(r)[:-2].rstrip(":")
        base = by_scn.get(r["scenario"], {}).get(base_key)
        if base is None:
            continue
        same = placements_sig(base) == placements_sig(r) and not r.get("error") and not base.get("error")
        det.append({"scenario": r["scenario"], "planner": base_key, "same": same})
    return scenarios, det


def subset(scenarios, set_name=None, kind=None):
    """The scenarios of one set (dev, heldout, profile:SCI, wonders, sites) and kind."""
    out = {}
    for sid, e in scenarios.items():
        g, k = group(sid)
        if (set_name is None or g == set_name) and (kind is None or k == kind):
            out[sid] = e
    return out


def share_stats(values):
    """Mean, median, worst and how many reach 100 %, 95 %, 90 % of the optimum."""
    if not values:
        return None
    n = len(values)
    return {"n": n, "mean": statistics.mean(values), "median": statistics.median(values), "min": min(values),
            "at100": sum(1 for v in values if v >= 1 - 1e-9) / n, "at95": sum(1 for v in values if v >= 0.95 - 1e-9) / n,
            "at90": sum(1 for v in values if v >= 0.90 - 1e-9) / n}


def per_planner(scenarios, kind_filter=None):
    agg = defaultdict(lambda: defaultdict(list))
    for sid, e in scenarios.items():
        if kind_filter and group(sid)[1] != {"S": "single", "M": "multi"}.get(kind_filter, kind_filter):
            continue
        for k, r in e["runs"].items():
            if k in ORACLE_KEYS:
                continue
            a = agg[k]
            a["n"].append(1)
            if r.get("error"):
                a["errors"].append(sid)
                # A planner that gives no plan reaches 0 % of a proven optimum.
                if e.get("optimum") is not None:
                    a["optimal"].append(0)
                    a["overOptimum"].append(0)
                    a["ofOptimum"].append(0.0)
                continue
            if r.get("quality") is not None:
                a["quality"].append(r["quality"])
            a["legal"].append(1 if r.get("legal") else 0)
            a["missing"].append(r.get("missing", 0))
            a["missingPlaceable"].append(r.get("missingPlaceable") or 0)
            a["seconds"].append(r.get("seconds") or 0)
            if e["reference"] is not None and r.get("gain") is not None:
                a["best"].append(1 if r["legal"] and r["gain"] >= e["reference"] - 1e-9 else 0)
            if e.get("optimum") is not None and r.get("gain") is not None:
                a["optimal"].append(1 if r["legal"] and r["gain"] >= e["optimum"] - 1e-9 else 0)
                # Share of the optimum: an illegal plan counts 0.
                o = e["optimum"]
                g = r["gain"] if r["legal"] else 0
                a["ofOptimum"].append(g / o if o > 0 else (1.0 if g >= 0 else 0.0))
                # Above the optimum: a check that must stay 0. A plan that
                # leaves out districts the optimum places solves an easier
                # problem; it is counted apart (fewerAbove).
                above = r["legal"] and r["gain"] > e["optimum"] + 1e-9
                fewer = (r.get("missing") or 0) > (e.get("optimumMissing") or 0)
                a["overOptimum"].append(1 if above and not fewer else 0)
                a["fewerAbove"].append(1 if above and fewer else 0)
            if r.get("outputGap") is not None:
                a["outGap"].append(r["outputGap"])
                a["outBest"].append(1 if r["legal"] and r["outputGap"] <= 1e-9 else 0)
            for kk, n in (r.get("violations") or {}).items():
                a["v_" + kk].append(n)
            q = r.get("sdpQuality")
            if isinstance(q, dict):
                a["q_n"].append(1)
                a["q_exhaustive"].append(1 if q.get("Exhaustive") else 0)
                if not q.get("Exhaustive") and q.get("Gap") is not None:
                    a["q_gap"].append(q["Gap"])
                a["q_truncated"].append(1 if q.get("Truncated") else 0)
                a["q_notConverged"].append(1 if q.get("Converged") is False else 0)
                a["q_boundBeaten"].append(1 if r.get("boundBeaten") else 0)
    out = {}
    for k, a in agg.items():
        q = a["quality"]
        out[k] = {
            "runs": len(a["n"]), "errors": len(a["errors"]),
            "qualityMean": statistics.mean(q) if q else None, "qualityMin": min(q) if q else None,
            "legalShare": statistics.mean(a["legal"]) if a["legal"] else None,
            "bestShare": statistics.mean(a["best"]) if a["best"] else None,
            "optimalShare": statistics.mean(a["optimal"]) if a["optimal"] else None, "optimalRuns": len(a["optimal"]),
            "overOptimum": sum(a["overOptimum"]),
            "fewerAbove": sum(a["fewerAbove"]),
            "ofOptimum": share_stats(a["ofOptimum"]),
            "missing": sum(a["missing"]), "missingPlaceable": sum(a["missingPlaceable"]), "secondsMedian": statistics.median(a["seconds"]) if a["seconds"] else None,
            "violations": {kk[2:]: sum(v) for kk, v in a.items() if kk.startswith("v_")},
            "outputBestShare": statistics.mean(a["outBest"]) if a["outBest"] else None,
            "outputGapMean": statistics.mean(a["outGap"]) if a["outGap"] else None,
        }
        if a["q_n"]:
            out[k]["sdpQuality"] = {
                "runs": len(a["q_n"]), "exhaustive": sum(a["q_exhaustive"]),
                "gapRuns": len(a["q_gap"]),
                "gapMean": statistics.mean(a["q_gap"]) if a["q_gap"] else None,
                "gapMax": max(a["q_gap"]) if a["q_gap"] else None,
                "truncated": sum(a["q_truncated"]), "notConverged": sum(a["q_notConverged"]),
                "boundBeaten": sum(a["q_boundBeaten"]),
            }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json")
    args = ap.parse_args()
    rows = load(args.files)
    scenarios, det = summarize(rows)
    sets = sorted({group(sid) for sid in scenarios})
    tables = {}
    for set_name, kind in sets:
        name = set_name + "/" + kind
        tables[name] = per_planner(subset(scenarios, set_name, kind))
        sub_all = subset(scenarios, set_name, kind)
        proven = sum(1 for e in sub_all.values() if e.get("optimum") is not None)
        ranged = sum(1 for e in sub_all.values() if e.get("optimum") is None and e.get("upper") is not None)
        print("==", name, " proven optimum %d/%d, range only %d" % (proven, len(sub_all), ranged))
        t = tables[name]
        for k in sorted(t):
            v = t[k]
            q = v["qualityMean"]
            ob, og = v.get("outputBestShare"), v.get("outputGapMean")
            print("  %-18s runs %3d err %2d  quality %s (min %s)  legal %s  best %s  missing %3d (placeable %d)  median %.1fs  %s" % (
                k, v["runs"], v["errors"], "%.3f" % q if q is not None else "-",
                "%.2f" % v["qualityMin"] if v["qualityMin"] is not None else "-",
                "%.2f" % v["legalShare"] if v["legalShare"] is not None else "-",
                "%.2f" % v["bestShare"] if v["bestShare"] is not None else "-",
                v["missing"], v["missingPlaceable"], v["secondsMedian"] or 0, json.dumps(v["violations"])))
            if v.get("optimalShare") is not None:
                so = v["ofOptimum"]
                print("  %-18s of the optimum (n %d): mean %.1f%% median %.1f%% worst %.1f%%; at 100%% %.0f%%, >=95%% %.0f%%, >=90%% %.0f%%; above the optimum %d" % (
                    "", so["n"], 100 * so["mean"], 100 * so["median"], 100 * so["min"], 100 * so["at100"], 100 * so["at95"],
                    100 * so["at90"], v["overOptimum"]) + (
                    "; above it with fewer districts placed %d" % v["fewerAbove"] if v.get("fewerAbove") else ""))
            if ob is not None:
                print("  %-18s output best %.2f gap %.2f" % ("", ob, og))
            sq = v.get("sdpQuality")
            if sq:
                print("  %-18s self-reported: exhaustive %d/%d, gap to the model's bound mean %s max %s (n %d), truncated %d, not converged %d, bound beaten by the reference %d" % (
                    "", sq["exhaustive"], sq["runs"],
                    "%.3f" % sq["gapMean"] if sq["gapMean"] is not None else "-",
                    "%.3f" % sq["gapMax"] if sq["gapMax"] is not None else "-",
                    sq["gapRuns"], sq["truncated"], sq["notConverged"], sq["boundBeaten"]))
        # Paired: this mod's standard tier against each competitor.
        sub = subset(scenarios, set_name, kind)
        # Adjacency and the competitors' objectives with the standard tier;
        # city output with the panel's default (land part on).
        for other in ("amt", "ep", "amt:DEFAULTW", "ep:DEFAULT"):
            for ours, field in (("sdp:STANDARD", "gain"), ("sdp:STANDARD_LAND", "output"),
                                ("sdp:STANDARD", "cross_amt"), ("sdp:STANDARD", "cross_ep")):
                pr = paired(sub, ours, other, field)
                if pr["n"]:
                    lo, hi = pr["ci"]
                    print("  %-17s vs %-13s %-10s n %3d  W/T/L %d/%d/%d  mean %+.2f  CI [%+.2f, %+.2f]  p %.2g" % (
                        ours, other, field, pr["n"], pr["wins"], pr["ties"], pr["losses"], pr["mean"], lo, hi, pr["p"]))
    # Coverage (design 19.5): reach and adjacency, each setting against the
    # same tier without coverage and against AMT.
    cov = subset(scenarios, "coverage", "multi")
    if cov:
        print("== coverage: pairs newly reached, adjacency gain")
        for a, b in (("sdp:STANDARD_COV1", "sdp:STANDARD"), ("sdp:STANDARD_COV3", "sdp:STANDARD"),
                     ("sdp:FINE_COV1", "sdp:FINE"), ("sdp:FINE_COV3", "sdp:FINE"),
                     ("sdp:STANDARD", "amt"), ("sdp:STANDARD_COV1", "amt"), ("sdp:STANDARD_COV3", "amt")):
            par = pareto(cov, a, b)
            if not par["n"]:
                continue
            line = "  %-17s vs %-13s pareto n %d: better %d, worse %d, same %d, trade-off %d" % (
                a, b, par["n"], par["better"], par["worse"], par["same"], par["tradeoff"])
            for field in ("coverage", "gain"):
                pr = paired(cov, a, b, field)
                line += "  | %s W/T/L %d/%d/%d mean %+.2f" % (field, pr["wins"], pr["ties"], pr["losses"], pr["mean"])
            print(line)
        for k in sorted({k for e in cov.values() for k in e["runs"]}):
            runs = [e["runs"][k] for e in cov.values() if k in e["runs"] and not e["runs"][k].get("error")]
            if runs:
                print("  %-18s coverage mean %.2f  gain mean %.2f  not requested %d  missing %d" % (
                    k, statistics.mean(r.get("coverage") or 0 for r in runs), statistics.mean(r.get("gain") or 0 for r in runs),
                    sum((r.get("violations") or {}).get("not_requested", 0) for r in runs), sum(r.get("missing", 0) for r in runs)))
    if det:
        print("== determinism")
        for d in det:
            print("  %-36s %-14s %s" % (d["scenario"], d["planner"], "same" if d["same"] else "DIFFERENT"))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"scenarios": scenarios, "tables": tables, "determinism": det}, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
