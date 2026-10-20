"""Hex map figures for the report: a scenario's map with one or more plans.

render(snapshot, panels, center, radius) -> SVG string. panels = list of
{ "title": str, "items": [ {type, x, y, adj} ], "bad": set((x, y)) }.
Pointy-top hexes, odd rows shifted right (the comparison world's layout).
Colors are CSS classes defined in the page, so dark mode works.
"""
import math

SQ3 = math.sqrt(3)

ABBR = {
    "DISTRICT_CAMPUS": "学", "DISTRICT_SEOWON": "书", "DISTRICT_OBSERVATORY": "观",
    "DISTRICT_HOLY_SITE": "圣", "DISTRICT_LAVRA": "修",
    "DISTRICT_THEATER": "剧", "DISTRICT_ACROPOLIS": "卫",
    "DISTRICT_COMMERCIAL_HUB": "商", "DISTRICT_SUGUBA": "苏", "DISTRICT_HARBOR": "港", "DISTRICT_COTHON": "港",
    "DISTRICT_ROYAL_NAVY_DOCKYARD": "港",
    "DISTRICT_INDUSTRIAL_ZONE": "工", "DISTRICT_HANSA": "汉",
    "DISTRICT_ENTERTAINMENT_COMPLEX": "娱", "DISTRICT_STREET_CARNIVAL": "娱", "DISTRICT_HIPPODROME": "娱",
    "DISTRICT_ENCAMPMENT": "军", "DISTRICT_IKANDA": "军", "DISTRICT_THANH": "城",
    "DISTRICT_GOVERNMENT": "政", "DISTRICT_DIPLOMATIC_QUARTER": "外", "DISTRICT_AQUEDUCT": "渠", "DISTRICT_BATH": "渠",
    "DISTRICT_DAM": "坝", "DISTRICT_CANAL": "运", "DISTRICT_NEIGHBORHOOD": "社", "DISTRICT_MBANZA": "社",
    "DISTRICT_OPPIDUM": "工", "DISTRICT_PRESERVE": "保", "DISTRICT_AERODROME": "机", "DISTRICT_SPACEPORT": "航",
    "DISTRICT_WONDER": "奇",
}

TERRAIN = {"GRASS": "tg", "PLAINS": "tp", "DESERT": "td", "TUNDRA": "tt", "SNOW": "ts"}


def terrain_class(p):
    t = p["t"]
    if t == "TERRAIN_OCEAN":
        return "to"
    if t == "TERRAIN_COAST":
        return "tl" if p.get("lake") else "tc"
    base = t.replace("TERRAIN_", "").replace("_HILLS", "").replace("_MOUNTAIN", "")
    if t.endswith("_MOUNTAIN"):
        return "tm"
    return TERRAIN.get(base, "tg")


def to_cube(x, y):
    return x - (y - (y & 1)) // 2, y


def distance(a, b):
    q1, r1 = to_cube(*a)
    q2, r2 = to_cube(*b)
    dq, dr = q1 - q2, r1 - r2
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def corners(cx, cy, s):
    return [(cx + s * math.cos(math.radians(60 * i - 30)), cy + s * math.sin(math.radians(60 * i - 30))) for i in range(6)]


def fmt(points):
    return " ".join("%.1f,%.1f" % p for p in points)


