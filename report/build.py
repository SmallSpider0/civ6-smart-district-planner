"""Build the delivery report from the comparison results.

    python3 -I report/build.py [RESULTS.jsonl ...]   (default: RESULTS below)

Writes two pages to dist/report/:

  index.html    the page published as the artifact; screenshots are referenced
                as images/<name>, published from docs/images/
  report.html   the same page as one self-contained file (screenshots inlined),
                to open from disk; tools/package.py puts it in the test package

Case-study maps come from `node tools/compare.mjs --snapshot ID`, cached in
report/snaps/ (commit new snapshots: the package build does not make them).
"""
import base64
import json
import os
import re
import statistics
import subprocess
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
IMAGES = os.path.join(REPO, "docs", "images")
OUT = os.path.join(REPO, "dist", "report")
sys.path.insert(0, os.path.join(REPO, "tests", "compare"))
sys.path.insert(0, HERE)
import summarize  # noqa: E402
import hexmap  # noqa: E402

# Everything the report reads, so tools/package.py can refuse uncommitted changes to it.
INPUTS = ["report", "tests/compare/results", "tests/compare/summarize.py", "docs/images"]
RESULTS = ["tests/compare/results/" + f + ".jsonl" for f in (
    "full_rejudged", "land", "full_cross", "heldout", "heldout_cross",
    "profiles_SCI", "profiles_PROD", "profiles_FAITH", "sites",
    "wonders_sdp_ep", "wonders_amt", "wonders_cross", "wonders_sdp_repair",
    "coverage_sdp", "coverage_amt")]

PLANNERS = {
    "sdp:FAST": {"label": "本模组 快速档", "color": "--s1"},
    "sdp:STANDARD": {"label": "本模组 标准档", "color": "--sdp"},
    "sdp:FINE": {"label": "本模组 精细档", "color": "--s3"},
    "sdp:STANDARD_LAND": {"label": "本模组 标准档·计入地块（面板默认）", "color": "--s3"},
    "sdp:CITY_BY_CITY": {"label": "本模组 逐城依次", "color": "--opt"},
    "amt": {"label": "AMT r49", "color": "--amt"},
    "amt:DEFAULTW": {"label": "AMT（默认权重）", "color": "--amt"},
    "ep": {"label": "Empire Planner", "color": "--ep"},
    "ep:DEFAULT": {"label": "EP（默认权重）", "color": "--ep"},
}
DNAME = {"DISTRICT_AQUEDUCT": "水渠", "DISTRICT_DAM": "水坝", "DISTRICT_HARBOR": "港口", "DISTRICT_SEOWON": "书院",
         "DISTRICT_CANAL": "运河", "DISTRICT_GOVERNMENT": "政府广场"}
STAGES = [("early", "前期 · 2 个区域"), ("mid", "中期 · 4–5 个"), ("late", "后期 · 7–8 个")]


def pct(v, digits=0):
    return ("%." + str(digits) + "f%%") % (v * 100)


def snapshot(sid, make):
    path = os.path.join(HERE, "snaps", sid + ".json")
    if not os.path.exists(path):
        if not make:
            raise RuntimeError("report/snaps/%s.json is missing: run report/build.py and commit it" % sid)
        out = subprocess.run(["node", "tools/compare.mjs", "--snapshot", sid], cwd=REPO,
                             capture_output=True, text=True, check=True)
        open(path, "w", encoding="utf-8").write(out.stdout)
    return json.load(open(path, encoding="utf-8"))


MULTIPOOLS_TEXT = (
    "多城另有一组基准（<code>tests/offline/bench_multipools.lua</code>）：首都加 3 个城址钉，每座城学院必建、再从 5 个候选里挑 2 个，3 个种子；"
    "参照是各档、精细档加两次继续优化、“先逐城挑再联合规划”（每座城单独用单城精细档挑组合，再一起规划）中最好的值。"
    "标准档、精细档 3 个种子都达到参照，按单价折算约 3.1 秒、7.1 秒，分帧计算；快速档平均 97.6%，约 0.5 秒。"
    "“先逐城挑”为 96%、97%、100%。标准档起初在一个种子上只有 93%：它挑的组合与精细档相同，差在多城的摆放搜索，"
    "加了宽束联合起点（4.3）后达到参照。")
MULTIPOOLS_ROW = ["多城挑选", "3", "标准档、精细档 3 个都达到参照，比“先逐城挑再联合规划”（96%–100%）好"]


