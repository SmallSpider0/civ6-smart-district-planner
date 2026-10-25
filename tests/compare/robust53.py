#!/usr/bin/env python3
"""robust53.py - robustness of the default yield weights (issue 53).

For every single-city scene and every pair of weight vectors (A, B): the
proven optimum for A (sdp:ORACLE, adjacency only) judged under B's weights,
as a share of B's optimum. Loss(A -> B) = 1 - score_B(plan_A) / V*_B.

The judge's gain is linear in the weights (cmp_lib.lua: gain = sum over
yields of weight x byYield), so score_B(plan_A) is computed from plan_A's
byYield; a rejudged file (compare.mjs --rejudge FILE --weights ...) given
with --check is compared with that, row by row.

Usage (Python 3.8, -I):
  python3 -I tests/compare/robust53.py --vectors tests/compare/weights/w53.jsonl \\
      [-s SCENE_REGEX] [--check REJUDGED.jsonl] [--distinct OUT.jsonl] ORACLE_RESULTS.jsonl ...

--distinct OUT writes each scene's distinct optimal plans once (for
compare.mjs --rejudge OUT --weights ...) and stops.
  python3 -I tests/compare/robust53.py --slim REJUDGED.jsonl OUT.jsonl
keeps only what --check reads of the rejudged rows.

Rows are sdp:ORACLE runs. A row's vector is its "weights" name (compare.mjs
--weights); a row without one is "all1", or sci3 / prod3 / faith3 for the
~SCI / ~PROD / ~FAITH scenes. Later files win for the same scene and vector.
"""

import json
import re
import statistics
import sys

YIELDS = {"science": "YIELD_SCIENCE", "culture": "YIELD_CULTURE", "faith": "YIELD_FAITH", "gold": "YIELD_GOLD",
          "production": "YIELD_PRODUCTION", "food": "YIELD_FOOD"}
PROFILE = {"SCI": "sci3", "PROD": "prod3", "FAITH": "faith3"}
SCENE = re.compile(r"^(H?S)\d\d-[^~]*$")
EPS = 1e-6


