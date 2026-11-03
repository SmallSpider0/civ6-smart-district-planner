"""Issue 250: the single-city pipeline vs the same request as a one-city
multi-city solve (cmp_sdp.lua's "_ASMULTI" variants), on the development set.

    python3 -I tests/compare/asmulti250.py tests/compare/results/one_city_as_multi.jsonl

Quality against the proven optima in the same file (ORACLE: judged adjacency;
ORACLE_LAND: the mod's own objective), violations and missed districts, and
the work units each solve ticked (stats.sdpUnits) turned into seconds with
SDP_Tiers' at-once speed and the sliced speed of one city (SDP_Task).
docs/notes/issue-250-one-city-as-multi.md has the command and the results.
"""
import json, sys, statistics, collections

AT_ONCE, SLICED = 20000.0, 9000.0   # SDP_Tiers / SDP_Task speeds (units per second)
SLICED_TIERS = {"FINE", "FINE_LAND"}  # single-city tiers that run over frames

rows = {}
for line in open(sys.argv[1]):
    if not line.strip():
        continue
    r = json.loads(line)
    rows[(r["scenario"], r["variant"])] = r
scenes = sorted({s for s, _ in rows})
print("rows", len(rows), "scenes", len(scenes))

def st(r):
    return ((r or {}).get("plan") or {}).get("stats") or {}

def sc(r):
    return (r or {}).get("score") or {}

def legal(r):
    return r is not None and not r.get("error") and sc(r).get("legal")

errors = [(k, r.get("error")) for k, r in rows.items() if r.get("error") or not r.get("score")]
print("errors", len(errors), errors[:5])

ADJ = ["FAST", "STANDARD", "FINE"]
LAND = ["STANDARD_LAND", "FINE_LAND"]
PANEL = "STANDARD_SWAP_LAND_DIST050"

# References: adjacency = best judged gain among legal adjacency-only plans and ORACLE;
# land = best mod objective among the land runs and ORACLE_LAND.
ref_adj, ref_land = {}, {}
for s in scenes:
    vals = [sc(rows[(s, v)]).get("gain") for v in ADJ + [x + "_ASMULTI" for x in ADJ] + ["ORACLE"]
            if (s, v) in rows and legal(rows[(s, v)])]
    ref_adj[s] = max(vals) if vals else None
    vals = [st(rows[(s, v)]).get("sdpObjective") for v in LAND + [x + "_ASMULTI" for x in LAND] + ["ORACLE_LAND"]
            if (s, v) in rows and legal(rows[(s, v)]) and st(rows[(s, v)]).get("sdpObjective") is not None]
    ref_land[s] = max(vals) if vals else None

def oracle_ok(s, v):
    r = rows.get((s, v))
    o = st(r).get("oracle") or {}
    return o.get("proven")

print("oracle proven: adj %d/%d, land %d/%d" % (
    sum(1 for s in scenes if oracle_ok(s, "ORACLE")), len(scenes),
    sum(1 for s in scenes if oracle_ok(s, "ORACLE_LAND")), len(scenes)))
# Does any run beat the proven oracle?
for s in scenes:
    o = sc(rows.get((s, "ORACLE"))).get("gain")
    if oracle_ok(s, "ORACLE") and o is not None and ref_adj[s] > o:
        print("  above adj oracle:", s, ref_adj[s], o)
    o = st(rows.get((s, "ORACLE_LAND"))).get("sdpObjective")
    if oracle_ok(s, "ORACLE_LAND") and o is not None and ref_land[s] is not None and ref_land[s] > o + 1e-6:
        print("  above land oracle:", s, ref_land[s], o)

def value(s, v, kind):
    r = rows.get((s, v))
    if not legal(r):
        return None
    return sc(r).get("gain") if kind == "adj" else st(r).get("sdpObjective")

def pct(x, ref):
    if ref is None or x is None:
        return None
    if ref <= 0:
        return 100.0 if x >= ref - 1e-9 else 0.0
    return 100.0 * x / ref

def secs(units, sliced):
    return units / (SLICED if sliced else AT_ONCE)

print()
print("quality: %-28s %8s %8s %6s %6s | W/T/L multi vs single | mean diff" % ("tier", "mean%", "worst%", "=ref", "n"))
for kind, tiers, ref in (("adj", ADJ, ref_adj), ("land", LAND, ref_land)):
    for t in tiers:
        for v in (t, t + "_ASMULTI"):
            ps = [pct(value(s, v, kind), ref[s]) for s in scenes]
            ok = [p for p in ps if p is not None]
            hit = sum(1 for s in scenes if value(s, v, kind) is not None and ref[s] is not None and value(s, v, kind) >= ref[s] - 1e-9)
            extra = ""
            if v.endswith("_ASMULTI"):
                w = l = e = 0; diffs = []; losers = []
                for s in scenes:
                    a, b = value(s, v, kind), value(s, t, kind)
                    if a is None or b is None:
                        continue
                    diffs.append(a - b)
                    if a > b + 1e-9: w += 1
                    elif a < b - 1e-9: l += 1; losers.append((round(a - b, 2), s))
                    else: e += 1
                extra = "| %d/%d/%d | %+.3f  worst: %s" % (w, e, l, statistics.mean(diffs), sorted(losers)[:4])
            short = [ref[s] - value(s, v, kind) for s in scenes if value(s, v, kind) is not None and ref[s] is not None]
            # Percentages mean little where the optimum is near or below 0
            # (land part on); the shortfall in points is the measure there.
            print("  %-28s %8.2f %8.2f %6d %6d short %.2f (worst %.2f) %s" % (v, statistics.mean(ok), min(ok), hit, len(ok),
                  sum(short), max(short), extra))

