"""Build the mod's page (introduction and evaluation) from the comparison results.

    python3 -I report/build.py [RESULTS.jsonl ...] [--version V] [--date D] [--site DIR]

RESULTS default to RESULTS below. The version defaults to the commit, the
date to the commit's date; a version that is a release tag (v...) links the
download button to that release, anything else to the latest release.
Writes to dist/report/:

  index.html    the page without the document skeleton (as published as an
                artifact); screenshots are referenced as images/<name>
  report.html   the same page as one self-contained file (screenshots inlined),
                to open from disk; tools/package.py puts it in the test package
  en/index.html, report_en.html
                the English page, appendices included (template_en.html,
                part_arch_en.html, part_algo_en.html, hexfig_en.svg.txt),
                from the same data

--site DIR also writes the pages for GitHub Pages: DIR/index.html and
DIR/en/index.html with the screenshots they use in DIR/images/ and
DIR/en/images/ (.github/workflows/release.yml).

Case-study maps come from `node tools/compare.mjs --snapshot ID`, cached in
report/snaps/ (commit new snapshots: the package build does not make them).
"""
import base64
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
IMAGES = os.path.join(REPO, "docs", "images")
REPO_URL = "https://github.com/SmallSpider0/civ6-smart-district-planner"
WORKSHOP_URL = "https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635"
OUT = os.path.join(REPO, "dist", "report")
sys.path.insert(0, os.path.join(REPO, "tests", "compare"))
sys.path.insert(0, HERE)
import summarize  # noqa: E402
import hexmap  # noqa: E402

# Everything the report reads, so tools/package.py can refuse uncommitted changes to it.
INPUTS = ["report", "tests/compare/results", "tests/compare/summarize.py", "docs/images", "tests/stress/results"]
STRESS = os.path.join(REPO, "tests", "stress", "results")
# The late-game stress scenarios (tools/stress.py SCENARIOS), in report order.
STRESS_ORDER = ["pangaea-gs", "continents-gs", "islands-rf"]
STRESS_RULES = {"RULESET_EXPANSION_2": "风云变幻", "RULESET_EXPANSION_1": "迭起兴衰", "RULESET_STANDARD": "原版"}
STRESS_MAPS = {"Pangaea.lua": "盘古大陆", "Continents.lua": "大陆", "Island_Plates.lua": "群岛"}
STRESS_SIZES = {"MAPSIZE_STANDARD": "标准", "MAPSIZE_LARGE": "大", "MAPSIZE_SMALL": "小", "MAPSIZE_HUGE": "巨型"}
STRESS_LEADERS = {"LEADER_HOJO": "北条时宗（日本）", "LEADER_WILHELMINA": "威廉明娜（荷兰）", "LEADER_PERICLES": "伯里克利（希腊）"}
STRESS_ERAS = {"ERA_ANCIENT": "远古", "ERA_CLASSICAL": "古典", "ERA_MEDIEVAL": "中世纪"}
# The same names in English, as the game's English text has them.
STRESS_RULES_EN = {"RULESET_EXPANSION_2": "Gathering Storm", "RULESET_EXPANSION_1": "Rise and Fall", "RULESET_STANDARD": "Base game"}
STRESS_MAPS_EN = {"Pangaea.lua": "Pangaea", "Continents.lua": "Continents", "Island_Plates.lua": "Island Plates"}
STRESS_SIZES_EN = {"MAPSIZE_STANDARD": "Standard", "MAPSIZE_LARGE": "Large", "MAPSIZE_SMALL": "Small", "MAPSIZE_HUGE": "Huge"}
STRESS_LEADERS_EN = {"LEADER_HOJO": "Hojo Tokimune (Japan)", "LEADER_WILHELMINA": "Wilhelmina (Netherlands)",
                     "LEADER_PERICLES": "Pericles (Greece)"}
