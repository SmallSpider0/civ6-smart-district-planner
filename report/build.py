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

The page describes this mod on its own: its quality against the true
optimum, its speed and its tests. The comparison with other planners is a
developer note (docs/notes/planner-comparison.md), not part of the page.
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
import diagrams  # noqa: E402

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
    "coverage_sdp", "coverage_amt",
    # The true optimum and the sets that need it (issue 48).
    "oracle_hs_om", "oracle_check", "oracle_single", "pools_wonders", "smallmulti", "large", "large_heldout", "longrun_multi")]

PLANNERS = {
    "sdp:FAST": {"label": "本模组 快速档", "color": "--s1"},
    "sdp:STANDARD": {"label": "本模组 标准档", "color": "--sdp"},
    "sdp:FINE": {"label": "本模组 精细档", "color": "--s3"},
    "sdp:STANDARD_LAND": {"label": "本模组 标准档·计入地块（面板默认）", "color": "--s3"},
    "sdp:CITY_BY_CITY": {"label": "本模组 逐城依次", "color": "--opt"},
}
STAGES = [("early", "前期 · 2 个区域"), ("mid", "中期 · 4–5 个"), ("late", "后期 · 7–8 个")]
PAGES_URL = "https://smallspider0.github.io/civ6-smart-district-planner/"

# The English page (issue 5): the whole page, appendices included, in English.
# Names and labels it uses; the numbers come from the same data.
PLANNERS_EN = {
    "sdp:FAST": "This mod, Fast", "sdp:STANDARD": "This mod, Standard", "sdp:FINE": "This mod, Thorough",
    "sdp:STANDARD_LAND": "This mod, Standard + Land loss (panel default)", "sdp:CITY_BY_CITY": "This mod, city by city",
}
STAGES_EN = [("early", "Early · 2 districts"), ("mid", "Middle · 4–5"), ("late", "Late · 7–8")]
MULTIPOOLS_ROW_EN = ["Several cities", "3", "Standard and Thorough reach the reference in all 3, better than picking "
                     "city by city and then planning together (96%–100%)"]


