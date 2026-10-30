#!/usr/bin/env python3
"""refmaps.py - pictures and tables of the reference scenes (issue 53).

For each reference scene (tests/compare/scenes/REF*.json, REF04 on by
default) one SVG picture: the chosen cities' 3-ring area with terrain,
features, resources, rivers, borders and everything that stays fixed, drawn
two or three times side by side:

  1. the author's layout (scene reference.placements), with the judge's
     adjacency per district;
  2. the proven optimum with adjacency only, all weights 1 (sdp:ORACLE row of
     results/refscore.jsonl, weights "all1");
  3. the proven optimum of the mod's whole objective at all weights 1 and
     land coefficient 1 (sdp:ORACLE_LAND100 row "all1-L100" of
     results/refgrid53.jsonl), only when it differs from 2.

North is up, as in the game (y grows to the north; other pictures in the
repository put row 0 on top, which mirrors them). Nothing is recomputed: the
numbers come from the result files.

  python3 -I tests/compare/refmaps.py                    # docs/images/refscenes/<id>.svg + legend.svg
  python3 -I tests/compare/refmaps.py REF15 REF16        # only these (prefix match)
  python3 -I tests/compare/refmaps.py --tables           # also print the Markdown tables of
                                                         # docs/reference-scenes.md
  python3 -I tests/compare/refmaps.py --out DIR
  python3 -I tests/compare/refmaps.py --workshop         # workshop/src/i1-ref12[-en].svg, i2-ref06[-en].svg:
                                                         # the Workshop description's pictures (player's layout
                                                         # and the Standard plan, zh and en; see render_workshop)

Python 3.8, standard library only.
"""

import glob
import hashlib
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "docs", "images", "refscenes")
SQ3 = math.sqrt(3)
S = 24          # hex size: centre to corner, px
GAP = 28        # between panels
TITLE_H = 58    # panel title band: a title and up to two note lines
MAX_W = 1000    # wrap panels to keep the picture readable at page width

# Short Chinese labels (the game's zh_Hans_CN names, shortened) and colours.
DISTRICT = {
    "DISTRICT_CAMPUS": ("学", "#3d7fd9", "#ffffff"),
    "DISTRICT_HOLY_SITE": ("圣", "#f1e3a0", "#3a3000"),
    "DISTRICT_THEATER": ("剧", "#9457b5", "#ffffff"),
    "DISTRICT_COMMERCIAL_HUB": ("商", "#e3a41f", "#2a1d00"),
    "DISTRICT_HARBOR": ("港", "#178fa6", "#ffffff"),
    "DISTRICT_INDUSTRIAL_ZONE": ("工", "#c5622a", "#ffffff"),
}
FIXED = {
    "DISTRICT_ENTERTAINMENT_COMPLEX": "娱", "DISTRICT_WATER_ENTERTAINMENT_COMPLEX": "水",
    "DISTRICT_ENCAMPMENT": "军", "DISTRICT_GOVERNMENT": "政", "DISTRICT_AQUEDUCT": "渠", "DISTRICT_BATH": "渠",
    "DISTRICT_DAM": "坝", "DISTRICT_CANAL": "运", "DISTRICT_NEIGHBORHOOD": "社", "DISTRICT_AERODROME": "机",
    "DISTRICT_SPACEPORT": "航", "DISTRICT_PRESERVE": "保", "DISTRICT_DIPLOMATIC_QUARTER": "外",
    "DISTRICT_WONDER": "奇", "DISTRICT_CAMPUS": "学", "DISTRICT_HOLY_SITE": "圣", "DISTRICT_THEATER": "剧",
    "DISTRICT_COMMERCIAL_HUB": "商", "DISTRICT_HARBOR": "港", "DISTRICT_INDUSTRIAL_ZONE": "工",
    "DISTRICT_CITY_CENTER": "城",
}
TERRAIN = {  # base, hills
    "GRASS": ("#a9d07c", "#8ab45a"), "PLAINS": ("#dccd80", "#c1ae5a"), "DESERT": ("#efe1ad", "#d8c387"),
    "TUNDRA": ("#bdb8a0", "#a29c80"), "SNOW": ("#f3f5f6", "#dde2e5"),
}
MOUNTAIN, COAST, OCEAN, LAKE, HIDDEN = "#8a8077", "#a6d4ec", "#6198c6", "#5fb3c4", "#5a5a5a"
FEATURE = {  # label, colour
    "FEATURE_FOREST": ("林", "#1f6b2a"), "FEATURE_JUNGLE": ("雨", "#0f4f2e"), "FEATURE_MARSH": ("沼", "#2c6f73"),
    "FEATURE_FLOODPLAINS": ("泛", "#7a5a1e"), "FEATURE_FLOODPLAINS_GRASSLAND": ("泛", "#7a5a1e"),
    "FEATURE_FLOODPLAINS_PLAINS": ("泛", "#7a5a1e"), "FEATURE_REEF": ("礁", "#b0457a"),
    "FEATURE_OASIS": ("洲", "#1d6fb0"), "FEATURE_VOLCANIC_SOIL": ("土", "#6b3a2a"),
    "FEATURE_VOLCANO": ("火", "#b3261e"), "FEATURE_GEOTHERMAL_FISSURE": ("热", "#b3261e"),
    "FEATURE_ICE": ("冰", "#6b7f8c"),
}
NATURAL_WONDER = "景"
RESOURCE = {
    "ALUMINUM": "铝", "ANTIQUITY_SITE": "古迹", "BANANAS": "香蕉", "CATTLE": "牛", "CITRUS": "柑橘", "COAL": "煤",
    "COCOA": "可可", "COFFEE": "咖啡", "COPPER": "铜", "COTTON": "棉花", "CRABS": "螃蟹", "DEER": "鹿",
    "DIAMONDS": "钻石", "DYES": "染料", "FISH": "鱼", "FURS": "皮草", "GYPSUM": "石膏", "HORSES": "马",
    "INCENSE": "熏香", "IRON": "铁", "IVORY": "象牙", "JADE": "玉", "MARBLE": "大理石", "MERCURY": "水银",
    "NITER": "硝石", "OIL": "石油", "OLIVES": "橄榄", "PEARLS": "珍珠", "RICE": "大米", "SALT": "盐",
    "SHEEP": "羊", "SHIPWRECK": "海难", "SILK": "丝绸", "SILVER": "银", "SPICES": "香料", "STONE": "石头",
    "SUGAR": "糖", "TEA": "茶叶", "TOBACCO": "烟草", "TRUFFLES": "松露", "TURTLES": "海龟", "URANIUM": "铀",
    "WHALES": "鲸鱼", "WHEAT": "小麦", "WINE": "葡萄酒", "AMBER": "琥珀", "HONEY": "蜂蜜",
}
STRATEGIC = {"ALUMINUM", "COAL", "HORSES", "IRON", "NITER", "OIL", "URANIUM"}
LUXURY = {"CITRUS", "COCOA", "COFFEE", "COTTON", "DIAMONDS", "DYES", "FURS", "GYPSUM", "INCENSE", "IVORY", "JADE",
          "MARBLE", "MERCURY", "OLIVES", "PEARLS", "SALT", "SILK", "SILVER", "SPICES", "SUGAR", "TEA", "TOBACCO",
          "TRUFFLES", "TURTLES", "WHALES", "WINE", "AMBER", "HONEY"}
