"""ranges - this mod's tiers against the reference where the optimum is a range (issues 40, 48).

    python3 -I tests/compare/ranges.py RESULTS.jsonl [MORE.jsonl ...] [--sets large,large/heldout,dev/multi,heldout/multi]

For the scene sets whose optimum the oracle cannot always prove (large
cities, several cities), per set: how many scenes are proven, the mean
width of the range (upper end / best known), and for each tier the mean
share of the best known plan and of the upper end (the share of the true
optimum lies between the two). The reference is what summarize.py takes
(sdp:ORACLE with a node limit, sdp:LONGRUN). With sdp:LONGRUN rows, also
the two-slot check: how many fine plans one move of two districts at once
improves (issue 40). Prints Markdown tables.
"""
import argparse
import statistics
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summarize  # noqa: E402

TIERS = ["sdp:FAST", "sdp:STANDARD", "sdp:FINE", "sdp:CITY_BY_CITY", "amt", "ep"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--sets", default="large/single,large/heldout/single,dev/multi,heldout/multi")
    args = ap.parse_args()
    rows = summarize.load(args.files)
    scenarios, _ = summarize.summarize(rows)
    raw = {}
    for r in rows:
        raw[(r["scenario"], summarize.key(r))] = r
    print("| 场景集 | 场景 | 已证明 | 上界 / 已知最好 | " + " | ".join(t.split(":")[-1] for t in TIERS) + " |")
    print("|---|---|---|---|" + "---|" * len(TIERS))
    two = []
    for spec in args.sets.split(","):
        set_name, kind = spec.rsplit("/", 1)
        sub = {sid: e for sid, e in summarize.subset(scenarios, set_name, kind).items() if e.get("reference") is not None}
        if not sub:
            continue
        proven = sum(1 for e in sub.values() if e.get("optimum") is not None)
        widths = []
        for e in sub.values():
            top = e["optimum"] if e.get("optimum") is not None else (e.get("upper") or e["reference"])
            if e["reference"] > 0:
                widths.append(max(top, e["reference"]) / e["reference"])
        cells = []
        for t in TIERS:
            known, low = [], []
            for e in sub.values():
                r = e["runs"].get(t)
                if r is None:
                    continue
                g = (r.get("gain") or 0) if (not r.get("error") and r.get("legal")) else 0
                best = e["reference"]
                top = max(best, e["optimum"] if e.get("optimum") is not None else (e.get("upper") or best))
                known.append(g / best if best > 0 else 1.0)
                low.append(g / top if top > 0 else 1.0)
            cells.append("%.1f%% / %.1f%%" % (100 * statistics.mean(low), 100 * statistics.mean(known)) if known else "—")
        print("| %s | %d | %d | %.2f | %s |" % (spec, len(sub), proven, statistics.mean(widths) if widths else 1, " | ".join(cells)))
        # The two-slot check of the long runs.
        fine_better = n = 0
        for sid in sub:
            for k, r in raw.items():
                if k[0] != sid or not k[1].startswith("sdp:LONGRUN"):
                    continue
                lr = ((r.get("plan") or {}).get("stats") or {}).get("longrun")
                if not lr:
                    continue
                n += 1
                fine_better += 1 if (lr.get("fineTwoSlot") or {}).get("improving") else 0
        if n:
            two.append((spec, n, fine_better))
    print()
    print("每格：占上界的比例 / 占已知最好的比例（真最优的比例在两者之间）。")
    if two:
        print()
        print("| 场景集 | 长跑 | 精细档方案能被两槽移动改进 |")
        print("|---|---|---|")
        for spec, n, a in two:
            print("| %s | %d | %d |" % (spec, n, a))


if __name__ == "__main__":
    main()
