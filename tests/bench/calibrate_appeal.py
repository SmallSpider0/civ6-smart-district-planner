"""Engine calibration of the appeal part (SDP_Appeal; docs/multicity-design.md 22).

The planner predicts appeal, a neighborhood's housing and a preserve's
yields from GameInfo and the game's current appeal; here the game builds the
plan and its own numbers are read back:
  A  a theater (on a plot whose feature building clears), an industrial zone
     and a holy site: Plot:GetAppeal of every plot within 4 of the capital
  B  a neighborhood next to the industrial zone: the city's housing before
     and after
  C  a preserve with its grove and sanctuary: the city's housing, and each
     plot around it, its yields before and after
The plan is picked and predicted in the SDP_Panel state (appeal_plan.lua),
built in GameCore_Tuner. Needs a game with the tuner on and a capital
(tools/game.py newgame --capital --reveal); changes the game for good
(everything unlocked, districts built): use a throwaway game.

    python3 -I tests/bench/calibrate_appeal.py
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402

YIELDS = ["YIELD_FOOD", "YIELD_PRODUCTION", "YIELD_GOLD", "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH"]


def run(state, code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("%s: %s" % (state, resp.get("error")))
    return resp.get("output") or []


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as fh:
        return fh.read()


def tagged(lines, tag):
    for line in lines:
        if line.startswith(tag + " "):
            return json.loads(line[len(tag) + 1:])
    raise SystemExit("no %s line in:\n%s" % (tag, "\n".join(lines)))


CITY = "local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()\n"
BUILD = """
local function Build(t, index)
  local row = GameInfo.Districts[t]
  city:GetBuildQueue():CreateDistrict(row.Index, index)
  local plot = Map.GetPlotByIndex(index)
  if plot:GetDistrictType() ~= row.Index then error("not built: " .. t .. " at " .. index) end
end
"""


def lua_list(values):
    return "{" + ",".join(str(v) for v in values) + "}"


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--no-unlock", action="store_true", help="do not unlock every technology and civic first")
    args = ap.parse_args()
    prefix = "SDP_APPEAL_UNLOCK = %s\n" % ("false" if args.no_unlock else "true")
    print("setup:", " ".join(run("GameCore_Tuner", prefix + read("tests/fixtures/appeal_setup.lua"))))
    time.sleep(3)  # let the UI state catch up with the setup
    plan = tagged(run("SDP_Panel", read("tests/bench/appeal_plan.lua"), 120), "SDP_APPEAL_PLAN")
    builds = plan["Builds"]
    for b in builds:
        print("plan %s: %s at (%d, %d)" % (b["Step"], b["Type"], b["X"], b["Y"]))
    failures = 0

    # The base the plan predicted from, against the game core's own reading.
    indices = [e["Index"] for e in plan["AppealA"]]
    code = "local out = {}\nfor _, i in ipairs(%s) do out[#out + 1] = i .. ':' .. Map.GetPlotByIndex(i):GetAppeal() end\n" % lua_list(indices)
    code += 'print("BASE " .. table.concat(out, ","))\n'
    core = {}
    for line in run("GameCore_Tuner", code):
        if line.startswith("BASE "):
            for part in line[5:].split(","):
                i, a = part.split(":")
                core[int(i)] = int(a)
    stale = [(e["Index"], e["Base"], core.get(e["Index"])) for e in plan["AppealA"] if core.get(e["Index"]) != e["Base"]]
    print("base: %d/%d plots read the same in both states%s" % (len(indices) - len(stale), len(indices),
                                                                "" if not stale else " (stale: %s)" % stale[:8]))

    # A: appeal around after the changers.
    code = CITY + BUILD
    for b in builds:
        if b["Step"] == "A":
            code += 'Build("%s", %d)\n' % (b["Type"], b["Index"])
    indices = [e["Index"] for e in plan["AppealA"]]
    code += "local out = {}\nfor _, i in ipairs(%s) do out[#out + 1] = i .. ':' .. Map.GetPlotByIndex(i):GetAppeal() end\n" % lua_list(indices)
    code += 'print("APPEAL " .. table.concat(out, ","))\n'
    lines = run("GameCore_Tuner", code)
    measured = {}
    for line in lines:
        if line.startswith("APPEAL "):
            for part in line[7:].split(","):
                i, a = part.split(":")
                measured[int(i)] = int(a)
    same = 0
    for e in plan["AppealA"]:
        got = measured.get(e["Index"])
        if got == e["Appeal"]:
            same += 1
        else:
            failures += 1
            print("  appeal at plot %d: predicted %s, game %s" % (e["Index"], e["Appeal"], got))
    print("A appeal: %d/%d plots as predicted" % (same, len(plan["AppealA"])))

    # B: a neighborhood's housing.
    hood = next(b for b in builds if b["Step"] == "B")
    code = CITY + BUILD + "local before = city:GetGrowth():GetHousing()\n"
    code += 'Build("%s", %d)\n' % (hood["Type"], hood["Index"])
    code += 'print("HOUSING " .. before .. " " .. city:GetGrowth():GetHousing() .. " " .. Map.GetPlotByIndex(%d):GetAppeal())\n' % hood["Index"]
    line = next(l for l in run("GameCore_Tuner", code) if l.startswith("HOUSING "))
    before, after, appeal = (float(v) for v in line.split()[1:])
    want = plan["Neighborhood"]
    ok = abs((after - before) - want["Housing"]) < 1e-6 and appeal == want["Appeal"]
    failures += 0 if ok else 1
    print("B neighborhood: appeal predicted %s game %s, housing predicted +%s game %+g %s"
          % (want["Appeal"], appeal, want["Housing"], after - before, "" if ok else "MISMATCH"))

    # C: a preserve, its grove and sanctuary.
    preserve = next(b for b in builds if b["Step"] == "C")
    tiles = plan["Tiles"]
    yields_lua = "{" + ",".join('"%s"' % y for y in YIELDS) + "}"
    # Plot yields are read in the UI state: Plot:GetYield in GameCore_Tuner
    # leaves out what buildings give other plots (2026-10-21, see
    # probe_preserve.py), and the UI state sees a change a frame later.
    snap = """