def load_vectors(path):
    order, vectors = [], {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            o = json.loads(line)
            w = {y: 1.0 for y in YIELDS.values()}
            for k, v in o.items():
                if k in YIELDS:
                    w[YIELDS[k]] = float(v)
            order.append(o["name"])
            vectors[o["name"]] = w
    return order, vectors


def vector_of(row):
    if row.get("weights"):
        return row["weights"]["name"]
    if "~" in row["scenario"]:
        return PROFILE.get(row["scenario"].split("~", 1)[1])
    return "all1"


def value(by_yield, w):
    return sum(a * w.get(y, 1.0) for y, a in (by_yield or {}).items())


def signature(row):
    return tuple(sorted((p["type"], p["x"], p["y"]) for p in row["plan"]["placements"]))


def pct(x):
    return "%.2f" % (100 * x)


def slim_rows(src, dst):
    """Keep what --check reads of rejudged rows (the full rows are ~2 kB each)."""
    n = 0
    with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as out:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            score = r.get("score") or {}
            row = {"scenario": r["scenario"], "planner": r["planner"], "variant": r.get("variant", ""),
                   "planWeights": r.get("planWeights"), "weights": {"name": (r.get("weights") or {}).get("name")},
                   "plan": {"placements": (r.get("plan") or {}).get("placements", [])},
                   "score": {"gain": score.get("gain"), "legal": score.get("legal")}}
            if r.get("judgeError"):
                row["judgeError"] = r["judgeError"]
            out.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
            n += 1
    print("%d rows -> %s" % (n, dst))


def main(argv):
    if argv[:1] == ["--slim"] and len(argv) == 3:
        slim_rows(argv[1], argv[2])
        return 0
    vectors_path, check_path, distinct_path, only, files = None, None, None, None, []
    i = 0
    while i < len(argv):
        if argv[i] == "--vectors":
            vectors_path = argv[i + 1]
            i += 2
        elif argv[i] == "-s":
            only = re.compile(argv[i + 1])
            i += 2
        elif argv[i] == "--distinct":
            distinct_path = argv[i + 1]
            i += 2
        elif argv[i] == "--check":
            check_path = argv[i + 1]
            i += 2
        else:
            files.append(argv[i])
            i += 1
    if not vectors_path or not files:
        print(__doc__)
        return 2
    order, vectors = load_vectors(vectors_path)

    # (scene, vector) -> row
    runs = {}
    problems = []
    for path in files:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                r = json.loads(line)
                # Rejudged rows (planWeights) are for --check only.
                if r.get("planner") != "sdp" or not str(r.get("variant", "")).startswith("ORACLE") or "planWeights" in r:
                    continue
                scene = r["scenario"].split("~", 1)[0]
                name = vector_of(r)
                if not SCENE.match(scene) or name not in vectors or (only and not only.search(scene)):
                    continue
                if r.get("error") or not r.get("score") or not r.get("plan"):
                    problems.append("%s [%s]: no plan or score" % (scene, name))
                    continue
                runs[(scene, name)] = r

    # Checks of each row against its own vector: the judge's weighted gain is
    # the weighted byYield and equals the oracle's value; proven.
    unproven = []
    for (scene, name), r in sorted(runs.items()):
        w = vectors[name]
        s = r["score"]
        own = value(s.get("byYield"), w)
        if abs(own - s["gain"]) > EPS:
            problems.append("%s [%s]: judge gain %s != weighted byYield %s" % (scene, name, s["gain"], own))
        o = (r["plan"].get("stats") or {}).get("oracle") or {}
        ow = (o.get("objective") or {}).get("weights")
        if ow and any(abs(ow.get(y, 1) - w[y]) > EPS for y in w):
            problems.append("%s [%s]: oracle ran with other weights %s" % (scene, name, ow))
        if o.get("value") is not None and abs(o["value"] - s["gain"]) > EPS:
            problems.append("%s [%s]: oracle value %s != judge gain %s" % (scene, name, o["value"], s["gain"]))
        if not s.get("legal", True):
            problems.append("%s [%s]: plan not legal" % (scene, name))
        # Rows marked oracleBound came from the bound before the fix of
        # 5ba714d: the best layout found, not a proven optimum.
        if o.get("proven") is not True or r.get("oracleBound"):
            unproven.append("%s [%s]" % (scene, name))

    scenes = sorted({s for s, _ in runs})
    names = [n for n in order if any((s, n) in runs for s in scenes)]

    if distinct_path:
        # Each scene's distinct optimal plans once (the first vector's row,
        # plan placements only), for compare.mjs --rejudge --weights.
        n = 0
        with open(distinct_path, "w", encoding="utf-8") as f:
            for s in scenes:
                seen = set()
                for name in names:
                    r = runs.get((s, name))
                    if r is None or signature(r) in seen:
                        continue
                    seen.add(signature(r))
                    slim = {"scenario": r["scenario"], "planner": r["planner"], "variant": r["variant"],
                            "plan": {"placements": r["plan"]["placements"]}}
                    if r.get("weights"):
                        slim["weights"] = r["weights"]
                    f.write(json.dumps(slim) + "\n")
                    n += 1
        print("%d distinct plans on %d scenes -> %s" % (n, len(scenes), distinct_path))
        return 0

    # Rejudged rows (compare.mjs --rejudge --weights): a plan judged under B,
    # against the value computed from the oracle row's byYield. Matched by
    # scene, plan and B, so a file with each distinct plan once will do.
    checked, worst, pairs = 0, 0.0, 0
    if check_path:
        judged = {}
        with open(check_path, encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                r = json.loads(line)
                if "planWeights" not in r or not r.get("score") or not r.get("plan"):
                    continue
                judged[(r["scenario"].split("~", 1)[0], signature(r), r["weights"]["name"])] = r["score"]
        for (scene, a), base in sorted(runs.items()):
            for b in vectors:
                if (scene, b) not in runs:
                    continue
                pairs += 1
                score = judged.get((scene, signature(base), b))
                if score is None:
                    continue
                computed = value(base["score"]["byYield"], vectors[b])
                d = abs(score["gain"] - computed)
                worst = max(worst, d)
                if d > EPS:
                    problems.append("check %s %s->%s: rejudged %s != computed %s" % (scene, a, b, score["gain"], computed))
                checked += 1

    def table(subset, title):
        print("\n## %s (%d scenes)\n" % (title, len(subset)))
        have = [n for n in names if all((s, n) in runs for s in subset)]
        missing = [n for n in names if n not in have]
        if missing:
            print("Left out (no optimum on every scene): %s\n" % ", ".join(missing))
        if len(have) < 2:
            print("Fewer than two vectors: nothing to compare.")
            return
        # Best known value under B per scene: B's optimum, or more if another
        # vector's plan beats it (then B's optimum was not one).
        loss = {}
        beaten = []
        zero = 0
        for s in subset:
            vals = {(a, b): value(runs[(s, a)]["score"]["byYield"], vectors[b]) for a in have for b in have}
            for b in have:
                vstar = vals[(b, b)]
                top = max(vals[(a, b)] for a in have)
                if top > vstar + EPS:
                    beaten.append("%s [%s] %s > %s" % (s, b, top, vstar))
                    vstar = top
                for a in have:
                    if vstar <= EPS:
                        loss[(s, a, b)] = 0.0
                    else:
                        loss[(s, a, b)] = 1 - vals[(a, b)] / vstar
            if all(vals[(b, b)] <= EPS for b in have):
                zero += 1
        if beaten:
            print("Optimum beaten by another vector's plan (%d): %s\n" % (len(beaten), "; ".join(beaten[:10])))
        if zero:
            print("%d scenes have optimum 0 under every vector (loss 0)\n" % zero)

        # Weight-insensitive scenes.
        same_plan = sum(1 for s in subset if len({signature(runs[(s, n)]) for n in have}) == 1)
        all_opt = sum(1 for s in subset if all(loss[(s, a, b)] <= EPS for a in have for b in have))
        print("Same plan under all %d vectors: %d / %d (%s %%); every plan optimal under every vector: %d / %d (%s %%)\n" % (
            len(have), same_plan, len(subset), pct(same_plan / len(subset)), all_opt, len(subset), pct(all_opt / len(subset))))

        print("Loss of choosing A when B is right, mean over scenes, % (row A, column B):\n")
        print("| A \\ B | " + " | ".join(have) + " |")
        print("|---|" + "---|" * len(have))
        for a in have:
            cells = []
            for b in have:
                ls = [loss[(s, a, b)] for s in subset]
                cells.append(pct(statistics.mean(ls)))
            print("| %s | %s |" % (a, " | ".join(cells)))

        print("\nPairs (A != B): mean / median / max loss %, share of scenes where plan A is optimal under B:\n")
        print("| A | B | mean | median | max | A optimal under B |")
        print("|---|---|---|---|---|---|")
        for a in have:
            for b in have:
                if a == b:
                    continue
                ls = [loss[(s, a, b)] for s in subset]
                opt = sum(1 for x in ls if x <= EPS)
                print("| %s | %s | %s | %s | %s | %d / %d |" % (a, b, pct(statistics.mean(ls)), pct(statistics.median(ls)),
                                                             pct(max(ls)), opt, len(ls)))

        print("\nRegret of A as the default, over every other B (mean of the pair means; worst pair mean; worst single scene), %:\n")
        candidates = [n for n in have if n not in PROFILE.values()]
        print("| A | mean over all B | worst B (pair mean) | worst scene | mean over defaults B | worst default B (pair mean) |")
        print("|---|---|---|---|---|---|")
        for a in have:
            pm = {b: statistics.mean([loss[(s, a, b)] for s in subset]) for b in have if b != a}
            worst_scene = max(loss[(s, a, b)] for s in subset for b in have if b != a)
            wb = max(pm, key=lambda b: pm[b])
            dm = {b: pm[b] for b in candidates if b != a}
            dwb = max(dm, key=lambda b: dm[b]) if dm else None
            print("| %s | %s | %s (%s) | %s | %s | %s |" % (
                a, pct(statistics.mean(pm.values())), pct(pm[wb]), wb, pct(worst_scene),
                pct(statistics.mean(dm.values())) if dm else "-", ("%s (%s)" % (pct(dm[dwb]), dwb)) if dm else "-"))

    print("# Robustness of the yield weights (issue 53)")
    print("\nOptima: %d rows, %d scenes, vectors %s; not proven (or found with the old bound): %d%s" % (
        len(runs), len(scenes), ", ".join(names), len(unproven), (" (" + "; ".join(unproven[:5]) + " ...)") if unproven else ""))
    if check_path:
        print("Rejudged under B and compared with the computed value: %d of %d (scene, A, B), largest difference %g" % (checked, pairs, worst))
    if problems:
        print("\nProblems (%d):" % len(problems))
        for p in problems[:30]:
            print("  " + p)
    dev = [s for s in scenes if s.startswith("S")]
    held = [s for s in scenes if s.startswith("HS")]
    if dev:
        table(dev, "Development set S")
    if held:
        table(held, "Held-out set HS")
    if dev and held:
        table(scenes, "S + HS")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
