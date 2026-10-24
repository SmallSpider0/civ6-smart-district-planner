#!/usr/bin/env python3
"""refscene - hand-written reference layouts as comparison scenes (issue 53).

A reference scene is a well-known community layout written down as text
(tests/compare/refscenes/<id>.txt): the map in the game's offset hex grid,
rivers, the cities and the layout's districts. `build` converts it into a
scene file of the same shape the real-save scenes have
(tests/compare/scenes/<id>.json, listed in index.json; tools/snapshot.py),
plus a "reference" entry with the layout's placements, so tools/compare.mjs
can judge the layout and find the optimum under given weights
(--refscore). Reference scenes are set "REF" and have no default runs, so
they never change the other scenario sets.

    python3 -I tools/refscene.py build                 # every source -> scenes/<id>.json + index.json
    python3 -I tools/refscene.py build REF01-suqin-aqueduct-dam
    python3 -I tools/refscene.py check REF01-suqin-aqueduct-dam [--svg FILE]
                                                       # render the scene file back (text, or an SVG
                                                       # picture) to compare with the source picture
    python3 -I tools/refscene.py verify [IDS]          # round trip, files up to date, and the judge
                                                       # (compare.mjs) accepts the reference layout
    python3 -I tools/refscene.py list

The format is described in tools/README.md ("refscene.py"). Coordinates are
the game's: x to the right, y down the page (row 0 on top), odd rows shifted
half a plot to the right, as tests/compare/cmp_game.lua lays out the map.
Python 3.8, standard library only.
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "tests", "compare", "refscenes")
SCENES = os.path.join(ROOT, "tests", "compare", "scenes")
INDEX = os.path.join(SCENES, "index.json")

TERRAINS = {"g": "TERRAIN_GRASS", "p": "TERRAIN_PLAINS", "d": "TERRAIN_DESERT", "t": "TERRAIN_TUNDRA",
            "s": "TERRAIN_SNOW", "c": "TERRAIN_COAST", "o": "TERRAIN_OCEAN"}
TERRAIN_CODE = {v: k for k, v in TERRAINS.items()}
FEATURES = {"f": "FEATURE_FOREST", "j": "FEATURE_JUNGLE", "m": "FEATURE_MARSH", "oa": "FEATURE_OASIS",
            "r": "FEATURE_REEF", "vs": "FEATURE_VOLCANIC_SOIL", "vo": "FEATURE_VOLCANO",
            "gf": "FEATURE_GEOTHERMAL_FISSURE", "ice": "FEATURE_ICE"}
FEATURE_CODE = {v: k for k, v in FEATURES.items()}
FLOODPLAINS = {"FEATURE_FLOODPLAINS", "FEATURE_FLOODPLAINS_GRASSLAND", "FEATURE_FLOODPLAINS_PLAINS"}
DISTRICTS = {"CC": "DISTRICT_CITY_CENTER", "CA": "DISTRICT_CAMPUS", "HS": "DISTRICT_HOLY_SITE",
             "TH": "DISTRICT_THEATER", "CH": "DISTRICT_COMMERCIAL_HUB", "HA": "DISTRICT_HARBOR",
             "IZ": "DISTRICT_INDUSTRIAL_ZONE", "EC": "DISTRICT_ENTERTAINMENT_COMPLEX",
             "WP": "DISTRICT_WATER_ENTERTAINMENT_COMPLEX", "AQ": "DISTRICT_AQUEDUCT", "DA": "DISTRICT_DAM",
             "CN": "DISTRICT_CANAL", "EN": "DISTRICT_ENCAMPMENT", "NB": "DISTRICT_NEIGHBORHOOD",
             "AE": "DISTRICT_AERODROME", "SP": "DISTRICT_SPACEPORT", "GP": "DISTRICT_GOVERNMENT",
             "DQ": "DISTRICT_DIPLOMATIC_QUARTER", "PR": "DISTRICT_PRESERVE"}
DISTRICT_CODE = {v: k for k, v in DISTRICTS.items()}
# Neighbour offsets by direction, for even and odd rows (row 0 on top; the
# directions of cmp_game.lua's DIRECTIONS, clockwise from north-east).
DIRECTIONS = ["NE", "E", "SE", "SW", "W", "NW"]
OFFSETS = {0: {"NE": (0, -1), "E": (1, 0), "SE": (0, 1), "SW": (-1, 1), "W": (-1, 0), "NW": (-1, -1)},
           1: {"NE": (1, -1), "E": (1, 0), "SE": (1, 1), "SW": (0, 1), "W": (-1, 0), "NW": (0, -1)}}
CELL = re.compile(r"^(?P<t>[A-Za-z_]+?)(?:\+(?P<f>[A-Za-z_]+))?(?::(?P<r>[A-Za-z_]+))?"
                  r"(?:@(?P<i>[A-Za-z_]+))?(?P<q>\?)?$")
SLOT = re.compile(r"^(?P<built>\*)?(?P<code>[A-Z][A-Z_]*?)(?P<n>\d+)?$")
COMMENT = re.compile(r"(^|\s)#.*$")  # "#" at the start or after a space; URLs keep theirs
SINGLE_KEYS = ("id", "title", "source", "author", "date", "ruleset", "civ", "techs", "civics", "pantheon", "turn", "guess")


class SceneError(Exception):
    pass


def neighbour(x, y, direction):
    dx, dy = OFFSETS[y & 1][direction]
    return x + dx, y + dy


def hex_distance(x1, y1, x2, y2):
    """Distance on the odd-r grid (as snapshot.py and cmp_game.lua)."""
    def cube(x, y):
        q = x - (y - (y & 1)) // 2
        return q, y, -q - y
    a, b = cube(x1, y1), cube(x2, y2)
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def full_name(prefix, name):
    return name.upper() if name.upper().startswith(prefix) else prefix + name.upper()


def short_name(prefix, name):
    return name[len(prefix):].lower() if name.startswith(prefix) else name


# ---------------------------------------------------------------------------
# Source text -> scene
# ---------------------------------------------------------------------------
def parse_terrain(code):
    if code.startswith("TERRAIN_"):
        return code, False
    if code == "L":
        return "TERRAIN_COAST", True
    if code == "M":
        return "TERRAIN_GRASS_MOUNTAIN", False
    base, suffix = code[:1], code[1:]
    if base not in TERRAINS or suffix not in ("", "h", "m"):
        raise SceneError("unknown terrain %r" % code)
    return TERRAINS[base] + {"": "", "h": "_HILLS", "m": "_MOUNTAIN"}[suffix], False


def parse_feature(code, terrain, ruleset):
    if code == "fp":
        if ruleset != "RULESET_EXPANSION_2":
            return "FEATURE_FLOODPLAINS"
        return {"TERRAIN_GRASS": "FEATURE_FLOODPLAINS_GRASSLAND",
                "TERRAIN_PLAINS": "FEATURE_FLOODPLAINS_PLAINS"}.get(terrain, "FEATURE_FLOODPLAINS")
    return FEATURES.get(code) or full_name("FEATURE_", code)


def parse_grid(lines, what):
    rows = []
    for number, text in lines:
        cells = COMMENT.sub("", text).split()
        if cells:
            rows.append((number, cells))
    if not rows:
        raise SceneError("%s: no rows" % what)
    width = len(rows[0][1])
    for number, cells in rows:
        if len(cells) != width:
            raise SceneError("line %d: %s row has %d plots, the first row %d" % (number, what, len(cells), width))
    return rows, width


def parse_source(text, path="<text>"):
    """Parse a reference scene's text. Returns (scenario, spec) as written to
    the scene file; raises SceneError with the line number on a mistake."""
    head, cities, rivers, wonders, notes = {}, {}, [], [], []
    blocks = {"map": [], "layout": []}
    block = None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if block is not None:
            if line.strip() == "end":
                block = None
            else:
                blocks[block].append((number, line))
            continue
        stripped = COMMENT.sub("", line).strip()
        if not stripped:
            continue
        key, _, rest = stripped.partition(" ")
        rest = rest.strip()
        try:
            if key in ("map", "layout"):
                if blocks[key]:
                    raise SceneError("second %s block" % key)
                block = key
            elif key in SINGLE_KEYS:
                if key in head:
                    raise SceneError("%s given twice" % key)
                head[key] = rest
            elif key == "note":
                notes.append(rest)
            elif key == "city":
                parts = rest.split()
                n = int(parts[0])
                if n in cities:
                    raise SceneError("city %d given twice" % n)
                entry = {"n": n}
                for part in parts[1:]:
                    k, _, v = part.partition("=")
                    if k == "capital" and not v:
                        entry["capital"] = True
                    elif k in ("pop", "owns"):
                        entry[k] = int(v)
                    elif k == "name":
                        entry["name"] = v
                    else:
                        raise SceneError("unknown city field %r" % part)
                cities[n] = entry
            elif key == "river":
                parts = rest.split()
                name, edges = parts[0], []
                for part in parts[1:]:
                    at, _, dirs = part.partition(":")
                    x, y = (int(v) for v in at.split(","))
                    for d in dirs.split(","):
                        if d not in DIRECTIONS:
                            raise SceneError("unknown direction %r (NE E SE SW W NW)" % d)
                        edges.append(((x, y), neighbour(x, y, d)))
                rivers.append((number, name, edges))
            elif key == "wonder":
                parts = rest.split()
                x, y = (int(v) for v in parts[0].split(","))
                fields = dict(p.partition("=")[::2] for p in parts[2:])
                wonders.append((number, x, y, full_name("BUILDING_", parts[1]), int(fields.get("city", "1"))))
            else:
                raise SceneError("unknown line %r" % key)
        except (ValueError, IndexError) as e:
            raise SceneError("%s:%d: %s" % (path, number, e))
        except SceneError as e:
            raise SceneError("%s:%d: %s" % (path, number, e))
    if block is not None:
        raise SceneError("%s: %s block without end" % (path, block))
    for key in ("id", "civ"):
        if key not in head:
            raise SceneError("%s: no %s line" % (path, key))
    sid = head["id"]
    if not re.match(r"^REF\d\d-[a-z0-9-]+$", sid):
        raise SceneError("%s: id %r must look like REF01-some-name" % (path, sid))
    ruleset = head.get("ruleset", "RULESET_EXPANSION_2")
    civ, _, leader = head["civ"].partition(" ")
    if not leader:
        raise SceneError("%s: civ needs the civilization and the leader" % path)

    try:
        rows, width = parse_grid(blocks["map"], "map")
    except SceneError as e:
        raise SceneError("%s: %s" % (path, e))
    height = len(rows)
    plots, guessed = [], []
    for y, (number, cells) in enumerate(rows):
        for x, cell in enumerate(cells):
            m = CELL.match(cell)
            if not m:
                raise SceneError("%s:%d: cannot read plot %r at %d,%d" % (path, number, cell, x, y))
            try:
                terrain, lake = parse_terrain(m.group("t"))
            except SceneError as e:
                raise SceneError("%s:%d: %s at %d,%d" % (path, number, e, x, y))
            plot = {"t": terrain}
            if lake:
                plot["lake"] = True
            if m.group("f"):
                plot["f"] = parse_feature(m.group("f"), terrain, ruleset)
            if m.group("r"):
                plot["r"], plot["rc"] = full_name("RESOURCE_", m.group("r")), 1
            if m.group("i"):
                plot["imp"] = full_name("IMPROVEMENT_", m.group("i"))
            if m.group("q"):
                guessed.append(y * width + x)
            plots.append(plot)
    guess_all = head.get("guess", "") == "all"
    if "guess" in head and not guess_all:
        raise SceneError("%s: guess takes only 'all' (mark single plots with ?)" % path)

    def index(x, y, number, what):
        if not (0 <= x < width and 0 <= y < height):
            raise SceneError("%s:%d: %s at %d,%d is off the map (%dx%d)" % (path, number, what, x, y, width, height))
        return y * width + x

    # Layout: city centers, built districts (*) and the reference layout.
    try:
        lrows, lwidth = parse_grid(blocks["layout"], "layout") if blocks["layout"] else ([], width)
    except SceneError as e:
        raise SceneError("%s: %s" % (path, e))
    if blocks["layout"] and (lwidth != width or len(lrows) != height):
        raise SceneError("%s: layout is %dx%d, the map %dx%d" % (path, lwidth, len(lrows), width, height))
    slots = []
    for y, (number, cells) in enumerate(lrows):
        for x, cell in enumerate(cells):
            if cell == ".":
                continue
            m = SLOT.match(cell)
            if not m:
                raise SceneError("%s:%d: cannot read layout entry %r at %d,%d" % (path, number, cell, x, y))
            code = m.group("code")
            dtype = DISTRICTS.get(code) or (code if code.startswith("DISTRICT_") else None)
            if dtype is None:
                raise SceneError("%s:%d: unknown district %r at %d,%d" % (path, number, code, x, y))
            slots.append((number, x, y, dtype, m.group("built") is not None, m.group("n")))
    centers = [s for s in slots if s[3] == "DISTRICT_CITY_CENTER"]
    if not centers:
        raise SceneError("%s: no city center (CC) in the layout" % path)
    several = len(centers) > 1
    spec_cities = {}
    for number, x, y, dtype, built, n in centers:
        if n is None and several:
            raise SceneError("%s:%d: with several cities each CC needs its number (CC1, CC2)" % (path, number))
        n = int(n or 1)
        if n in spec_cities:
            raise SceneError("%s:%d: city %d has two centers" % (path, number, n))
        attrs = cities.get(n, {})
        spec_cities[n] = {"id": n, "owner": 0, "x": x, "y": y, "name": attrs.get("name", "City%d" % n),
                          "population": attrs.get("pop", 10), "capital": attrs.get("capital", False),
                          "rings": attrs.get("owns", 1),
                          "districts": [], "buildings": [], "plots": []}
    for n in cities:
        if n not in spec_cities:
            raise SceneError("%s: city %d has no CC%d in the layout" % (path, n, n))
    if not any(c["capital"] for c in spec_cities.values()):
        spec_cities[min(spec_cities)]["capital"] = True
    order = sorted(spec_cities)
    placements, occupied = [], {}
    for number, x, y, dtype, built, n in slots:
        if dtype == "DISTRICT_CITY_CENTER":
            continue
        if n is None and several:
            raise SceneError("%s:%d: with several cities each district needs its city number (IZ1)" % (path, number))
        n = int(n or order[0])
        if n not in spec_cities:
            raise SceneError("%s:%d: no city %d" % (path, number, n))
        city = spec_cities[n]
        if hex_distance(x, y, city["x"], city["y"]) > 3:
            raise SceneError("%s:%d: %s at %d,%d is more than 3 from city %d" % (path, number, dtype, x, y, n))
        if built:
            city["districts"].append({"type": dtype, "x": x, "y": y})
            occupied[(x, y)] = n
        else:
            placements.append({"city": n, "type": dtype, "x": x, "y": y})
    # Owned plots: each city its rings up to `owns` (default 1) and the plots
    # of its built districts, in city order, a plot to the first city that
    # claims it (the center itself is added by cmp_game).
    owner = {}
    for n in order:
        c = spec_cities[n]
        owner[c["y"] * width + c["x"]] = n
    for (x, y), n in sorted(occupied.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        owner.setdefault(y * width + x, n)
    for n in order:
        c = spec_cities[n]
        rings = c["rings"]
        for i in range(width * height):
            if hex_distance(i % width, i // width, c["x"], c["y"]) <= rings:
                owner.setdefault(i, n)
    for i in sorted(owner):
        n = owner[i]
        c = spec_cities[n]
        if i != c["y"] * width + c["x"]:
            c["plots"].append(i)

    # Rivers: edges between two plots; floodplains belong to the first river
    # running along one of their edges.
    spec_rivers, by_name = [], {}
    for number, name, edges in rivers:
        if name not in by_name:
            by_name[name] = {"name": name, "edges": [], "floodplains": []}
            spec_rivers.append(by_name[name])
        entry = by_name[name]
        for (ax, ay), (bx, by) in edges:
            a, b = index(ax, ay, number, "river edge"), index(bx, by, number, "river edge")
            if [a, b] in entry["edges"] or [b, a] in entry["edges"]:
                raise SceneError("%s:%d: river edge %d,%d-%d,%d given twice" % (path, number, ax, ay, bx, by))
            entry["edges"].append([a, b])
    for i, plot in enumerate(plots):
        if plot.get("f") in FLOODPLAINS:
            river = next((r for r in spec_rivers if any(i in e for e in r["edges"])), None)
            if river is None:
                raise SceneError("%s: floodplains at %d,%d with no river along them" % (path, i % width, i // width))
            river["floodplains"].append(i)

    spec_wonders = []
    for number, x, y, building, n in wonders:
        index(x, y, number, "wonder")
        if n not in spec_cities:
            raise SceneError("%s:%d: no city %d" % (path, number, n))
        spec_wonders.append({"building": building, "city": n, "owner": 0, "x": x, "y": y})

    techs = head.get("techs", "all")
    civics = head.get("civics", "all")
    player = {"id": 0, "civ": civ, "leader": leader, "minor": False,
              "techs": techs if techs == "all" else [full_name("TECH_", t) for t in techs.split(",") if t],
              "civics": civics if civics == "all" else [full_name("CIVIC_", t) for t in civics.split(",") if t]}
    if head.get("pantheon"):
        player["pantheon"] = full_name("BELIEF_", head["pantheon"])

    # What the scene asks for: per city the reference layout's districts.
    plans = [[p["type"] for p in placements if p["city"] == n] for n in order]
    union = []
    for plan in plans:
        for t in plan:
            if t not in union:
                union.append(t)
    kind = "multi" if several else "single"
    scenario = {"id": sid, "kind": kind, "set": "REF", "civ": civ, "leader": leader,
                "title": head.get("title", sid), "districts": union, "only": order, "target": order[0],
                "file": sid + ".json", "turn": int(head.get("turn", "150")), "ruleset": ruleset,
                "source": head.get("source", ""), "author": head.get("author", ""), "date": head.get("date", "")}
    if kind == "multi":
        scenario["plans"] = plans
    spec = {
        "width": width, "height": height, "plots": plots, "rivers": spec_rivers, "players": [player],
        "cities": [spec_cities[n] for n in order], "wonders": spec_wonders, "pins": [], "sample": [],
        "turn": scenario["turn"], "ruleset": ruleset,
        "meta": {"localPlayer": 0, "refscene": path, "mapWidth": width, "mapHeight": height, "x0": 0, "y0": 0},
        "reference": {"placements": placements, "guessed": list(range(width * height)) if guess_all else guessed,
                      "guessAll": guess_all, "notes": notes},
        "scenario": scenario,
    }
    return scenario, spec


# ---------------------------------------------------------------------------
# Scene -> text (the round trip and --check)
# ---------------------------------------------------------------------------
def cell_token(plot, guessed):
    t = plot["t"]
    if plot.get("lake"):
        code = "L"
    elif t in TERRAIN_CODE:
        code = TERRAIN_CODE[t]
    elif t.endswith("_HILLS") and t[:-6] in TERRAIN_CODE:
        code = TERRAIN_CODE[t[:-6]] + "h"
    elif t.endswith("_MOUNTAIN") and t[:-9] in TERRAIN_CODE:
        code = TERRAIN_CODE[t[:-9]] + "m"
    else:
        code = t
    f = plot.get("f")
    if f:
        code += "+" + ("fp" if f in FLOODPLAINS else FEATURE_CODE.get(f) or short_name("FEATURE_", f))
    if plot.get("r"):
        code += ":" + short_name("RESOURCE_", plot["r"])
    if plot.get("imp"):
        code += "@" + short_name("IMPROVEMENT_", plot["imp"])
    if guessed:
        code += "?"
    return code


def grid_lines(cells, width):
    size = max(len(c) for c in cells) + 1
    half = (size + 1) // 2
    lines = []
    for y in range(len(cells) // width):
        row = cells[y * width:(y + 1) * width]
        lines.append("  " + (" " * half if y & 1 else "") + "".join(c.ljust(size) for c in row).rstrip())
    return lines


def to_text(spec):
    """The scene file written back in the source format (canonical codes)."""
    scn, ref, width = spec["scenario"], spec["reference"], spec["width"]
    player = spec["players"][0]
    out = ["# written back from tests/compare/scenes/%s by tools/refscene.py" % scn["file"],
           "id      %s" % scn["id"], "title   %s" % scn["title"]]
    for key in ("source", "author", "date"):
        if scn.get(key):
            out.append("%-7s %s" % (key, scn[key]))
    out.append("ruleset %s" % scn["ruleset"])
    out.append("civ     %s %s" % (player["civ"], player["leader"]))
    for key, prefix in (("techs", "TECH_"), ("civics", "CIVIC_")):
        v = player[key]
        out.append("%-7s %s" % (key, v if v == "all" else ",".join(short_name(prefix, t) for t in v)))
    if player.get("pantheon"):
        out.append("pantheon %s" % short_name("BELIEF_", player["pantheon"]))
    out.append("turn    %d" % scn["turn"])
    if ref.get("guessAll"):
        out.append("guess   all")
    for note in ref.get("notes", []):
        out.append("note    %s" % note)
    out.append("")
    for c in spec["cities"]:
        fields = ["name=%s" % c["name"], "pop=%d" % c["population"], "owns=%d" % c["rings"]]
        if c.get("capital"):
            fields.append("capital")
        out.append("city %d %s" % (c["id"], " ".join(fields)))
    guessed = set() if ref.get("guessAll") else set(ref.get("guessed", []))
    out.append("")
    out.append("map")
    out.extend(grid_lines([cell_token(p, i in guessed) for i, p in enumerate(spec["plots"])], width))
    out.append("end")
    several = len(spec["cities"]) > 1
    layout = ["."] * (width * spec["height"])
    for c in spec["cities"]:
        layout[c["y"] * width + c["x"]] = "CC" + (str(c["id"]) if several else "")
        for d in c["districts"]:
            layout[d["y"] * width + d["x"]] = "*" + DISTRICT_CODE.get(d["type"], d["type"]) + (str(c["id"]) if several else "")
    for p in ref["placements"]:
        layout[p["y"] * width + p["x"]] = DISTRICT_CODE.get(p["type"], p["type"]) + (str(p["city"]) if several else "")
    out.append("")
    out.append("layout")
    out.extend(grid_lines(layout, width))
    out.append("end")
    out.append("")
    for river in spec["rivers"]:
        by_plot = {}
        for a, b in river["edges"]:
            ax, ay, bx, by = a % width, a // width, b % width, b // width
            d = next(d for d in DIRECTIONS if neighbour(ax, ay, d) == (bx, by))
            by_plot.setdefault((ay, ax), []).append(d)
        parts = ["%d,%d:%s" % (x, y, ",".join(sorted(ds, key=DIRECTIONS.index))) for (y, x), ds in sorted(by_plot.items())]
        out.append("river %s %s" % (river["name"], " ".join(parts)))
    for wd in spec["wonders"]:
        out.append("wonder %d,%d %s city=%d" % (wd["x"], wd["y"], wd["building"], wd["city"]))
    return "\n".join(out) + "\n"


def canonical(spec):
    """The parts of a scene the round trip must keep (river edge order and
    direction are free)."""
    s = json.loads(json.dumps(spec))
    s.pop("meta", None)
    for river in s["rivers"]:
        river["edges"] = sorted(sorted(e) for e in river["edges"])
        river["floodplains"] = sorted(river["floodplains"])
    s["reference"]["guessed"] = sorted(s["reference"]["guessed"])
    s["reference"]["placements"] = sorted(s["reference"]["placements"], key=lambda p: (p["y"], p["x"]))
    for c in s["cities"]:
        c["districts"] = sorted(c["districts"], key=lambda d: (d["y"], d["x"]))
    return s


def round_trip_problem(spec):
    """None when text written back from `spec` reads as the same scene."""
    _, again = parse_source(to_text(spec), "<written back>")
    a, b = canonical(spec), canonical(again)
    if a != b:
        diff = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
        return "round trip differs in %s" % ", ".join(diff)
    return None


def to_svg(spec, size=28):
    """A picture of the scene: terrain, features, rivers, cities and the
    reference layout (built districts in grey), guessed plots dashed."""
    width, height = spec["width"], spec["height"]
    w = math.sqrt(3) * size
    colors = {"TERRAIN_GRASS": "#9cc46a", "TERRAIN_PLAINS": "#d2c46e", "TERRAIN_DESERT": "#ead9a0",
              "TERRAIN_TUNDRA": "#a9a48c", "TERRAIN_SNOW": "#f0f2f4", "TERRAIN_COAST": "#7fb8d8",
              "TERRAIN_OCEAN": "#4a83b0"}

    def center(x, y):
        return w * (x + 0.5 * (y & 1)) + w / 2 + 4, 1.5 * size * y + size + 4

    def corner(cx, cy, k):
        a = math.radians(60 * k - 90)
        return cx + size * math.cos(a), cy + size * math.sin(a)

    guessed = set(spec["reference"].get("guessed", []))
    layout = {}
    for c in spec["cities"]:
        layout[(c["x"], c["y"])] = ("CC%d" % c["id"], "#ffffff", "#222")
        for d in c["districts"]:
            layout[(d["x"], d["y"])] = (DISTRICT_CODE.get(d["type"], d["type"][9:12]) + str(c["id"]), "#bbbbbb", "#222")
    for p in spec["reference"]["placements"]:
        layout[(p["x"], p["y"])] = (DISTRICT_CODE.get(p["type"], p["type"][9:12]) + str(p["city"]), "#f6a623", "#222")
    parts = []
    W = w * (width + 0.5) + 8
    H = 1.5 * size * (height - 1) + 2 * size + 8
    parts.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %.1f %.1f" '
                 'font-family="sans-serif">' % (W, H, W, H))
    parts.append('<rect width="100%%" height="100%%" fill="#ffffff"/>')
    for i, plot in enumerate(spec["plots"]):
        x, y = i % width, i // width
        cx, cy = center(x, y)
        t = plot["t"]
        base = t.replace("_HILLS", "").replace("_MOUNTAIN", "")
        fill = "#4f9fd0" if plot.get("lake") else colors.get(base, "#cccccc")
        if t.endswith("_MOUNTAIN"):
            fill = "#8a7f74"
        pts = " ".join("%.1f,%.1f" % corner(cx, cy, k) for k in range(6))
        dash = ' stroke-dasharray="3,2"' if i in guessed else ""
        parts.append('<polygon points="%s" fill="%s" stroke="#555" stroke-width="0.8"%s/>' % (pts, fill, dash))
        if t.endswith("_HILLS"):
            parts.append('<path d="M%.1f,%.1f q%.1f,-%.1f %.1f,0" fill="none" stroke="#5b4a2f" stroke-width="1.2"/>'
                         % (cx - size * 0.45, cy + size * 0.55, size * 0.25, size * 0.3, size * 0.5))
        label = []
        if plot.get("f"):
            label.append("fp" if plot["f"] in FLOODPLAINS else FEATURE_CODE.get(plot["f"], short_name("FEATURE_", plot["f"])))
        if plot.get("r"):
            label.append(short_name("RESOURCE_", plot["r"]))
        if label:
            parts.append('<text x="%.1f" y="%.1f" font-size="8" text-anchor="middle" fill="#233">%s</text>'
                         % (cx, cy - size * 0.5, " ".join(label)))
        if (x, y) in layout:
            text, bg, fg = layout[(x, y)]
            parts.append('<rect x="%.1f" y="%.1f" width="%.1f" height="12" rx="3" fill="%s" stroke="#333" stroke-width="0.6"/>'
                         % (cx - size * 0.62, cy - 4, size * 1.24, bg))
            parts.append('<text x="%.1f" y="%.1f" font-size="9" font-weight="bold" text-anchor="middle" fill="%s">%s</text>'
                         % (cx, cy + 5, fg, text))
        parts.append('<text x="%.1f" y="%.1f" font-size="6" text-anchor="middle" fill="#334">%d,%d</text>'
                     % (cx, cy + size * 0.72, x, y))
    for river in spec["rivers"]:
        for a, b in river["edges"]:
            ax, ay, bx, by = a % width, a // width, b % width, b // width
            k = DIRECTIONS.index(next(d for d in DIRECTIONS if neighbour(ax, ay, d) == (bx, by)))
            cx, cy = center(ax, ay)
            p1, p2 = corner(cx, cy, k), corner(cx, cy, k + 1)
            parts.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#1f5fbf" stroke-width="4" '
                         'stroke-linecap="round"/>' % (p1 + p2))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
def source_files(ids=None):
    if not os.path.isdir(SOURCES):
        return []
    files = sorted(f for f in os.listdir(SOURCES) if f.endswith(".txt"))
    if ids:
        files = [f for f in files if any(f[:-4] == i or f.startswith(i) for i in ids)]
    return [os.path.join(SOURCES, f) for f in files]


def convert(path):
    with open(path, encoding="utf-8") as f:
        scenario, spec = parse_source(f.read(), os.path.relpath(path, ROOT).replace(os.sep, "/"))
    if scenario["id"] != os.path.basename(path)[:-4]:
        raise SceneError("%s: the id line says %s, the file name %s" % (path, scenario["id"], os.path.basename(path)[:-4]))
    return scenario, spec


def scene_text(spec):
    return json.dumps(spec, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"


def read_index():
    if not os.path.exists(INDEX):
        return []
    with open(INDEX, encoding="utf-8") as f:
        return json.load(f)


def index_text(entries):
    entries = sorted(entries, key=lambda e: e["id"])
    return json.dumps(entries, ensure_ascii=False, indent=1) + "\n"


def problems():
    """What validate.py reports: sources that do not parse, do not survive
    the round trip, or whose scene file or index entry is out of date."""
    out = []
    index = {e["id"]: e for e in read_index()}
    for path in source_files():
        rel = os.path.relpath(path, ROOT)
        try:
            scenario, spec = convert(path)
        except SceneError as e:
            out.append((rel, str(e)))
            continue
        problem = round_trip_problem(spec)
        if problem:
            out.append((rel, problem))
        target = os.path.join(SCENES, scenario["file"])
        if not os.path.exists(target):
            out.append((rel, "no scene file; run: python3 -I tools/refscene.py build"))
        else:
            with open(target, encoding="utf-8") as f:
                if f.read() != scene_text(spec):
                    out.append((rel, "scene file out of date; run: python3 -I tools/refscene.py build"))
        if index.get(scenario["id"]) != scenario:
            out.append((rel, "index.json entry out of date; run: python3 -I tools/refscene.py build"))
    return out


def cmd_build(args):
    paths = source_files(args.ids)
    if not paths:
        print("no sources in %s" % os.path.relpath(SOURCES, ROOT))
        return 2
    entries = {e["id"]: e for e in read_index()}
    code = 0
    for path in paths:
        try:
            scenario, spec = convert(path)
            problem = round_trip_problem(spec)
            if problem:
                raise SceneError(problem)
        except SceneError as e:
            print("ERROR %s" % e)
            code = 1
            continue
        target = os.path.join(SCENES, scenario["file"])
        os.makedirs(SCENES, exist_ok=True)
        with open(target, "w", encoding="utf-8", newline="\n") as f:
            f.write(scene_text(spec))
        entries[scenario["id"]] = scenario
        ref = spec["reference"]
        print("%s: %dx%d, %d cities, %d rivers, reference %s; guessed %s" % (
            os.path.relpath(target, ROOT), spec["width"], spec["height"], len(spec["cities"]), len(spec["rivers"]),
            ", ".join("%s@%d,%d" % (DISTRICT_CODE.get(p["type"], p["type"]) + str(p["city"]), p["x"], p["y"])
                      for p in ref["placements"]),
            "all" if ref["guessAll"] else "%d plots" % len(ref["guessed"])))
    with open(INDEX, "w", encoding="utf-8", newline="\n") as f:
        f.write(index_text(list(entries.values())))
    return code


def load_scene(sid):
    entry = next((e for e in read_index() if e["id"] == sid or e["id"].startswith(sid)), None)
    if entry is None or entry.get("set") != "REF":
        raise SceneError("no reference scene %s in index.json" % sid)
    with open(os.path.join(SCENES, entry["file"]), encoding="utf-8") as f:
        return json.load(f)


def cmd_check(args):
    try:
        spec = load_scene(args.id)
    except SceneError as e:
        print(e)
        return 2
    sys.stdout.write(to_text(spec))
    problem = round_trip_problem(spec)
    print("# round trip: %s" % (problem or "ok"))
    if args.svg:
        with open(args.svg, "w", encoding="utf-8", newline="\n") as f:
            f.write(to_svg(spec))
        print("# picture: %s" % args.svg)
    return 1 if problem else 0


def cmd_verify(args):
    bad = problems()
    for rel, message in bad:
        print("ERROR %s: %s" % (rel, message))
    ids = [e["id"] for e in read_index() if e.get("set") == "REF"
           and (not args.ids or any(e["id"].startswith(i) for i in args.ids))]
    code = 1 if bad else 0
    os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
    for sid in ids:
        proc = subprocess.run(["node", os.path.join(ROOT, "tools", "compare.mjs"), "--refscore", "--reference-only",
                               "-s", "^" + re.escape(sid) + "$", "-j", "1", "--out",
                               os.path.join(ROOT, "logs", "refscene-verify.jsonl")],
                              cwd=ROOT, capture_output=True, text=True)
        rows = []
        path = os.path.join(ROOT, "logs", "refscene-verify.jsonl")
        if proc.returncode == 0 and os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                rows = [json.loads(l) for l in f if l.strip()]
        ref = rows[0].get("reference") if rows else None
        if ref is None or rows[0].get("error"):
            print("ERROR %s: the judge gave no score\n%s%s" % (sid, proc.stdout[-1500:], proc.stderr[-1500:]))
            code = 1
            continue
        spec = load_scene(sid)
        wanted = len(spec["reference"]["placements"])
        problems_here = []
        if not ref.get("legal"):
            problems_here.append("not legal: %s" % "; ".join(
                "%s %s at %s,%s %s" % (v["kind"], v.get("type"), v.get("x"), v.get("y"), v.get("detail") or "")
                for v in ref["violations"]))
        if ref.get("placed") != wanted:
            problems_here.append("placed %s of %d" % (ref.get("placed"), wanted))
        if ref.get("missing"):
            problems_here.append("%d requested districts missing" % ref["missing"])
        print("%s %s: reference gain %s, items %s" % ("ERROR" if problems_here else "ok", sid, ref.get("gain"),
                                                       ", ".join("%s %s" % (i["type"][9:], i["adj"]) for i in ref.get("items", []))))
        for p in problems_here:
            print("    " + p)
        if problems_here:
            code = 1
    return code


def cmd_list(_args):
    for e in read_index():
        if e.get("set") == "REF":
            print("%-34s %-6s %-26s %s" % (e["id"], e["kind"], e["civ"], e["title"]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    bp = sub.add_parser("build", help="convert sources into scene files and index.json entries")
    bp.add_argument("ids", nargs="*")
    cp = sub.add_parser("check", help="render a scene file back as text (and an SVG picture)")
    cp.add_argument("id")
    cp.add_argument("--svg", help="write a picture of the scene to this file")
    vp = sub.add_parser("verify", help="round trip, up to date, and the judge accepts the reference layout")
    vp.add_argument("ids", nargs="*")
    sub.add_parser("list")
    args = ap.parse_args(argv)
    return {"build": cmd_build, "check": cmd_check, "verify": cmd_verify, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