def pct(v, digits=0):
    return ("%." + str(digits) + "f%%") % (v * 100)


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
        "colon": "：", "mean": "平均 ",
        "outcomeTip": "{0}：{1} {2} 个场景（共 {3} 个）",
        "headOverview": ["档位", "达到真最优", "平均质量", "最差", "合法方案", "漏放区域", "中位耗时（离线）"],
        "headCorrect": ["档位", "违规方案", "压掉玩家的钉", "漏放区域", "其中有位置却没放", "同输入两次一致"],
        "headRobust": ["场景集", "达到真最优（标准档）", "平均质量", "最差"],
        "headWonders": ["档位", "奇观放下", "合法方案", "达到真最优", "平均质量"],
        "better": "没有一项更差、至少一项更好", "same": "两项都相同", "tradeoff": "一项更好、一项更差",
        "worse": "没有一项更好、至少一项更差", "excluded": "不比",
        "ariaOptimum": "各类场景标准档的加成占真最优的比例",
        "ariaBest": "按阶段达到真最优的场景比例", "ariaQuality": "按阶段的平均质量",
        "ariaRobust": "各场景集达到真最优的比例", "ariaMRobust": "多城开发集与留出集达到参照的比例",
        "ariaWonders": "奇观放下的比例与达到真最优的比例", "ariaStrip": "多城场景的加成占该场景参照的百分比",
        "ariaCoverage": "覆盖范围场景：覆盖城数与相邻加成两项一起比较的结果",
    },
    "en": {
        "colon": ": ", "mean": "mean ",
        "outcomeTip": "{0}: {1}, {2} of {3} scenarios",
        "headOverview": ["Effort level", "At the optimum", "Mean quality", "Worst", "Valid plans", "Left out", "Median time, offline"],
        "headCorrect": ["Effort level", "Plans not valid", "Player's tacks overwritten", "Districts left out", "Of them with a valid tile",
                        "Same plan twice"],
        "headRobust": ["Set", "At the optimum (Standard)", "Mean quality", "Worst"],
        "headWonders": ["Effort level", "Wonders placed", "Valid plans", "At the optimum", "Mean quality"],
        "better": "None worse, at least one better", "same": "Both the same", "tradeoff": "One better, one worse",
        "worse": "None better, at least one worse", "excluded": "Not compared",
        "ariaOptimum": "Standard's share of the true optimum in each kind of scenario",
        "ariaBest": "Share of scenarios at the true optimum, by stage", "ariaQuality": "Mean quality by stage",
        "ariaRobust": "Share of scenarios at the true optimum in each set",
        "ariaMRobust": "Share of several-city scenarios at the reference, development and held-out sets",
        "ariaWonders": "Share of wonders placed and of scenarios at the true optimum",
        "ariaStrip": "Adjacency in several-city scenarios as a percentage of the scenario's reference",
        "ariaCoverage": "Coverage scenarios: cities covered and adjacency compared together",
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


def build(files=None, version=None, date=None, lang="zh"):
    """Return (page, data): the page (without the document skeleton) and its chart data.

    lang "zh" is the Chinese page, "en" the English one; both have every section and appendix."""
    EN = lang == "en"

    def L(zh, en):
        return en if EN else zh
    PL = {k: dict(v, label=PLANNERS_EN[k]) for k, v in PLANNERS.items()} if EN else PLANNERS
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
        return {
            "n": len(rs), "best": statistics.mean(best), "quality": statistics.mean(q) if q else 0, "worst": min(q) if q else 0,
            "legal": sum(1 for _, r in rs if r["legal"]), "missing": missing, "requested": requested,
            "missingPlaceable": placeable,
            "time": statistics.median([r["seconds"] for _, r in rs]),
            "pinPlans": sum(1 for _, r in rs if (r.get("violations") or {}).get("overwrites_pin")),
        }

    order = ["sdp:FAST", "sdp:STANDARD", "sdp:FINE", "sdp:STANDARD_LAND"]
    S = {k: stats(single, k) for k in order}
    overview = []
    for k in order:
        s = S[k]
        if s is None:
            continue
        overview.append({"label": PL[k]["label"], "best": pct(s["best"]), "quality": pct(s["quality"], 1),
                         "worst": pct(s["worst"]), "legal": "%d / %d" % (s["legal"], s["n"]),
                         "missing": "%d / %d" % (s["missing"], s["requested"]), "time": L("%.1f 秒", "%.1f s") % s["time"]})

    main_series = [k for k in ["sdp:FAST", "sdp:STANDARD", "sdp:FINE"] if S.get(k)]
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

    # ---------------------------------------------------------------- correctness
    correct = []
    det_by = defaultdict(lambda: [0, 0])
    for d in det:
        det_by[d["planner"]][0] += 1 if d["same"] else 0
        det_by[d["planner"]][1] += 1
    for k in order:
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
    mseries = [k for k in ["sdp:FAST", "sdp:STANDARD", "sdp:FINE", "sdp:CITY_BY_CITY"] if any(k in e["runs"] for e in multi.values())]
    mrows, mvals = [], []
    for sid, e in sorted(multi.items()):
        ref = e["reference"]
        vals, extra = {}, {}
        for k in mseries:
            r = e["runs"].get(k)
            if r and not r.get("error") and ref:
                vals[k] = r["gain"] / ref * 100
                mvals.append(vals[k])
                ex = ["+%d" % r["gain"], L("%.0f 秒", "%.0f s") % r["seconds"]]
                if r.get("missing"):
                    ex.append(L("漏放 %d", "%d left out") % r["missing"])
                if not r["legal"]:
                    ex.append(L("违规", "not valid"))
                extra[k] = L("，", ", ").join(ex)
        parts = sid.split("-")
        label = "%s %s %s %s" % (parts[0], parts[1], parts[3] if len(parts) > 3 else "", parts[4] if len(parts) > 4 else "")
        mrows.append({"label": label.strip(), "values": vals, "extra": extra})
    mmin = max(0, (int(min(mvals + [100]) // 10)) * 10 - 10) if mvals else 50
    M = {k: stats(multi, k) for k in mseries}

    # ---------------------------------------------------------------- texts
    sd = S.get("sdp:STANDARD")
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

    texts = {
        "VERSION": version, "DATE": date, "DOWNLOAD_URL": download, "REPO_URL": REPO_URL, "WORKSHOP_URL": WORKSHOP_URL, "PAGES_URL": PAGES_URL,
        "DOWNLOAD_LABEL": (L("下载 ", "Download ") + version) if version.startswith("v") else L("下载最新版", "Download the latest version"),
        "N_SINGLE": str(len(single)), "N_MULTI": str(len(multi)), "N_CIVS": "17",
        "SELF_CHECK": L("%d 次，%d 次不一致", "%d runs, %d differ") % (self_n, self_mis),
        "SIMILAR_FIG": diagrams.similar_svg(lang),
        "CHOOSE_FIG": diagrams.decide_svg(lang),
    }
    late = by_best[-1]["values"] if by_best else {}
    texts["SINGLE_TEXT"] = ""
    if sd:
        texts["SINGLE_TEXT"] = L(
            "标准档在 %s 的场景达到真最优，平均质量 %s，最差的场景 %s；快速档、精细档达到真最优的比例分别是 %s、%s。"
            "后期场景（7–8 个区域）标准档 %s 达到真最优。",
            "Standard reaches the true optimum in %s of the scenarios, with a mean quality of %s and %s in the worst scenario; "
            "Fast and Thorough reach it in %s and %s. In the late-game scenarios (7–8 districts) Standard reaches it in %s.") % (
            pct(sd["best"]), pct(sd["quality"], 1), pct(sd["worst"]),
            pct(S["sdp:FAST"]["best"]) if S.get("sdp:FAST") else "-", pct(S["sdp:FINE"]["best"]) if S.get("sdp:FINE") else "-",
            "%.0f%%" % late.get("sdp:STANDARD", 0))

    # Correctness: districts left off although they had a place.
    no_plot = sd["missing"] - sd["missingPlaceable"] if sd else 0
    texts["CORRECT_TEXT"] = (L(
        "标准档%s，%s。没放下的 %d 个区域（%d 个场景共要求 %d 个）在那座城都确实没有合法位置。",
        "On Standard, %s; %s. The %d districts not placed (of %d asked for over the %d scenarios) really have no valid tile "
        "in their city.") % (
            sd_claim, L("能放下的区域都放了", "every district that fits is placed") if sd["missingPlaceable"] == 0 else
            L("但有 %d 个区域有位置却没放", "but %d districts with a valid tile were left out") % sd["missingPlaceable"],
            no_plot, *((sd["requested"], sd["n"]) if EN else (sd["n"], sd["requested"])))) if sd else ""
    texts["SPEED_TEXT"] = L(
        "游戏里实测，单城 6–8 个区域标准档不到 0.3 秒；3 城联合 2.7 秒（之后标准档加了宽束联合起点，游戏内同规模实测多约 10%），"
        "经面板分帧时游戏照常响应。",
        "Measured in the game: one city with 6–8 districts takes under 0.3 s on Standard effort; three cities planned together "
        "take 2.7 s (Standard has since gained a wide joint start, about 10% more at the same size), and the game keeps "
        "responding while the panel computes over several frames. ")
    # Picking districts per city on the multi tab: tests/offline/bench_multipools.lua, run by hand
    # (docs/self-test-report.md, fifth round).
    texts["MULTIPOOLS_TEXT"] = L(MULTIPOOLS_TEXT, MULTIPOOLS_TEXT_EN)

    # ---------------------------------------------------------------- robustness
    robust_best = {}
    robust_quality = {}

    def robust(sets, kind):
        table_rows, groups = [], []
        for set_name, label in sets:
            sub = summarize.subset(scenarios, set_name, kind)
            if not sub:
                continue
            tab = summarize.per_planner(sub)
            best = {k: tab[k]["bestShare"] for k in main_series if k in tab and tab[k]["bestShare"] is not None}
            robust_best[set_name + "/" + kind] = best
            st = tab.get("sdp:STANDARD")
            if st:
                robust_quality[set_name + "/" + kind] = st["qualityMean"]
                table_rows.append([L("%s（%d）", "%s (%d)") % (label, len(sub)), pct(st["bestShare"] or 0),
                                   pct(st["qualityMean"] or 0, 1), pct(st["qualityMin"] or 0)])
            groups.append({"label": label, "key": set_name, "values": {k: v * 100 for k, v in best.items()}})
        return table_rows, groups

    DEV, HELD = L("开发集", "Development"), L("留出集", "Held-out")
    robust_rows, robust_groups = robust([("dev", DEV), ("heldout", HELD), ("profile:SCI", L("科研 ×3", "Science ×3")),
                                         ("profile:PROD", L("生产 ×3", "Production ×3")),
                                         ("profile:FAITH", L("信仰 ×3", "Faith ×3"))], "single")
    _, robust_multi_groups = robust([("dev", DEV), ("heldout", HELD)], "multi")
    texts["ROBUST_TEXT"] = ""
    if robust_groups:
        vals = [g["values"].get("sdp:STANDARD", 0) for g in robust_groups]
        quals = [robust_quality[k] for k in robust_quality if k.endswith("/single") and robust_quality[k] is not None]
        texts["ROBUST_TEXT"] = L(
            "换成开发时没看过的地图，或把一项产出的权重调到 3，标准档达到真最优的比例在 %.0f%%–%.0f%% 之间，每一组的平均质量都不低于 %s。",
            "On maps not looked at during development, or with one yield's weight at 3, Standard reaches the true optimum in "
            "%.0f%%–%.0f%% of the scenarios, and the mean quality of every set is at least %s.") % (
                min(vals), max(vals), pct(min(quals), 1) if quals else "-")

    # ---------------------------------------------------------------- multi texts
    texts["MULTI_TEXT"] = ""
    mb = robust_best.get("dev/multi", {})
    if M.get("sdp:STANDARD"):
        every = mb.get("sdp:STANDARD") == 1
        texts["MULTI_TEXT"] = L(
            "标准档的联合规划在%s达到参照，平均是参照的 %s。用单城页签一座一座规划，平均只有参照的 %s：差的是跨城互惠和市政广场的位置。",
            "Joint planning on Standard reaches the reference in %s, %s of it on average. Planning the cities one at a time on "
            "the One city tab reaches on average only %s of it: what it misses is the bonuses across cities and where the "
            "Government Plaza goes.") % (
                (L("全部 %d 个场景里都", "all %d scenarios") % M["sdp:STANDARD"]["n"]) if every else
                (L(" %s 的场景", "%s of the scenarios") % pct(mb.get("sdp:STANDARD") or 0)),
                pct(M["sdp:STANDARD"]["quality"], 1),
                pct(M["sdp:CITY_BY_CITY"]["quality"]) if M.get("sdp:CITY_BY_CITY") else "-")
    hom = robust_best.get("heldout/multi", {})
    texts["MULTI_ROBUST_TEXT"] = (L(
        "留出集的 %d 个新地图上，标准档 %s 的场景达到参照，平均是参照的 %s。",
        "On the %d new maps of the held-out set, Standard reaches the reference in %s of the scenarios, %s of it on average.") % (
            len(summarize.subset(scenarios, "heldout", "multi")), pct(hom["sdp:STANDARD"]),
            pct(robust_quality.get("heldout/multi") or 0, 1))) if hom.get("sdp:STANDARD") is not None else ""
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
                 ("sdp:FINE_COV1", "sdp:FINE", L("覆盖权重 1 对 不计（精细档）", "Weight 1 vs off (Thorough)"))]
        for a, b, label in comps:
            pr = summarize.pareto(vsub, a, b)
            pr["excluded"] = 0
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
                       "cov3": max(c3) if c3 else 0}
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
                text += ". Weight 3 covers at most %d more and changes adjacency by %s on average." % (cov_summary["cov3"], gain3)
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
        texts["COVERAGE_TEXT"] = text
        coverage["head"] = L(["场景", "不计覆盖", "覆盖权重 1", "覆盖权重 3"],
                             ["Scenario", "Coverage off", "Coverage weight 1", "Coverage weight 3"])
        for sid in sorted(vsub):
            cells = [sid]
            for k in ("sdp:STANDARD", "sdp:STANDARD_COV1", "sdp:STANDARD_COV3"):
                r = vrun(sid, k)
                cells.append("%g / %d" % (r["gain"], r["coverage"]) if r else "—")
            coverage["table"].append(cells)

    # ---------------------------------------------------------------- wonders
    wonder_rows = []
    wnum = {}
    wsub = summarize.subset(scenarios, "wonders", "single")
    if wsub:
        wtab = summarize.per_planner(wsub)
        for k in ("sdp:STANDARD", "sdp:STANDARD_LAND"):
            if k not in wtab:
                continue
            placed = sum((e["runs"][k].get("wondersPlaced") or 0) for e in wsub.values() if k in e["runs"])
            wanted = sum((e["runs"][k].get("wondersRequested") or 0) for e in wsub.values() if k in e["runs"])
            v = wtab[k]
            wnum[k] = (placed, wanted, v["bestShare"] or 0, v["qualityMean"] or 0)
            wonder_rows.append({"label": PL.get(k, {"label": k})["label"], "wonders": "%d / %d" % (placed, wanted),
                                "legal": "%d / %d" % (round((v["legalShare"] or 0) * (v["runs"] - v["errors"])), v["runs"]),
                                "best": pct(v["bestShare"] or 0), "quality": pct(v["qualityMean"] or 0, 1)})
    why = {"NO_LEGAL_PLOT": 0, "NO_FREE_PLOT": 0}
    for sid in wsub:
        r = raw.get((sid, "sdp:STANDARD"))
        for note in ((r or {}).get("plan") or {}).get("notes", []):
            parts = note.split()
            if len(parts) == 3 and parts[0] == "unplaced" and parts[1].startswith("BUILDING_") and parts[2] in why:
                why[parts[2]] += 1
    wonder_groups = []
    texts["WONDER_TEXT"] = ""
    if "sdp:STANDARD" in wnum:
        ws = wnum["sdp:STANDARD"]
        wonder_groups = [{"label": L("放下的奇观", "Wonders placed"), "values": {"sdp:STANDARD": ws[0] / max(ws[1], 1) * 100}},
                         {"label": L("达到真最优的场景", "Scenarios at the true optimum"), "values": {"sdp:STANDARD": ws[2] * 100}}]
        texts["WONDER_TEXT"] = L(
            "标准档放下了 %d 座奇观中的 %d 座；没放下的 %d 座里，%d 座在城市 3 环内根本没有合法格。连同区域的加成一起，%s 的场景达到真最优，平均质量 %s。",
            "Standard places %d of the %d wonders; of the %d it does not place, %d have no valid tile at all within the city's "
            "3 rings. Counting the districts' adjacency too, it reaches the true optimum in %s of the scenarios, with a mean "
            "quality of %s.") % (
                ((ws[0], ws[1]) if EN else (ws[1], ws[0])) + (ws[1] - ws[0], why["NO_LEGAL_PLOT"], pct(ws[2]), pct(ws[3], 1)))

    # ---------------------------------------------------------------- true optimum (issue 48)
    # Every category against its reference: the proven optimum where the
    # oracle proved one, else the range [best known, upper end] (the oracle
    # cut at its node limit, or the long-run reference for several cities,
    # issue 40). A tier's share of the optimum is at least gain / upper
    # and at most gain / best known; with every scene proven the two agree.
    TIERS = ["sdp:FAST", "sdp:STANDARD", "sdp:FINE"]
    OPT_SETS = [
        ("dev", "single", "单城·开发集", "One city, development set", TIERS),
        ("heldout", "single", "单城·留出集", "One city, held-out set", TIERS),
        ("profile:SCI", "single", "偏科技（科技 ×3）", "Science weighted 3", ["sdp:STANDARD"]),
        ("profile:PROD", "single", "偏生产力（×3）", "Production weighted 3", ["sdp:STANDARD"]),
        ("profile:FAITH", "single", "偏信仰（×3）", "Faith weighted 3", ["sdp:STANDARD"]),
        ("real", "single", "真实存档·单城", "Real saves, one city", TIERS),
        ("large", "single", "大城（9–12 个区域）·开发集", "Large city (9–12 districts), development", TIERS),
        ("large/heldout", "single", "大城·留出集", "Large city, held-out", TIERS),
        ("pools", "single", "从候选里挑·开发集", "Picking from the pool, development", TIERS),
        ("pools/heldout", "single", "从候选里挑·留出集", "Picking from the pool, held-out", TIERS),
        ("wonders", "single", "奇观与区域·开发集", "Wonders with districts, development", ["sdp:STANDARD"]),
        ("wonders/heldout", "single", "奇观与区域·留出集", "Wonders with districts, held-out", ["sdp:STANDARD"]),
        ("smallmulti", "multi", "小多城（2–4 城）·开发集", "Small several cities (2–4), development", TIERS + ["sdp:CITY_BY_CITY"]),
        ("smallmulti/heldout", "multi", "小多城·留出集", "Small several cities, held-out", TIERS + ["sdp:CITY_BY_CITY"]),
        ("dev", "multi", "多城（3–4 城）·开发集", "Several cities (3–4), development", TIERS + ["sdp:CITY_BY_CITY"]),
        ("heldout", "multi", "多城·留出集", "Several cities, held-out", TIERS + ["sdp:CITY_BY_CITY"]),
    ]
    OPT_COLS = TIERS + ["sdp:CITY_BY_CITY"]
    OPT_HEAD = {"sdp:FAST": L("快速", "Fast"), "sdp:STANDARD": L("标准", "Standard"), "sdp:FINE": L("精细", "Thorough"),
                "sdp:CITY_BY_CITY": L("逐城依次", "City by city")}

    def optimum_stats(sub, k):
        """Shares of the reference for tier k over the scenes of `sub` that have a reference."""
        low, known, hit, n, over, fewer = [], [], 0, 0, 0, 0
        for sid, e in sorted(sub.items()):
            r = e["runs"].get(k)
            best = e.get("reference")
            if r is None or best is None:
                continue
            top = e["optimum"] if e.get("optimum") is not None else (e.get("upper") if e.get("upper") is not None else best)
            top = max(top, best)
            g = (r.get("gain") or 0) if (not r.get("error") and r.get("legal")) else 0
            n += 1
            low.append(g / top if top > 0 else (1.0 if g >= 0 else 0.0))
            known.append(g / best if best > 0 else (1.0 if g >= 0 else 0.0))
            if e.get("optimum") is not None and g >= e["optimum"] - 1e-9:
                hit += 1
            if e.get("optimum") is not None and g > e["optimum"] + 1e-9:
                if (r.get("leftOut") or 0) <= (e.get("optimumMissing") or 0):
                    over += 1
                else:
                    fewer += 1
        if not n:
            return None
        return {"n": n, "low": statistics.mean(low), "known": statistics.mean(known), "worst": min(low), "hit": hit, "over": over, "fewer": fewer}

    opt_rows, opt_data, opt_chart = [], {}, []
    for set_name, kind, zh, en, planners in OPT_SETS:
        sub = {sid: e for sid, e in summarize.subset(scenarios, set_name, kind).items() if e.get("reference") is not None}
        if not sub:
            continue
        proven = sum(1 for e in sub.values() if e.get("optimum") is not None)
        ranged = len(sub) - proven
        cells, data = [], {}
        for k in OPT_COLS:
            st = optimum_stats(sub, k) if k in planners else None
            data[k] = st
            if st is None:
                cells.append("—")
            elif ranged == 0:
                cells.append(L("%s · %d 个最优", "%s · %d optimal") % (pct(st["low"], 1), st["hit"]))
            else:
                cells.append(L("%s–%s", "%s–%s") % (pct(st["low"], 0), pct(st["known"], 0)))
        if all(v is None for v in data.values()):
            continue
        opt_data[(set_name, kind)] = {"n": len(sub), "proven": proven, "planners": data}
        st = data.get("sdp:STANDARD")
        if st:
            opt_chart.append({"label": L(zh, en), "low": st["low"] * 100, "known": st["known"] * 100, "ranged": ranged > 0,
                              "tip": (L("%s：标准档平均达到真最优的 %s，%d / %d 个正好是", "%s: Standard reaches %s of the optimum on average, "
                                        "the optimum itself in %d of %d") % (L(zh, en), pct(st["low"], 1), st["hit"], len(sub)))
                              if not ranged else
                              (L("%s：%d 个场景里 %d 个已证明；标准档在真最优的 %s 到 %s 之间",
                                 "%s: %d of %d scenarios proven; Standard is between %s and %s of the optimum")
                               % (((L(zh, en), len(sub), proven) if not EN else (L(zh, en), proven, len(sub)))
                                  + (pct(st["low"], 0), pct(st["known"], 0))))})
        label = L(zh, en)
        prov = L("%d / %d", "%d / %d") % (proven, len(sub))
        opt_rows.append("<tr><td>%s</td><td class=\"num\">%s</td>%s</tr>" % (
            label, prov, "".join("<td class=\"num\">%s</td>" % c for c in cells)))
    texts["OPTIMUM_TABLE"] = (
        '<table class="opt"><thead><tr><th>%s</th><th class="num">%s</th>%s</tr></thead><tbody>%s</tbody></table>' % (
            L("场景", "Scenarios"), L("已证明", "Proven"),
            "".join('<th class="num">%s</th>' % OPT_HEAD[k] for k in OPT_COLS),
            "".join(opt_rows))) if opt_rows else ""
    over_total = sum((st or {}).get("over", 0) for d in opt_data.values() for st in d["planners"].values())
    fewer_total = sum((st or {}).get("fewer", 0) for d in opt_data.values() for st in d["planners"].values())
    # The oracle's own checks over every reference run (cmp_oracle.lua).
    ref_runs = viol = brute_n = brute_ok = climb_n = climb_above = 0
    for r in rows:
        k = summarize.key(r)
        o = summarize.stats_of(r).get("oracle")
        if not summarize.is_adjacency_reference(k) or not isinstance(o, dict) or r.get("error"):
            continue
        ref_runs += 1
        viol += o.get("violations") or 0
        if o.get("brute") is not None:
            brute_n += 1
            brute_ok += 1 if abs(o["brute"] - o["value"]) < 1e-6 else 0
        if o.get("climb") is not None:
            climb_n += 1
            climb_above += 1 if o["climb"] > o["value"] + 1e-6 else 0
    texts["ORACLE_CHECK_TEXT"] = L(
        "每个精确评估过的方案都检查不超过它的上界，超过就不算证明（%d 次运行里超过 %d 次）；布局不超过 40 万种的 %d 个场景另把全部布局逐一算过，"
        "%d 个与真最优相同；%d 个场景另做 8 次不依赖上界的爬山，超过真最优的 %d 个。",
        "every plan evaluated exactly is checked against its bound, and one above it voids the proof (%d runs, %d above); in %d "
        "scenarios of at most 400,000 layouts every layout was also tried, and %d agree with the optimum; in %d scenarios 8 hill "
        "climbs that do not use the bound were run as well, and %d went above the optimum.") % (
            ref_runs, viol, brute_n, brute_ok, climb_n, climb_above)
    pl = [opt_data.get(("pools", "single")), opt_data.get(("pools/heldout", "single"))]
    pl = [d for d in pl if d]
    texts["POOLS_OPT_TEXT"] = ""
    if pl and all(d["planners"].get(k) for d in pl for k in TIERS):
        n_ = sum(d["n"] for d in pl)
        pr_ = sum(d["proven"] for d in pl)

        def avg(k):
            return sum(d["planners"][k]["low"] * d["n"] for d in pl) / n_

        def hits(k):
            return sum(d["planners"][k]["hit"] for d in pl)
        texts["POOLS_OPT_TEXT"] = L(
            "离线评估另有 %d 个从候选里挑的场景（开发集 P、留出集 HP：中期一座城必建学院、商业中心，再从剧院广场、工业区、娱乐中心和港口或军营里挑 2 或 3 个），"
            "真最优对每种组合各做一次分支定界，%d 个已证明：快速档平均达到真最优的 %s（%d 个正好是），标准档 %s（%d 个），精细档 %s（%d 个）。",
            "The offline evaluation also has %d picking scenarios (development set P, held-out set HP: a mid-game city must have a "
            "Campus and a Commercial Hub and picks 2 or 3 more from a Theater Square, an Industrial Zone, an Entertainment Complex "
            "and a Harbor or Encampment); the optimum runs the branch and bound once for every combination, and %d are proven: "
            "Fast reaches %s of the optimum on average (the optimum itself in %d), Standard %s (%d), Thorough %s (%d).") % (
                n_, pr_, pct(avg("sdp:FAST"), 1), hits("sdp:FAST"), pct(avg("sdp:STANDARD"), 1), hits("sdp:STANDARD"),
                pct(avg("sdp:FINE"), 1), hits("sdp:FINE"))
    land_path = os.path.join(REPO, "tests", "compare", "results", "land_oracle.jsonl")
    n_land = 0
    if os.path.exists(land_path):
        for line in open(land_path, encoding="utf-8"):
            if line.strip() and (json.loads(line).get("plan") or {}).get("stats", {}).get("oracle", {}).get("proven"):
                n_land += 1
    texts["N_LAND_ORACLE"] = str(n_land)
    proven_all = sum(d["proven"] for d in opt_data.values())
    n_all = sum(d["n"] for d in opt_data.values())
    texts["OPTIMUM_TEXT"] = L(
        "下表按场景类别列出各档的加成占真最优的比例：平均百分之几，以及正好是真最优的场景数。%d 个场景里 %d 个的真最优已证明；"
        "没证明的（多是 10–12 个区域的大城，以及 3–4 座城的多城）给的是范围：前一个数按真最优的上界算，是比例的下限，后一个数按已知最好的方案算。"
        "%s",
        "The table sets each effort level's adjacency against the true optimum in every kind of scenario: the mean share of the "
        "optimum and the number of scenarios at the optimum itself. Of %d scenarios, %d have a proven optimum; for the others "
        "(mostly large cities of 10–12 districts, and 3–4 cities together) the table gives a range: the first number is against the "
        "optimum's upper bound, a floor of the share, the second against the best plan known. %s") % (
        n_all, proven_all,
        (L("把要求的区域和奇观都放下的合法方案，没有一个超过证明过的真最优",
           "No valid plan that places all the districts and wonders asked for is above a proven optimum")
         if over_total == 0 else
         L("把要求的区域和奇观都放下的合法方案超过证明过的真最优 %d 次",
           "Valid plans that place all the districts and wonders asked for are above a proven optimum %d times") % over_total)
        + ((L("；少放了奇观或区域的方案有 %d 个高于它（解的是更容易的问题，表里按实际加成计）。",
              "; plans that leave out a wonder or a district are above it in %d scenario%s (an easier problem; the table "
              "counts their actual adjacency).") % ((fewer_total, "" if fewer_total == 1 else "s") if EN else (fewer_total,)))
           if fewer_total else L("。", ".")))
    texts["OPTIMUM_NOTE"] = L(
        "真最优的求法：在本模组搜索用的候选格和合法性上做分支定界，上界 = 每个区域单独的值 + 相邻区域两两的配对值，配对值取 DMT "
        "在那两格上的实测和查表里大的一个，凑满几个邻居才给加成的规则按份额计。每个算过的方案都检查不超过它的上界，超过就不算证明；"
        "小场景与逐一枚举全部方案对照，另有不依赖上界的爬山检查。大城的“已知最好”是所有离线运行和分支定界找到的最好方案，"
        "多城的是精细档再继续优化 20 次、模拟退火 20 万次后由分支定界接着改进的结果（附录 B.1）。",
        "How the optimum is found: branch and bound over the candidate tiles and validity rules this mod's search uses; the "
        "upper bound is each district's value alone plus every two neighbouring districts' pair value, the larger of DMT's "
        "measured value on those two tiles and the rules table, with rules that need several neighbours counted by their "
        "share. Every plan evaluated is checked against its bound, and one above it voids the proof; small scenarios are "
        "checked against trying every layout, and a hill climb that does not use the bound checks the rest. The best known "
        "plan of a large city is the best of every offline run and the branch and bound; that of several cities is the Thorough "
        "plan continued 20 times, then 200,000 steps of simulated annealing, then improved by the branch and bound "
        "(appendix B.1).")

    # ---------------------------------------------------------------- quality summary (section 4) and hero
    def cap1(t):
        return t[:1].upper() + t[1:]

    dv, hd = opt_data.get(("dev", "single")), opt_data.get(("heldout", "single"))
    sm = opt_data.get(("smallmulti", "multi"))
    texts["QUALITY_TEXT"] = ""
    if dv and dv["proven"] == dv["n"] and dv["planners"].get("sdp:STANDARD"):
        s_ = dv["planners"]["sdp:STANDARD"]
        parts = [L("%d 个单城场景的真最优都已求出并证明：标准档平均达到真最优的 %s，%d 个场景正好是真最优；%s",
                   "In %d one-city scenarios every true optimum was found and proven: Standard reaches %s "
                   "of it on average and the optimum itself in %d scenarios; %s") % (dv["n"], pct(s_["low"], 1), s_["hit"], sd_claim)]
        if hd and hd["proven"] == hd["n"] and hd["planners"].get("sdp:STANDARD"):
            parts.append(L("开发时没用过的留出集上平均达到 %s", "on held-out maps not used during development it reaches %s on average")
                         % pct(hd["planners"]["sdp:STANDARD"]["low"], 1))
        if sm and sm["proven"] == sm["n"] and sm["planners"].get("sdp:STANDARD"):
            parts.append(L("2–4 座城一起规划的 %d 个场景里 %d 个正好是真最优", "planning 2–4 cities together it reaches the optimum itself in %d of %d scenarios")
                         % ((sm["n"], sm["planners"]["sdp:STANDARD"]["hit"]) if not EN else (sm["planners"]["sdp:STANDARD"]["hit"], sm["n"])))
        if "sdp:STANDARD" in wnum:
            parts.append(L("与区域一起放奇观，放下 %d / %d 座", "placing wonders together with districts, it places %d of %d wonders")
                         % wnum["sdp:STANDARD"][:2])
        texts["QUALITY_TEXT"] = (". ".join(cap1(p) for p in parts) + ".") if EN else ("；".join(parts) + "。")
    hero = []
    if dv and dv["planners"].get("sdp:STANDARD"):
        s_ = dv["planners"]["sdp:STANDARD"]
        hero.append({"value": pct(s_["low"], 1), "label": L(
            "单城场景平均达到真最优的比例（标准档；%d 个场景的真最优都已证明，%d 个正好是）",
            "of the true optimum on average in one-city scenarios (Standard effort; all %d optima proven, %d reached exactly)")
            % (dv["n"], s_["hit"])})
    if sm and sm["planners"].get("sdp:STANDARD"):
        hero.append({"value": "%d / %d" % (sm["planners"]["sdp:STANDARD"]["hit"], sm["n"]), "label": L(
            "2–4 座城一起规划，标准档正好达到真最优的场景", "scenarios with 2–4 cities planned together at the true optimum (Standard)")})
    hero += [
        {"value": L("0 违规", "0 violations"), "label": L("方案全部合法，不压玩家的钉，同输入同结果",
                                                        "every plan valid, no tack of the player overwritten, same input, same plan")},
        {"value": L("0.25 秒", "0.25 s"), "label": L("游戏内单城 6 个区域（标准档）", "one city, 6 districts, in the game (Standard effort)")},
    ]

    # ---------------------------------------------------------------- results table (section 4)
    def tr(cells):
        return "<tr>" + "".join("<td>%s</td>" % c for c in cells) + "</tr>"

    def grp(anchor, title):
        return '<tr class="grp"><td colspan="3"><a href="#%s">%s</a></td></tr>' % (anchor, title)
    srows = [grp("e-single", L("B.2 单城", "B.2 One city"))]
    if sd:
        srows.append(tr([L("相邻加成", "Adjacency"), L("开发集 %d", "development set, %d") % sd["n"],
                         L("达到真最优：", "at the true optimum: ") + L("、", ", ").join(
                             L("%s %s", "%s %s") % (OPT_HEAD[k], pct(S[k]["best"])) for k in main_series)]))
        srows.append(tr([L("合法与完整", "Valid and complete"), "%d" % sd["n"],
                         L("零违规、能放的都放了", "no violation, every district that fits placed") if sd_clean and sd["missingPlaceable"] == 0
                         else L("见 B.2", "see B.2")]))
    rg = {g["key"]: g["values"] for g in robust_groups}
    if "heldout" in rg:
        srows.append(tr([L("换地图", "Other maps"), L("留出集 %d", "held-out set, %d") % len(summarize.subset(scenarios, "heldout", "single")),
                         L("达到真最优：标准档 %.0f%%", "at the true optimum: Standard %.0f%%") % rg["heldout"].get("sdp:STANDARD", 0)]))
    prof = [g for g in robust_groups if g["key"].startswith("profile:")]
    if prof:
        srows.append(tr([L("换权重", "Other weights"), "3 × %d" % len(single),
                         L("达到真最优：标准档 %.0f%%–%.0f%%", "at the true optimum: Standard %.0f%%–%.0f%%") % (
                             min(g["values"]["sdp:STANDARD"] for g in prof), max(g["values"]["sdp:STANDARD"] for g in prof))]))
    srows.append(grp("e-multi", L("B.3 多城", "B.3 Several cities")))
    if M.get("sdp:STANDARD"):
        srows.append(tr([L("联合规划", "Joint planning"), L("开发集 %d", "development set, %d") % len(multi),
                         L("平均达到参照的：标准档 %s", "average share of the reference: Standard %s") % pct(M["sdp:STANDARD"]["quality"])
                         + ((L("；逐城依次规划 %s", "; city by city %s") % pct(M["sdp:CITY_BY_CITY"]["quality"])) if M.get("sdp:CITY_BY_CITY") else "")]))
    if hom.get("sdp:STANDARD") is not None:
        srows.append(tr([L("换地图", "Other maps"), L("留出集 %d", "held-out set, %d") % len(summarize.subset(scenarios, "heldout", "multi")),
                         L("达到参照：标准档 %s", "at the reference: Standard %s") % pct(hom["sdp:STANDARD"])]))
    if cov_summary:
        srows.append(tr([L("覆盖范围", "Coverage"), "%d" % cov_summary["n"], L(
            "有取舍余地的 %d 个场景里，覆盖权重 1 时 %d 个多覆盖了城市",
            "of the %d scenarios that leave room for it, coverage weight 1 covers more cities in %d") % (cov_summary["room"], cov_summary["more1"])]))
    if "sdp:STANDARD" in wnum:
        srows.append(grp("e-wonders", L("B.4 奇观", "B.4 Wonders")))
        srows.append(tr([L("奇观与区域", "Wonders with districts"), "%d" % len(wsub),
                         L("放下的奇观 %d/%d；达到真最优 %s", "wonders placed %d/%d; at the true optimum %s") % (
                             wnum["sdp:STANDARD"][0], wnum["sdp:STANDARD"][1], pct(wnum["sdp:STANDARD"][2]))]))
    srows.append(grp("e-pools", L("B.5 从候选里挑", "B.5 Picking from the pool")))
    srows.append(tr([L("单城挑选", "One city"), L("4 种情形 × 4", "4 cases × 4"),
                     L("标准档 16 个全部挑中最好的组合，约 0.4–1.0 秒；快速档平均 98%",
                       "Standard picks the best combination in all 16, in about 0.4–1.0 s; Fast 98% on average")]))
    srows.append(tr(MULTIPOOLS_ROW_EN if EN else MULTIPOOLS_ROW))
    srows.append(grp("e-tests", L("速度（第 4 节）· B.6 本模组自身的测试", "Speed (section 4) · B.6 This mod's own tests")))
    srows.append(tr([L("速度", "Speed"), L("游戏内实测", "measured in the game"),
                     L("单城不到 0.3 秒，3 城联合约 3 秒", "one city under 0.3 s, three cities together about 3 s")]))
    srows.append(tr([L("自身的测试", "Own tests"), L("游戏内 103 项、离线 121 项、真实点击 34 项", "103 in the game, 121 offline, 34 real clicks"),
                     L("全部通过；裁判与游戏引擎逐格一致（沉船一处已知偏差）；魅力逐格校准",
                       "all pass; the judge agrees with the game engine tile by tile (one known difference, at a shipwreck); Appeal "
                       "calibrated tile by tile")]))
    stress_text, stress_table, stress_row = stress_section(lang=lang)
    texts["STRESS_TEXT"], texts["STRESS_TABLE"] = stress_text, stress_table
    if stress_row:
        srows.append(grp("e-stress", L("B.7 后期存档压力测试", "B.7 Late-game saves")))
        srows.append(tr(stress_row))
    texts["EVAL_SUMMARY"] = ('<table><thead><tr><th>%s</th><th>%s</th><th>%s</th></tr></thead><tbody>%s</tbody></table>' % (
        L("实验", "Experiment"), L("场景", "Scenarios"), L("结论", "Result"), "".join(srows)))

    texts["N_HS"] = str(len(summarize.subset(scenarios, "heldout", "single")))
    texts["N_HM"] = str(len(summarize.subset(scenarios, "heldout", "multi")))
    texts["N_W"] = str(len(wsub))
    texts["N_ALL"] = str(len(single) + len(multi) + int(texts["N_HS"]) + int(texts["N_HM"]) + 3 * len(single) + len(wsub) + len(vsub))

    data = {
        "lang": lang, "words": CHART_WORDS[lang], "hero": hero, "planners": PL, "mainSeries": main_series, "overview": overview,
        "byStage": {"best": by_best, "quality": by_q, "qMin": qmin, "qTicks": qticks},
        "correct": correct, "robust": robust_rows, "robustGroups": robust_groups, "robustMultiGroups": robust_multi_groups,
        "coverage": coverage, "wonders": wonder_rows, "wonderGroups": wonder_groups,
        "optimum": opt_chart,
        "strip": {"rows": strip, "min": mmin, "max": 100, "ticks": list(range(mmin, 101, 10))},
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