RIVER, BORDER, CHANGED = "#1f62c9", "#2b2b2b", "#d0021b"
FONT = "'Noto Sans SC','PingFang SC','Microsoft YaHei','Hiragino Sans GB',sans-serif"

# Some city names come out of the game's export with broken characters; the
# game's own zh_Hans_CN names (LOC_CITY_NAME_*).
CITY_NAME = {
    "REF05-bh-japan-tokyo-shizuoka/327684": "静冈",
    "REF16-vi-maori-south-3c/196610": "纳鲁阿瓦希亚", "REF16-vi-maori-south-3c/262147": "华卡雷瓦雷瓦",
    "REF16-vi-maori-south-3c/458758": "卡皮蒂", "REF18-vi-maori-capital/65536": "特赫基昂加-努伊-阿-库珀",
    "REF20-ga-rome-puteoli/262147": "普提奥利",
}


def cube(x, y):
    return x - (y - (y & 1)) // 2, y


def dist(a, b):
    q1, r1 = cube(*a)
    q2, r2 = cube(*b)
    dq, dr = q1 - q2, r1 - r2
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def corners(cx, cy, s):
    return [(cx + s * math.cos(math.radians(60 * i - 30)), cy + s * math.sin(math.radians(60 * i - 30)))
            for i in range(6)]


def pts(points):
    return " ".join("%.1f,%.1f" % p for p in points)