print()
print("panel default (%s): mod objective and judged gain, multi vs single" % PANEL)
for key in ("sdpObjective",):
    w = l = e = 0; diffs = []; losers = []
    for s in scenes:
        a, b = st(rows.get((s, PANEL + "_ASMULTI"))).get(key), st(rows.get((s, PANEL))).get(key)
        if a is None or b is None: continue
        diffs.append(a - b)
        if a > b + 1e-9: w += 1
        elif a < b - 1e-9: l += 1; losers.append((round(a - b, 2), s))
        else: e += 1
    print("  %s W/T/L %d/%d/%d mean %+.3f worst %s" % (key, w, e, l, statistics.mean(diffs), sorted(losers)[:4]))
w = l = e = 0
for s in scenes:
    a, b = sc(rows.get((s, PANEL + "_ASMULTI"))).get("gain"), sc(rows.get((s, PANEL))).get("gain")
    if a is None or b is None: continue
    if a > b: w += 1
    elif a < b: l += 1
    else: e += 1
print("  judged gain W/T/L %d/%d/%d" % (w, e, l))
def layout(r):
    # The multi-city branch writes kind "DISTRICT", the single-city one leaves
    # it out: compare city, type, kind and tile only.
    return sorted((str(p.get("city")), p.get("type"), p.get("kind") or "DISTRICT", p.get("x"), p.get("y"))
                  for p in ((r or {}).get("plan") or {}).get("placements", []))
for t in ADJ + LAND + [PANEL]:
    same = sum(1 for s in scenes if (s, t) in rows and layout(rows[(s, t)]) == layout(rows.get((s, t + "_ASMULTI"))))
    print("  identical plans %-28s %d/%d" % (t, same, len(scenes)))

print()
print("violations, missing")
for t in ADJ + LAND + [PANEL]:
    for v in (t, t + "_ASMULTI"):
        viol = collections.Counter(); runs_v = 0; miss = mp = 0
        for s in scenes:
            r = rows.get((s, v))
            if not r: continue
            vs = sc(r).get("violations") or []
            real = [x for x in vs if not (x.get("kind") == "missing" and x.get("detail") == "no_plot")]
            for x in vs:
                viol[x.get("kind") + ("/" + x["detail"] if x.get("detail") else "")] += 1
            if real: runs_v += 1
            miss += sc(r).get("missing") or 0
            mp += sc(r).get("missingPlaceable") or 0
        print("  %-36s runs with violations %d  kinds %s  missing %d (placeable %d)" % (v, runs_v, dict(viol), miss, mp))

print()
print("work units (sdpUnits) and estimated seconds; single FAST/STANDARD at once (%d u/s), FINE and all multi sliced (%d u/s)" % (AT_ONCE, SLICED))
for t in ADJ + LAND + [PANEL]:
    for v in (t, t + "_ASMULTI"):
        sliced = v.endswith("_ASMULTI") or t in SLICED_TIERS
        us = [(st(rows[(s, v)]).get("sdpUnits") or 0, s) for s in scenes if (s, v) in rows]
        est = [st(rows[(s, v)]).get("sdpEstimate") or 0 for s in scenes if (s, v) in rows]
        calls = [st(rows[(s, v)]).get("dmtCalls") or 0 for s in scenes if (s, v) in rows]
        u = sorted(x for x, _ in us)
        top = sorted(us, reverse=True)[:3]
        print("  %-36s units median %7.0f p90 %7.0f max %7.0f | sec median %.2f max %.2f | est/actual %.2f | dmt median %d | slowest %s" % (
            v, statistics.median(u), u[int(0.9 * (len(u) - 1))], u[-1], secs(statistics.median(u), sliced), secs(u[-1], sliced),
            sum(est) / max(1, sum(u)), statistics.median(calls), [(int(x), s) for x, s in top]))
    ratio = []
    for s in scenes:
        a, b = st(rows.get((s, t + "_ASMULTI"))).get("sdpUnits"), st(rows.get((s, t))).get("sdpUnits")
        if a and b: ratio.append(a / b)
    print("    multi/single units ratio median %.2f max %.2f" % (statistics.median(ratio), max(ratio)))

print()
print("offline planSeconds (fengari, 2nd machine; only for scale)")
for t in ADJ + LAND + [PANEL]:
    for v in (t, t + "_ASMULTI"):
        p = sorted(rows[(s, v)].get("planSeconds") or 0 for s in scenes if (s, v) in rows)
        print("  %-36s median %.1f max %.1f" % (v, statistics.median(p), p[-1]))

# Slowest scenes for the panel default, side by side.
print()
print("slowest 8 scenes by multi units (panel default and FINE_LAND):")
for t in (PANEL, "FINE_LAND"):
    us = sorted(((st(rows[(s, t + "_ASMULTI")]).get("sdpUnits") or 0, s) for s in scenes), reverse=True)[:8]
    for u, s in us:
        b = st(rows[(s, t)]).get("sdpUnits") or 0
        print("  %-16s %-34s multi %7d (%.1fs) single %7d (%.2fs %s) obj %s / %s" % (t, s, u, secs(u, True), b,
              secs(b, t in SLICED_TIERS), "sliced" if t in SLICED_TIERS else "at once",
              st(rows[(s, t + "_ASMULTI")]).get("sdpObjective"), st(rows[(s, t)]).get("sdpObjective")))

# Notes: unplaced reasons that differ
print()
print("unplaced notes that differ (panel default):")
nd = 0
for s in scenes:
    a = sorted((rows[(s, PANEL + "_ASMULTI")].get("plan") or {}).get("notes") or [])
    b = sorted((rows[(s, PANEL)].get("plan") or {}).get("notes") or [])
    if a != b:
        nd += 1
        if nd <= 8: print("  ", s, "multi", a, "single", b)
print("  scenes with different notes:", nd)