local yields = %s
local out = {}
for _, i in ipairs(%s) do
  local plot = Map.GetPlotByIndex(i)
  local parts = {}
  for _, y in ipairs(yields) do parts[#parts + 1] = plot:GetYield(GameInfo.Yields[y].Index) end
  out[#out + 1] = i .. ":" .. table.concat(parts, "/")
end
print("%%s " .. table.concat(out, ","))
""" % (yields_lua, lua_list([t["Index"] for t in tiles]))
    lines = run("InGame", snap % "BEFORE")
    code = CITY + BUILD + """
local before = city:GetGrowth():GetHousing()
Build("%s", %d)
for _, b in ipairs({ "BUILDING_GROVE", "BUILDING_SANCTUARY" }) do
  WorldBuilder.CityManager():CreateBuilding(city, b, 100, %d)
end
print("HOUSING " .. before .. " " .. city:GetGrowth():GetHousing() .. " " .. Map.GetPlotByIndex(%d):GetAppeal())
""" % (preserve["Type"], preserve["Index"], preserve["Index"], preserve["Index"])
    lines += run("GameCore_Tuner", code)
    time.sleep(2)
    lines += run("InGame", snap % "AFTER")

    def parse(tag):
        line = next(l for l in lines if l.startswith(tag + " "))
        out = {}
        for part in line[len(tag) + 1:].split(","):
            i, values = part.split(":")
            out[int(i)] = [float(v) for v in values.split("/")]
        return out
    before, after = parse("BEFORE"), parse("AFTER")
    line = next(l for l in lines if l.startswith("HOUSING "))
    h0, h1, appeal = (float(v) for v in line.split()[1:])
    want = plan["Preserve"]
    ok = abs((h1 - h0) - want["Housing"]) < 1e-6 and appeal == want["Appeal"]
    failures += 0 if ok else 1
    print("C preserve: appeal predicted %s game %s, housing predicted +%s game %+g %s"
          % (want["Appeal"], appeal, want["Housing"], h1 - h0, "" if ok else "MISMATCH"))
    for t in tiles:
        got = {y: after[t["Index"]][k] - before[t["Index"]][k] for k, y in enumerate(YIELDS)}
        predicted = {y: (t["Yields"] or {}).get(y, 0) if isinstance(t["Yields"], dict) else 0 for y in YIELDS}
        same = all(abs(got[y] - predicted[y]) < 1e-6 for y in YIELDS)
        failures += 0 if same else 1
        print("  plot (%d, %d) appeal %s%s%s: predicted %s, game %s %s" % (
            t["X"], t["Y"], t["Appeal"], " blocked" if t["Blocked"] else "", "" if t["Workable"] else " unworkable",
            {y[6:]: v for y, v in predicted.items() if v}, {y[6:]: v for y, v in got.items() if v}, "" if same else "MISMATCH"))
    print("calibration: %s" % ("all as predicted" if failures == 0 else "%d mismatches" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