STRESS_ERAS_EN = {"ERA_ANCIENT": "Ancient Era", "ERA_CLASSICAL": "Classical Era", "ERA_MEDIEVAL": "Medieval Era"}
RESULTS = ["tests/compare/results/" + f + ".jsonl" for f in (
    "full_rejudged", "land", "full_cross", "heldout", "heldout_cross",
    "profiles_SCI", "profiles_PROD", "profiles_FAITH", "sites",
    "wonders_sdp_ep", "wonders_amt", "wonders_cross", "wonders_sdp_repair", "wonders_v120",
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
DNAME = {"DISTRICT_AQUEDUCT": "水渠", "DISTRICT_DAM": "堤坝", "DISTRICT_HARBOR": "港口", "DISTRICT_SEOWON": "书院",
         "DISTRICT_CANAL": "运河", "DISTRICT_GOVERNMENT": "市政广场"}
STAGES = [("early", "前期 · 2 个区域"), ("mid", "中期 · 4–5 个"), ("late", "后期 · 7–8 个")]
PAGES_URL = "https://smallspider0.github.io/civ6-smart-district-planner/"

# The English page (issue 5): the whole page, appendices included, in English.
# Names and labels it uses; the numbers come from the same data.
PLANNERS_EN = {
    "sdp:FAST": "This mod, Fast", "sdp:STANDARD": "This mod, Standard", "sdp:FINE": "This mod, Thorough",
    "sdp:STANDARD_LAND": "This mod, Standard + Land loss (panel default)", "sdp:CITY_BY_CITY": "This mod, city by city",
    "amt": "AMT r49", "amt:DEFAULTW": "AMT (default weights)", "ep": "Empire Planner", "ep:DEFAULT": "EP (default weights)",
}
# Short labels for the time chart: the tiers are this mod's.
SHORT_EN = {"sdp:FAST": "Fast", "sdp:STANDARD": "Standard", "sdp:FINE": "Thorough", "amt": "AMT", "ep": "EP"}
DNAME_EN = {"DISTRICT_AQUEDUCT": "Aqueduct", "DISTRICT_DAM": "Dam", "DISTRICT_HARBOR": "Harbor", "DISTRICT_SEOWON": "Seowon",
            "DISTRICT_CANAL": "Canal", "DISTRICT_GOVERNMENT": "Government Plaza"}
STAGES_EN = [("early", "Early · 2 districts"), ("mid", "Middle · 4–5"), ("late", "Late · 7–8")]
CIVN_EN = {"rome": "Rome", "japan": "Japan", "korea": "Korea", "germany": "Germany", "brazil": "Brazil",
           "netherlands": "Netherlands", "gaul": "Gaul", "vietnam": "Vietnam", "greece": "Greece", "mali": "Mali",
           "russia": "Russia", "indonesia": "Indonesia", "egypt": "Egypt", "byzantium": "Byzantium", "kongo": "Kongo",
           "australia": "Australia", "maya": "Maya"}
BION_EN = {"temperate": "temperate", "coastal": "coastal", "highland": "highland", "jungle": "rainforest", "desert": "desert",
           "tundra": "tundra", "island": "island", "volcanic": "volcanic"}
STN_EN = {"early": "early game", "mid": "mid game", "late": "late game"}
MULTIPOOLS_ROW_EN = ["Several cities", "3", "Standard and Thorough reach the reference in all 3, better than picking "
                     "city by city and then planning together (96%–100%)"]


def pct(v, digits=0):
    return ("%." + str(digits) + "f%%") % (v * 100)


def snapshot(sid, make):
    path = os.path.join(HERE, "snaps", sid + ".json")
    if not os.path.exists(path):
        if not make:
            raise RuntimeError("report/snaps/%s.json is missing: run report/build.py and commit it" % sid)
        out = subprocess.run(["node", "tools/compare.mjs", "--snapshot", sid], cwd=REPO,
                             capture_output=True, encoding="utf-8", check=True)
        open(path, "w", encoding="utf-8").write(out.stdout)
    return json.load(open(path, encoding="utf-8"))


MULTIPOOLS_TEXT = (
    "多城另有一组基准（<code>tests/offline/bench_multipools.lua</code>）：首都加 3 个城址钉，每座城学院必建、再从 5 个候选里挑 2 个，3 个种子；"
    "参照是各档、精细档加两次继续优化、“先逐城挑再联合规划”（每座城单独用单城精细档挑组合，再一起规划）中最好的值。"
    "标准档、精细档 3 个种子都达到参照，按单价折算约 3.1 秒、7.1 秒，分帧计算；快速档平均 97.6%，约 0.5 秒。"
    "“先逐城挑”为 96%、97%、100%。标准档起初在一个种子上只有 93%：它挑的组合与精细档相同，差在多城的摆放搜索，"
    "加了宽束联合起点（A.3）后达到参照。")
MULTIPOOLS_ROW = ["多城挑选", "3", "标准档、精细档 3 个都达到参照，比“先逐城挑再联合规划”（96%–100%）好"]
MULTIPOOLS_TEXT_EN = (
    "Several cities have a benchmark of their own (<code>tests/offline/bench_multipools.lua</code>): the capital and 3 site "
    "tacks, a Campus as a Must in every city and 2 more picked from a pool of 5, 3 seeds. The reference is the best of the "
    "effort levels, Thorough with two rounds of Improve, and “pick city by city, then plan together” (each city picks its "
    "combination alone on the One city tab at Thorough, then the cities are planned together). Standard and Thorough reach "
    "the reference on all 3 seeds, about 3.1 s and 7.1 s at the measured unit cost, computed over several frames; Fast "
    "reaches 97.6% on average in about 0.5 s. “Pick city by city” reaches 96%, 97% and 100%. At first Standard reached only "
    "93% on one seed: it picked the same combination as Thorough and fell short in the search over the cities' layout; with "
    "the wide joint start (A.3) it reaches the reference.")

# Words the charts (charts.js) show, by language.
CHART_WORDS = {
    "zh": {
        "colon": "：", "mean": "平均 ", "sec": " 秒", "medianTip": "{0}：中位 {1} 秒（离线）",
        "outcomeTip": "{0}：{1} {2} 个场景（共 {3} 个）",
        "scatterX": "本模组标准档的加成", "scatterAmtY": "AMT r49 的加成", "scatterEpY": "Empire Planner 的加成",
        "sitesX": "本模组的城址总值", "sitesY": "EP 的城址总值",
        "headOverview": ["规划器", "达到最高", "平均质量", "最差", "合法方案", "漏放区域", "中位耗时（离线）"],
        "headCorrect": ["规划器", "违规方案", "压掉玩家的钉", "漏放区域", "其中有位置却没放", "同输入两次一致"],
        "headPair": ["场景集", "对手", "拿到最高 本模组 / 对手", "本模组 胜 / 平 / 负", "平均差 [95% 区间]", "p"],
        "headCross": ["场景集", "打分用", "本模组", "AMT", "EP", "本模组 vs 打分方 胜 / 平 / 负", "平均差 [95% 区间]", "p"],
        "headWonders": ["规划器", "奇观放下", "合法方案", "达到最高加成", "平均质量", "总产出最高"],
        "headSites": ["规划器", "合法方案", "城址总值", "地块产出", "区域潜力", "淡水城址", "新奢侈种类", "重叠格"],
        "headOutput": ["规划器", "拿到最高", "本模组（计入地块）高 / 平 / 低：开发集", "留出集"],
        "byAmt": "按 AMT 的目标函数", "byEp": "按 EP 的目标函数",
        "better": "没有一项更差、至少一项更好", "same": "两项都相同", "tradeoff": "一项更好、一项更差",
        "worse": "没有一项更好、至少一项更差", "excluded": "对手放了清单外的区域，不比",
        "ariaBest": "按阶段达到最高加成的场景比例", "ariaQuality": "按阶段的平均质量",
        "ariaScatterAmt": "本模组与 AMT 的逐场景加成对比", "ariaScatterEp": "本模组与 Empire Planner 的逐场景加成对比",
        "ariaMissing": "各规划器有位置却没放的区域数", "ariaRobust": "各场景集拿到最高加成的比例",
        "ariaMRobust": "多城开发集与留出集拿到最高加成的比例",
        "ariaForest": "单城：按对手自己的目标函数，本模组方案得分占对手自己方案得分的百分比",
        "ariaForestMulti": "多城：按对手自己的目标函数，本模组方案得分占对手自己方案得分的百分比",
        "ariaWonders": "奇观放下的比例与拿到最高加成的比例", "ariaSites": "本模组与 EP 的逐场景城址总值",
        "ariaOutput": "拿到最高城市总产出的场景比例", "ariaStrip": "多城场景各规划器的加成占该场景最高值的百分比",
        "ariaCoverage": "覆盖范围场景：覆盖城数与相邻加成两项一起比较的结果", "ariaTime": "离线中位耗时对比",
    },
    "en": {
        "colon": ": ", "mean": "mean ", "sec": " s", "medianTip": "{0}: median {1} s (offline)",
        "outcomeTip": "{0}: {1}, {2} of {3} scenarios",
        "scatterX": "This mod's adjacency (Standard)", "scatterAmtY": "AMT r49's adjacency", "scatterEpY": "Empire Planner's adjacency",
        "sitesX": "This mod's site value", "sitesY": "EP's site value",
        "headOverview": ["Planner", "Highest", "Mean quality", "Worst", "Valid plans", "Left out", "Median time, offline"],
        "headCorrect": ["Planner", "Plans not valid", "Player's tacks overwritten", "Districts left out", "Of them with a valid tile",
                        "Same plan twice"],
        "headPair": ["Set", "Rival", "Highest: this mod / rival", "This mod wins / ties / losses", "Mean difference [95% CI]", "p"],
        "headCross": ["Set", "Scored by", "This mod", "AMT", "EP", "This mod vs scorer: wins / ties / losses",
                      "Mean difference [95% CI]", "p"],
        "headWonders": ["Planner", "Wonders placed", "Valid plans", "Highest adjacency", "Mean quality", "Highest output"],
        "headSites": ["Planner", "Valid plans", "Site value", "Tile yields", "District potential", "Fresh Water sites",
                      "New luxury kinds", "Overlapping tiles"],
        "headOutput": ["Planner", "Highest", "This mod (Land loss) higher / level / lower: development set", "Held-out set"],
        "byAmt": "By AMT's objective", "byEp": "By EP's objective",
        "better": "None worse, at least one better", "same": "Both the same", "tradeoff": "One better, one worse",
        "worse": "None better, at least one worse", "excluded": "Rival placed districts not on the list, not compared",
        "ariaBest": "Share of scenarios with the highest adjacency, by stage", "ariaQuality": "Mean quality by stage",
        "ariaScatterAmt": "Adjacency per scenario, this mod against AMT",
        "ariaScatterEp": "Adjacency per scenario, this mod against Empire Planner",
        "ariaMissing": "Districts each planner left out although they had a valid tile",
        "ariaRobust": "Share of scenarios with the highest adjacency in each set",
        "ariaMRobust": "Share of several-city scenarios with the highest adjacency, development and held-out sets",
        "ariaForest": "One city: by the rival's own objective, this mod's score as a percentage of the rival's own",
        "ariaForestMulti": "Several cities: by the rival's own objective, this mod's score as a percentage of the rival's own",
        "ariaWonders": "Share of wonders placed and of scenarios with the highest adjacency",
        "ariaSites": "Site value per scenario, this mod against EP",
        "ariaOutput": "Share of scenarios with the highest city output",
        "ariaStrip": "Each planner's adjacency in several-city scenarios as a percentage of the scenario's highest",
        "ariaCoverage": "Coverage scenarios: cities covered and adjacency compared together", "ariaTime": "Median time offline",
    },
}


def join_en(items):
    """A, B and C."""
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1] if items else ""


def git(*args):
    try:
        return subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, encoding="utf-8",
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def build(files=None, make_snapshots=True, version=None, date=None, lang="zh"):
    """Return (page, data): the page (without the document skeleton) and its chart data.

    lang "zh" is the Chinese page, "en" the English one; both have every section and appendix."""
    EN = lang == "en"

    def L(zh, en):
        return en if EN else zh
    PL = {k: dict(v, label=PLANNERS_EN[k]) for k, v in PLANNERS.items()} if EN else PLANNERS
    dname = DNAME_EN if EN else DNAME
    version = version or git("rev-parse", "--short", "HEAD") or "dev"
    date = date or git("log", "-1", "--format=%cs") or ""
    download = (REPO_URL + "/releases/tag/" + version) if version.startswith("v") else (REPO_URL + "/releases/latest")
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
        overview.append({"label": PL[k]["label"], "best": pct(s["best"]), "quality": pct(s["quality"], 1),
                         "worst": pct(s["worst"]), "legal": "%d / %d" % (s["legal"], s["n"]),
                         "missing": "%d / %d" % (s["missing"], s["requested"]), "time": L("%.1f 秒", "%.1f s") % s["time"]})

    main_series = [k for k in ["sdp:STANDARD", "amt", "ep"] if S.get(k)]
    by_best, by_q = [], []
    qmins = []
    for stage, label in (STAGES_EN if EN else STAGES):
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
                extra.append(L("漏放 %d", "%d left out") % o["missing"])
            if not o["legal"]:
                extra.append(L("违规", "not valid"))
            pts[k].append({"x": us["gain"], "y": o["gain"], "bad": not o["legal"],
                           "label": L("%s：本模组 +%d，%s +%d%s", "%s: this mod +%d, %s +%d%s") % (
                               sid, us["gain"], PL[k]["label"], o["gain"],
                               (L("（", " (") + L("，", ", ").join(extra) + L("）", ")")) if extra else "")})
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
            vs = L("%d / %d / %d（平均 %+.1f）", "%d / %d / %d (mean %+.1f)") % (w, t, l, d)
        output_rows.append({"label": PL[k]["label"], "best": pct(s_["outBest"]), "gap": "%.1f" % s_["outGap"], "vs": vs})
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
        KN = L({"overwrites_pin": "压钉", "dmt_illegal": "DMT 判不可放", "on_resource": "压资源", "slots": "超槽位",
                "empire_limit": "超帝国上限", "twice_in_city": "同城重复", "out_of_range": "超出 3 环", "foreign_tile": "别国的格",
                "other_city_tile": "本国其他城的格", "occupied": "格已占用", "same_tile": "同一格两个"},
               {"overwrites_pin": "tacks overwritten", "dmt_illegal": "DMT refuses", "on_resource": "on a resource",
                "slots": "over the slots", "empire_limit": "over the empire limit", "twice_in_city": "twice in a city",
                "out_of_range": "beyond 3 rings", "foreign_tile": "foreign tile", "other_city_tile": "another own city's tile",
                "occupied": "tile taken", "same_tile": "two on one tile"})
        detail = L("、", ", ").join(L("%s %d", "%s: %d") % (KN.get(kk, kk), n) for kk, n in sorted(kinds.items(), key=lambda x: -x[1]))
        d = det_by.get(k, [0, 0])
        correct.append({"label": PL[k]["label"], "illegal": "%d / %d%s" % (illegal, s["n"], (L("（", " (") + detail + L("）", ")")) if detail else ""),
                        "pins": L("%d 个方案", "%d plans") % s["pinPlans"], "missing": "%d / %d" % (s["missing"], s["requested"]),
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
                ex = ["+%d" % r["gain"], L("%.0f 秒", "%.0f s") % r["seconds"]]
                if r.get("missing"):
                    ex.append(L("漏放 %d", "%d left out") % r["missing"])
                if not r["legal"]:
                    ex.append(L("违规", "not valid"))
                extra[k] = L("，", ", ").join(ex)
        parts = sid.split("-")
        label = "%s %s %s %s" % (parts[0], parts[1], parts[3] if len(parts) > 3 else "", parts[4] if len(parts) > 4 else "")
        mrows.append({"label": label.strip(), "values": vals, "bad": bad, "extra": extra})
    mmin = max(0, (int(min(mvals + [100]) // 10)) * 10 - 10) if mvals else 50
    M = {k: stats(multi, k) for k in mseries}

    # ---------------------------------------------------------------- time
    trows = []
    for k in ["sdp:FAST", "sdp:STANDARD", "sdp:FINE", "amt", "ep"]:
        if S.get(k):
            trows.append({"label": L("单城 " + PL[k]["label"], "One city, " + SHORT_EN[k]), "value": S[k]["time"], "color": PL[k]["color"]})
    for k in ["sdp:STANDARD", "amt", "ep"]:
        if M.get(k):
            trows.append({"label": L("多城 " + PL[k]["label"], "Cities, " + SHORT_EN[k]), "value": M[k]["time"], "color": PL[k]["color"]})

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
            t = "%s  +%d%s" % (PL[k]["label"], s["gain"], (L("  漏放 %d", ", %d left out") % miss) if miss else "")
            panels.append({"title": t, "items": items, "bad": bad, "cls": cls})
        w, h, body = hexmap.render(snap, panels, (city["x"], city["y"]), 3, lang=lang)
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

    if EN:
        CIVN, BION, STN = CIVN_EN, BION_EN, STN_EN

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
                names = L("、", ", ").join(dname.get(v.get("type"), v.get("type")) for v in mine)
                notes.append(L("本模组漏放的%s在这座城没有合法位置", "the %s this mod left out has no valid tile in this city") % names)
        for k in ("amt", "ep"):
            r = raw.get((sid, k))
            if r and r.get("score"):
                for v in r["score"]["violations"]:
                    if v["kind"] == "overwrites_pin":
                        notes.append(L("%s 把玩家在 (%d,%d) 的钉压掉了", "%s overwrote the player's tack at (%d,%d)") % (PL[k]["label"], v["x"], v["y"]))
                miss = [v.get("type", "").replace("DISTRICT_", "").lower() for v in r["score"]["violations"] if v["kind"] == "missing"]
                if miss:
                    placeable = sum(1 for v in r["score"]["violations"] if v["kind"] == "missing" and v.get("detail") == "placeable")
                    if EN:
                        notes.append("%s left out %d district%s%s" % (PL[k]["label"], len(miss), "" if len(miss) == 1 else "s",
                                                                    (" (%d with a valid tile)" % placeable) if placeable else ""))
                    else:
                        notes.append("%s 漏放 %d 个区域%s" % (PL[k]["label"], len(miss),
                                                           ("（其中 %d 个有合法位置）" % placeable) if placeable else ""))
        if EN:
            body = "; ".join(notes)
            cap_txt = "%s (%s). %s" % (describe(sid), sid, (body[:1].upper() + body[1:] + ". ") if notes else "")
            cap_txt = cap_txt[0].upper() + cap_txt[1:]
        else:
            cap_txt = "%s（%s）。%s" % (describe(sid), sid, "；".join(notes) + "。" if notes else "")
        if i == 0:
            hero_svg, hero_cap = svg, L("同一座城、同样的区域清单，三个规划器的方案：", "One city, the same district list, the plans of the three planners: ") + cap_txt + L(
                "城=市中心，灰色=已建区域，彩色=新规划的区域（数字是它自己的相邻加成）。",
                "C = City Center, gray = districts already built, colored = newly planned districts (the number is its own adjacency bonus).")
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
    sd_claim = (L("方案全部合法、不压玩家的钉、同输入同结果", "every plan is valid, overwrites no tack of the player, and the same input gives the same plan")
                if sd_clean else
                L("方案违规 %d 个、压钉 %d 个、重复运行不一致 %d 个", "%d plans are not valid, %d overwrite a tack, %d runs do not repeat")
                % (sd["n"] - sd["legal"], sd["pinPlans"], det_sd[1] - det_sd[0])) if sd else ""

    def lower_in(n, who):
        return ("没有一个场景低于 %s" % who) if n == 0 else ("只有 %d 个场景低于 %s" % (n, who))

    texts = {
        "VERSION": version, "DATE": date, "DOWNLOAD_URL": download, "REPO_URL": REPO_URL, "WORKSHOP_URL": WORKSHOP_URL, "PAGES_URL": PAGES_URL,
        "DOWNLOAD_LABEL": (L("下载 ", "Download ") + version) if version.startswith("v") else L("下载最新版", "Download the latest version"),
        "SUMMARY_COMPARE": (L(
            "在 %d 个模拟实际对局的单城场景上与 AMT r49、Empire Planner 对比：本模组标准档有 %s 的场景拿到最高加成（AMT %s，EP %s），%s。",
            "On %d one-city scenarios modeled on real games, compared with AMT r49 and Empire Planner, this mod on Standard effort "
            "reaches the highest adjacency in %s of them (AMT %s, EP %s), and %s.")
            % (sd["n"], pct(sd["best"]), pct(am["best"]), pct(ep["best"]), sd_claim)) if sd and am and ep else "",
        "N_SINGLE": str(len(single)), "N_MULTI": str(len(multi)), "N_CIVS": "17",
        "SELF_CHECK": L("%d 次，%d 次不一致", "%d runs, %d differ") % (self_n, self_mis),
        "AMT_QUALITY": L("单城场景中 %d 个低于本模组、%d 个持平、%d 个更高；平均质量 %s。",
                         "One-city scenarios: %d below this mod, %d level, %d above; average quality %s.")
        % (w_a, t_a, l_a, pct(am["quality"], 1)) if am else "",
        "AMT_MISSING": L("单城场景共漏放 %d 个要求的区域，其中 %d 个在它的方案摆好后仍有合法位置和空槽位。",
                         "Over the one-city scenarios it left out %d requested districts; %d of them still had a valid tile and a free "
                         "slot after its plan was placed.") % (am["missing"], am["missingPlaceable"]) if am else "",
        "AMT_MULTI_TIME": "",
        "AMT_SLOTS": L("后期场景要 6 个以上特色区域时，超出的只能不选。",
                       "Late-game scenarios that ask for more than 6 specialty districts have to drop the rest."),
        "EP_QUALITY": L("单城场景中 %d 个低于本模组、%d 个持平、%d 个更高；平均质量 %s。",
                        "One-city scenarios: %d below this mod, %d level, %d above; average quality %s.")
        % (w_e, t_e, l_e, pct(ep["quality"], 1)) if ep else "",
        "EP_MISSING": L("单城场景要求的 %d 个区域中漏放 %d 个（其中 %d 个有合法位置），%d 个方案一个区域都没放。",
                        "Of the %d districts the one-city scenarios ask for it left out %d (%d of them had a valid tile); %d plans "
                        "placed no district at all.") % (
            ep["requested"], ep["missing"], ep["missingPlaceable"], sum(1 for _, r in runs_of(single, "ep") if r.get("placed") == 0)) if ep else "",
        "EP_PINS": L("%d 个带手打钉的场景里，%d 个方案压到了玩家的钉。",
                     "In the %d scenarios with tacks the player placed by hand, %d plans overwrote one of them.") % (
            sum(1 for sid in single if int(sid[1:3]) % 3 == 0 and not sid.endswith("early")), ep["pinPlans"]) if ep else "",
    }
    late = by_best[-1]["values"] if by_best else {}

    def below_en(na, ne):
        if na == 0 and ne == 0:
            return "this mod is below AMT or EP in no scenario"

        def n_(n):
            return "no scenario" if n == 0 else "only %d scenario%s" % (n, "" if n == 1 else "s")
        return "this mod is below AMT in %s and below EP in %s" % (n_(na), n_(ne))

    def late_share(who, v):
        if EN:
            return "none" if v < 0.5 else ("only %.0f%%" % v)
        return ("%s 一个也没拿到" % who) if v < 0.5 else ("%s 只有 %.0f%%" % (who, v))
    texts["SINGLE_TEXT"] = (L(
        "本模组标准档在 %s 的场景拿到最高加成，AMT %s，EP %s。区域越多差距越大：后期场景（7–8 个区域）%s、%s。"
        "逐场景看，本模组%s，%s。",
        "This mod on Standard reaches the highest adjacency in %s of the scenarios, AMT in %s, EP in %s. The more districts, "
        "the wider the gap: in the late-game scenarios (7–8 districts) AMT reaches it in %s, EP in %s. Scenario by scenario, %s.")
        % ((pct(sd["best"]), pct(am["best"]), pct(ep["best"]), late_share("AMT", late.get("amt", 0)), late_share("EP", late.get("ep", 0)))
           + ((below_en(l_a, l_e),) if EN else (lower_in(l_a, "AMT"), lower_in(l_e, "EP"))))) if sd and am and ep else ""
    for k in ("amt", "ep"):
        w, t, l, _, _ = cap.get(k + "_wtl", (0, 0, 0, 0, 0))
        cap[k] = L("本模组更高 %d 个场景、持平 %d 个、%s更高 %d 个。", "This mod is higher in %d scenarios, level in %d, %shigher in %d.") % (
            w, t, "AMT " if k == "amt" else "EP ", l)

    # Correctness: districts left off although they had a place.
    no_plot = sd["missing"] - sd["missingPlaceable"] if sd else 0
    texts["CORRECT_TEXT"] = (L(
        "本模组%s，%s。AMT 和 EP 分别漏放了 %d 个和 %d 个其实有位置的区域（原因见第 3 节）%s。",
        "This mod: %s; %s. AMT and EP left out %d and %d districts that did have a valid tile (the reasons are in section 3)%s.") % (
            sd_claim, L("能放下的区域都放了", "every district that fits is placed") if sd["missingPlaceable"] == 0 else
            L("但有 %d 个区域有位置却没放", "but %d districts with a valid tile were left out") % sd["missingPlaceable"],
            am["missingPlaceable"], ep["missingPlaceable"],
            (L("；EP 还有 %d 个方案压掉了玩家事先打的钉", "; in %d plans EP also overwrote tacks the player had placed")
             % ep["pinPlans"]) if ep["pinPlans"] else "")) if sd and am and ep else ""
    texts["MISSING_CAP"] = (L(
        "有位置却没放的区域数（%d 个场景共要求 %d 个区域）。地图上确实放不下的区域（本模组漏放的 %d 个都是这种）不计。",
        "Districts left out although they had a valid tile (the %d scenarios ask for %d districts in all). Districts that really "
        "do not fit on the map (all %d this mod left out are of this kind) are not counted.") % (
        sd["n"], sd["requested"], no_plot)) if sd else ""
    missing_chart = [{"label": PL[k]["label"], "value": S[k]["missingPlaceable"], "color": PL[k]["color"],
                      "tip": L("%s：漏放 %d 个，其中有位置却没放 %d 个", "%s: %d left out, %d of them with a valid tile")
                      % (PL[k]["label"], S[k]["missing"], S[k]["missingPlaceable"])}
                     for k in ("sdp:STANDARD", "amt", "ep") if S.get(k)]

    # City output.
    output_chart = []
    for k in ("sdp:STANDARD_LAND", "sdp:STANDARD", "amt", "ep"):
        s_ = S.get(k)
        if s_ and s_.get("outBest") is not None:
            label = L("本模组 计入地块（面板默认）", "This mod, Land loss (panel default)") if k == "sdp:STANDARD_LAND" else PL[k]["label"]
            output_chart.append({"label": label, "value": s_["outBest"] * 100, "color": PL[k]["color"],
                                 "tip": L("%s：%s 的场景拿到最高总产出", "%s: the highest city output in %s of the scenarios")
                                 % (label, pct(s_["outBest"]))})
    texts["OUTPUT_TEXT"] = ""
    if sl and sl.get("outBest") is not None and am and ep:
        texts["OUTPUT_TEXT"] = L(
            "换成不属于任何一方的城市总产出，本模组用面板默认的“计入地块”仍最常拿到最高（%s，AMT %s，EP %s）。只看相邻加成的标准档是 %s："
            "“计入地块”确实把占好地的代价算了进去。",
            "Measured by city output, which belongs to none of the planners, this mod with the panel's default Land loss still "
            "reaches the highest most often (%s; AMT %s, EP %s). Standard, which counts adjacency only, reaches %s: Land loss "
            "does count the cost of taking good tiles.") % (
                pct(sl["outBest"]), pct(am["outBest"] or 0), pct(ep["outBest"] or 0),
                pct(sd["outBest"] or 0) if sd and sd.get("outBest") is not None else "-")
    if sd and am and ep:
        texts["SPEED_TEXT"] = L(
            "游戏里实测，单城 6–8 个区域标准档不到 0.3 秒；3 城联合 2.7 秒（之后标准档加了宽束联合起点，游戏内同规模实测多约 10%%），经面板分帧时游戏照常响应。离线环境里同样的单城规划，"
            "AMT 慢约 %.0f 倍，EP 慢约 %.0f 倍。",
            "Measured in the game: one city with 6–8 districts takes under 0.3 s on Standard effort; three cities planned together "
            "take 2.7 s (Standard has since gained a wide joint start, about 10%% more at the same size), and the game keeps "
            "responding while the panel computes over several frames. Offline, the same one-city planning takes AMT about %.0f times "
            "and EP about %.0f times as long. ") % (am["time"] / sd["time"], ep["time"] / sd["time"])
    # Picking districts per city on the multi tab: tests/offline/bench_multipools.lua, run by hand
    # (docs/self-test-report.md, fifth round).
    texts["MULTIPOOLS_TEXT"] = L(MULTIPOOLS_TEXT, MULTIPOOLS_TEXT_EN)
    hero = []
    if sd and am and ep:
        hero = [
            {"value": pct(sd["best"]), "label": L("单城场景拿到最高加成（标准档）；AMT %s，EP %s",
                                                  "of one-city scenarios with the highest adjacency (Standard effort); AMT %s, EP %s")
             % (pct(am["best"]), pct(ep["best"]))},
            {"value": "+%s / +%s" % (pct(r_a, 0).rstrip("%") + "%", pct(r_e, 0).rstrip("%") + "%"),
             "label": L("平均比 AMT / Empire Planner 多出的相邻加成", "more adjacency than AMT / Empire Planner on average")},
            {"value": L("0 违规", "0 violations"), "label": L("方案全部合法，不压玩家的钉，同输入同结果",
                                                            "every plan valid, no tack of the player overwritten, same input, same plan")},
            {"value": L("0.25 秒", "0.25 s"), "label": L("游戏内单城 6 个区域（标准档）", "one city, 6 districts, in the game (Standard effort)")},
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
            groups.append({"label": label, "key": set_name, "values": {k: v * 100 for k, v in best.items()}})
            for other, oname in (("amt", "AMT"), ("ep", "EP")):
                pr = summarize.paired(sub, "sdp:STANDARD", other, "gain")
                if pr["n"]:
                    pairs[(set_name, kind, other)] = pr
                    table_rows.append(dict({"set": L("%s（%d）", "%s (%d)") % (label, len(sub)), "vs": oname,
                                            "best": "%s / %s" % (pct(best.get("sdp:STANDARD") or 0), pct(best.get(other) or 0))},
                                           **fmt_pair(pr)))
        return table_rows, groups

    DEV, HELD = L("开发集", "Development"), L("留出集", "Held-out")
    robust_rows, robust_groups = robust([("dev", "single", DEV), ("heldout", "single", HELD),
                                         ("profile:SCI", "single", L("科研 ×3", "Science ×3")),
                                         ("profile:PROD", "single", L("生产 ×3", "Production ×3")),
                                         ("profile:FAITH", "single", L("信仰 ×3", "Faith ×3"))])
    robust_multi_rows, robust_multi_groups = robust([("dev", "multi", DEV), ("heldout", "multi", HELD)])
    single_pairs = [pr for (s_, kind, o), pr in pairs.items() if kind == "single"]
    if robust_groups:
        mins = min(g["values"].get("sdp:STANDARD", 0) for g in robust_groups)
        amax = max(g["values"].get("amt", 0) for g in robust_groups)
        emax = max(g["values"].get("ep", 0) for g in robust_groups)
        all_sig = all(pr["ci"][0] > 0 for pr in single_pairs)
        texts["ROBUST_TEXT"] = L(
            "换成开发时没看过的地图，或把一项产出的权重调到 3，结论不变：每一组里本模组拿到最高的比例都不低于 %.0f%%，AMT 不超过 %.0f%%，EP 不超过 %.0f%%%s。",
            "On maps not looked at during development, or with one yield's weight at 3, the result holds: in every set this mod "
            "reaches the highest in at least %.0f%% of the scenarios, AMT in at most %.0f%%, EP in at most %.0f%%%s.") % (
                mins, amax, emax, L("；逐场景配对，每一组本模组都显著更高", "; paired by scenario, this mod is significantly higher in every set")
                if all_sig else "")
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
                row = {"set": L("%s（%d）", "%s (%d)") % (label, len(sub)), "scorer": L("%s 的目标函数", "%s's objective") % sname,
                       "sdp": "%.2f" % means["sdp:STANDARD"], "amt": "%.2f" % means["amt"] if "amt" in means else "-",
                       "ep": "%.2f" % means["ep"] if "ep" in means else "-"}
                row.update(fmt_pair(pr))
                table_rows.append(row)
                own = means[scorer]
                lo, hi = pr["ci"]
                forest.append({"label": L("%s · 按 %s 的", "%s · by %s") % (label, sname), "scorer": scorer, "color": PL[scorer]["color"],
                               "value": 100 * (1 + pr["mean"] / own), "lo": 100 * (1 + lo / own), "hi": 100 * (1 + hi / own),
                               "tip": L("%s · 按 %s 的目标函数：本模组 %.2f，%s 自己 %.2f；逐场景胜 %d 平 %d 负 %d，平均差 %+.2f [%+.2f, %+.2f]",
                                        "%s · by %s's objective: this mod %.2f, %s's own %.2f; per scenario %d wins, %d ties, %d losses, "
                                        "mean difference %+.2f [%+.2f, %+.2f]") % (
                                   label, sname, means["sdp:STANDARD"], sname, own, pr["wins"], pr["ties"], pr["losses"], pr["mean"], lo, hi)})
        return table_rows, forest

    def cross_claim(forest, scorer):
        rs = [r for r in forest if r["scorer"] == scorer]
        if not rs:
            return ""
        who = "AMT" if scorer == "amt" else "EP"
        d = [r["value"] - 100 for r in rs]
        lo_, hi_ = min(d), max(d)
        rng = ("%.0f%%" % abs(lo_)) if round(lo_) == round(hi_) else ("%.0f–%.0f%%" % (abs(lo_), abs(hi_)) if lo_ >= 0 else
                                                                      L("%+.0f%% 到 %+.0f%%", "%+.0f%% to %+.0f%%") % (lo_, hi_))
        pos = sum(1 for r in rs if r["lo"] > 100)
        neg = sum(1 for r in rs if r["hi"] < 100)
        if EN:
            head = "scored by %s's own objective, " % who
            if pos == len(rs):
                return head + "this mod's plans beat %s's own by %s, significant in every set" % (who, rng)
            if neg == len(rs):
                return head + "this mod's plans are %s below %s's own" % (rng, who)
            if neg == 0 and pos > 0:
                return head + "this mod's plans are a little higher (%s), but not significantly so in every set" % rng
            if neg == 0:
                return head + "the two are level (%s apart, not significant)" % rng
            return head + "each is ahead in some sets"
        if pos == len(rs):
            return "按 %s 的，本模组的方案比 %s 自己的方案高 %s，各组都显著" % (who, who, rng)
        if neg == len(rs):
            return "按 %s 的，本模组的方案比 %s 自己的方案低 %s" % (who, who, rng)
        if neg == 0 and pos > 0:
            return "按 %s 的，本模组的方案略高（%s），但不是每组都显著" % (who, rng)
        if neg == 0:
            return "按 %s 的，两者持平（相差 %s，不显著）" % (who, rng)
        return "按 %s 的，两者互有高低" % who

    cross_rows, forest_single = cross("single", [("dev", DEV), ("heldout", HELD)])
    cross_multi_rows, forest_multi = cross("multi", [("dev", DEV), ("heldout", HELD)])

    def cap1(t):
        return t[:1].upper() + t[1:]
    texts["CROSS_TEXT"] = (L(
        "AMT、EP 各有自己的目标函数：AMT 把特色区域的产出放大 6–10.5 倍再减地块损失，EP 用自己的规则引擎并扣 0.15 倍地块产出。"
        "用它们自己的目标函数给方案打分，%s；%s。",
        "AMT and EP each have an objective of their own: AMT multiplies specialty districts' yields by 6–10.5 and subtracts the "
        "land loss; EP uses its own rules engine and subtracts 0.15 × the tiles' yields. %s; %s.") % (
        L(cross_claim(forest_single, "amt"), cap1(cross_claim(forest_single, "amt"))), cross_claim(forest_single, "ep"))) if forest_single else ""
    texts["CROSS_MULTI_TEXT"] = (L("%s；%s。", "%s; %s.") % (
        L(cross_claim(forest_multi, "ep"), cap1(cross_claim(forest_multi, "ep"))), cross_claim(forest_multi, "amt"))) if forest_multi else ""
    texts["FOREST_CAP"] = L("按对手自己的目标函数，本模组方案的平均分占打分方自己方案平均分的百分比；横线是 95% 置信区间。"
                            "点在 100% 右边表示按对手自己的标准，本模组的方案也更好；横线跨过 100% 表示差别不显著。",
                            "By the rival's own objective, this mod's mean score as a percentage of the scoring rival's own plans; "
                            "the horizontal lines are 95% confidence intervals. A point right of 100% means this mod's plans are better by "
                            "the rival's own standard too; a line across 100% means the difference is not significant.")

    # ---------------------------------------------------------------- multi texts
    texts["MULTI_TEXT"] = ""
    if M.get("sdp:STANDARD"):
        mb = robust_best.get("dev/multi", {})
        every = mb.get("sdp:STANDARD") == 1
        texts["MULTI_TEXT"] = L(
            "联合规划在%s拿到最高。用单城页签一座一座规划，平均只有最高值的 %s：差的是跨城互惠和市政广场的位置。AMT 也做联合规划，平均 %s；EP %s。",
            "Joint planning reaches the highest in %s. Planning the cities one at a time on the One city tab reaches on average "
            "only %s of the highest: what it misses is the bonuses across cities and where the Government Plaza goes. AMT also "
            "plans cities together, %s on average; EP %s.") % (
                (L("全部 %d 个场景里都", "all %d scenarios") % M["sdp:STANDARD"]["n"]) if every else
                (L(" %s 的场景", "%s of the scenarios") % pct(mb.get("sdp:STANDARD") or 0)),
                pct(M["sdp:CITY_BY_CITY"]["quality"]) if M.get("sdp:CITY_BY_CITY") else "-",
                pct(M["amt"]["quality"]) if M.get("amt") else "-", pct(M["ep"]["quality"]) if M.get("ep") else "-")
        if M.get("amt"):
            texts["AMT_MULTI_TIME"] = L("多城联合离线中位 %.0f 秒，是本模组标准档的 %.0f 倍。",
                                        "Several cities together: median %.0f s offline, %.0f times this mod's Standard.") % (
                M["amt"]["time"], M["amt"]["time"] / max(M["sdp:STANDARD"]["time"], 0.1))
    hom = robust_best.get("heldout/multi", {})
    multi_losses = sum(pr["losses"] for (s_, kind, o), pr in pairs.items() if kind == "multi")
    texts["MULTI_ROBUST_TEXT"] = (L(
        "留出集的 %d 个新地图上，本模组 %s 的场景拿到最高，AMT %s，EP %s%s。",
        "On the %d new maps of the held-out set, this mod reaches the highest in %s of the scenarios, AMT in %s, EP in %s%s.") % (
            len(summarize.subset(scenarios, "heldout", "multi")), pct(hom["sdp:STANDARD"]), pct(hom.get("amt") or 0), pct(hom.get("ep") or 0),
            L("；逐场景配对，开发集和留出集里本模组都没有输过一个场景",
              "; paired by scenario, this mod loses no scenario in either the development or the held-out set")
            if multi_losses == 0 else "")) if hom.get("sdp:STANDARD") is not None else ""
    strip = []
    for k in mseries:
        pts_ = [{"v": r["values"][k], "tip": L("%s · %s：%.1f%%（%s）", "%s · %s: %.1f%% (%s)") % (
                    r["label"], PL[k]["label"], r["values"][k], r["extra"].get(k, ""))}
                for r in mrows if k in r["values"]]
        if pts_:
            strip.append({"label": PL[k]["label"], "color": PL[k]["color"], "points": pts_,
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
        comps = [("sdp:STANDARD_COV1", "sdp:STANDARD", L("覆盖权重 1 对 不计（标准档）", "Weight 1 vs off (Standard)")),
                 ("sdp:STANDARD_COV3", "sdp:STANDARD", L("覆盖权重 3 对 不计（标准档）", "Weight 3 vs off (Standard)")),
                 ("sdp:FINE_COV1", "sdp:FINE", L("覆盖权重 1 对 不计（精细档）", "Weight 1 vs off (Thorough)")),
                 ("sdp:STANDARD", "amt", L("本模组（不计覆盖）对 AMT", "This mod (off) vs AMT")),
                 ("sdp:STANDARD_COV1", "amt", L("本模组（覆盖权重 1）对 AMT", "This mod (weight 1) vs AMT")),
                 ("sdp:STANDARD_COV3", "amt", L("本模组（覆盖权重 3）对 AMT", "This mod (weight 3) vs AMT"))]
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
        pa = par.get(("sdp:STANDARD_COV1", "amt"))
        pa3 = par.get(("sdp:STANDARD_COV3", "amt"))
        gain3 = ("%+.1f" % cov_summary["gain3"]).replace("-", "−")
        if EN:
            text = ("In %d of the %d scenarios every city is covered even with coverage off: the cities all lie within 6 tiles of "
                    "an Industrial Zone and an Entertainment Complex wherever they go. " % (len(saturated), len(vsub)))
            if room:
                text += "In the other %d, coverage weight 1 covers more cities in %d, %s" % (
                    len(room), cov_summary["more1"],
                    "with no loss of adjacency" if cov_summary["loss1"] == 0 else "with a little less adjacency in %d" % cov_summary["loss1"])
                if wobble:
                    text += "; in %d more Standard covers no more cities and loses a little adjacency%s" % (
                        len(wobble), " (on Thorough it is the usual trade, a little less adjacency for 1 more city covered: a wobble "
                        "of Standard's search)" if len(fine_trades) == len(wobble) else "")
                text += ". Weight 3 covers at most %d more and changes adjacency by %s on average. " % (cov_summary["cov3"], gain3)
            if amt_runs and pa and pa["n"]:
                text += "AMT has coverage of its own and gets the same per-city lists. %s" % (
                    ("In %d scenario%s it put a district into a city whose list did not have it, the problem described in section 3, "
                     "so %s not compared; " % (amt_scn_not_req, "" if amt_scn_not_req == 1 else "s",
                                               "that scenario is" if amt_scn_not_req == 1 else "those scenarios are")) if amt_not_req else "")

                def outcome(pr):
                    return join_en(["%d %s" % (pr[k], w) for k, w in (("better", "better"), ("same", "the same"),
                                                                      ("tradeoff", "a trade-off"), ("worse", "worse")) if pr[k]])
                text += "%s %d scenarios, on both measures together, this mod at weight 1 is %s" % (
                    "in the other" if amt_not_req else "In the", pa["n"] - pa["excluded"], outcome(pa))
                shown = [pa]
                if pa3 and pa3["n"]:
                    text += "; at weight 3, %s" % outcome(pa3)
                    shown.append(pa3)
                if all(pr["worse"] == 0 for pr in shown):
                    text += "; %s" % ("worse in none at either weight" if len(shown) > 1 else "worse in none")
                text += "."
        else:
            text = "%d 个场景里，%d 个不计覆盖也已全部覆盖：几座城都在工业区、娱乐中心 6 格以内，放在哪都够得着。" % (len(vsub), len(saturated))
            if room:
                text += "其余 %d 个场景里，覆盖权重 1 时 %d 个多覆盖了城市，%s" % (
                    len(room), cov_summary["more1"],
                    "相邻加成都没降" if cov_summary["loss1"] == 0 else "其中 %d 个相邻加成略降" % cov_summary["loss1"])
                if wobble:
                    text += "；另 %d 个标准档没多覆盖、相邻加成反而略降%s" % (
                        len(wobble), "，精细档下是正常的“相邻略降、覆盖多 1 座”，属于标准档搜索的波动" if len(fine_trades) == len(wobble) else "")
                text += "。权重 3 时最多多覆盖 %d 座，相邻加成平均 %s。" % (cov_summary["cov3"], gain3)
            if amt_runs and pa and pa["n"]:
                text += "AMT 自带覆盖，用同样的逐城清单。%s" % (
                    ("它在 %d 个场景里把区域放进了清单上没有它的城市，这正是第 3 节说的问题，这%s场景不比；" % (
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
        coverage["head"] = L(["场景", "不计覆盖", "覆盖权重 1", "覆盖权重 3", "AMT"],
                             ["Scenario", "Coverage off", "Coverage weight 1", "Coverage weight 3", "AMT"])
        for sid in sorted(vsub):
            cells = [sid]
            for k in ("sdp:STANDARD", "sdp:STANDARD_COV1", "sdp:STANDARD_COV3", "amt"):
                r = vrun(sid, k)
                cells.append("%g / %d%s" % (r["gain"], r["coverage"], L("（%d 个放错城）", " (%d in the wrong city)") % r["violations"]["not_requested"]
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
            wonder_rows.append({"label": PL.get(k, {"label": k})["label"], "wonders": "%d / %d" % (placed, wanted),
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
        wonder_groups = [{"label": L("放下的奇观", "Wonders placed"),
                          "values": {k: wnum[k][0] / max(wnum[k][1], 1) * 100 for k in ("sdp:STANDARD", "amt", "ep")}},
                         {"label": L("拿到最高加成的场景", "Scenarios with the highest adjacency"),
                          "values": {k: wnum[k][2] * 100 for k in ("sdp:STANDARD", "amt", "ep")}}]
        left = ws[1] - ws[0]
        texts["WONDER_TEXT"] = L(
            "%s，EP 只放下 %d 座；连同区域的加成一起比，本模组在 %s 的场景拿到最高，AMT %s，EP %s。本模组没放下的 %d 座里，%d 座在城市 3 环内根本没有合法格。",
            "%s, EP only %d. Counting the districts' adjacency too, this mod reaches the highest in %s of the scenarios, AMT in %s, "
            "EP in %s. Of the %d wonders this mod did not place, %d have no valid tile at all within the city's 3 rings.") % (
                (L("本模组与 AMT 都放下了 %d 座奇观中的 %d 座", "This mod and AMT both place %d of the %d wonders") % (
                    (ws[1], ws[0]) if not EN else (ws[0], ws[1]))) if ws[0] == wa[0] else
                (L("本模组放下了 %d 座奇观中的 %d 座，AMT %d 座", "This mod places %d of the %d wonders, AMT %d") % (
                    (ws[1], ws[0], wa[0]) if not EN else (ws[0], ws[1], wa[0]))),
                we[0], pct(ws[2]), pct(wa[2]), pct(we[2]), left, why["NO_LEGAL_PLOT"])

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
            site_rows.append({"label": PL.get(k, {"label": k})["label"],
                              "legal": "%d / %d" % (sum(1 for r in runs if r["legal"]), len(runs)),
                              "value": "%.1f" % avg("siteValue"), "tiles": "%.1f" % avg("tileValue"),
                              "districts": "%.1f" % avg("districtPotential"), "water": "%.2f" % avg("freshWater"),
                              "lux": "%.2f" % avg("newLuxuries"), "overlap": "%.1f" % avg("overlap")})
        vals = []
        for sid, e in sorted(csub.items()):
            us, o = e["runs"].get("sdp:STANDARD"), e["runs"].get("ep")
            if us and o and us.get("siteValue") is not None and o.get("siteValue") is not None:
                site_pts.append({"x": us["siteValue"], "y": o["siteValue"], "bad": not o["legal"],
                                 "label": L("%s：本模组 %.1f，EP %.1f", "%s: this mod %.1f, EP %.1f") % (sid, us["siteValue"], o["siteValue"])})
                vals += [us["siteValue"], o["siteValue"]]
        if vals:
            smin = int((min(vals) - 3) // 10 * 10)
            smax_ = int(((max(vals) + 3) // 10 + 1) * 10)
            sticks = list(range(smin, smax_ + 1, 10))
        pr = summarize.paired(csub, "sdp:STANDARD", "ep", "gain")
        if pr["n"] and len(site_rows) == 2:
            us, ep_row = site_rows
            ours, theirs = [], []
            for f, better, low in (("tiles", L("地块产出更高", "higher tile yields"), False),
                                   ("districts", L("区域潜力更高", "higher district potential"), False),
                                   ("water", L("更常有淡水", "Fresh Water more often"), False),
                                   ("lux", L("新的奢侈资源更多", "more new luxury resources"), False),
                                   ("overlap", L("与已有城市重叠更少", "less overlap with existing cities"), True)):
                a_, b_ = float(us[f]), float(ep_row[f])
                if a_ == b_:
                    continue
                ((ours if (a_ < b_) == low else theirs)).append(better)
            if EN:
                texts["SITES_TEXT"] = (
                    "AMT does not choose city sites, so only EP is compared. Over %d scenarios this mod's site value wins %d, ties %d "
                    "and loses %d. This mod's sites have %s; EP's have %s." % (
                        pr["n"], pr["wins"], pr["ties"], pr["losses"], join_en(ours) or "no part ahead", join_en(theirs) or "no part ahead"))
            else:
                texts["SITES_TEXT"] = (
                    "AMT 不自动选城址，只比 EP。%d 个场景里本模组的城址总值胜 %d、平 %d、负 %d。本模组的城址%s；EP 的城址%s。" % (
                        pr["n"], pr["wins"], pr["ties"], pr["losses"], "、".join(ours) or "没有占优的分项", "、".join(theirs) or "没有占优的分项"))

    # ---------------------------------------------------------------- overview table (5.1)
    def tr(cells):
        return "<tr>" + "".join("<td>%s</td>" % c for c in cells) + "</tr>"

    def grp(anchor, title):
        return '<tr class="grp"><td colspan="3"><a href="#%s">%s</a></td></tr>' % (anchor, title)

    def vs(a, b, c):
        return L("%s，AMT %s，EP %s", "%s, AMT %s, EP %s") % (a, b, c)
    srows = [grp("e-single", L("B.2 单城", "B.2 One city"))]
    if sd and am and ep:
        srows.append(tr([L("相邻加成", "Adjacency"), L("开发集 %d", "development set, %d") % sd["n"],
                         L("拿到最高加成：本模组 ", "highest adjacency: this mod ") + vs(pct(sd["best"]), pct(am["best"]), pct(ep["best"]))]))
        srows.append(tr([L("合法与完整", "Valid and complete"), "%d" % sd["n"],
                         L("本模组%s；有位置却没放的区域：AMT %d 个，EP %d 个", "this mod: %s; districts left out although they had a valid tile: AMT %d, EP %d") % (
            L("零违规、能放的都放了", "no violation, every district that fits placed") if sd_clean and sd["missingPlaceable"] == 0 else L("见 B.2", "see B.2"),
            am["missingPlaceable"], ep["missingPlaceable"])]))
    if robust_groups:
        rg = {g["key"]: g["values"] for g in robust_groups}
        if "heldout" in rg:
            v = rg["heldout"]
            srows.append(tr([L("换地图", "Other maps"), L("留出集 %d", "held-out set, %d") % len(summarize.subset(scenarios, "heldout", "single")),
                             L("拿到最高：本模组 ", "highest: this mod ") + vs("%.0f%%" % v.get("sdp:STANDARD", 0), "%.0f%%" % v.get("amt", 0), "%.0f%%" % v.get("ep", 0))]))
        prof = [g for g in robust_groups if g["key"].startswith("profile:")]
        if prof:
            srows.append(tr([L("换权重", "Other weights"), "3 × %d" % len(single),
                             L("拿到最高：本模组 %.0f%%–%.0f%%，AMT、EP 都不超过 %.0f%%", "highest: this mod %.0f%%–%.0f%%, AMT and EP at most %.0f%%") % (
                min(g["values"]["sdp:STANDARD"] for g in prof), max(g["values"]["sdp:STANDARD"] for g in prof),
                max(max(g["values"].get("amt", 0), g["values"].get("ep", 0)) for g in prof))]))
    if sl and sl.get("outBest") is not None:
        srows.append(tr([L("城市总产出", "City output"), "%d" % sl["n"],
                         L("拿到最高：本模组（计入地块）", "highest: this mod (Land loss) ") + vs(pct(sl["outBest"]), pct(am["outBest"] or 0), pct(ep["outBest"] or 0))]))
    if forest_single:
        srows.append(tr([L("对手的目标函数", "The rivals' own objectives"), L("开发集、留出集各 %d", "development and held-out sets, %d each") % len(single),
                         L("%s；%s", "%s; %s") % (cross_claim(forest_single, "amt"), cross_claim(forest_single, "ep"))]))
    srows.append(grp("e-multi", L("B.3 多城", "B.3 Several cities")))
    if M.get("sdp:STANDARD"):
        srows.append(tr([L("联合规划", "Joint planning"), L("开发集 %d", "development set, %d") % len(multi),
                         L("平均达到最高值的：本模组 ", "average share of the best value: this mod ") + vs(
            pct(M["sdp:STANDARD"]["quality"]), pct(M["amt"]["quality"]) if M.get("amt") else "-", pct(M["ep"]["quality"]) if M.get("ep") else "-")
            + ((L("；逐城依次规划 %s", "; city by city %s") % pct(M["sdp:CITY_BY_CITY"]["quality"])) if M.get("sdp:CITY_BY_CITY") else "")]))
    if hom.get("sdp:STANDARD") is not None:
        srows.append(tr([L("换地图", "Other maps"), L("留出集 %d", "held-out set, %d") % len(summarize.subset(scenarios, "heldout", "multi")),
                         L("拿到最高：本模组 ", "highest: this mod ") + vs(pct(hom["sdp:STANDARD"]), pct(hom.get("amt") or 0), pct(hom.get("ep") or 0))]))
    if forest_multi:
        srows.append(tr([L("对手的目标函数", "The rivals' own objectives"), L("开发集、留出集各 %d", "development and held-out sets, %d each") % len(multi),
                         L("%s；%s", "%s; %s") % (cross_claim(forest_multi, "ep"), cross_claim(forest_multi, "amt"))]))
    if cov_summary:
        pa = par.get(("sdp:STANDARD_COV1", "amt")) or {}
        srows.append(tr([L("覆盖范围", "Coverage"), "%d" % cov_summary["n"], L(
            "有取舍余地的 %d 个场景里，覆盖权重 1 时 %d 个多覆盖了城市；覆盖、相邻两项一起与 AMT 比，%d 个更好、%d 个更差",
            "of the %d scenarios that leave room for it, coverage weight 1 covers more cities in %d; on coverage and adjacency together "
            "against AMT, %d better, %d worse") % (cov_summary["room"], cov_summary["more1"], pa.get("better", 0), pa.get("worse", 0))]))
    if wnum.get("sdp:STANDARD"):
        srows.append(grp("e-wonders", L("B.4 奇观", "B.4 Wonders")))
        srows.append(tr([L("奇观与区域", "Wonders with districts"), "%d" % len(wsub),
                         L("放下的奇观：本模组 %s；拿到最高加成：本模组 %s", "wonders placed: this mod %s; highest adjacency: this mod %s") % (
            vs("%d/%d" % wnum["sdp:STANDARD"][:2], "%d" % wnum["amt"][0], "%d" % wnum["ep"][0]),
            vs(pct(wnum["sdp:STANDARD"][2]), pct(wnum["amt"][2]), pct(wnum["ep"][2])))]))
    if csub:
        spr = summarize.paired(csub, "sdp:STANDARD", "ep", "gain")
        srows.append(grp("e-sites", L("B.5 选城址", "B.5 City sites")))
        srows.append(tr([L("两座新城（只比 EP）", "Two new cities (against EP only)"), "%d" % spr["n"],
                         L("城址总值逐场景：本模组胜 %d、平 %d、负 %d", "site value per scenario: this mod wins %d, ties %d, loses %d")
                         % (spr["wins"], spr["ties"], spr["losses"])]))
    srows.append(grp("e-pools", L("B.6 从候选里挑", "B.6 Picking from the pool")))
    srows.append(tr([L("单城挑选", "One city"), L("4 种情形 × 4", "4 cases × 4"),
                     L("标准档 16 个全部挑中最好的组合，约 0.4–1.0 秒；快速档平均 98%",
                       "Standard picks the best combination in all 16, in about 0.4–1.0 s; Fast 98% on average")]))
    srows.append(tr(MULTIPOOLS_ROW_EN if EN else MULTIPOOLS_ROW))
    srows.append(grp("e-tests", L("速度（第 4 节）· B.7 本模组自身的测试", "Speed (section 4) · B.7 This mod's own tests")))
    if sd and am and ep:
        srows.append(tr([L("速度", "Speed"), L("游戏内实测", "measured in the game"),
                         L("单城不到 0.3 秒，3 城联合约 3 秒；离线比 AMT 快约 %.0f 倍",
                           "one city under 0.3 s, three cities together about 3 s; offline about %.0f times as fast as AMT") % (am["time"] / sd["time"])]))
    srows.append(tr([L("自身的测试", "Own tests"), L("游戏内 100 项、离线 111 项、真实点击 30 项", "100 in the game, 111 offline, 30 real clicks"),
                     L("全部通过；裁判与游戏引擎逐格一致（沉船一处已知偏差）；魅力逐格校准",
                       "all pass; the judge agrees with the game engine tile by tile (one known difference, at a shipwreck); Appeal "
                       "calibrated tile by tile")]))
    stress_text, stress_table, stress_row = stress_section(lang=lang)
    texts["STRESS_TEXT"], texts["STRESS_TABLE"] = stress_text, stress_table
    if stress_row:
        srows.append(grp("e-stress", L("B.8 后期存档压力测试", "B.8 Late-game saves")))
        srows.append(tr(stress_row))
    texts["EVAL_SUMMARY"] = ('<table><thead><tr><th>%s</th><th>%s</th><th>%s</th></tr></thead><tbody>%s</tbody></table>' % (
        L("实验", "Experiment"), L("场景", "Scenarios"), L("结论", "Result"), "".join(srows)))

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
        extra.append(L("开发时没用过的留出集上为 %s（AMT %s，EP %s）",
                       "On held-out maps not used during development it reaches %s (AMT %s, EP %s)")
                     % (pct(ho["sdp:STANDARD"]), pct(ho.get("amt") or 0), pct(ho.get("ep") or 0)))
    if wnum.get("sdp:STANDARD") and wnum.get("amt"):
        extra.append(L("与区域一起放奇观，放下 %d / %d 座（AMT %d，EP %d）",
                       "Placing wonders together with districts, it places %d of %d wonders (AMT %d, EP %d)")
                     % (wnum["sdp:STANDARD"][0], wnum["sdp:STANDARD"][1], wnum["amt"][0], wnum.get("ep", (0,))[0]))
    if csub:
        spr = summarize.paired(csub, "sdp:STANDARD", "ep", "gain")
        if spr["n"]:
            extra.append(L("选城址 %d 个场景对 EP 胜 %d、平 %d、负 %d",
                           "Choosing city sites in %d scenarios, it wins %d, ties %d and loses %d against EP")
                         % (spr["n"], spr["wins"], spr["ties"], spr["losses"]))
    if cov_summary and cov_summary["room"]:
        pa = par.get(("sdp:STANDARD_COV1", "amt")) or {}
        better = pa.get("n") and pa.get("worse") == 0
        extra.append(L("覆盖范围（多城页签可选，默认关）在有取舍余地的 %d 个场景里，权重 1 时 %d 个多覆盖了城市",
                       "With the coverage weight (Several cities tab, off by default) at 1, it covers more cities in %d of the %d "
                       "scenarios that leave room for it") % (
            (cov_summary["room"], cov_summary["more1"]) if not EN else (cov_summary["more1"], cov_summary["room"]))
            + ((L("；覆盖、相邻两项一起与 AMT 比没有更差的", "; on coverage and adjacency together it is never worse than AMT")) if better else ""))
    if extra and texts["SUMMARY_COMPARE"]:
        texts["SUMMARY_COMPARE"] += (" " + ". ".join(extra) + ".") if EN else ("；".join(extra) + "。")

    # Output table: add the paired comparison with its interval.
    lab2key = {PL[k]["label"]: k for k in ("amt", "ep")}
    for row in output_rows:
        k = lab2key.get(row["label"])
        row["ho"] = "—"
        if k and ("dev", k) in out_rows_pairs:
            pr = out_rows_pairs[("dev", k)]
            row["vs"] = L("%d / %d / %d（%+.2f [%+.2f, %+.2f]）", "%d / %d / %d (%+.2f [%+.2f, %+.2f])") % (
                pr["wins"], pr["ties"], pr["losses"], pr["mean"], pr["ci"][0], pr["ci"][1])
        if k and ("heldout", k) in out_rows_pairs:
            pr = out_rows_pairs[("heldout", k)]
            row["ho"] = L("%d / %d / %d（%+.2f [%+.2f, %+.2f]）", "%d / %d / %d (%+.2f [%+.2f, %+.2f])") % (
                pr["wins"], pr["ties"], pr["losses"], pr["mean"], pr["ci"][0], pr["ci"][1])

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
        "lang": lang, "words": CHART_WORDS[lang], "hero": hero, "planners": PL, "mainSeries": main_series, "overview": overview,
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

    def part(name):
        # The English page reads name_en.ext where the Chinese one reads name.ext.
        if EN:
            name = re.sub(r"(\.[a-z]+(\.txt)?)$", r"_en\1", name)
        return open(os.path.join(HERE, name), encoding="utf-8").read()
    tpl = part("template.html")
    arch = part("part_arch.html")
    algo = part("part_algo.html").replace("{{HEX}}", part("hexfig.svg.txt"))
    # The design goals each algorithm serves, as tags under its heading.
    for sn, goal in (("A.1", "G1 G6"), ("A.2", "G2 G5"), ("A.3", "G2 G3"), ("A.4", "G2"), ("A.5", "G6")):
        tags = " ".join('<span class="tag goal">%s</span>' % g for g in goal.split())
        algo, n = re.subn(r'(<h3><span class="sn">%s</span>.*?</h3>)' % re.escape(sn), lambda m: m.group(1) + "\n  <p>%s</p>" % tags, algo, count=1)
        if n != 1:
            raise RuntimeError("no heading for " + sn)
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


def stress_section(markdown=False, lang="zh"):
    """The late-game stress table (B.8) from tests/stress/results/*.json:
    (summary text, table html, summary-row cells). markdown: the table as
    Markdown instead (for docs/self-test-report.md)."""
    EN = lang == "en"

    def L(zh, en):
        return en if EN else zh
    runs = []
    for name in STRESS_ORDER:
        path = os.path.join(STRESS, name + ".json")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                runs.append(json.load(fh))
    if not runs:
        return L("还没有压力测试结果。", "No stress test results yet."), "", None

    def steps(run, test):
        return [st for st in run["Steps"] if test(st["Label"])]

    def secs(list_):
        return [st["Seconds"] for st in list_]

    def fmt_s(v):
        return (L("%.1f 秒", "%.1f s") % v) if v >= 1 else (L("%.2f 秒", "%.2f s") % v)

    def times(run, test, many=False):
        xs = secs(steps(run, test))
        if not xs:
            return "—"
        if many and len(xs) > 1:
            return L("%d 次：中位 %s，最长 %s", "%d runs: median %s, longest %s") % (len(xs), fmt_s(statistics.median(xs)), fmt_s(max(xs)))
        return fmt_s(xs[0])

    def problems(run):
        bad = mism = eng = 0
        det = [0, 0]
        for st in run["Steps"]:
            d = st["Data"] or {}
            if d.get("Ok") is False and d.get("Error") != "NO_SITE":
                bad += 1
            if d.get("Mismatch"):
                mism += 1
            eng += d.get("EngineBad") or 0
            if "Deterministic" in d:
                det[0] += 1 if d["Deterministic"] else 0
                det[1] += 1
        return bad, mism, eng, det

    def label_has(*parts, crowded=False):
        return lambda lb: all(p in lb for p in parts) and (("crowded" in lb) == crowded)

    rows = []

    def row(title, fn):
        if markdown:
            rows.append("| %s | %s |" % (title, " | ".join(fn(r).replace("<br>", L("；", "; ")) for r in runs)))
        else:
            rows.append("<tr><td>%s</td>%s</tr>" % (title, "".join("<td>%s</td>" % fn(r) for r in runs)))
    rules, maps, sizes, leaders, eras = ((STRESS_RULES_EN, STRESS_MAPS_EN, STRESS_SIZES_EN, STRESS_LEADERS_EN, STRESS_ERAS_EN) if EN else
                                         (STRESS_RULES, STRESS_MAPS, STRESS_SIZES, STRESS_LEADERS, STRESS_ERAS))

    def setting(r):
        st = r.get("Settings") or {}
        return L("%s · %s · %s<br>%s，%s开局，自动 %s 回合", "%s · %s · %s<br>%s, %s start, %s turns of autoplay") % (
            rules.get(st.get("ruleset"), st.get("ruleset")), maps.get(st.get("script"), st.get("script")),
            sizes.get(st.get("size"), st.get("size")), leaders.get(st.get("leader"), st.get("leader")),
            eras.get(st.get("era"), st.get("era")), st.get("turns"))

    def board(r):
        c = r["Census"]
        return L("第 %s 回合；本方 %d 城、%d 个区域、%d 个奇观；其他文明与城邦 %d 城",
                 "Turn %s; the player: %d cities, %d districts, %d wonders; other civilizations and city-states: %d cities") % (
            c["Turn"], len(c["Cities"]), c["Districts"], c["Wonders"], c["OtherCities"])
    row(L("场景", "Setup"), setting)
    row(L("局面", "Game state"), board)
    row(L("单城 · 候选池 · 快速档", "One city · Pool · Fast"), lambda r: times(r, label_has("single", "FAST", "pool"), True))
    row(L("单城 · 候选池 · 标准档", "One city · Pool · Standard"), lambda r: times(r, label_has("single", "STANDARD", "pool"), True))
    row(L("单城 · 最多 6 个必建", "One city · up to 6 Musts"), lambda r: times(r, label_has("single", "must"), True))
    row(L("单城 · 社区 + 保护区 + 工业区", "One city · Neighborhood + Preserve + Industrial Zone"),
        lambda r: times(r, label_has("single", "appeal"), True))
    row(L("单城 · 港口与商业中心在候选里", "One city · Harbor and Commercial Hub in the pool"),
        lambda r: times(r, label_has("single", "harbor"), True))
    row(L("单城 · 精细档", "One city · Thorough"), lambda r: times(r, label_has("single", "fine")))

    def sites(r):
        st = steps(r, label_has("sites"))
        if st and (st[0]["Data"] or {}).get("Error") == "NO_SITE":
            return L("%s（8 格内没有可建城址）", "%s (no site within 8 tiles)") % fmt_s(st[0]["Seconds"])
        return times(r, label_has("sites"))
    row(L("选城址 · 3 个、8 格内", "City sites · 3, within 8 tiles"), sites)
    row(L("多城 · 4 城 · 标准档", "Several cities · 4 cities · Standard"), lambda r: times(r, label_has("multi 4 cities standard")))
    row(L("多城 · 4 城 · 精细档", "Several cities · 4 cities · Thorough"), lambda r: times(r, label_has("multi 4 cities fine")))
    row(L("多城 · 8 城 · 标准档", "Several cities · 8 cities · Standard"), lambda r: times(r, label_has("multi 8 cities standard")))
    row(L("打满空格后 · 单城 / 多城", "With every free tile tacked · One city / Several cities"), lambda r: "%s / %s" % (
        times(r, lambda lb: lb.startswith("single") and "crowded" in lb), times(r, lambda lb: lb.startswith("multi") and "crowded" in lb)))
    row(L("打钉后游戏处理新钉：多城方案 / 打满空格", "The game handling new tacks: a several-city plan / every free tile tacked"),
        lambda r: L("%s / %s（%s 个钉）", "%s / %s (%s tacks)") % (
            times(r, label_has("settle after place multi")), times(r, label_has("settle after heavy pins")),
            next(((st["Data"] or {}).get("Placed") for st in r["Steps"] if st["Label"] == "heavy pins"), "—")))
    row(L("面板各页签切换", "Switching the panel's tabs"), lambda r: times(r, label_has("panel")))

    def checks(r):
        bad, mism, eng, det = problems(r)
        return L("失败 %d；增量与全量评估不一致 %d；引擎不允许的格 %d；两次求解相同 %d/%d",
                 "failures %d; incremental and full evaluation differ %d; tiles the engine refuses %d; two solves the same %d/%d") % (
            bad, mism, eng, det[0], det[1])
    row(L("核对", "Checks"), checks)

    def appeal(r):
        ac = r.get("AppealCheck")
        if not ac:
            return "—"
        done = [a for a in ac if "Skipped" not in a]
        dist = sum(len(a["Districts"]) for a in done)
        same = sum(1 for a in done for d in a["Districts"] if d["AppealGame"] == d["AppealPredicted"])

        def district_housing(a):
            return a["HousingDistricts"] if a.get("HousingDistricts") is not None else a["HousingGame"]
        text = L("%d 个方案建成：社区、保护区格的魅力相同 %d/%d，区域住房相同 %d/%d",
                 "%d plans built: Appeal of the Neighborhood and Preserve tiles the same %d/%d, district Housing the same %d/%d") % (
            len(done), same, dist, sum(1 for a in done if abs(district_housing(a) - a["HousingPredicted"]) < 1e-6), len(done))
        pred = [a for a in done if a.get("ImprovementsPredicted") is not None]
        if pred:
            lost = sum(1 for a in pred if (a.get("HousingImprovements") or 0) < 0)
            text += L("，改良设施住房相同 %d/%d（%d 个方案占掉了给住房的改良设施）",
                      ", improvement Housing the same %d/%d (%d plans took improvements that give Housing)") % (
                sum(1 for a in pred if abs(a["HousingImprovements"] - a["ImprovementsPredicted"]) < 1e-6), len(pred), lost)
        if len(done) < len(ac):
            text += L("（%d 个游戏没建成，不计）", " (%d the game did not build, not counted)") % (len(ac) - len(done))
        return text
    row(L("魅力复核：游戏按正常流程建出“社区 + 保护区 + 工业区”的方案",
          "Appeal check: the game builds the “Neighborhood + Preserve + Industrial Zone” plans the normal way"), appeal)

    def preserves(r):
        st = steps(r, lambda lb: lb == "preserves")
        d = (st[0]["Data"] or {}) if st else {}
        if not d:
            return "—"
        if not d.get("Preserves"):
            return L("各文明都没有建保护区", "no civilization built a Preserve")
        if not d.get("WithBuildings"):
            return L("%d 个保护区，都没有建古树林、避难所", "%d Preserves, none with a Grove or Sanctuary") % d["Preserves"]
        return L("%d 个保护区（%d 个有古树林或避难所）；按规则该有产出的地块 %d 块，产出不少于规则的 %d 块，少于的 %d 块",
                 "%d Preserves (%d with a Grove or Sanctuary); %d tiles should get yields by the rules, %d get at least that, "
                 "%d less") % (d["Preserves"], d["WithBuildings"], d["Expected"], d["Seen"], d["Missing"])
    row(L("保护区周边产出（AI 自己建的）", "Yields around Preserves (built by the AI)"), preserves)

    if markdown:
        table = "| %s | %s |\n|%s\n%s" % (L("项目", "Item"), " | ".join(r["Scenario"] for r in runs), "---|" * (len(runs) + 1), "\n".join(rows))
    else:
        head = "".join("<th>%s</th>" % r["Scenario"] for r in runs)
        table = '<table><thead><tr><th>%s</th>%s</tr></thead><tbody>%s</tbody></table>' % (L("项目", "Item"), head, "".join(rows))
    all_secs = [st["Seconds"] for r in runs for st in r["Steps"]
                if st["Label"] not in ("load steps", "census") and not st["Label"].startswith("settle")]
    worst = max(all_secs) if all_secs else 0
    fails = sum(problems(r)[0] + problems(r)[1] + problems(r)[2] for r in runs)
    text = L("AI 自动打出 %d 张后期存档，每张跑同一组求解步骤（<code>tools/stress.py</code>）。耗时是一次算完的墙钟时间；"
             "面板里同样的计算分帧进行，游戏照常响应，所以这是玩家等结果的时间，不是卡顿。最长一步 %s；%s。",
             "The AI played %d games on its own into the late game, and each save runs the same set of solve steps "
             "(<code>tools/stress.py</code>). Times are wall-clock times of computing in one go; in the panel the same "
             "computation runs over several frames and the game keeps responding, so this is how long the player waits for a "
             "result, not a freeze. Longest step %s; %s.") % (
        len(runs), fmt_s(worst), L("失败、不一致和引擎不允许的格都为 0", "failures, mismatches and tiles the engine refuses are all 0")
        if fails == 0 else L("有 %d 处问题，见表", "%d problems, see the table") % fails)
    summary = [L("后期存档", "Late-game saves"), L("%d 张", "%d") % len(runs), L("最长一步 %s；%s", "longest step %s; %s") % (
        fmt_s(worst), L("全部通过", "all passed") if fails == 0 else L("%d 处问题", "%d problems") % fails)]
    return text, table, summary


MIME = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png"}


def standalone(page, read_image, lang="zh"):
    """The page as one file: document skeleton added, screenshots inlined.

    read_image(name) returns the bytes of docs/images/<name>; None leaves the
    screenshots as images/<name> links."""
    m = re.match(r"\s*<title>(.*?)</title>", page)
    title, body = (m.group(1), page[m.end():]) if m else ("智能区域规划器", page)

    def inline(m):
        name = m.group(1)
        data = base64.b64encode(read_image(name)).decode("ascii")
        return 'src="data:%s;base64,%s"' % (MIME[os.path.splitext(name)[1].lower()], data)

    if read_image is not None:
        body = re.sub(r'src="images/([^"]+)"', inline, body)
    return ('<!doctype html>\n<html lang="%s"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>%s</title><style>[hidden]{display:none!important}img{max-width:100%%}</style>'
            '</head><body>%s</body></html>\n' % ("en" if lang == "en" else "zh-CN", title, body))


def site(page, out_dir, lang="zh"):
    """The page for GitHub Pages: document skeleton added, the screenshots it uses copied next to it."""
    os.makedirs(os.path.join(out_dir, "images"), exist_ok=True)
    for name in sorted(set(re.findall(r'src="images/([^"]+)"', page))):
        shutil.copyfile(os.path.join(IMAGES, name), os.path.join(out_dir, "images", name))
    html = standalone(page, None, lang)
    open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8").write(html)
    return html


def main():
    import argparse
    ap = argparse.ArgumentParser(description="Build the mod's page from the comparison results")
    ap.add_argument("files", nargs="*", help="result files (default: the committed results)")
    ap.add_argument("--version", help="version shown on the page (default: the commit)")
    ap.add_argument("--date", help="date shown on the page (default: the commit's date)")
    ap.add_argument("--site", metavar="DIR", help="also write the GitHub Pages site to DIR")
    ap.add_argument("--stress-md", action="store_true", help="print the stress-test table as Markdown and stop")
    args = ap.parse_args()
    if args.stress_md:
        text, table, _ = stress_section(markdown=True)
        print(text.replace("<code>", "`").replace("</code>", "`"))
        print()
        print(table)
        return
    page, data = build(args.files, version=args.version, date=args.date)
    page_en, _ = build(args.files, version=args.version, date=args.date, lang="en")
    os.makedirs(os.path.join(OUT, "en"), exist_ok=True)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(page)
    open(os.path.join(OUT, "en", "index.html"), "w", encoding="utf-8").write(page_en)

    def read_image(name):
        with open(os.path.join(IMAGES, name), "rb") as f:
            return f.read()

    single = standalone(page, read_image)
    single_en = standalone(page_en, read_image, "en")
    if args.site:
        site(page, args.site)
        site(page_en, os.path.join(args.site, "en"), "en")
        print("site: %s/index.html, %s/en/index.html" % (args.site, args.site))
    open(os.path.join(OUT, "report.html"), "w", encoding="utf-8").write(single)
    open(os.path.join(OUT, "report_en.html"), "w", encoding="utf-8").write(single_en)
    json.dump(data, open(os.path.join(OUT, "data.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("report: dist/report/index.html (%d KB), report.html (%d KB, self-contained), en/index.html, report_en.html (%d KB)"
          % (len(page.encode("utf-8")) // 1024, len(single.encode("utf-8")) // 1024, len(single_en.encode("utf-8")) // 1024))


if __name__ == "__main__":
    main()
