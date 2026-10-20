"""Summarize tools/compare.mjs results.

    python3 -I tests/compare/summarize.py RESULTS.jsonl [MORE.jsonl ...] [--json OUT]

For every scenario the reference is the best gain any planner reached with
a legal plan (no rule broken; leaving a requested district out is not a
broken rule, but it costs gain). Quality = gain / reference. A plan that
breaks a rule keeps its gain in the tables but is counted as illegal.
Repeated runs ("#2" variants) only feed the determinism check.
"""
import argparse
import json
import statistics
import sys
from collections import defaultdict

HARD = {"off_map", "same_tile", "occupied", "overwrites_pin", "no_city", "out_of_range", "foreign_tile",
        "other_city_tile", "unknown_type", "dmt_illegal", "twice_in_city", "empire_limit", "slots", "on_resource"}


def key(r):
    return r["planner"] + (":" + r["variant"] if r.get("variant") else "")


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
            if not hard:
                best = s["gain"] if best is None else max(best, s["gain"])
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
        entry = {"reference": best, "exact": exact, "referenceOutput": best_out, "runs": {}}
        for k, r in runs.items():
            s = r.get("score")
            e = {"seconds": r.get("planSeconds"), "error": r.get("error")}
            if s:
                kinds = defaultdict(int)
                for v in s["violations"]:
                    kinds[v["kind"]] += 1
                hard = sum(n for kk, n in kinds.items() if kk in HARD)
                e.update({
                    "gain": s["gain"], "legal": hard == 0, "violations": dict(kinds), "missing": s.get("missing", 0),
                    "missingPlaceable": s.get("missingPlaceable"),
                    "tileLoss": s.get("tileLoss"), "placed": s.get("placed"),
                    "quality": (s["gain"] / best) if best and best > 0 else (1.0 if best == 0 and s["gain"] >= 0 else None),
                    "dmtCalls": (r.get("plan") or {}).get("stats", {}).get("dmtCalls"),
                    "output": s.get("output"), "worked": s.get("worked"),
                    "outputGap": (best_out - s["output"]) if (best_out is not None and s.get("output") is not None) else None,
                    "notes": (r.get("plan") or {}).get("notes"),
                })
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


def per_planner(scenarios, kind_filter=None):
    agg = defaultdict(lambda: defaultdict(list))
    for sid, e in scenarios.items():
        if kind_filter and not sid.startswith(kind_filter):
            continue
        for k, r in e["runs"].items():
            a = agg[k]
            a["n"].append(1)
            if r.get("error"):
                a["errors"].append(sid)
                continue
            if r.get("quality") is not None:
                a["quality"].append(r["quality"])
            a["legal"].append(1 if r.get("legal") else 0)
            a["missing"].append(r.get("missing", 0))
            a["missingPlaceable"].append(r.get("missingPlaceable") or 0)
            a["seconds"].append(r.get("seconds") or 0)
            if e["reference"] is not None and r.get("gain") is not None:
                a["best"].append(1 if r["legal"] and r["gain"] >= e["reference"] - 1e-9 else 0)
            if r.get("outputGap") is not None:
                a["outGap"].append(r["outputGap"])
                a["outBest"].append(1 if r["legal"] and r["outputGap"] <= 1e-9 else 0)
            for kk, n in (r.get("violations") or {}).items():
                a["v_" + kk].append(n)
    out = {}
    for k, a in agg.items():
        q = a["quality"]
        out[k] = {
            "runs": len(a["n"]), "errors": len(a["errors"]),
            "qualityMean": statistics.mean(q) if q else None, "qualityMin": min(q) if q else None,
            "legalShare": statistics.mean(a["legal"]) if a["legal"] else None,
            "bestShare": statistics.mean(a["best"]) if a["best"] else None,
            "missing": sum(a["missing"]), "missingPlaceable": sum(a["missingPlaceable"]), "secondsMedian": statistics.median(a["seconds"]) if a["seconds"] else None,
            "violations": {kk[2:]: sum(v) for kk, v in a.items() if kk.startswith("v_")},
            "outputBestShare": statistics.mean(a["outBest"]) if a["outBest"] else None,
            "outputGapMean": statistics.mean(a["outGap"]) if a["outGap"] else None,
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json")
    args = ap.parse_args()
    rows = load(args.files)
    scenarios, det = summarize(rows)
    tables = {"all": per_planner(scenarios), "single": per_planner(scenarios, "S"), "multi": per_planner(scenarios, "M")}
    for name, t in tables.items():
        print("==", name)
        for k in sorted(t):
            v = t[k]
            q = v["qualityMean"]
            ob, og = v.get("outputBestShare"), v.get("outputGapMean")
            print("  %-18s output best %s gap %s" % (k, "%.2f" % ob if ob is not None else "-", "%.2f" % og if og is not None else "-"))
            print("  %-18s runs %3d err %2d  quality %s (min %s)  legal %s  best %s  missing %3d (placeable %d)  median %.1fs  %s" % (
                k, v["runs"], v["errors"], "%.3f" % q if q is not None else "-",
                "%.2f" % v["qualityMin"] if v["qualityMin"] is not None else "-",
                "%.2f" % v["legalShare"] if v["legalShare"] is not None else "-",
                "%.2f" % v["bestShare"] if v["bestShare"] is not None else "-",
                v["missing"], v["missingPlaceable"], v["secondsMedian"] or 0, json.dumps(v["violations"])))
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