def esc(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def num(v):
    if v is None:
        return "-"
    return ("%d" % v) if abs(v - round(v)) < 1e-9 else ("%.2f" % v).rstrip("0")


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
def load_rows(path, keep):
    rows = {}
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                if keep(r):
                    rows[(r["scenario"], r["weights"]["name"])] = r
    return rows


def load_all(prefixes):
    scenes = []
    for path in sorted(glob.glob(os.path.join(HERE, "scenes", "REF*.json"))):
        with open(path, encoding="utf-8") as f:
            spec = json.load(f)
        sid = spec["scenario"]["id"]
        if prefixes:
            if not any(sid.startswith(p) for p in prefixes):
                continue
        elif sid < "REF04":
            continue
        scenes.append(spec)
    refscore = load_rows(os.path.join(HERE, "results", "refscore.jsonl"), lambda r: r.get("mode") == "refscore")
    grid = load_rows(os.path.join(HERE, "results", "refgrid53.jsonl"),
                     lambda r: r.get("mode") == "refscore" and r.get("objective") == "sdp")
    return scenes, refscore, grid


def check_group(all_ids, author_of):
    """refgrid53.py's split: authors by SHA-1 of the name, the check group
    takes them in that order while it stays within a third of the scenes."""
    count = {}
    for s in all_ids:
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


def city_name(sid, city):
    return CITY_NAME.get("%s/%d" % (sid, city["id"]), city["name"])


# ---------------------------------------------------------------------------
# Picture
# ---------------------------------------------------------------------------
def same_plan(a, b):
    key = lambda p: sorted((i["city"], i["type"], i["x"], i["y"]) for i in p)  # noqa: E731
    return key(a) == key(b)


def panels_for(spec, refscore, grid):
    sid = spec["scenario"]["id"]
    ref_row = refscore.get((sid, "all1"))
    land_row = grid.get((sid, "all1-L100"))
    ref_items = (ref_row or {}).get("reference", {}).get("items") or [
        dict(p, adj=None) for p in spec["reference"]["placements"]]
    pins = {(p["city"], p["type"], p["x"], p["y"]) for p in spec["reference"]["placements"] if p.get("pin")}
    for it in ref_items:
        it["pin"] = (it["city"], it["type"], it["x"], it["y"]) in pins
    skipped = {(p["city"], p["type"], p["x"], p["y"])
               for p in ((land_row or {}).get("summary", {}).get("referenceSkipped") or [])}
    for it in ref_items:
        it["skipped"] = (it["city"], it["type"], it["x"], it["y"]) in skipped
    # The judge's gain: the layout's own adjacency plus what it adds to the
    # districts that stay (a Japanese district next to them, say).
    gain = lambda part, items: num(part["gain"]) if part else num(sum(i.get("adj") or 0 for i in items))  # noqa: E731
    panels = [{"title": "作者布局 · 相邻 %s" % gain((ref_row or {}).get("reference"), ref_items),
               "items": ref_items, "ref": True}]
    tie = lambda row: bool(row and row["summary"].get("referenceOptimal"))  # noqa: E731
    if ref_row:
        opt = ref_row["optimum"]["items"]
        panels.append({"title": "真最优（只算相邻）· 相邻 %s" % gain(ref_row["optimum"], opt), "items": opt,
                       "notes": ["只算相邻加成，全 1" + ("，与作者布局同分" if tie(ref_row) else "")]})
    if land_row:
        land = land_row["optimum"]["items"]
        land_note = "，与作者布局同分" if tie(land_row) else ""
        if ref_row and same_plan(land, ref_row["optimum"]["items"]):
            panels[-1]["notes"].append("计入地块（λ = 1）的真最优相同" + land_note)
        else:
            panels.append({"title": "真最优（计入地块 λ=1）· 相邻 %s" % gain(land_row["optimum"], land),
                           "items": land, "notes": ["相邻 + 地块 + 住房，全 1、λ = 1" + land_note]})
    building = any(c.get("complete") is False for c in spec["reference"].get("claimed", []))
    panels[0]["notes"] = ["作者已建%s的区域" % ("和在建" if building else "")]
    if any(i["pin"] for i in ref_items):
        panels[0]["notes"].append("虚线框是作者打的钉")
    return panels


def render(spec, panels):
    sc = spec["scenario"]
    W = spec["width"]
    plots = spec["plots"]
    chosen = [c for c in spec["cities"] if c["owner"] == 0 and c["id"] in sc["only"]]
    chosen.sort(key=lambda c: sc["only"].index(c["id"]))
    number = {c["id"]: i + 1 for i, c in enumerate(chosen)} if len(chosen) > 1 else {}
    centres = [(c["x"], c["y"]) for c in chosen]
    area = [(i % W, i // W) for i in range(len(plots)) if any(dist((i % W, i // W), c) <= 3 for c in centres)]
    area_set = set(area)
    owner = {}
    for c in spec["cities"]:
        for i in c.get("plots", []):
            owner[i] = (c["owner"], c["id"])
    chosen_keys = {(0, c["id"]) for c in chosen}
    ymax = max(y for _, y in area)

    def pos(x, y):  # north up
        return SQ3 * S * (x + 0.5 * (y & 1)), 1.5 * S * (ymax - y)

    xs = [pos(*xy)[0] for xy in area]
    ys = [pos(*xy)[1] for xy in area]
    minx, maxx = min(xs) - SQ3 * S / 2 - 2, max(xs) + SQ3 * S / 2 + 2
    miny, maxy = min(ys) - S - 2, max(ys) + S + 2
    pw, ph = maxx - minx, maxy - miny
    cols = max(1, min(len(panels), int((MAX_W + GAP) // (pw + GAP))))
    rows = (len(panels) + cols - 1) // cols
    width = cols * pw + (cols - 1) * GAP
    height = rows * (ph + TITLE_H) + (rows - 1) * 12

    # Fixed things, the same in every panel.
    fixed = {}
    for c in spec["cities"]:
        xy = (c["x"], c["y"])
        if c["owner"] == 0 and c["id"] in sc["only"]:
            fixed[xy] = ("city", "城%s" % (number.get(c["id"], "")))
        else:
            fixed[xy] = ("othercity", "城" if c["owner"] == 0 else "外")
        for d in c["districts"]:
            fixed[(d["x"], d["y"])] = ("fixed", FIXED.get(d["type"], "区"))
    for w in spec.get("wonders", []):
        fixed.setdefault((w["x"], w["y"]), ("fixed", "奇"))
    for p in spec.get("pins", []):
        icon = p.get("icon") or ""
        key = "DISTRICT_" + icon[len("ICON_DISTRICT_"):] if icon.startswith("ICON_DISTRICT_") else None
        fixed.setdefault((p["x"], p["y"]), ("tack", FIXED.get(key, "钉")))

    rivers = []
    for r in spec.get("rivers", []):
        for a, b in r["edges"]:
            rivers.append(((a % W, a // W), (b % W, b // W)))

    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %.1f %.1f" '
           'font-family="%s">' % (math.ceil(width), math.ceil(height), width, height, FONT)]
    out.append('<rect width="100%" height="100%" fill="#ffffff"/>')
    out.append('<defs><pattern id="foreign" width="6" height="6" patternUnits="userSpaceOnUse" '
               'patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" stroke="#ffffff" '
               'stroke-width="2.2" stroke-opacity="0.75"/></pattern></defs>')
    for n, panel in enumerate(panels):
        col, row = n % cols, n // cols
        ox = col * (pw + GAP) - minx
        oy = row * (ph + TITLE_H + 12) + TITLE_H - miny
        out.append('<g>')
        out.append('<text x="%.1f" y="%.1f" font-size="15" font-weight="700" fill="#14202a">%s</text>'
                   % (col * (pw + GAP) + 2, row * (ph + TITLE_H + 12) + 19, esc(panel["title"])))
        for k, note in enumerate(panel.get("notes", [])):
            out.append('<text x="%.1f" y="%.1f" font-size="12" fill="#555555">%s</text>'
                       % (col * (pw + GAP) + 2, row * (ph + TITLE_H + 12) + 36 + 15 * k, esc(note)))
        placed = {(i["x"], i["y"]): i for i in panel["items"]}
        ref_set = {(i["city"], i["type"], i["x"], i["y"]) for i in panels[0]["items"]}
        for xy in sorted(area, key=lambda a: (-a[1], a[0])):
            p = plots[xy[1] * W + xy[0]]
            cx, cy = pos(*xy)
            cx, cy = cx + ox, cy + oy
            t = p["t"]
            if p.get("hidden"):
                fill = HIDDEN
            elif t == "TERRAIN_OCEAN":
                fill = OCEAN
            elif t == "TERRAIN_COAST":
                fill = LAKE if p.get("lake") else COAST
            elif t.endswith("_MOUNTAIN"):
                fill = MOUNTAIN
            else:
                base = t.replace("TERRAIN_", "").replace("_HILLS", "")
                fill = TERRAIN.get(base, TERRAIN["GRASS"])[1 if t.endswith("_HILLS") else 0]
            out.append('<polygon points="%s" fill="%s" stroke="#6b6b6b" stroke-width="0.7"/>'
                       % (pts(corners(cx, cy, S)), fill))
            own = owner.get(xy[1] * W + xy[0])
            if own and own not in chosen_keys and not p.get("hidden"):
                out.append('<polygon points="%s" fill="#ffffff" fill-opacity="0.5"/>' % pts(corners(cx, cy, S - 0.4)))
                if own[0] != 0:
                    out.append('<polygon points="%s" fill="url(#foreign)"/>' % pts(corners(cx, cy, S - 0.4)))
            if p.get("hidden"):
                out.append('<text x="%.1f" y="%.1f" font-size="14" fill="#dddddd" text-anchor="middle">?</text>'
                           % (cx, cy + 5))
                continue
            if t.endswith("_HILLS"):
                out.append('<path d="M%.1f,%.1f q%.1f,-%.1f %.1f,0" fill="none" stroke="#4d3f22" '
                           'stroke-width="1.4"/>' % (cx - 8, cy + 20.5, 8, 5, 16))
            f = p.get("f")
            feat = FEATURE.get(f) if f else None
            if f and not feat:
                feat = (NATURAL_WONDER, "#7a2f8f")
            res = p.get("r")
            res_label = RESOURCE.get(res[len("RESOURCE_"):], res[len("RESOURCE_"):].title()) if res else None
            item = placed.get(xy)
            fx = fixed.get(xy)
            middle = item is not None or fx is not None
            top = []
            if feat and middle:
                top.append(('<tspan fill="%s" font-weight="700">%s</tspan>' % (feat[1], feat[0])))
            if res_label:
                kind = res[len("RESOURCE_"):]
                colour = "#8a1c1c" if kind in STRATEGIC else ("#5b2a86" if kind in LUXURY else "#1b3a4b")
                top.append('<tspan fill="%s">%s</tspan>' % (colour, esc(res_label)))
            if top:
                out.append('<text x="%.1f" y="%.1f" font-size="8.5" text-anchor="middle">%s</text>'
                           % (cx, cy - 8.5, " ".join(top)))
            if not middle:
                if feat:
                    out.append('<text x="%.1f" y="%.1f" font-size="13" font-weight="700" fill="%s" '
                               'text-anchor="middle">%s</text>' % (cx, cy + 8, feat[1], feat[0]))
                elif t.endswith("_MOUNTAIN"):
                    out.append('<text x="%.1f" y="%.1f" font-size="12" fill="#3d362f" text-anchor="middle">▲</text>'
                               % (cx, cy + 8))
                continue
            if item is not None and (fx is None or fx[0] in ("tack",)):
                label, bg, fg = DISTRICT.get(item["type"], (FIXED.get(item["type"], "区"), "#cccccc", "#222222"))
                if item["city"] in number:
                    label += str(number[item["city"]])
                changed = not panel.get("ref") and (item["city"], item["type"], item["x"], item["y"]) not in ref_set
                dash = ' stroke-dasharray="4,2.5" fill-opacity="0.55"' if item.get("pin") else ""
                stroke, sw = (CHANGED, 2.6) if changed else ("#1a1a1a", 2 if item.get("pin") else 1.2)
                out.append('<polygon points="%s" fill="%s" stroke="%s" stroke-width="%.1f"%s/>'
                           % (pts(corners(cx, cy, S - 4.5)), bg, stroke, sw, dash))
                out.append('<text x="%.1f" y="%.1f" font-size="13" font-weight="700" fill="%s" '
                           'text-anchor="middle">%s</text>' % (cx, cy + 5, fg, esc(label)))
                if item.get("adj") is not None:
                    adj = "不计" if item.get("skipped") else "+%s" % num(item["adj"])
                    out.append('<text x="%.1f" y="%.1f" font-size="9.5" font-weight="700" fill="%s" '
                               'text-anchor="middle">%s</text>' % (cx, cy + 15.5, fg, adj))
            else:
                kind, label = fx
                if kind == "city":
                    out.append('<polygon points="%s" fill="#ffffff" stroke="#111111" stroke-width="2"/>'
                               % pts(corners(cx, cy, S - 4.5)))
                    out.append('<text x="%.1f" y="%.1f" font-size="12" font-weight="700" fill="#111111" '
                               'text-anchor="middle">%s</text>' % (cx, cy + 4.5, esc(label)))
                elif kind == "othercity":
                    out.append('<polygon points="%s" fill="#e6e6e6" stroke="#555555" stroke-width="1.2"/>'
                               % pts(corners(cx, cy, S - 4.5)))
                    out.append('<text x="%.1f" y="%.1f" font-size="12" fill="#333333" text-anchor="middle">%s</text>'
                               % (cx, cy + 4.5, esc(label)))
                elif kind == "tack":
                    out.append('<polygon points="%s" fill="none" stroke="#333333" stroke-width="1.2" '
                               'stroke-dasharray="2,2"/>' % pts(corners(cx, cy, S - 4.5)))
                    out.append('<text x="%.1f" y="%.1f" font-size="11" fill="#333333" text-anchor="middle">%s</text>'
                               % (cx, cy + 4.5, esc(label)))
                else:
                    out.append('<polygon points="%s" fill="#cfcfcf" stroke="#555555" stroke-width="1"/>'
                               % pts(corners(cx, cy, S - 4.5)))
                    out.append('<text x="%.1f" y="%.1f" font-size="12" fill="#333333" text-anchor="middle">%s</text>'
                               % (cx, cy + 4.5, esc(label)))
        # Borders: an edge between two plots of different owners, one of
        # them a chosen city.
        for xy in area:
            i = xy[1] * W + xy[0]
            for nb in neighbours(xy):
                if nb not in area_set or nb < xy:
                    continue
                a, b = owner.get(i), owner.get(nb[1] * W + nb[0])
                if a != b and (a in chosen_keys or b in chosen_keys):
                    out.append(edge_line(pos, xy, nb, ox, oy, BORDER, 2.4, ' stroke-dasharray="5,3"'))
        for a, b in rivers:
            if a in area_set or b in area_set:
                out.append(edge_line(pos, a, b, ox, oy, RIVER, 4.2, ' stroke-linecap="round"'))
        out.append('</g>')
    out.append('</svg>')
    return "\n".join(out) + "\n"


def neighbours(xy):
    x, y = xy
    if y & 1:
        return [(x + 1, y + 1), (x + 1, y), (x + 1, y - 1), (x, y - 1), (x - 1, y), (x, y + 1)]
    return [(x, y + 1), (x + 1, y), (x, y - 1), (x - 1, y - 1), (x - 1, y), (x - 1, y + 1)]


def edge_line(pos, a, b, ox, oy, colour, width, extra="", s=S):
    ax, ay = pos(*a)
    bx, by = pos(*b)
    mx, my = (ax + bx) / 2 + ox, (ay + by) / 2 + oy
    dx, dy = bx - ax, by - ay
    d = math.hypot(dx, dy) or 1
    px, py = -dy / d * s / 2, dx / d * s / 2
    return ('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f"%s/>'
            % (mx - px, my - py, mx + px, my + py, colour, width, extra))


def legend():
    rows = []
    width = 920

    def hexagon(cx, cy, fill, s=15, stroke="#6b6b6b", sw=0.7, extra=""):
        return '<polygon points="%s" fill="%s" stroke="%s" stroke-width="%.1f"%s/>' % (
            pts(corners(cx, cy, s)), fill, stroke, sw, extra)

    def text(tx, ty, s, size=12, fill="#14202a", weight="400", anchor="start"):
        return '<text x="%.1f" y="%.1f" font-size="%s" font-weight="%s" fill="%s" text-anchor="%s">%s</text>' % (
            tx, ty, size, weight, fill, anchor, s)

    def swatch(fill, glyph=None, colour="#14202a", size=12, extra=""):
        def draw(cx, cy):
            s = hexagon(cx, cy, fill, extra=extra)
            if glyph:
                s += text(cx, cy + 4.5, glyph, size, colour, "700", "middle")
            return s
        return draw

    def hills(fill):
        def draw(cx, cy):
            return hexagon(cx, cy, fill) + ('<path d="M%.1f,%.1f q5,-3.5 10,0" fill="none" stroke="#4d3f22" '
                                            'stroke-width="1.3"/>' % (cx - 5, cy + 9))
        return draw

    def badge(bg, fg, glyph, dash="", stroke="#1a1a1a", sw=1.2):
        def draw(cx, cy):
            return (hexagon(cx, cy, "#a9d07c") + hexagon(cx, cy, bg, 11.5, stroke, sw, dash)
                    + text(cx, cy + 4.5, glyph, 12 if len(glyph) == 1 else 10.5, fg, "700", "middle"))
        return draw

    def segment(colour, w, extra=""):
        def draw(cx, cy):
            return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f"%s/>' % (
                cx - 12, cy, cx + 12, cy, colour, w, extra)
        return draw

    def faded(cx, cy):
        return (hexagon(cx, cy, "#a9d07c") + '<polygon points="%s" fill="#ffffff" fill-opacity="0.5"/>'
                % pts(corners(cx, cy, 14.6)))

    def foreign(cx, cy):
        return faded(cx, cy) + '<polygon points="%s" fill="url(#foreign)"/>' % pts(corners(cx, cy, 14.6))

    groups = [
        ("地形", [(swatch(TERRAIN["GRASS"][0]), "草原"), (swatch(TERRAIN["PLAINS"][0]), "平原"),
                (swatch(TERRAIN["DESERT"][0]), "沙漠"), (swatch(TERRAIN["TUNDRA"][0]), "冻土"),
                (hills(TERRAIN["GRASS"][1]), "丘陵（颜色深一档、底部弧线）"),
                (swatch(MOUNTAIN, "▲", "#3d362f"), "山脉")]),
        ("", [(swatch(COAST), "海岸"), (swatch(OCEAN), "海洋"), (swatch(LAKE), "湖泊"),
              (swatch(HIDDEN, "?", "#dddddd"), "未揭示"), (segment(RIVER, 4.2, ' stroke-linecap="round"'), "河流"),
              (segment(BORDER, 2.4, ' stroke-dasharray="5,3"'), "所选城市的领土边界")]),
        ("地貌", [(swatch("#a9d07c", "林", "#1f6b2a"), "树林"), (swatch("#a9d07c", "雨", "#0f4f2e"), "雨林"),
                (swatch("#a9d07c", "沼", "#2c6f73"), "沼泽"), (swatch("#a9d07c", "泛", "#7a5a1e"), "泛滥平原"),
                (swatch(COAST, "礁", "#b0457a"), "礁石"), (swatch("#a9d07c", "土", "#6b3a2a"), "火山土"),
                (swatch(MOUNTAIN, "火", "#b3261e"), "火山"), (swatch("#a9d07c", "热", "#b3261e"), "地热裂缝"),
                (swatch("#a9d07c", "景", "#7a2f8f"), "自然奇观")]),
        ("资源", [(swatch("#a9d07c", "鱼", "#1b3a4b", 10), "加成资源"), (swatch("#a9d07c", "染", "#5b2a86", 10), "奢侈品"),
                (swatch("#a9d07c", "铁", "#8a1c1c", 10), "战略资源（格子上方的小字）")]),
        ("固定", [(badge("#ffffff", "#111111", "城1", sw=2), "所选城市的市中心（多城时带编号）"),
                (badge("#e6e6e6", "#333333", "城", stroke="#555555"), "本方其他城市"),
                (badge("#e6e6e6", "#333333", "外", stroke="#555555"), "外国城市"),
                (badge("#cfcfcf", "#333333", "政", stroke="#555555", sw=1), "已建的其他区域、奇观（奇）")]),
        ("", [(badge("#ffffff00", "#333333", "钉", ' stroke-dasharray="2,2"', "#333333"), "留在图上的地图钉"),
              (faded, "其他城市的领土"), (foreign, "外国领土")]),
        ("布局", [(badge(*DISTRICT["DISTRICT_CAMPUS"][1:], "学"), "学院"),
                (badge(*DISTRICT["DISTRICT_HOLY_SITE"][1:], "圣"), "圣地"),
                (badge(*DISTRICT["DISTRICT_THEATER"][1:], "剧"), "剧院广场"),
                (badge(*DISTRICT["DISTRICT_COMMERCIAL_HUB"][1:], "商"), "商业中心"),
                (badge(*DISTRICT["DISTRICT_HARBOR"][1:], "港"), "港口"),
                (badge(*DISTRICT["DISTRICT_INDUSTRIAL_ZONE"][1:], "工"), "工业区")]),
        ("", [(badge(*DISTRICT["DISTRICT_CAMPUS"][1:], "学2"), "区域后的数字：属于几号城"),
              (badge(*DISTRICT["DISTRICT_CAMPUS"][1:], "学", ' stroke-dasharray="4,2.5" fill-opacity="0.55"', sw=2), "作者打的钉（未建）"),
              (badge(*DISTRICT["DISTRICT_CAMPUS"][1:], "学", stroke=CHANGED, sw=2.6), "与作者布局不同")]),
    ]
    y = 22
    for title, entries in groups:
        if title:
            rows.append(text(10, y + 4.5, title, 12, "#946510", "700"))
        x = 56
        for draw, label in entries:
            rows.append(draw(x + 15, y))
            rows.append(text(x + 35, y + 4.5, label))
            x += 38 + 12.2 * len(label) + 12
        y += 36
    rows.append(text(10, y + 2, "区域下方的数字是裁判（DMT）给的相邻加成；“不计”：对比框架不请求这个区域（见正文）。北在上。",
                     12, "#444444"))
    height = y + 14
    head = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="%s">'
            % (width, height, width, height, FONT), '<rect width="100%" height="100%" fill="#ffffff"/>',
            '<defs><pattern id="foreign" width="6" height="6" patternUnits="userSpaceOnUse" '
            'patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" stroke="#ffffff" '
            'stroke-width="2.2" stroke-opacity="0.75"/></pattern></defs>']
    return "\n".join(head + rows + ["</svg>"]) + "\n"


# ---------------------------------------------------------------------------
# Workshop pictures (--workshop)
# ---------------------------------------------------------------------------
# Two panels for the Steam Workshop description: the player's layout and the
# mod's Standard plan (results/refscore_sdp.jsonl), which must be the proven
# optimum of results/refscore.jsonl tile for tile. Bigger hexes and text than
# the review pictures, words in the game's own names, a legend of only what is
# drawn, no author names. workshop/src/i<n>-<name>.html shows each at 1260 px
# and tools/workshop.py render turns it into workshop/inline/*.jpg.
WS_DIR = os.path.join(ROOT, "workshop", "src")
WS_SCENES = (("i1-ref12", "REF12"), ("i2-ref06", "REF06"))
WS_S = 30
WS_GAP = 34
WS_TITLE_H = 56
WS_INSET = 4
# Game names (Base and DLC text, zh_Hans_CN and en_US), checked 2026-10-30.
WS_WORDS = {
    "zh": {
        "player": "高手的布局 · 相邻 +%s", "player_note": "存档里已建的区域",
        "sdp": "本模组 · 相邻 +%s", "sdp_note": "标准档，与证明过的最优逐格相同",
        "moved": "红框：与高手的布局不同", "mountain": "山脉", "river": "河流", "border": "领土边界",
        "floodplains": "泛滥平原", "other": "其他城市的领土", "city": "城", "foreign": "外", "tack": "钉",
        "sep": "：",
    },
    "en": {
        "player": "Player's layout · +%s", "player_note": "Adjacency of the districts built in the save",
        "sdp": "Smart District Planner · +%s", "sdp_note": "Adjacency; the same tiles as the proven best",
        "moved": "Red outline: moved", "mountain": "Mountains", "river": "River", "border": "Border",
        "floodplains": "Floodplains", "other": "Another city's tiles", "city": "City", "foreign": "Foreign",
        "tack": "Tack", "sep": " ",
    },
}
WS_DISTRICT = {  # label, name: zh, en
    "DISTRICT_CAMPUS": (("学", "学院"), ("C", "Campus")),
    "DISTRICT_HOLY_SITE": (("圣", "圣地"), ("HS", "Holy Site")),
    "DISTRICT_THEATER": (("剧", "剧院广场"), ("TS", "Theater Square")),
    "DISTRICT_COMMERCIAL_HUB": (("商", "商业中心"), ("CH", "Commercial Hub")),
    "DISTRICT_HARBOR": (("港", "港口"), ("H", "Harbor")),
    "DISTRICT_INDUSTRIAL_ZONE": (("工", "工业区"), ("IZ", "Industrial Zone")),
}
WS_FIXED = {  # other districts: zh name in the hex; en abbreviation in the hex, name in the legend
    "DISTRICT_WONDER": ("奇观", "W", "Wonder"), "DISTRICT_GOVERNMENT": ("市政广场", "GP", "Government Plaza"),
    "DISTRICT_ENCAMPMENT": ("军营", "E", "Encampment"), "DISTRICT_AERODROME": ("航空港", "A", "Aerodrome"),
    "DISTRICT_DAM": ("堤坝", "D", "Dam"), "DISTRICT_ENTERTAINMENT_COMPLEX": ("娱乐中心", "EC", "Entertainment Complex"),
    "DISTRICT_AQUEDUCT": ("水渠", "Aq", "Aqueduct"), "DISTRICT_NEIGHBORHOOD": ("社区", "N", "Neighborhood"),
}
WS_IMPROVEMENT = {"IMPROVEMENT_FARM": ("农场", "Farm"), "IMPROVEMENT_MINE": ("矿山", "Mine"),
                  "IMPROVEMENT_MONASTERY": ("修道院", "Monastery"), "IMPROVEMENT_PASTURE": ("牧场", "Pasture"),
                  "IMPROVEMENT_PLANTATION": ("种植园", "Plantation"), "IMPROVEMENT_CAMP": ("营地", "Camp"),
                  "IMPROVEMENT_QUARRY": ("采石场", "Quarry")}
WS_RESOURCE_EN = {"WHEAT": "Wheat", "SHEEP": "Sheep", "FURS": "Furs", "TEA": "Tea", "DYES": "Dyes",
                  "MERCURY": "Mercury", "CRABS": "Crabs", "FISH": "Fish", "RICE": "Rice", "CATTLE": "Cattle"}
WS_CITY_EN = {"REF12": "Xi’an", "REF06": "Kyoto"}
FLOOD = "#7a5a1e"


def load_sdp():
    return load_rows(os.path.join(HERE, "results", "refscore_sdp.jsonl"),
                     lambda r: r.get("planner") == "sdp" and r.get("variant") == "STANDARD")


def workshop_panels(spec, refscore, sdp, lang):
    """The player's layout and the Standard plan; refuses when the plan is not
    the proven optimum tile for tile."""
    sid = spec["scenario"]["id"]
    ref_row, sdp_row = refscore.get((sid, "all1")), sdp.get((sid, "all1"))
    if not ref_row or not sdp_row:
        raise SystemExit("%s: no all1 row in refscore.jsonl or refscore_sdp.jsonl" % sid)
    opt, plan = ref_row["optimum"], sdp_row["score"]
    if not ref_row["summary"].get("proven") or not same_plan(opt["items"], plan["items"]) or opt["gain"] != plan["gain"]:
        raise SystemExit("%s: the Standard plan (+%s) is not the proven optimum (+%s) tile for tile"
                         % (sid, num(plan["gain"]), num(opt["gain"])))
    w = WS_WORDS[lang]
    return [{"title": w["player"] % num(ref_row["reference"]["gain"]), "notes": [w["player_note"]],
             "items": ref_row["reference"]["items"], "ref": True},
            {"title": w["sdp"] % num(plan["gain"]), "notes": [w["sdp_note"]], "items": plan["items"]}]


def render_workshop(spec, panels, lang):
    zh = lang == "zh"
    w = WS_WORDS[lang]
    s = WS_S
    sc = spec["scenario"]
    sid = sc["id"][:5]
    W = spec["width"]
    plots = spec["plots"]
    chosen = [c for c in spec["cities"] if c["owner"] == 0 and c["id"] in sc["only"]]
    centres = [(c["x"], c["y"]) for c in chosen]
    area = [(i % W, i // W) for i in range(len(plots)) if any(dist((i % W, i // W), c) <= 3 for c in centres)]
    area_set = set(area)
    owner = {}
    for c in spec["cities"]:
        for i in c.get("plots", []):
            owner[i] = (c["owner"], c["id"])
    chosen_keys = {(0, c["id"]) for c in chosen}
    ymax = max(y for _, y in area)

    def pos(x, y):  # north up
        return SQ3 * s * (x + 0.5 * (y & 1)), 1.5 * s * (ymax - y)

    xs = [pos(*xy)[0] for xy in area]
    ys = [pos(*xy)[1] for xy in area]
    minx, maxx = min(xs) - SQ3 * s / 2 - 2, max(xs) + SQ3 * s / 2 + 2
    miny, maxy = min(ys) - s - 2, max(ys) + s + 2
    pw, ph = maxx - minx, maxy - miny
    width = 2 * pw + WS_GAP

    fixed, used = {}, {"fixed": set(), "district": set()}
    for c in spec["cities"]:
        xy = (c["x"], c["y"])
        if c["owner"] == 0 and c["id"] in sc["only"]:
            fixed[xy] = ("city", city_name(sc["id"], c) if zh else WS_CITY_EN.get(sid, c["name"]))
        else:
            fixed[xy] = ("othercity", w["city"] if c["owner"] == 0 else w["foreign"])
        for d in c["districts"]:
            fixed[(d["x"], d["y"])] = ("fixed", d["type"])
    for wd in spec.get("wonders", []):
        fixed.setdefault((wd["x"], wd["y"]), ("fixed", "DISTRICT_WONDER"))
    for p in spec.get("pins", []):
        fixed.setdefault((p["x"], p["y"]), ("tack", w["tack"]))
    rivers = [((a % W, a // W), (b % W, b // W)) for r in spec.get("rivers", []) for a, b in r["edges"]]
    rivers = [e for e in rivers if e[0] in area_set or e[1] in area_set]
    # Tiles a district covers in one panel and not the other: what it covers
    # (improvement, resource) is written on them where they are bare.
    covered = {(i["x"], i["y"]) for p in panels for i in p["items"]}
    flood = other = False

    def text(x, y, body, size, fill, weight="400", anchor="middle"):
        return ('<text x="%.1f" y="%.1f" font-size="%s" font-weight="%s" fill="%s" text-anchor="%s">%s</text>'
                % (x, y, size, weight, fill, anchor, body))

    out = []
    for n, panel in enumerate(panels):
        ox = n * (pw + WS_GAP) - minx
        oy = WS_TITLE_H - miny
        out.append(text(n * (pw + WS_GAP) + 2, 22, esc(panel["title"]), 19, "#14202a", "700", "start"))
        out.append(text(n * (pw + WS_GAP) + 2, 44, esc(panel["notes"][0]), 13, "#555555", "400", "start"))
        placed = {(i["x"], i["y"]): i for i in panel["items"]}
        late = []  # words drawn over the neighbouring hexes
        ref_set = {(i["city"], i["type"], i["x"], i["y"]) for i in panels[0]["items"]}
        for xy in sorted(area, key=lambda a: (-a[1], a[0])):
            p = plots[xy[1] * W + xy[0]]
            cx, cy = pos(*xy)
            cx, cy = cx + ox, cy + oy
            t = p["t"]
            if p.get("hidden"):
                fill = HIDDEN
            elif t == "TERRAIN_OCEAN":
                fill = OCEAN
            elif t == "TERRAIN_COAST":
                fill = LAKE if p.get("lake") else COAST
            elif t.endswith("_MOUNTAIN"):
                fill = MOUNTAIN
            else:
                base = t.replace("TERRAIN_", "").replace("_HILLS", "")
                fill = TERRAIN.get(base, TERRAIN["GRASS"])[1 if t.endswith("_HILLS") else 0]
            out.append('<polygon points="%s" fill="%s" stroke="#6b6b6b" stroke-width="0.8"/>'
                       % (pts(corners(cx, cy, s)), fill))
            own = owner.get(xy[1] * W + xy[0])
            if own and own not in chosen_keys and not p.get("hidden"):
                other = True
                out.append('<polygon points="%s" fill="#ffffff" fill-opacity="0.5"/>' % pts(corners(cx, cy, s - 0.4)))
                if own[0] != 0:
                    out.append('<polygon points="%s" fill="url(#foreign)"/>' % pts(corners(cx, cy, s - 0.4)))
            if p.get("hidden"):
                out.append(text(cx, cy + 6, "?", 16, "#dddddd"))
                continue
            if (p.get("f") or "").startswith("FEATURE_FLOODPLAINS"):
                flood = True
                out.append('<polygon points="%s" fill="url(#flood)"/>' % pts(corners(cx, cy, s - 0.4)))
            if t.endswith("_HILLS"):
                out.append('<path d="M%.1f,%.1f q10,-6 20,0" fill="none" stroke="#4d3f22" stroke-width="1.6"/>'
                           % (cx - 10, cy + 25))
            item, fx = placed.get(xy), fixed.get(xy)
            if item is None and fx is None:
                if t.endswith("_MOUNTAIN"):
                    out.append(text(cx, cy + 6, "▲", 16, "#3d362f"))
                elif xy in covered:
                    words = []
                    imp = WS_IMPROVEMENT.get(p.get("imp") or "")
                    if imp:
                        words.append(imp[0 if zh else 1])
                    res = (p.get("r") or "")[len("RESOURCE_"):]
                    if res:
                        words.append(RESOURCE.get(res, res.title()) if zh else WS_RESOURCE_EN.get(res, res.title()))
                    for k, word in enumerate(words):
                        late.append(text(cx, cy - 2 + 14 * k - 7 * (len(words) - 1), esc(word),
                                         11.5 if len(word) < 8 else 10, "#14202a", "700"))
                continue
            if item is not None and (fx is None or fx[0] == "tack"):
                names = WS_DISTRICT.get(item["type"])
                label = names[0 if zh else 1][0] if names else "?"
                used["district"].add(item["type"])
                _, bg, fg = DISTRICT.get(item["type"], ("", "#cccccc", "#222222"))
                changed = not panel.get("ref") and (item["city"], item["type"], item["x"], item["y"]) not in ref_set
                stroke, sw = (CHANGED, 3.4) if changed else ("#1a1a1a", 1.4)
                out.append('<polygon points="%s" fill="%s" stroke="%s" stroke-width="%.1f"/>'
                           % (pts(corners(cx, cy, s - WS_INSET)), bg, stroke, sw))
                out.append(text(cx, cy + 3, esc(label), 17, fg, "700"))
                out.append(text(cx, cy + 19, "+%s" % num(item["adj"]), 15, fg, "700"))
                continue
            kind, label = fx
            if kind == "city":
                out.append('<polygon points="%s" fill="#ffffff" stroke="#111111" stroke-width="2.2"/>'
                           % pts(corners(cx, cy, s - WS_INSET)))
                out.append(text(cx, cy + 5, esc(label), 13, "#111111", "700"))
            elif kind == "othercity":
                out.append('<polygon points="%s" fill="#e6e6e6" stroke="#555555" stroke-width="1.2"/>'
                           % pts(corners(cx, cy, s - WS_INSET)))
                out.append(text(cx, cy + 5, esc(label), 12, "#333333"))
            elif kind == "tack":
                out.append('<polygon points="%s" fill="none" stroke="#333333" stroke-width="1.2" '
                           'stroke-dasharray="3,2"/>' % pts(corners(cx, cy, s - WS_INSET)))
                out.append(text(cx, cy + 4.5, esc(label), 11.5, "#333333"))
            else:
                names = WS_FIXED.get(label)
                used["fixed"].add(label)
                wonder = label == "DISTRICT_WONDER"
                out.append('<polygon points="%s" fill="%s" stroke="#555555" stroke-width="1"/>'
                           % (pts(corners(cx, cy, s - WS_INSET)), "#e8d9b5" if wonder else "#cfcfcf"))
                word = (names[0] if zh else names[1]) if names else "?"
                out.append(text(cx, cy + 4.5, esc(word), 11.5 if zh else 13, "#333333", "700"))
        for xy in area:
            i = xy[1] * W + xy[0]
            for nb in neighbours(xy):
                if nb not in area_set or nb < xy:
                    continue
                a, b = owner.get(i), owner.get(nb[1] * W + nb[0])
                if a != b and (a in chosen_keys or b in chosen_keys):
                    out.append(edge_line(pos, xy, nb, ox, oy, BORDER, 2.6, ' stroke-dasharray="6,4"', s))
        for a, b in rivers:
            out.append(edge_line(pos, a, b, ox, oy, RIVER, 5, ' stroke-linecap="round"', s))
        out += late

    # Legend: only what the picture shows, wrapped to the picture's width.
    entries = []

    def badge(bg, fg, glyph, stroke="#1a1a1a", sw=1.4):
        return lambda x, y: ('<polygon points="%s" fill="%s" stroke="%s" stroke-width="%.1f"/>'
                             % (pts(corners(x, y, 12)), bg, stroke, sw)
                             + (text(x, y + 4.5, esc(glyph), 11 if len(glyph) < 3 else 9, fg, "700") if glyph else ""))

    for dtype in sorted(used["district"], key=lambda d: list(WS_DISTRICT).index(d) if d in WS_DISTRICT else 99):
        names = WS_DISTRICT.get(dtype)
        if names:
            label, name = names[0 if zh else 1]
            entries.append((badge(DISTRICT[dtype][1], DISTRICT[dtype][2], label), name))
    entries.append((badge("#ffffff", "", "", CHANGED, 3), w["moved"]))
    if not zh:
        for ftype in sorted(used["fixed"], key=lambda d: list(WS_FIXED).index(d) if d in WS_FIXED else 99):
            if ftype in WS_FIXED:
                entries.append((badge("#e8d9b5" if ftype == "DISTRICT_WONDER" else "#cfcfcf", "#333333",
                                      WS_FIXED[ftype][1], "#555555", 1), WS_FIXED[ftype][2]))
    entries.append((lambda x, y: ('<polygon points="%s" fill="%s" stroke="#6b6b6b" stroke-width="0.8"/>'
                                  % (pts(corners(x, y, 12)), MOUNTAIN) + text(x, y + 5, "▲", 12, "#3d362f")),
                    w["mountain"]))
    if flood:
        entries.append((lambda x, y: ('<polygon points="%s" fill="%s" stroke="#6b6b6b" stroke-width="0.8"/>'
                                      '<polygon points="%s" fill="url(#flood)"/>'
                                      % (pts(corners(x, y, 12)), TERRAIN["GRASS"][0], pts(corners(x, y, 11.6)))),
                        w["floodplains"]))
    if rivers:
        entries.append((lambda x, y: '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="5" '
                        'stroke-linecap="round"/>' % (x - 12, y, x + 12, y, RIVER), w["river"]))
    entries.append((lambda x, y: '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="2.6" '
                    'stroke-dasharray="6,4"/>' % (x - 12, y, x + 12, y, BORDER), w["border"]))
    if other:
        entries.append((lambda x, y: ('<polygon points="%s" fill="%s" stroke="#6b6b6b" stroke-width="0.8"/>'
                                      '<polygon points="%s" fill="#ffffff" fill-opacity="0.5"/>'
                                      % (pts(corners(x, y, 12)), TERRAIN["GRASS"][0], pts(corners(x, y, 11.6)))),
                        w["other"]))
    top = WS_TITLE_H + ph + 26
    x, y = 14.0, top
    for draw, label in entries:
        cw = 13.5 if zh else 7.4  # rough advance per character at 14 px
        span = 34 + cw * len(label) + 20
        if x + span > width and x > 14:
            x, y = 14.0, y + 30
        out.append(draw(x, y))
        out.append(text(x + 20, y + 5, esc(label), 14, "#14202a", "400", "start"))
        x += span
    height = y + 20
    head = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %.1f %.1f" font-family="%s">'
            % (math.ceil(width), math.ceil(height), width, height, FONT),
            '<rect width="100%" height="100%" fill="#ffffff"/>',
            '<defs><pattern id="foreign" width="6" height="6" patternUnits="userSpaceOnUse" '
            'patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" stroke="#ffffff" '
            'stroke-width="2.2" stroke-opacity="0.75"/></pattern>'
            '<pattern id="flood" width="8" height="7" patternUnits="userSpaceOnUse">'
            '<path d="M0,4 q2,-2.5 4,0 t4,0" fill="none" stroke="%s" stroke-width="1.1" stroke-opacity="0.7"/>'
            '</pattern></defs>' % FLOOD]
    return "\n".join(head + out + ["</svg>"]) + "\n"


def write_workshop(out_dir):
    scenes, refscore, _ = load_all([sid for _, sid in WS_SCENES])
    by_id = {s["scenario"]["id"][:5]: s for s in scenes}
    sdp = load_sdp()
    os.makedirs(out_dir, exist_ok=True)
    for name, sid in WS_SCENES:
        spec = by_id[sid]
        for lang, suffix in (("zh", ""), ("en", "-en")):
            path = os.path.join(out_dir, name + suffix + ".svg")
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(render_workshop(spec, workshop_panels(spec, refscore, sdp, lang), lang))
            print("wrote %s" % os.path.relpath(path, ROOT))
    return 0


# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------
ZH = {
    "CIVILIZATION_JAPAN": "日本", "CIVILIZATION_AUSTRALIA": "澳大利亚", "CIVILIZATION_NETHERLANDS": "荷兰",
    "CIVILIZATION_CHINA": "中国", "CIVILIZATION_POLAND": "波兰", "CIVILIZATION_HUNGARY": "匈牙利",
    "CIVILIZATION_MAORI": "毛利", "CIVILIZATION_ROME": "罗马",
    "LEADER_HOJO": "北条时宗", "LEADER_JOHN_CURTIN": "约翰·科廷", "LEADER_WILHELMINA": "威廉明娜",
    "LEADER_QIN": "秦始皇", "LEADER_JADWIGA": "雅德维加", "LEADER_MATTHIAS_CORVINUS": "匈雅提·马加什",
    "LEADER_KUPE": "库佩", "LEADER_TRAJAN": "图拉真",
    "RULESET_EXPANSION_1": "迭起兴衰", "RULESET_EXPANSION_2": "风云变幻",
    "DISTRICT_CAMPUS": "学院", "DISTRICT_HOLY_SITE": "圣地", "DISTRICT_THEATER": "剧院广场",
    "DISTRICT_COMMERCIAL_HUB": "商业中心", "DISTRICT_HARBOR": "港口", "DISTRICT_INDUSTRIAL_ZONE": "工业区",
}


def pct(a, b):
    return "-" if not b else "%.1f%%" % (100.0 * a / b)


def tables(scenes, refscore, grid):
    author_of = {s["scenario"]["id"]: s["scenario"].get("author", "?") for s in scenes}
    check = check_group(sorted(author_of), author_of)
    print("## 总表\n")
    print("| 场景 | 作者 | 组 | 文明 | 城市（人口） | 回合 | 存档规则 | 区域数 | 全 1 | 金币、信仰减半 | λ=0 / 0.5 / 1 差距 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    shares = {"all1": [], "gold-faith-half": []}
    for spec in scenes:
        sc = spec["scenario"]
        sid = sc["id"]
        chosen = sorted((c for c in spec["cities"] if c["owner"] == 0 and c["id"] in sc["only"]),
                        key=lambda c: sc["only"].index(c["id"]))
        cities = "、".join("%s（%d）" % (city_name(sid, c), c["population"]) for c in chosen)
        saved = ZH[spec["meta"].get("savedRuleset", spec["ruleset"])]
        cells = []
        for w in ("all1", "gold-faith-half"):
            r = refscore.get((sid, w))
            if r:
                a, b = r["reference"]["gain"], r["optimum"]["gain"]
                shares[w].append(a / b)
                cells.append("%s / %s = %s" % (num(a), num(b), pct(a, b)))
            else:
                cells.append("-")
        gaps = []
        for lam in ("L000", "L050", "L100"):
            r = grid.get((sid, "all1-" + lam))
            m = (r or {}).get("summary")
            gaps.append("%.1f" % (100.0 * m["gap"] / m["referenceGain"]) if m and m.get("referenceGain") else "-")
        print("| %s | %s | %s | %s | %s | %s | %s | %d | %s | %s | %s |" % (
            sid[:5], sc.get("author", "?"), "复核" if sc.get("author") in check else "开发",
            ZH.get(sc["civ"], sc["civ"]), cities, sc.get("turn", "-"), saved,
            len(spec["reference"]["placements"]), cells[0], cells[1], " / ".join(gaps)))
    for w, v in shares.items():
        if v:
            print("\n平均（%s）：%.1f%%，%d 个场景" % (w, 100 * sum(v) / len(v), len(v)))
    print()
    for spec in scenes:
        sc = spec["scenario"]
        sid = sc["id"]
        print("### %s\n" % sid)
        print("网格（差距 %，全 1 / 金币减半 / 金币和信仰减半 × λ = 0、0.25、0.5、0.75、1；* = 参照就是最优）：\n")
        print("| 权重 | λ=0 | 0.25 | 0.5 | 0.75 | 1 |")
        print("|---|---|---|---|---|---|")
        for fam, label in (("all1", "全 1"), ("g05", "金币减半"), ("g05f05", "金币、信仰减半")):
            cells = []
            for lam in ("L000", "L025", "L050", "L075", "L100"):
                r = grid.get((sid, "%s-%s" % (fam, lam)))
                m = (r or {}).get("summary")
                if not m or not m.get("referenceGain"):
                    cells.append("-")
                    continue
                cells.append("%.1f%s" % (100.0 * m["gap"] / m["referenceGain"], "*" if m["referenceOptimal"] else ""))
            print("| %s | %s |" % (label, " | ".join(cells)))
        print()
        r = refscore.get((sid, "all1"))
        judge = {(i["city"], i["type"], i["x"], i["y"]): i["adj"] for i in (r or {}).get("reference", {}).get("items", [])}
        print("| 区域 | 城 | 格 | 来源 | 游戏显示 | 裁判 |")
        print("|---|---|---|---|---|---|")
        claimed = {(c["city"], c["x"], c["y"]): c for c in spec["reference"].get("claimed", [])}
        names = {c["id"]: city_name(sid, c) for c in spec["cities"] if c["owner"] == 0}
        for p in spec["reference"]["placements"]:
            c = claimed.get((p["city"], p["x"], p["y"]))
            src = "钉" if p.get("pin") else ("建造中" if c and c.get("complete") is False else "已建")
            game = num(c["adj"]) if c else "-"
            if c and c.get("withPolicies") is not None and c["withPolicies"] != c["adj"]:
                game += "（含政策卡 %s）" % num(c["withPolicies"])
            print("| %s | %s | %d,%d | %s | %s | %s |" % (
                ZH.get(p["type"], p["type"]), names.get(p["city"], p["city"]), p["x"], p["y"], src, game,
                num(judge.get((p["city"], p["type"], p["x"], p["y"])))))
        print()


def main(argv):
    out_dir = OUT
    want_tables = "--tables" in argv
    argv = [a for a in argv if a != "--tables"]
    if "--out" in argv:
        i = argv.index("--out")
        out_dir = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if "--workshop" in argv:
        if argv != ["--workshop"]:
            print(__doc__)
            return 2
        return write_workshop(WS_DIR if out_dir == OUT else out_dir)
    if any(a.startswith("-") for a in argv):
        print(__doc__)
        return 2
    scenes, refscore, grid = load_all(argv)
    if not scenes:
        print("no scenes")
        return 2
    os.makedirs(out_dir, exist_ok=True)
    for spec in scenes:
        sid = spec["scenario"]["id"]
        path = os.path.join(out_dir, sid[:5] + ".svg")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(render(spec, panels_for(spec, refscore, grid)))
        print("wrote %s" % os.path.relpath(path, ROOT))
    with open(os.path.join(out_dir, "legend.svg"), "w", encoding="utf-8", newline="\n") as f:
        f.write(legend())
    if want_tables:
        tables(scenes, refscore, grid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