def render(snapshot, panels, center, radius=3, s=17, gap=26, title_h=26):
    plots = {(p["x"], p["y"]): p for p in snapshot["plots"]}
    area = [xy for xy in plots if distance(xy, center) <= radius]
    def pos(x, y):
        return SQ3 * s * (x + 0.5 * (y & 1)), 1.5 * s * y
    xs = [pos(*xy)[0] for xy in area]
    ys = [pos(*xy)[1] for xy in area]
    minx, maxx, miny, maxy = min(xs) - s, max(xs) + s, min(ys) - s, max(ys) + s
    pw, ph = maxx - minx, maxy - miny
    width = len(panels) * pw + (len(panels) - 1) * gap
    height = ph + title_h
    out = []
    cities = {(c["x"], c["y"]): c for c in snapshot["cities"]}
    pins = {(p["x"], p["y"]): p for p in snapshot.get("pins", [])}
    for n, panel in enumerate(panels):
        ox = n * (pw + gap) - minx
        oy = title_h - miny
        out.append('<g>')
        out.append('<text class="hm-title" x="%.1f" y="16">%s</text>' % (n * (pw + gap) + 2, panel["title"]))
        placed = {(i["x"], i["y"]): i for i in panel.get("items", [])}
        bad = panel.get("bad", set())
        for xy in sorted(area, key=lambda a: (a[1], a[0])):
            p = plots[xy]
            cx, cy = pos(*xy)
            cx, cy = cx + ox, cy + oy
            cls = terrain_class(p)
            hills = p["t"].endswith("_HILLS")
            owned = p.get("owner") == 0
            out.append('<polygon class="hx %s%s%s" points="%s"/>' % (
                cls, " hills" if hills else "", "" if owned or cls in ("to", "tc", "tl") else " unowned", fmt(corners(cx, cy, s - 0.6))))
            f = p.get("f", "")
            glyph = None
            if f == "FEATURE_FOREST":
                glyph = ("hm-wood", "♣")
            elif f == "FEATURE_JUNGLE":
                glyph = ("hm-jungle", "♠")
            elif f == "FEATURE_MARSH":
                glyph = ("hm-marsh", "≈")
            elif f.startswith("FEATURE_FLOODPLAINS"):
                glyph = ("hm-flood", "∴")
            elif f == "FEATURE_REEF":
                glyph = ("hm-reef", "◌")
            elif f == "FEATURE_VOLCANO":
                glyph = ("hm-volcano", "▲")
            elif f == "FEATURE_OASIS":
                glyph = ("hm-water", "◉")
            elif f == "FEATURE_VOLCANIC_SOIL":
                glyph = ("hm-soil", "∵")
            elif f == "FEATURE_GEOTHERMAL_FISSURE":
                glyph = ("hm-volcano", "◎")
            elif f:
                glyph = ("hm-nw", "★")
            if cls == "tm" and f != "FEATURE_VOLCANO" and not glyph:
                glyph = ("hm-mtn", "▲")
            if hills:
                out.append('<text class="hm-hill" x="%.1f" y="%.1f">⌒</text>' % (cx - 7, cy - 6))
            label = None
            if xy in cities:
                c = cities[xy]
                out.append('<polygon class="hx-city%s" points="%s"/>' % ("" if c["owner"] == 0 else " foreign", fmt(corners(cx, cy, s - 3))))
                label = ("hm-city", "城" if c["owner"] == 0 else "他")
            elif p.get("d"):
                out.append('<polygon class="hx-built" points="%s"/>' % fmt(corners(cx, cy, s - 3)))
                label = ("hm-built", ABBR.get(p["d"], "区"))
            elif xy in pins:
                out.append('<polygon class="hx-pin" points="%s"/>' % fmt(corners(cx, cy, s - 3)))
                label = ("hm-pin", ABBR.get(pins[xy]["icon"].replace("ICON_", ""), "钉"))
            if xy in placed and xy not in cities:
                it = placed[xy]
                out.append('<polygon class="hx-plan%s" points="%s"/>' % (" bad" if xy in bad else "", fmt(corners(cx, cy, s - 2.2))))
                label = ("hm-plan", ABBR.get(it["type"], "区"))
                if it.get("adj") is not None:
                    out.append('<text class="hm-adj" x="%.1f" y="%.1f">+%d</text>' % (cx, cy + 10.5, it["adj"]))
            if label:
                out.append('<text class="%s" x="%.1f" y="%.1f">%s</text>' % (label[0], cx, cy + (1 if xy in placed else 4.5), label[1]))
            elif glyph:
                out.append('<text class="%s" x="%.1f" y="%.1f">%s</text>' % (glyph[0], cx, cy + 4.5, glyph[1]))
            if p.get("r") and not label:
                rc = {"RESOURCECLASS_LUXURY": "lux", "RESOURCECLASS_STRATEGIC": "str"}.get(p.get("rc"), "bon")
                out.append('<circle class="hm-res %s" cx="%.1f" cy="%.1f" r="2.6"/>' % (rc, cx + 7, cy - 7))
        # Rivers on top: each edge once.
        for xy in area:
            p = plots[xy]
            cx, cy = pos(*xy)
            cx, cy = cx + ox, cy + oy
            cs = corners(cx, cy, s)
            for d in p.get("river", []):
                a, b = cs[(d + 5) % 6], cs[d]
                out.append('<line class="hm-river" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"/>' % (a[0], a[1], b[0], b[1]))
        out.append('</g>')
    return width, height, "\n".join(out)
