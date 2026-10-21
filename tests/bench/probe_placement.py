"""What building a district really changes, through the game's own flow.

The calibration (calibrate_appeal.py) and the stress check build districts
with the build queue's CreateDistrict, which does not always clear the
plot's feature (woods stayed under a commercial hub in the islands save,
2026-10-21; AGENTS pitfall 36). Here the capital buys neighborhoods with
the player's flow: the capital is ordered to build a neighborhood on the
plot (CityOperationTypes.BUILD, as the placement screen does), then the
build queue finishes the current item (FinishProgress), as when production
runs out. Districts cannot be bought with gold. A neighborhood has no appeal of its own,
so what changes is what its plot loses. For a plot with woods, rainforest,
marsh, a farm, and a bare one: the plot's feature and improvement, its own
appeal and its neighbours' before and after, and the city's housing from
districts and from improvements.

Needs a throwaway game with a capital (game.py newgame --capital --reveal);
unlocks everything, grows the capital, puts two farms down.

    python3 -I tests/bench/probe_placement.py [--no-setup]

--no-setup keeps the game as it is (to test a player without, say, Mining:
give only what the neighborhood needs, the Urbanization civic).
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402


def run(state, code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("%s: %s" % (state, resp.get("error")))
    return resp.get("output") or []


def tagged(lines, tag):
    for line in lines:
        if line.startswith(tag + " "):
            return json.loads(line[len(tag) + 1:])
    raise SystemExit("no %s in %s" % (tag, lines))


SETUP = """
SDP_APPEAL_UNLOCK = true
%s
local pid = Game.GetLocalPlayer()
Players[pid]:GetTreasury():ChangeGoldBalance(1000000)
-- A farm on two bare flat plots, so one of the test plots has a farm.
local city = Players[pid]:GetCities():GetCapitalCity()
local farms = 0
for dx = -2, 2 do for dy = -2, 2 do
  local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 2)
  if farms < 2 and p and not p:IsWater() and not p:IsHills() and not p:IsMountain() and not p:IsCity()
      and p:GetFeatureType() == -1 and p:GetImprovementType() == -1 and p:GetDistrictType() == -1
      and p:GetResourceType() == -1 then
    ImprovementBuilder.SetImprovementType(p, GameInfo.Improvements["IMPROVEMENT_FARM"].Index, pid)
    farms = farms + 1
  end
end end
print("farms", farms)
"""

# In the UI state: candidate plots of each kind where buying a neighborhood works.
PICK = """
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
local hood = GameInfo.Districts["DISTRICT_NEIGHBORHOOD"]
local want = { FOREST = 1, JUNGLE = 1, MARSH = 1, FARM = 1, BARE = 1 }
local out = {}
for dx = -3, 3 do for dy = -3, 3 do
  local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
  if p and p:GetOwner() == pid and not p:IsWater() then
    local f = p:GetFeatureType()
    local kind = nil
    if p:GetImprovementType() ~= -1 then
      if GameInfo.Improvements[p:GetImprovementType()].ImprovementType == "IMPROVEMENT_FARM" then kind = "FARM" end
    elseif f ~= -1 then
      local ft = GameInfo.Features[f].FeatureType
      if ft == "FEATURE_FOREST" then kind = "FOREST" elseif ft == "FEATURE_JUNGLE" then kind = "JUNGLE"
      elseif ft == "FEATURE_MARSH" then kind = "MARSH" end
    elseif p:GetResourceType() == -1 then
      kind = "BARE"
    end
    if kind and want[kind] and want[kind] > 0 then
      local t = {}
      t[CityOperationTypes.PARAM_X] = p:GetX()
      t[CityOperationTypes.PARAM_Y] = p:GetY()
      t[CityOperationTypes.PARAM_DISTRICT_TYPE] = hood.Hash
      t[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE
      if CityManager.CanStartOperation(city, CityOperationTypes.BUILD, t) then
        -- Not next to another pick: each test sees only its own change.
        local apart = true
        for _, o in ipairs(out) do
          if Map.GetPlotDistance(o.X, o.Y, p:GetX(), p:GetY()) <= 2 then apart = false end
        end
        if apart then
          want[kind] = want[kind] - 1
          out[#out + 1] = { Kind = kind, X = p:GetX(), Y = p:GetY() }
        end
      end
    end
  end
end end
local parts = {}
for _, o in ipairs(out) do parts[#parts + 1] = string.format('{"Kind":"%s","X":%d,"Y":%d}', o.Kind, o.X, o.Y) end
print("PICK [" .. table.concat(parts, ",") .. "]")
"""

READ = """
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
local p = Map.GetPlot(%(x)d, %(y)d)
local n = {}
for dir = 0, 5 do local q = Map.GetAdjacentPlot(p:GetX(), p:GetY(), dir) if q then n[#n + 1] = q:GetAppeal() end end
local g = city:GetGrowth()
print(string.format('STATE {"Feature":%%d,"Improvement":%%d,"District":%%d,"Appeal":%%d,"Neighbours":[%%s],"Districts":%%s,"Improvements":%%s}',
  p:GetFeatureType(), p:GetImprovementType(), p:GetDistrictType(), p:GetAppeal(), table.concat(n, ","),
  tostring(g:GetHousingFromDistricts()), tostring(g:GetHousingFromImprovements())))
"""

BUY = """
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
local t = {}
t[CityOperationTypes.PARAM_X] = %(x)d
t[CityOperationTypes.PARAM_Y] = %(y)d
t[CityOperationTypes.PARAM_DISTRICT_TYPE] = GameInfo.Districts["DISTRICT_NEIGHBORHOOD"].Hash
t[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE
CityManager.RequestOperation(city, CityOperationTypes.BUILD, t)
print("ordered")
"""
FINISH = """
local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
city:GetBuildQueue():FinishProgress()
print("finished")
"""


def main():
    with open(os.path.join(ROOT, "tests", "fixtures", "appeal_setup.lua"), encoding="utf-8") as fh:
        setup = fh.read()
    if "--no-setup" not in sys.argv:
        print(" ".join(run("GameCore_Tuner", SETUP % setup)))
        time.sleep(3)
    picks = tagged(run("InGame", PICK), "PICK")
    print("plots:", picks)
    rows = []
    for pick in picks:
        before = tagged(run("InGame", READ % {"x": pick["X"], "y": pick["Y"]}), "STATE")
        run("InGame", BUY % {"x": pick["X"], "y": pick["Y"]})
        time.sleep(2)
        placed = tagged(run("InGame", READ % {"x": pick["X"], "y": pick["Y"]}), "STATE")
        print("  placed, not built: feature %d, district %d, own appeal %d" % (placed["Feature"], placed["District"],
                                                                              placed["Appeal"]))
        run("GameCore_Tuner", FINISH)
        time.sleep(3)
        after = tagged(run("InGame", READ % {"x": pick["X"], "y": pick["Y"]}), "STATE")
        rows.append((pick, before, after))
        dn = [a - b for a, b in zip(after["Neighbours"], before["Neighbours"])]
        print("%-6s (%d,%d): built %s; feature %d -> %d, improvement %d -> %d; own appeal %d -> %d (%+d); "
              "neighbours %s; housing districts %+g, improvements %+g" % (
                  pick["Kind"], pick["X"], pick["Y"], after["District"] != -1, before["Feature"], after["Feature"],
                  before["Improvement"], after["Improvement"], before["Appeal"], after["Appeal"],
                  after["Appeal"] - before["Appeal"], dn, after["Districts"] - before["Districts"],
                  after["Improvements"] - before["Improvements"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