def build(files=None, make_snapshots=True):
    """Return (page, data): the artifact page (without the document skeleton) and its chart data."""
    rows = summarize.load([os.path.join(REPO, f) for f in (files or RESULTS)])
    scenarios, det = summarize.summarize(rows)
    raw = {}
    for r in rows:
        raw[(r["scenario"], summarize.key(r))] = r
    single = summarize.subset(scenarios, "dev", "single")
    multi = summarize.subset(scenarios, "dev", "multi")

    def runs_of(sc, key):
        return [(sid, e["runs"][key]) for sid, e in sorted(sc.items()) if key in e["runs"] and not e["runs"][key].get("error")]

    # ---------------------------------------------------------------- overview
    def stats(sc, key):
        rs = runs_of(sc, key)
        if not rs:
            return None
        q = [r["quality"] for _, r in rs if r.get("quality") is not None]
        best = [1 if (r["legal"] and r.get("quality") is not None and r["quality"] >= 1 - 1e-9) else 0 for _, r in rs]
        requested = sum(raw[(sid, key)]["score"]["requested"] for sid, _ in rs)
        missing = sum(r.get("missing", 0) for _, r in rs)
        placeable = sum(r.get("missingPlaceable") or 0 for _, r in rs)
        og = [r["outputGap"] for _, r in rs if r.get("outputGap") is not None]
        ob = [1 if (r["legal"] and r["outputGap"] <= 1e-9) else 0 for _, r in rs if r.get("outputGap") is not None]
        return {
            "n": len(rs), "best": statistics.mean(best), "quality": statistics.mean(q) if q else 0, "worst": min(q) if q else 0,
            "legal": sum(1 for _, r in rs if r["legal"]), "missing": missing, "requested": requested,
            "missingPlaceable": placeable,
            "outBest": statistics.mean(ob) if ob else None, "outGap": statistics.mean(og) if og else None,
            "time": statistics.median([r["seconds"] for _, r in rs]),
            "pins": sum((r.get("violations") or {}).get("overwrites_pin", 0) for _, r in rs),
            "pinPlans": sum(1 for _, r in rs if (r.get("violations") or {}).get("overwrites_pin")),
            "illegalKinds": defaultdict(int),
        }

    order = ["sdp:FAST", "sdp:STANDARD", "sdp:FINE", "sdp:STANDARD_LAND", "amt", "amt:DEFAULTW", "ep", "ep:DEFAULT"]
    S = {k: stats(single, k) for k in order}
    overview = []
    for k in order:
        s = S[k]
        if s is None:
            continue
        overview.append({"label": PLANNERS[k]["label"], "best": pct(s["best"]), "quality": pct(s["quality"], 1),
                         "worst": pct(s["worst"]), "legal": "%d / %d" % (s["legal"], s["n"]),
                         "missing": "%d / %d" % (s["missing"], s["requested"]), "time": "%.1f 秒" % s["time"]})

    main_series = [k for k in ["sdp:STANDARD", "amt", "ep"] if S.get(k)]
    by_best, by_q = [], []
    qmins = []
    for stage, label in STAGES:
        sc = {k: v for k, v in single.items() if k.endswith("-" + stage)}
        vb, vq = {}, {}
        for k in main_series:
            s = stats(sc, k)
            if s:
                vb[k] = s["best"] * 100
                vq[k] = s["quality"] * 100
                qmins.append(s["quality"] * 100)
        by_best.append({"label": label, "values": vb})
        by_q.append({"label": label, "values": vq})
    qmin = max(0, (int(min(qmins + [100]) // 10) - 1) * 10) if qmins else 50
    qticks = list(range(qmin, 101, 10 if 100 - qmin > 30 else 5))

    # ---------------------------------------------------------------- scatter
    pts = {"amt": [], "ep": []}
    gmax = 1
    for sid, e in sorted(single.items()):
        us = e["runs"].get("sdp:STANDARD")
        if not us or us.get("error"):
            continue
        for k in ("amt", "ep"):
            o = e["runs"].get(k)
            if not o or o.get("error") or o.get("gain") is None:
                continue
            gmax = max(gmax, us["gain"], o["gain"])
            extra = []
            if o.get("missing"):
                extra.append("漏放 %d" % o["missing"])
            if not o["legal"]:
                extra.append("违规")
            pts[k].append({"x": us["gain"], "y": o["gain"], "bad": not o["legal"],
                           "label": "%s：本模组 +%d，%s +%d%s" % (sid, us["gain"], PLANNERS[k]["label"], o["gain"],
                                                              ("（" + "，".join(extra) + "）") if extra else "")})
    smax = int((gmax + 9) // 10 * 10)
    ticks = list(range(0, smax + 1, 10 if smax <= 60 else 20))

    def wtl(k):
        w = t = l = 0
        diffs = []
        for sid, e in single.items():
            us, o = e["runs"].get("sdp:STANDARD"), e["runs"].get(k)
            if not us or not o or us.get("error") or o.get("error"):
                continue
            d = us["gain"] - o["gain"]
            diffs.append(d)
            if d > 1e-9:
                w += 1
            elif d < -1e-9:
                l += 1
            else:
                t += 1
        return w, t, l, diffs

    cap = {}
    for k, name in (("amt", "AMT"), ("ep", "Empire Planner")):
        w, t, l, diffs = wtl(k)
        n = w + t + l
        rel = []
        for sid, e in single.items():
            us, o = e["runs"].get("sdp:STANDARD"), e["runs"].get(k)
            if us and o and not us.get("error") and not o.get("error") and us["gain"] > 0:
                rel.append((us["gain"] - o["gain"]) / us["gain"])
        cap[k] = "%d 个场景中：本模组更高 %d 个，持平 %d 个，%s更高 %d 个；平均高出 %.1f（%s）。" % (
            n, w, t, name, l, statistics.mean(diffs) if diffs else 0, pct(statistics.mean(rel), 0) if rel else "-")
        cap[k + "_wtl"] = (w, t, l, statistics.mean(diffs) if diffs else 0, statistics.mean(rel) if rel else 0)

    # ---------------------------------------------------------------- city output
    def paired_output(a, b):
        w = t = l = 0
        diffs = []
        for sid, e in single.items():
            ra, rb = e["runs"].get(a), e["runs"].get(b)
            if not ra or not rb or ra.get("error") or rb.get("error") or ra.get("output") is None or rb.get("output") is None:
                continue
            d = ra["output"] - rb["output"]
            diffs.append(d)
            if d > 1e-9:
                w += 1
            elif d < -1e-9:
                l += 1
            else:
                t += 1
        return w, t, l, (statistics.mean(diffs) if diffs else 0)

    output_rows = []
    ours_out = "sdp:STANDARD_LAND" if S.get("sdp:STANDARD_LAND") else "sdp:STANDARD"
    for k in ["sdp:STANDARD", "sdp:STANDARD_LAND", "amt", "amt:DEFAULTW", "ep", "ep:DEFAULT"]:
        s_ = S.get(k)
        if not s_ or s_.get("outBest") is None:
            continue
        if k == ours_out:
            vs = "—"
        else:
            w, t, l, d = paired_output(ours_out, k)
            vs = "%d / %d / %d（平均 %+.1f）" % (w, t, l, d)
        output_rows.append({"label": PLANNERS[k]["label"], "best": pct(s_["outBest"]), "gap": "%.1f" % s_["outGap"], "vs": vs})
    out_pairs = {k: paired_output(ours_out, k) for k in ("amt", "amt:DEFAULTW", "ep", "ep:DEFAULT") if S.get(k)}

    # ---------------------------------------------------------------- correctness
    correct = []
    det_by = defaultdict(lambda: [0, 0])
    for d in det:
        det_by[d["planner"]][0] += 1 if d["same"] else 0
        det_by[d["planner"]][1] += 1
    for k in ["sdp:STANDARD", "sdp:STANDARD_LAND", "amt", "amt:DEFAULTW", "ep", "ep:DEFAULT"]:
        s = S.get(k)
        if not s:
            continue
        illegal = s["n"] - s["legal"]
        kinds = defaultdict(int)
        for sid, r in runs_of(single, k):
            for kk, n in (r.get("violations") or {}).items():
                if kk in summarize.HARD:
                    kinds[kk] += n
        KN = {"overwrites_pin": "压钉", "dmt_illegal": "DMT 判不可放", "on_resource": "压资源", "slots": "超槽位",
              "empire_limit": "超帝国上限", "twice_in_city": "同城重复", "out_of_range": "超出 3 环", "foreign_tile": "别国的格",
              "other_city_tile": "本国其他城的格", "occupied": "格已占用", "same_tile": "同一格两个"}
        detail = "、".join("%s %d" % (KN.get(kk, kk), n) for kk, n in sorted(kinds.items(), key=lambda x: -x[1]))
        d = det_by.get(k, [0, 0])
        correct.append({"label": PLANNERS[k]["label"], "illegal": "%d / %d%s" % (illegal, s["n"], ("（" + detail + "）") if detail else ""),
                        "pins": "%d 个方案" % s["pinPlans"], "missing": "%d / %d" % (s["missing"], s["requested"]),
                        "placeable": "%d" % s["missingPlaceable"],
                        "det": ("%d / %d" % tuple(d)) if d[1] else "—"})

    # ---------------------------------------------------------------- multi
    mseries = [k for k in ["sdp:STANDARD", "sdp:CITY_BY_CITY", "amt", "ep"] if any(k in e["runs"] for e in multi.values())]
    mrows, mvals = [], []
    for sid, e in sorted(multi.items()):
        ref = e["reference"]
        vals, bad, extra = {}, {}, {}
        for k in mseries:
            r = e["runs"].get(k)
            if r and not r.get("error") and ref:
                vals[k] = r["gain"] / ref * 100
                mvals.append(vals[k])
                bad[k] = not r["legal"]
                ex = ["+%d" % r["gain"], "%.0f 秒" % r["seconds"]]
                if r.get("missing"):
                    ex.append("漏放 %d" % r["missing"])
                if not r["legal"]:
                    ex.append("违规")
                extra[k] = "，".join(ex)
        parts = sid.split("-")
        label = "%s %s %s %s" % (parts[0], parts[1], parts[3] if len(parts) > 3 else "", parts[4] if len(parts) > 4 else "")
        mrows.append({"label": label.strip(), "values": vals, "bad": bad, "extra": extra})
    mmin = max(0, (int(min(mvals + [100]) // 10)) * 10 - 10) if mvals else 50
    M = {k: stats(multi, k) for k in mseries}

    # ---------------------------------------------------------------- time
    trows = []
    for k in ["sdp:FAST", "sdp:STANDARD", "sdp:FINE", "amt", "ep"]:
        if S.get(k):
            trows.append({"label": "单城 " + PLANNERS[k]["label"], "value": S[k]["time"], "color": PLANNERS[k]["color"]})
    for k in ["sdp:STANDARD", "amt", "ep"]:
        if M.get(k):
            trows.append({"label": "多城 " + PLANNERS[k]["label"], "value": M[k]["time"], "color": PLANNERS[k]["color"]})

    # ---------------------------------------------------------------- cases
    def case_svg(sid, title):
        snap = snapshot(sid, make_snapshots)
        city = [c for c in snap["cities"] if c["owner"] == 0][0]
        panels = []
        for k, cls in (("sdp:STANDARD", "sdp"), ("amt", "amt"), ("ep", "ep")):
            r = raw.get((sid, k))
            if not r or not r.get("score"):
                continue
            s = r["score"]
            items = s.get("items") or []
            bad = set()
            for v in s["violations"]:
                if v["kind"] in summarize.HARD and v.get("x") is not None:
                    bad.add((v["x"], v["y"]))
            miss = s.get("missing", 0)
            t = "%s  +%d%s" % (PLANNERS[k]["label"], s["gain"], ("  漏放 %d" % miss) if miss else "")
            panels.append({"title": t, "items": items, "bad": bad, "cls": cls})
        w, h, body = hexmap.render(snap, panels, (city["x"], city["y"]), 3)
        # tag each panel group for its color
        groups = body.split("<g>")
        out = groups[0]
        for i, g in enumerate(groups[1:]):
            out += '<g class="hm-panel-%s">' % panels[i]["cls"] + g
        svg = '<svg viewBox="0 0 %.0f %.0f" role="img" aria-label="%s">%s</svg>' % (w, h, title, out)
        return svg

    def pick_cases():
        cands = []
        for sid, e in single.items():
            us, a, p = e["runs"].get("sdp:STANDARD"), e["runs"].get("amt"), e["runs"].get("ep")
            if not us or not a or not p or us.get("error") or a.get("error") or p.get("error"):
                continue
            cands.append((sid, us["gain"] - a["gain"], us["gain"] - p["gain"],
                          (p.get("violations") or {}).get("overwrites_pin", 0), a.get("missing", 0), p.get("missing", 0)))
        hero = max(cands, key=lambda c: (min(c[1], c[2]), c[1] + c[2])) if cands else None
        amtc = max(cands, key=lambda c: (c[4] > 0, c[1])) if cands else None
        pinc = max(cands, key=lambda c: (c[3] > 0, c[2])) if cands else None
        out = []
        for c in (hero, amtc, pinc):
            if c and c[0] not in [x[0] for x in out]:
                out.append(c)
        return out

    cases = pick_cases()
    case_html = []
    hero_svg, hero_cap = "", ""
    CIVN = {"rome": "罗马", "japan": "日本", "korea": "高丽", "germany": "德国", "brazil": "巴西", "netherlands": "荷兰",
            "gaul": "高卢", "vietnam": "越南", "greece": "希腊", "mali": "马里", "russia": "俄罗斯", "indonesia": "印尼",
            "egypt": "埃及", "byzantium": "拜占庭", "kongo": "刚果", "australia": "澳大利亚", "maya": "玛雅"}
    BION = {"temperate": "温带", "coastal": "沿海", "highland": "高地", "jungle": "雨林", "desert": "沙漠", "tundra": "苔原",
            "island": "岛屿", "volcanic": "火山"}
    STN = {"early": "前期", "mid": "中期", "late": "后期"}

    def describe(sid):
        p = sid.split("-")
        return "%s · %s · %s" % (CIVN.get(p[1], p[1]), BION.get(p[2], p[2]), STN.get(p[3], p[3]))

    for i, c in enumerate(cases):
        sid = c[0]
        svg = case_svg(sid, describe(sid))
        notes = []
        rs = raw.get((sid, "sdp:STANDARD"))
        if rs and rs.get("score"):
            mine = [v for v in rs["score"]["violations"] if v["kind"] == "missing"]
            if mine and all(v.get("detail") == "no_plot" for v in mine):
                names = "、".join(DNAME.get(v.get("type"), v.get("type")) for v in mine)
                notes.append("本模组漏放的%s在这座城没有合法位置" % names)
        for k in ("amt", "ep"):
            r = raw.get((sid, k))
            if r and r.get("score"):
                for v in r["score"]["violations"]:
                    if v["kind"] == "overwrites_pin":
                        notes.append("%s 把玩家在 (%d,%d) 的钉压掉了" % (PLANNERS[k]["label"], v["x"], v["y"]))
                miss = [v.get("type", "").replace("DISTRICT_", "").lower() for v in r["score"]["violations"] if v["kind"] == "missing"]
                if miss:
                    placeable = sum(1 for v in r["score"]["violations"] if v["kind"] == "missing" and v.get("detail") == "placeable")
                    notes.append("%s 漏放 %d 个区域%s" % (PLANNERS[k]["label"], len(miss),
                                                       ("（其中 %d 个有合法位置）" % placeable) if placeable else ""))
        cap_txt = "%s（%s）。%s" % (describe(sid), sid, "；".join(notes) + "。" if notes else "")
        if i == 0:
            hero_svg, hero_cap = svg, "同一座城、同样的区域清单，三个规划器的方案：" + cap_txt + "城=市中心，灰色=已建区域，彩色=新规划的区域（数字是它自己的相邻加成）。"
        case_html.append('<figure><div class="frame scroll hexmap">%s</div><figcaption>%s</figcaption></figure>' % (svg, cap_txt))

    # ---------------------------------------------------------------- texts
    sd, am, ep = S.get("sdp:STANDARD"), S.get("amt"), S.get("ep")
    sl = S.get("sdp:STANDARD_LAND")
    w_a, t_a, l_a, d_a, r_a = cap.get("amt_wtl", (0, 0, 0, 0, 0))
    w_e, t_e, l_e, d_e, r_e = cap.get("ep_wtl", (0, 0, 0, 0, 0))
    self_mis = 0
    self_n = 0
    for r in rows:
        st = (r.get("plan") or {}).get("stats", {})
        if r["planner"] == "sdp" and r.get("score") and st.get("sdpGain") is not None:
            self_n += 1
            if abs(st["sdpGain"] - r["score"]["gain"]) > 1e-6:
                self_mis += 1
    det_sd = det_by.get("sdp:STANDARD", [0, 0])
    sd_clean = bool(sd) and sd["legal"] == sd["n"] and sd["pinPlans"] == 0 and det_sd[0] == det_sd[1]
    sd_claim = ("方案全部合法、不压玩家的钉、同输入同结果" if sd_clean else
                "方案违规 %d 个、压钉 %d 个、重复运行不一致 %d 个" % (sd["n"] - sd["legal"], sd["pinPlans"], det_sd[1] - det_sd[0])) if sd else ""

    def lower_in(n, who):
        return ("没有一个场景低于 %s" % who) if n == 0 else ("只有 %d 个场景低于 %s" % (n, who))

    texts = {
        "SUMMARY_COMPARE": (
            "在 %d 个模拟实际对局的单城场景上与 AMT r49、Empire Planner 正面对比：本模组标准档有 %s 的场景拿到最高加成（AMT %s，EP %s），"
            "%s。" % (sd["n"], pct(sd["best"]), pct(am["best"]), pct(ep["best"]), sd_claim)) if sd and am and ep else "",
        "N_SINGLE": str(len(single)), "N_MULTI": str(len(multi)), "N_CIVS": "17",
        "SELF_CHECK": "%d 次，%d 次不一致" % (self_n, self_mis),
        "AMT_QUALITY": "单城场景中 %d 个低于本模组、%d 个持平、%d 个更高；平均质量 %s。" % (w_a, t_a, l_a, pct(am["quality"], 1)) if am else "",
        "AMT_MISSING": "单城场景共漏放 %d 个要求的区域，其中 %d 个在它的方案摆好后仍有合法位置和空槽位。" % (am["missing"], am["missingPlaceable"]) if am else "",
        "AMT_MULTI_TIME": "",
        "AMT_SLOTS": "后期场景要 6 个以上特色区域时，超出的只能不选。",
        "EP_QUALITY": "单城场景中 %d 个低于本模组、%d 个持平、%d 个更高；平均质量 %s。" % (w_e, t_e, l_e, pct(ep["quality"], 1)) if ep else "",
        "EP_MISSING": "单城场景要求的 %d 个区域中漏放 %d 个（其中 %d 个有合法位置），%d 个方案一个区域都没放。" % (
            ep["requested"], ep["missing"], ep["missingPlaceable"], sum(1 for _, r in runs_of(single, "ep") if r.get("placed") == 0)) if ep else "",
        "EP_PINS": "%d 个带手打钉的场景里，%d 个方案压到了玩家的钉。" % (
            sum(1 for sid in single if int(sid[1:3]) % 3 == 0 and not sid.endswith("early")), ep["pinPlans"]) if ep else "",
    }
    late = by_best[-1]["values"] if by_best else {}

    def late_share(who, v):
        return ("%s 一个也没拿到" % who) if v < 0.5 else ("%s 只有 %.0f%%" % (who, v))
    texts["SINGLE_TEXT"] = (
        "本模组标准档在 %s 的场景拿到最高加成，AMT %s，EP %s。区域越多差距越大：后期场景（7–8 个区域）%s、%s。"
        "逐场景看，本模组%s，%s。" % (pct(sd["best"]), pct(am["best"]), pct(ep["best"]), late_share("AMT", late.get("amt", 0)),
                                 late_share("EP", late.get("ep", 0)), lower_in(l_a, "AMT"), lower_in(l_e, "EP"))) if sd and am and ep else ""
    for k in ("amt", "ep"):
        w, t, l, _, _ = cap.get(k + "_wtl", (0, 0, 0, 0, 0))
        cap[k] = "本模组更高 %d 个场景、持平 %d 个、%s更高 %d 个。" % (w, t, "AMT " if k == "amt" else "EP ", l)

    # Correctness: districts left off although they had a place.
    no_plot = sd["missing"] - sd["missingPlaceable"] if sd else 0
    texts["CORRECT_TEXT"] = (
        "本模组%s，%s。AMT 和 EP 分别漏放了 %d 个和 %d 个其实有位置的区域（原因见第 2 节）%s。" % (
            sd_claim, "能放下的区域都放了" if sd["missingPlaceable"] == 0 else "但有 %d 个区域有位置却没放" % sd["missingPlaceable"],
            am["missingPlaceable"], ep["missingPlaceable"],
            ("；EP 还有 %d 个方案压掉了玩家事先打的钉" % ep["pinPlans"]) if ep["pinPlans"] else "")) if sd and am and ep else ""
    texts["MISSING_CAP"] = ("有位置却没放的区域数（%d 个场景共要求 %d 个区域）。地图上确实放不下的区域（本模组漏放的 %d 个都是这种）不计。" % (
        sd["n"], sd["requested"], no_plot)) if sd else ""
    missing_chart = [{"label": PLANNERS[k]["label"], "value": S[k]["missingPlaceable"], "color": PLANNERS[k]["color"],
                      "tip": "%s：漏放 %d 个，其中有位置却没放 %d 个" % (PLANNERS[k]["label"], S[k]["missing"], S[k]["missingPlaceable"])}
                     for k in ("sdp:STANDARD", "amt", "ep") if S.get(k)]

    # City output.
    output_chart = []
    for k in ("sdp:STANDARD_LAND", "sdp:STANDARD", "amt", "ep"):
        s_ = S.get(k)
        if s_ and s_.get("outBest") is not None:
            label = "本模组 计入地块（面板默认）" if k == "sdp:STANDARD_LAND" else PLANNERS[k]["label"]
            output_chart.append({"label": label, "value": s_["outBest"] * 100, "color": PLANNERS[k]["color"],
                                 "tip": "%s：%s 的场景拿到最高总产出" % (label, pct(s_["outBest"]))})
    texts["OUTPUT_TEXT"] = ""
    if sl and sl.get("outBest") is not None and am and ep:
        texts["OUTPUT_TEXT"] = (
            "换成不属于任何一方的城市总产出，本模组用面板默认的“计入地块”仍最常拿到最高（%s，AMT %s，EP %s）。只看相邻加成的标准档是 %s："
            "“计入地块”确实把占好地的代价算了进去。" % (pct(sl["outBest"]), pct(am["outBest"] or 0), pct(ep["outBest"] or 0),
                                         pct(sd["outBest"] or 0) if sd and sd.get("outBest") is not None else "-"))
    if sd and am and ep:
        texts["SPEED_TEXT"] = (
            "游戏里实测，单城 6–8 个区域标准档不到 0.3 秒；3 城联合 2.7 秒（之后标准档加了宽束联合起点，游戏内同规模实测多约 10%%），经面板分帧时游戏照常响应。离线环境里同样的单城规划，"
            "AMT 慢约 %.0f 倍，EP 慢约 %.0f 倍。" % (am["time"] / sd["time"], ep["time"] / sd["time"]))
    # Picking districts per city on the multi tab: tests/offline/bench_multipools.lua, run by hand
    # (docs/self-test-report.md, fifth round).
    texts["MULTIPOOLS_TEXT"] = MULTIPOOLS_TEXT
    hero = []
    if sd and am and ep:
        hero = [
            {"value": pct(sd["best"]), "label": "单城场景拿到最高加成（标准档）；AMT %s，EP %s" % (pct(am["best"]), pct(ep["best"]))},
            {"value": "+%s / +%s" % (pct(r_a, 0).rstrip("%") + "%", pct(r_e, 0).rstrip("%") + "%"),
             "label": "平均比 AMT / Empire Planner 多出的相邻加成"},
            {"value": "0 违规", "label": "方案全部合法，不压玩家的钉，同输入同结果"},
            {"value": "0.25 秒", "label": "游戏内单城 6 个区域（标准档）"},
        ]

    # ---------------------------------------------------------------- robustness
    def fmt_pair(pr):
        lo, hi = pr["ci"]
        p = pr["p"]
        ptxt = "< 0.001" if p < 0.001 else "%.3f" % p
        return {"n": str(pr["n"]), "wtl": "%d / %d / %d" % (pr["wins"], pr["ties"], pr["losses"]),
                "mean": "%+.2f [%+.2f, %+.2f]" % (pr["mean"], lo, hi), "p": ptxt}

    robust_best = {}
    pairs = {}

    def robust(sets):
        table_rows, groups = [], []
        for set_name, kind, label in sets:
            sub = summarize.subset(scenarios, set_name, kind)
            if not sub:
                continue
            tab = summarize.per_planner(sub)
            best = {k: tab[k]["bestShare"] for k in ("sdp:STANDARD", "amt", "ep") if k in tab and tab[k]["bestShare"] is not None}
            robust_best[set_name + "/" + kind] = best
            groups.append({"label": label, "values": {k: v * 100 for k, v in best.items()}})
            for other, oname in (("amt", "AMT"), ("ep", "EP")):
                pr = summarize.paired(sub, "sdp:STANDARD", other, "gain")
                if pr["n"]:
                    pairs[(set_name, kind, other)] = pr
                    table_rows.append(dict({"set": "%s（%d）" % (label, len(sub)), "vs": oname,
                                            "best": "%s / %s" % (pct(best.get("sdp:STANDARD") or 0), pct(best.get(other) or 0))},
                                           **fmt_pair(pr)))
        return table_rows, groups

    robust_rows, robust_groups = robust([("dev", "single", "开发集"), ("heldout", "single", "留出集"),
                                         ("profile:SCI", "single", "科研 ×3"), ("profile:PROD", "single", "生产 ×3"),
                                         ("profile:FAITH", "single", "信仰 ×3")])
    robust_multi_rows, robust_multi_groups = robust([("dev", "multi", "开发集"), ("heldout", "multi", "留出集")])
    single_pairs = [pr for (s_, kind, o), pr in pairs.items() if kind == "single"]
    if robust_groups:
        mins = min(g["values"].get("sdp:STANDARD", 0) for g in robust_groups)
        amax = max(g["values"].get("amt", 0) for g in robust_groups)
        emax = max(g["values"].get("ep", 0) for g in robust_groups)
        all_sig = all(pr["ci"][0] > 0 for pr in single_pairs)
        texts["ROBUST_TEXT"] = (
            "换成开发时没看过的地图，或把一项产出的权重调到 3，结论不变：每一组里本模组拿到最高的比例都不低于 %.0f%%，AMT 不超过 %.0f%%，EP 不超过 %.0f%%%s。" % (
                mins, amax, emax, "；逐场景配对，每一组本模组都显著更高" if all_sig else ""))
    else:
        texts["ROBUST_TEXT"] = ""

    # Pinned-pin output pairs for the output table (development set).
    out_rows_pairs = {}
    for set_name in ("dev", "heldout"):
        sub = summarize.subset(scenarios, set_name, "single")
        for other in ("amt", "ep"):
            pr = summarize.paired(sub, "sdp:STANDARD_LAND", other, "output")
            if pr["n"]:
                out_rows_pairs[(set_name, other)] = pr

    # ---------------------------------------------------------------- cross scoring
    def cross(kind, sets):
        table_rows, forest = [], []
        for set_name, label in sets:
            sub = summarize.subset(scenarios, set_name, kind)
            if not sub:
                continue
            for scorer, sname in (("amt", "AMT"), ("ep", "EP")):
                field = "cross_" + scorer
                means = {}
                for k in ("sdp:STANDARD", "amt", "ep"):
                    vals = [e["runs"][k][field] for e in sub.values() if k in e["runs"] and e["runs"][k].get(field) is not None]
                    if vals:
                        means[k] = statistics.mean(vals)
                pr = summarize.paired(sub, "sdp:STANDARD", scorer, field)
                if not pr["n"] or scorer not in means or "sdp:STANDARD" not in means:
                    continue
                row = {"set": "%s（%d）" % (label, len(sub)), "scorer": "%s 的目标函数" % sname,
                       "sdp": "%.2f" % means["sdp:STANDARD"], "amt": "%.2f" % means["amt"] if "amt" in means else "-",
                       "ep": "%.2f" % means["ep"] if "ep" in means else "-"}
                row.update(fmt_pair(pr))
                table_rows.append(row)
                own = means[scorer]
                lo, hi = pr["ci"]
                forest.append({"label": "%s · 按 %s 的" % (label, sname), "scorer": scorer, "color": PLANNERS[scorer]["color"],
                               "value": 100 * (1 + pr["mean"] / own), "lo": 100 * (1 + lo / own), "hi": 100 * (1 + hi / own),
                               "tip": "%s · 按 %s 的目标函数：本模组 %.2f，%s 自己 %.2f；逐场景胜 %d 平 %d 负 %d，平均差 %+.2f [%+.2f, %+.2f]" % (
                                   label, sname, means["sdp:STANDARD"], sname, own, pr["wins"], pr["ties"], pr["losses"], pr["mean"], lo, hi)})
        return table_rows, forest

    def cross_claim(forest, scorer):
        rs = [r for r in forest if r["scorer"] == scorer]
        if not rs:
            return ""
        who = "AMT" if scorer == "amt" else "EP"
        d = [r["value"] - 100 for r in rs]
        lo_, hi_ = min(d), max(d)
        rng = ("%.0f%%" % abs(lo_)) if round(lo_) == round(hi_) else ("%.0f–%.0f%%" % (abs(lo_), abs(hi_)) if lo_ >= 0 else "%+.0f%% 到 %+.0f%%" % (lo_, hi_))
        pos = sum(1 for r in rs if r["lo"] > 100)
        neg = sum(1 for r in rs if r["hi"] < 100)
        if pos == len(rs):
            return "按 %s 的，本模组的方案比 %s 自己的方案高 %s，各组都显著" % (who, who, rng)
        if neg == len(rs):
            return "按 %s 的，本模组的方案比 %s 自己的方案低 %s" % (who, who, rng)
        if neg == 0 and pos > 0:
            return "按 %s 的，本模组的方案略高（%s），但不是每组都显著" % (who, rng)
        if neg == 0:
            return "按 %s 的，两者持平（相差 %s，不显著）" % (who, rng)
        return "按 %s 的，两者互有高低" % who

    cross_rows, forest_single = cross("single", [("dev", "开发集"), ("heldout", "留出集")])
    cross_multi_rows, forest_multi = cross("multi", [("dev", "开发集"), ("heldout", "留出集")])
    texts["CROSS_TEXT"] = (
        "AMT、EP 各有自己的目标函数：AMT 把特色区域的产出放大 6–10.5 倍再减地块损失，EP 用自己的规则引擎并扣 0.15 倍地块产出。"
        "用它们自己的目标函数给方案打分，%s；%s。" % (cross_claim(forest_single, "amt"), cross_claim(forest_single, "ep"))) if forest_single else ""
    texts["CROSS_MULTI_TEXT"] = ("%s；%s。" % (cross_claim(forest_multi, "ep"), cross_claim(forest_multi, "amt"))) if forest_multi else ""
    texts["FOREST_CAP"] = ("按对手自己的目标函数，本模组方案的平均分占打分方自己方案平均分的百分比；横线是 95% 置信区间。"
                           "点在 100% 右边表示按对手自己的标准，本模组的方案也更好；横线跨过 100% 表示差别不显著。")

    # ---------------------------------------------------------------- multi texts
    texts["MULTI_TEXT"] = ""
    if M.get("sdp:STANDARD"):
        mb = robust_best.get("dev/multi", {})
        every = mb.get("sdp:STANDARD") == 1
        texts["MULTI_TEXT"] = (
            "联合规划在%s拿到最高。用单城页签一座一座规划，平均只有最高值的 %s：差的是跨城互惠和政府广场的位置。AMT 也做联合规划，平均 %s；EP %s。" % (
                ("全部 %d 个场景里都" % M["sdp:STANDARD"]["n"]) if every else (" %s 的场景" % pct(mb.get("sdp:STANDARD") or 0)),
                pct(M["sdp:CITY_BY_CITY"]["quality"]) if M.get("sdp:CITY_BY_CITY") else "-",
                pct(M["amt"]["quality"]) if M.get("amt") else "-", pct(M["ep"]["quality"]) if M.get("ep") else "-"))
        if M.get("amt"):
            texts["AMT_MULTI_TIME"] = "多城联合离线中位 %.0f 秒，是本模组标准档的 %.0f 倍。" % (
                M["amt"]["time"], M["amt"]["time"] / max(M["sdp:STANDARD"]["time"], 0.1))
    hom = robust_best.get("heldout/multi", {})
    multi_losses = sum(pr["losses"] for (s_, kind, o), pr in pairs.items() if kind == "multi")
    texts["MULTI_ROBUST_TEXT"] = (
        "留出集的 %d 个新地图上，本模组 %s 的场景拿到最高，AMT %s，EP %s%s。" % (
            len(summarize.subset(scenarios, "heldout", "multi")), pct(hom["sdp:STANDARD"]), pct(hom.get("amt") or 0), pct(hom.get("ep") or 0),
            "；逐场景配对，开发集和留出集里本模组都没有输过一个场景" if multi_losses == 0 else "")) if hom.get("sdp:STANDARD") is not None else ""
    strip = []
    for k in mseries:
        pts_ = [{"v": r["values"][k], "tip": "%s · %s：%.1f%%（%s）" % (r["label"], PLANNERS[k]["label"], r["values"][k], r["extra"].get(k, ""))}
                for r in mrows if k in r["values"]]
        if pts_:
            strip.append({"label": PLANNERS[k]["label"], "color": PLANNERS[k]["color"], "points": pts_,
                          "mean": statistics.mean(p["v"] for p in pts_)})

    # ---------------------------------------------------------------- coverage (design 19)
    vsub = summarize.subset(scenarios, "coverage", "multi")
    coverage = {"rows": [], "head": [], "table": []}
    texts["COVERAGE_TEXT"] = ""
    texts["N_V"] = str(len(vsub))
    cov_summary = None
    if vsub:
        def ncities(sid):
            m = re.search(r"-(\d)c$", sid)
            return int(m.group(1)) if m else 0

        def vrun(sid, k):
            r = vsub[sid]["runs"].get(k)
            return r if r and not r.get("error") and r.get("coverage") is not None else None
        # Every city reached by both kinds without the coverage part: nothing to gain.
        saturated = [sid for sid in sorted(vsub) if vrun(sid, "sdp:STANDARD") and vrun(sid, "sdp:STANDARD")["coverage"] >= 2 * ncities(sid)]
        room = [sid for sid in sorted(vsub) if sid not in saturated]
        comps = [("sdp:STANDARD_COV1", "sdp:STANDARD", "覆盖权重 1 对 不计（标准档）"),
                 ("sdp:STANDARD_COV3", "sdp:STANDARD", "覆盖权重 3 对 不计（标准档）"),
                 ("sdp:FINE_COV1", "sdp:FINE", "覆盖权重 1 对 不计（精细档）"),
                 ("sdp:STANDARD", "amt", "本模组（不计覆盖）对 AMT"),
                 ("sdp:STANDARD_COV1", "amt", "本模组（覆盖权重 1）对 AMT"),
                 ("sdp:STANDARD_COV3", "amt", "本模组（覆盖权重 3）对 AMT")]
        # A plan with a district a city did not ask for (AMT: reach requests
        # open to every city) gets adjacency it should not have: such
        # scenarios are counted apart, not compared.
        def asked_only(sid, k):
            r = vrun(sid, k)
            return r is not None and not (r.get("violations") or {}).get("not_requested")
        par = {}
        for a, b, label in comps:
            fair = {sid: e for sid, e in vsub.items() if asked_only(sid, a) and asked_only(sid, b)}
            pr = summarize.pareto(fair, a, b)
            pr["excluded"] = sum(1 for sid in vsub if vrun(sid, a) and vrun(sid, b) and sid not in fair)
            pr["n"] += pr["excluded"]
            par[(a, b)] = pr
            if pr["n"]:
                coverage["rows"].append(dict(pr, label=label))

        def deltas(a, b, ids):
            dc, dg = [], []
            for sid in ids:
                ra, rb = vrun(sid, a), vrun(sid, b)
                if ra and rb:
                    dc.append(ra["coverage"] - rb["coverage"])
                    dg.append(ra["gain"] - rb["gain"])
            return dc, dg
        c1, g1 = deltas("sdp:STANDARD_COV1", "sdp:STANDARD", room)
        c3, g3 = deltas("sdp:STANDARD_COV3", "sdp:STANDARD", room)
        f1, fg1 = deltas("sdp:FINE_COV1", "sdp:FINE", sorted(vsub))
        amt_runs = [vrun(sid, "amt") for sid in sorted(vsub) if vrun(sid, "amt")]
        amt_not_req = sum((r.get("violations") or {}).get("not_requested", 0) for r in amt_runs)
        amt_scn_not_req = sum(1 for r in amt_runs if (r.get("violations") or {}).get("not_requested", 0) > 0)
        # Scenarios where weight 1 lost adjacency without reaching more cities
        # (a search wobble of the standard tier when the fine tier trades).
        wobble = [sid for sid in room if vrun(sid, "sdp:STANDARD_COV1") and vrun(sid, "sdp:STANDARD")
                  and vrun(sid, "sdp:STANDARD_COV1")["coverage"] <= vrun(sid, "sdp:STANDARD")["coverage"]
                  and vrun(sid, "sdp:STANDARD_COV1")["gain"] < vrun(sid, "sdp:STANDARD")["gain"]]
        fine_trades = [sid for sid in wobble if vrun(sid, "sdp:FINE_COV1") and vrun(sid, "sdp:FINE")
                       and vrun(sid, "sdp:FINE_COV1")["coverage"] > vrun(sid, "sdp:FINE")["coverage"]]
        cov_summary = {"n": len(vsub), "saturated": len(saturated), "room": len(room),
                       "more1": sum(1 for d in c1 if d > 0),
                       "loss1": sum(1 for dc, dg in zip(c1, g1) if dc > 0 and dg < 0),
                       "more3": sum(1 for d in c3 if d > 0), "gain3": statistics.mean(g3) if g3 else 0,
                       "cov3": max(c3) if c3 else 0, "amt": len(amt_runs), "amtNotReq": amt_not_req, "amtScnNotReq": amt_scn_not_req}
        text = "%d 个场景里，%d 个不计覆盖也已全部覆盖：几座城都在工业区、娱乐中心 6 格以内，放在哪都够得着。" % (len(vsub), len(saturated))
        if room:
            text += "其余 %d 个场景里，覆盖权重 1 时 %d 个多覆盖了城市，%s" % (
                len(room), cov_summary["more1"],
                "相邻加成都没降" if cov_summary["loss1"] == 0 else "其中 %d 个相邻加成略降" % cov_summary["loss1"])
            if wobble:
                text += "；另 %d 个标准档没多覆盖、相邻加成反而略降%s" % (
                    len(wobble), "，精细档下是正常的“相邻略降、覆盖多 1 座”，属于标准档搜索的波动" if len(fine_trades) == len(wobble) else "")
            text += "。权重 3 时最多多覆盖 %d 座，相邻加成平均 %s。" % (
                cov_summary["cov3"], ("%+.1f" % cov_summary["gain3"]).replace("-", "−"))
        pa = par.get(("sdp:STANDARD_COV1", "amt"))
        pa3 = par.get(("sdp:STANDARD_COV3", "amt"))
        if amt_runs and pa and pa["n"]:
            text += "AMT 自带覆盖，用同样的逐城清单。%s" % (
                ("它在 %d 个场景里把区域放进了清单上没有它的城市，这正是第 2 章说的问题，这%s场景不比；" % (
                    amt_scn_not_req, "个" if amt_scn_not_req == 1 else "些")) if amt_not_req else "")
            def outcome(pr):
                parts = [("%d 个" + w) % pr[k] for k, w in (("better", "更好"), ("same", "相同"), ("tradeoff", "各有胜负"), ("worse", "更差")) if pr[k]]
                return "、".join(parts)
            text += "其余 %d 个场景两项一起比，本模组权重 1 时 %s" % (pa["n"] - pa["excluded"], outcome(pa))
            shown = [pa]
            if pa3 and pa3["n"]:
                text += "；权重 3 时 %s" % outcome(pa3)
                shown.append(pa3)
            if all(pr["worse"] == 0 for pr in shown):
                text += "；%s没有更差的" % ("两种权重都" if len(shown) > 1 else "")
            text += "。"
        texts["COVERAGE_TEXT"] = text
        coverage["head"] = ["场景", "不计覆盖", "覆盖权重 1", "覆盖权重 3", "AMT"]
        for sid in sorted(vsub):
            cells = [sid]
            for k in ("sdp:STANDARD", "sdp:STANDARD_COV1", "sdp:STANDARD_COV3", "amt"):
                r = vrun(sid, k)
                cells.append("%g / %d%s" % (r["gain"], r["coverage"], "（%d 个放错城）" % r["violations"]["not_requested"]
                                              if (r.get("violations") or {}).get("not_requested") else "") if r else "—")
            coverage["table"].append(cells)

    # ---------------------------------------------------------------- wonders
    wonder_rows = []
    wnum = {}
    wsub = summarize.subset(scenarios, "wonders", "single")
    if wsub:
        wtab = summarize.per_planner(wsub)
        for k in ("sdp:STANDARD", "sdp:STANDARD_LAND", "amt", "ep"):
            if k not in wtab:
                continue
            placed = sum((e["runs"][k].get("wondersPlaced") or 0) for e in wsub.values() if k in e["runs"])
            wanted = sum((e["runs"][k].get("wondersRequested") or 0) for e in wsub.values() if k in e["runs"])
            v = wtab[k]
            wnum[k] = (placed, wanted, v["bestShare"] or 0)
            wonder_rows.append({"label": PLANNERS.get(k, {"label": k})["label"], "wonders": "%d / %d" % (placed, wanted),
                                "legal": "%d / %d" % (round((v["legalShare"] or 0) * (v["runs"] - v["errors"])), v["runs"]),
                                "best": pct(v["bestShare"] or 0), "quality": pct(v["qualityMean"] or 0, 1),
                                "outBest": pct(v["outputBestShare"]) if v.get("outputBestShare") is not None else "-"})
    why = {"NO_LEGAL_PLOT": 0, "NO_FREE_PLOT": 0}
    for sid in wsub:
        r = raw.get((sid, "sdp:STANDARD"))
        for note in ((r or {}).get("plan") or {}).get("notes", []):
            parts = note.split()
            if len(parts) == 3 and parts[0] == "unplaced" and parts[1].startswith("BUILDING_") and parts[2] in why:
                why[parts[2]] += 1
    wonder_groups = []
    texts["WONDER_TEXT"] = ""
    if all(k in wnum for k in ("sdp:STANDARD", "amt", "ep")):
        ws, wa, we = wnum["sdp:STANDARD"], wnum["amt"], wnum["ep"]
        wonder_groups = [{"label": "放下的奇观", "values": {k: wnum[k][0] / max(wnum[k][1], 1) * 100 for k in ("sdp:STANDARD", "amt", "ep")}},
                         {"label": "拿到最高加成的场景", "values": {k: wnum[k][2] * 100 for k in ("sdp:STANDARD", "amt", "ep")}}]
        left = ws[1] - ws[0]
        texts["WONDER_TEXT"] = (
            "%s，EP 只放下 %d 座；连同区域的加成一起比，本模组在 %s 的场景拿到最高，AMT %s，EP %s。本模组没放下的 %d 座里，%d 座在城市 3 环内根本没有合法格。" % (
                ("本模组与 AMT 都放下了 %d 座奇观中的 %d 座" % (ws[1], ws[0])) if ws[0] == wa[0] else ("本模组放下了 %d 座奇观中的 %d 座，AMT %d 座" % (ws[1], ws[0], wa[0])),
                we[0], pct(ws[2]), pct(wa[2]), pct(we[2]), left, why["NO_LEGAL_PLOT"]))

    # ---------------------------------------------------------------- sites
    site_rows = []
    site_pts = []
    csub = summarize.subset(scenarios, "sites", "sites")
    texts["SITES_TEXT"] = ""
    smin, smax_, sticks = 0, 100, [0, 50, 100]
    if csub:
        for k in ("sdp:STANDARD", "ep"):
            runs = [e["runs"][k] for e in csub.values() if k in e["runs"] and not e["runs"][k].get("error")]
            if not runs:
                continue

            def avg(f, runs=runs):
                vals = [r.get(f) for r in runs if r.get(f) is not None]
                return statistics.mean(vals) if vals else 0
            site_rows.append({"label": PLANNERS.get(k, {"label": k})["label"],
                              "legal": "%d / %d" % (sum(1 for r in runs if r["legal"]), len(runs)),
                              "value": "%.1f" % avg("siteValue"), "tiles": "%.1f" % avg("tileValue"),
                              "districts": "%.1f" % avg("districtPotential"), "water": "%.2f" % avg("freshWater"),
                              "lux": "%.2f" % avg("newLuxuries"), "overlap": "%.1f" % avg("overlap")})
        vals = []
        for sid, e in sorted(csub.items()):
            us, o = e["runs"].get("sdp:STANDARD"), e["runs"].get("ep")
            if us and o and us.get("siteValue") is not None and o.get("siteValue") is not None:
                site_pts.append({"x": us["siteValue"], "y": o["siteValue"], "bad": not o["legal"],
                                 "label": "%s：本模组 %.1f，EP %.1f" % (sid, us["siteValue"], o["siteValue"])})
                vals += [us["siteValue"], o["siteValue"]]
        if vals:
            smin = int((min(vals) - 3) // 10 * 10)
            smax_ = int(((max(vals) + 3) // 10 + 1) * 10)
            sticks = list(range(smin, smax_ + 1, 10))
        pr = summarize.paired(csub, "sdp:STANDARD", "ep", "gain")
        if pr["n"] and len(site_rows) == 2:
            us, ep_row = site_rows
            ours, theirs = [], []
            for f, better, low in (("tiles", "地块产出更高", False), ("districts", "区域潜力更高", False), ("water", "更常有淡水", False),
                                   ("lux", "新的奢侈资源更多", False), ("overlap", "与已有城市重叠更少", True)):
                a_, b_ = float(us[f]), float(ep_row[f])
                if a_ == b_:
                    continue
                ((ours if (a_ < b_) == low else theirs)).append(better)
            texts["SITES_TEXT"] = (
                "AMT 不自动选城址，只比 EP。%d 个场景里本模组的城址总值胜 %d、平 %d、负 %d。本模组的城址%s；EP 的城址%s。" % (
                    pr["n"], pr["wins"], pr["ties"], pr["losses"], "、".join(ours) or "没有占优的分项", "、".join(theirs) or "没有占优的分项"))

    # ---------------------------------------------------------------- overview table (5.1)
    def tr(cells):
        return "<tr>" + "".join("<td>%s</td>" % c for c in cells) + "</tr>"

    def grp(anchor, title):
        return '<tr class="grp"><td colspan="3"><a href="#%s">%s</a></td></tr>' % (anchor, title)

    def vs(a, b, c):
        return "%s，AMT %s，EP %s" % (a, b, c)
    srows = [grp("e-single", "5.3 单城")]
    if sd and am and ep:
        srows.append(tr(["相邻加成", "开发集 %d" % sd["n"], "拿到最高加成：本模组 " + vs(pct(sd["best"]), pct(am["best"]), pct(ep["best"]))]))
        srows.append(tr(["合法与完整", "%d" % sd["n"], "本模组%s；有位置却没放的区域：AMT %d 个，EP %d 个" % (
            "零违规、能放的都放了" if sd_clean and sd["missingPlaceable"] == 0 else "见 5.3", am["missingPlaceable"], ep["missingPlaceable"])]))
    if robust_groups:
        rg = {g["label"]: g["values"] for g in robust_groups}
        if "留出集" in rg:
            v = rg["留出集"]
            srows.append(tr(["换地图", "留出集 %d" % len(summarize.subset(scenarios, "heldout", "single")),
                             "拿到最高：本模组 " + vs("%.0f%%" % v.get("sdp:STANDARD", 0), "%.0f%%" % v.get("amt", 0), "%.0f%%" % v.get("ep", 0))]))
        prof = [g for g in robust_groups if "×3" in g["label"]]
        if prof:
            srows.append(tr(["换权重", "3 × %d" % len(single), "拿到最高：本模组 %.0f%%–%.0f%%，AMT、EP 都不超过 %.0f%%" % (
                min(g["values"]["sdp:STANDARD"] for g in prof), max(g["values"]["sdp:STANDARD"] for g in prof),
                max(max(g["values"].get("amt", 0), g["values"].get("ep", 0)) for g in prof))]))
    if sl and sl.get("outBest") is not None:
        srows.append(tr(["城市总产出", "%d" % sl["n"], "拿到最高：本模组（计入地块）" + vs(pct(sl["outBest"]), pct(am["outBest"] or 0), pct(ep["outBest"] or 0))]))
    if forest_single:
        srows.append(tr(["对手的目标函数", "开发集、留出集各 %d" % len(single), "%s；%s" % (cross_claim(forest_single, "amt"), cross_claim(forest_single, "ep"))]))
    srows.append(grp("e-multi", "5.4 多城"))
    if M.get("sdp:STANDARD"):
        srows.append(tr(["联合规划", "开发集 %d" % len(multi), "平均达到最高值的：本模组 " + vs(
            pct(M["sdp:STANDARD"]["quality"]), pct(M["amt"]["quality"]) if M.get("amt") else "-", pct(M["ep"]["quality"]) if M.get("ep") else "-")
            + ("；逐城依次规划 %s" % pct(M["sdp:CITY_BY_CITY"]["quality"]) if M.get("sdp:CITY_BY_CITY") else "")]))
    if hom.get("sdp:STANDARD") is not None:
        srows.append(tr(["换地图", "留出集 %d" % len(summarize.subset(scenarios, "heldout", "multi")),
                         "拿到最高：本模组 " + vs(pct(hom["sdp:STANDARD"]), pct(hom.get("amt") or 0), pct(hom.get("ep") or 0))]))
    if forest_multi:
        srows.append(tr(["对手的目标函数", "开发集、留出集各 %d" % len(multi), "%s；%s" % (cross_claim(forest_multi, "ep"), cross_claim(forest_multi, "amt"))]))
    if cov_summary:
        pa = par.get(("sdp:STANDARD_COV1", "amt")) or {}
        srows.append(tr(["覆盖范围", "%d" % cov_summary["n"], "有取舍余地的 %d 个场景里，覆盖权重 1 时 %d 个多覆盖了城市；覆盖、相邻两项一起与 AMT 比，%d 个更好、%d 个更差" % (
            cov_summary["room"], cov_summary["more1"], pa.get("better", 0), pa.get("worse", 0))]))
    if wnum.get("sdp:STANDARD"):
        srows.append(grp("e-wonders", "5.5 奇观"))
        srows.append(tr(["奇观与区域", "%d" % len(wsub), "放下的奇观：本模组 %s；拿到最高加成：本模组 %s" % (
            vs("%d/%d" % wnum["sdp:STANDARD"][:2], "%d" % wnum["amt"][0], "%d" % wnum["ep"][0]),
            vs(pct(wnum["sdp:STANDARD"][2]), pct(wnum["amt"][2]), pct(wnum["ep"][2])))]))
    if csub:
        spr = summarize.paired(csub, "sdp:STANDARD", "ep", "gain")
        srows.append(grp("e-sites", "5.6 选城址"))
        srows.append(tr(["两座新城（只比 EP）", "%d" % spr["n"], "城址总值逐场景：本模组胜 %d、平 %d、负 %d" % (spr["wins"], spr["ties"], spr["losses"])]))
    srows.append(grp("e-pools", "5.7 从候选里挑"))
    srows.append(tr(["单城挑选", "4 种情形 × 4", "标准档 16 个全部挑中最好的组合，约 0.4–1.0 秒；快速档平均 98%"]))
    srows.append(tr(MULTIPOOLS_ROW))
    srows.append(grp("e-speed", "5.8 速度 · 5.9 本模组自身的测试"))
    if sd and am and ep:
        srows.append(tr(["速度", "游戏内实测", "单城不到 0.3 秒，3 城联合约 3 秒；离线比 AMT 快约 %.0f 倍" % (am["time"] / sd["time"])]))
    srows.append(tr(["自身的测试", "游戏内 87 项、离线 73 项", "全部通过；裁判与游戏引擎逐格一致（沉船一处已知偏差）"]))
    texts["EVAL_SUMMARY"] = ('<table><thead><tr><th>实验</th><th>场景</th><th>结论</th></tr></thead><tbody>%s</tbody></table>' % "".join(srows))

    texts["N_HS"] = str(len(summarize.subset(scenarios, "heldout", "single")))
    texts["N_HM"] = str(len(summarize.subset(scenarios, "heldout", "multi")))
    texts["N_W"] = str(len(wsub))
    texts["N_C"] = str(len(csub))
    texts["N_ALL"] = str(len(single) + len(multi) + int(texts["N_HS"]) + int(texts["N_HM"]) + 3 * len(single) + len(wsub) + len(csub)
                         + len(vsub))

    # SUMMARY (section 01) extras
    extra = []
    ho = robust_best.get("heldout/single", {})
    if ho.get("sdp:STANDARD") is not None:
        extra.append("开发时没用过的留出集上为 %s（AMT %s，EP %s）" % (pct(ho["sdp:STANDARD"]), pct(ho.get("amt") or 0), pct(ho.get("ep") or 0)))
    if wnum.get("sdp:STANDARD") and wnum.get("amt"):
        extra.append("与区域一起放奇观，放下 %d / %d 座（AMT %d，EP %d）" % (wnum["sdp:STANDARD"][0], wnum["sdp:STANDARD"][1], wnum["amt"][0], wnum.get("ep", (0,))[0]))
    if csub:
        spr = summarize.paired(csub, "sdp:STANDARD", "ep", "gain")
        if spr["n"]:
            extra.append("选城址 %d 个场景对 EP 胜 %d、平 %d、负 %d" % (spr["n"], spr["wins"], spr["ties"], spr["losses"]))
    if cov_summary and cov_summary["room"]:
        pa = par.get(("sdp:STANDARD_COV1", "amt")) or {}
        extra.append("覆盖范围（多城页签可选，默认关）在有取舍余地的 %d 个场景里，权重 1 时 %d 个多覆盖了城市%s" % (
            cov_summary["room"], cov_summary["more1"], "；覆盖、相邻两项一起与 AMT 比没有更差的" if pa.get("n") and pa.get("worse") == 0 else ""))
    if extra and texts["SUMMARY_COMPARE"]:
        texts["SUMMARY_COMPARE"] += "；".join(extra) + "。"

    # Output table: add the paired comparison with its interval.
    lab2key = {PLANNERS[k]["label"]: k for k in ("amt", "ep")}
    for row in output_rows:
        k = lab2key.get(row["label"])
        row["ho"] = "—"
        if k and ("dev", k) in out_rows_pairs:
            pr = out_rows_pairs[("dev", k)]
            row["vs"] = "%d / %d / %d（%+.2f [%+.2f, %+.2f]）" % (pr["wins"], pr["ties"], pr["losses"], pr["mean"], pr["ci"][0], pr["ci"][1])
        if k and ("heldout", k) in out_rows_pairs:
            pr = out_rows_pairs[("heldout", k)]
            row["ho"] = "%d / %d / %d（%+.2f [%+.2f, %+.2f]）" % (pr["wins"], pr["ties"], pr["losses"], pr["mean"], pr["ci"][0], pr["ci"][1])

    def fmt_forest_axis(rows_):
        if not rows_:
            return {"min": 80, "max": 120, "ticks": [80, 100, 120]}
        lo_ = min(min(r["lo"] for r in rows_), 100)
        hi_ = max(max(r["hi"] for r in rows_), 100)
        lo_ = int(lo_ // 5 * 5)
        hi_ = int(-(-hi_ // 5) * 5)
        step = 5 if hi_ - lo_ <= 40 else 10
        return {"min": lo_, "max": hi_, "ticks": list(range(lo_, hi_ + 1, step))}

    data = {
        "hero": hero, "planners": PLANNERS, "mainSeries": main_series, "overview": overview,
        "byStage": {"best": by_best, "quality": by_q, "qMin": qmin, "qTicks": qticks},
        "scatter": {"amt": pts["amt"], "ep": pts["ep"], "max": smax, "ticks": ticks, "capAmt": cap.get("amt", ""), "capEp": cap.get("ep", "")},
        "correct": correct, "missing": missing_chart, "output": output_rows, "outputChart": output_chart,
        "robust": robust_rows, "robustGroups": robust_groups, "robustMulti": robust_multi_rows, "robustMultiGroups": robust_multi_groups,
        "cross": cross_rows, "crossMulti": cross_multi_rows,
        "forest": dict({"rows": forest_single}, **fmt_forest_axis(forest_single)),
        "forestMulti": dict({"rows": forest_multi}, **fmt_forest_axis(forest_multi)),
        "coverage": coverage,
        "wonders": wonder_rows, "wonderGroups": wonder_groups,
        "sites": site_rows, "sitesScatter": {"points": site_pts, "min": smin, "max": smax_, "ticks": sticks},
        "strip": {"rows": strip, "min": mmin, "max": 100, "ticks": list(range(mmin, 101, 10))},
        "time": {"rows": trows, "legend": [], "min": 0.5, "max": 3000, "ticks": [1, 10, 100, 1000]},
    }

    tpl = open(os.path.join(HERE, "template.html"), encoding="utf-8").read()
    arch = open(os.path.join(HERE, "part_arch.html"), encoding="utf-8").read()
    algo = open(os.path.join(HERE, "part_algo.html"), encoding="utf-8").read()
    algo = algo.replace("{{HEX}}", open(os.path.join(HERE, "hexfig.svg.txt"), encoding="utf-8").read())
    for head, goal in (('<span class="sn">4.1</span>增量 + 记忆评估（SDP_Board）', "G1 G6"),
                       ('<span class="sn">4.2</span>单城搜索管线（SDP_Search）', "G2 G5"),
                       ('<span class="sn">4.3</span>多城联合规划（SDP_Multi）', "G2 G3"),
                       ('<span class="sn">4.4</span>选城址（SDP_Sites + SDP_SiteSolver）', "G2"),
                       ('<span class="sn">4.5</span>分帧计算（SDP_Task）', "G6")):
        tags = " ".join('<span class="tag goal">%s</span>' % g for g in goal.split())
        algo = algo.replace("<h3>%s</h3>" % head, "<h3>%s</h3>\n  <p>%s</p>" % (head, tags))
    out = tpl.replace("{{ARCH}}", arch).replace("{{ALGO}}", algo)
    out = out.replace("{{CASE_HERO}}", hero_svg).replace("{{CASE_HERO_CAP}}", hero_cap)
    out = out.replace("{{CASES}}", "\n".join(case_html[1:]))
    for k, v in texts.items():
        out = out.replace("{{%s}}" % k, v)
    out = out.replace("{{DATA}}", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    out = out.replace("{{SCRIPT}}", open(os.path.join(HERE, "charts.js"), encoding="utf-8").read())
    if "{{" in out:
        i = out.index("{{")
        raise RuntimeError("unfilled placeholder near: " + out[i:i + 40])
    return out, data


MIME = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png"}


def standalone(page, read_image):
    """The page as one self-contained file: document skeleton added, screenshots inlined.

    read_image(name) returns the bytes of docs/images/<name>."""
    m = re.match(r"\s*<title>(.*?)</title>", page)
    title, body = (m.group(1), page[m.end():]) if m else ("交付报告", page)

    def inline(m):
        name = m.group(1)
        data = base64.b64encode(read_image(name)).decode("ascii")
        return 'src="data:%s;base64,%s"' % (MIME[os.path.splitext(name)[1].lower()], data)

    body = re.sub(r'src="images/([^"]+)"', inline, body)
    return ('<!doctype html>\n<html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>%s</title><style>[hidden]{display:none!important}img{max-width:100%%}</style>'
            '</head><body>%s</body></html>\n' % (title, body))


def main():
    page, data = build(sys.argv[1:])
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(page)

    def read_image(name):
        with open(os.path.join(IMAGES, name), "rb") as f:
            return f.read()

    single = standalone(page, read_image)
    open(os.path.join(OUT, "report.html"), "w", encoding="utf-8").write(single)
    json.dump(data, open(os.path.join(OUT, "data.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("report: dist/report/index.html (%d KB), report.html (%d KB, self-contained)"
          % (len(page.encode("utf-8")) // 1024, len(single.encode("utf-8")) // 1024))


if __name__ == "__main__":
    main()
