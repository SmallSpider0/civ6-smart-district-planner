"""Whose Camp counts for a wonder that must stand next to an improvement (issue 51).

The Temple of Artemis (Buildings.AdjacentImprovement = IMPROVEMENT_CAMP) is
the only such wonder. DMT only asks whether a Camp is next to the plot. This
probe asks the engine (CityManager.GetOperationTargets and CanStartOperation
for the wonder, in the UI state) with a Camp next to city A's plot that
belongs to
  same    city A itself,
  other   another city of ours (B), or
  none    nobody (an unowned plot).
Gives the player every technology and civic, founds city B four plots from
the capital and lets each city own its two rings: changes the game for good,
use it on a throwaway game (game.py newgame --capital --reveal).

    python3 -I tests/bench/probe_camp.py
Prints one line "SDP_PROBE_CAMP <json>" with the tallies.
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
    raise SystemExit("no %s line in %r" % (tag, lines))


SETUP = """
local pid = Game.GetLocalPlayer()
local player = Players[pid]
local techs, culture = player:GetTechs(), player:GetCulture()
for row in GameInfo.Technologies() do techs:SetTech(row.Index, true) end
for row in GameInfo.Civics() do culture:SetCivic(row.Index, true) end
local a = player:GetCities():GetCapitalCity()
local b = nil
for _, city in player:GetCities():Members() do
  if city:GetID() ~= a:GetID() then b = city end
end
if b == nil then
  for dx = -4, 4 do for dy = -4, 4 do
    local p = Map.GetPlotXYWithRangeCheck(a:GetX(), a:GetY(), dx, dy, 4)
    if b == nil and p ~= nil and Map.GetPlotDistance(a:GetX(), a:GetY(), p:GetX(), p:GetY()) == 4 and not p:IsWater()
        and not p:IsMountain() and not p:IsNaturalWonder() and p:GetOwner() == -1 then
      WorldBuilder.CityManager():Create(pid, p:GetX(), p:GetY())
      b = Cities.GetCityInPlot(p:GetX(), p:GetY())
    end
  end end
end
if b == nil then error("no site for city B") end
for _, city in ipairs({ a, b }) do
  for dx = -2, 2 do for dy = -2, 2 do
    local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 2)
    if p ~= nil and p:GetOwner() == -1 then
      WorldBuilder.CityManager():SetPlotOwner(p:GetX(), p:GetY(), pid, city:GetID())
    end
  end end
end
print(string.format('SETUP {"A":%d,"AX":%d,"AY":%d,"B":%d,"BX":%d,"BY":%d}', a:GetID(), a:GetX(), a:GetY(), b:GetID(),
  b:GetX(), b:GetY()))
"""

# Plots for the three cases: a land plot W of city A with no improvement
# around it, and a free land plot next to it that belongs to A (same), to B
# (other) or to nobody (none).
PICK = """
local pid = Game.GetLocalPlayer()
local camp = GameInfo.Improvements["IMPROVEMENT_CAMP"].Index
local a, b = %(A)d, %(B)d
local function CityOf(p)
  if p:GetOwner() ~= pid then return nil end
  local c = Cities.GetPlotPurchaseCity(p)
  return c and c:GetID() or nil
end
local function Free(p)
  return p ~= nil and not p:IsWater() and not p:IsMountain() and not p:IsCity() and not p:IsNaturalWonder()
    and p:GetDistrictType() == -1 and p:GetWonderType() == -1 and p:GetImprovementType() == -1
end
local function NoCampNear(p)
  for d = 0, 5 do
    local q = Map.GetAdjacentPlot(p:GetX(), p:GetY(), d)
    if q ~= nil and q:GetImprovementType() == camp then return false end
  end
  return true
end
local out, used = {}, {}
for _, kind in ipairs({ "same", "other", "none" }) do
  local found = 0
  for i = 0, Map.GetPlotCount() - 1 do
    local w = Map.GetPlotByIndex(i)
    if found < 6 and Free(w) and CityOf(w) == a and Map.GetPlotDistance(w:GetX(), w:GetY(), %(AX)d, %(AY)d) >= 1
        and NoCampNear(w) and not used[i] then
      for d = 0, 5 do
        local x = Map.GetAdjacentPlot(w:GetX(), w:GetY(), d)
        local owner = x and CityOf(x) or nil
        local ok = Free(x) and not used[x:GetIndex()]
          and ((kind == "same" and owner == a) or (kind == "other" and owner == b)
            or (kind == "none" and x:GetOwner() == -1))
        if ok and found < 6 then
          -- Each camp is removed again before the next case.
          found = found + 1
          used[i] = true
          local what = GameInfo.Terrains[w:GetTerrainType()].TerrainType
          if w:GetFeatureType() ~= -1 then what = what .. "+" .. GameInfo.Features[w:GetFeatureType()].FeatureType end
          if w:GetResourceType() ~= -1 then what = what .. "+" .. GameInfo.Resources[w:GetResourceType()].ResourceType end
          out[#out + 1] = string.format('{"Kind":"%%s","WX":%%d,"WY":%%d,"CX":%%d,"CY":%%d,"W":"%%s"}', kind, w:GetX(), w:GetY(),
            x:GetX(), x:GetY(), what)
          break
        end
      end
    end
  end
end
print("PICK [" .. table.concat(out, ",") .. "]")
"""

SET_CAMP = """
local p = Map.GetPlot(%(x)d, %(y)d)
ImprovementBuilder.SetImprovementType(p, %(type)s, %(owner)s)
print("SET", p:GetImprovementType())
"""

ASK = """
local pid = Game.GetLocalPlayer()
local city = CityManager.GetCity(pid, %(A)d)
local temple = GameInfo.Buildings["BUILDING_TEMPLE_ARTEMIS"]
local params = {}
params[CityOperationTypes.PARAM_BUILDING_TYPE] = temple.Hash
local ok, results = pcall(CityManager.GetOperationTargets, city, CityOperationTypes.BUILD, params)
local set = {}
for _, id in ipairs(ok and results and results[CityOperationResults.PLOTS] or {}) do set[id] = true end
local w = Map.GetPlot(%(wx)d, %(wy)d)
local t = {}
t[CityOperationTypes.PARAM_X] = w:GetX(); t[CityOperationTypes.PARAM_Y] = w:GetY()
t[CityOperationTypes.PARAM_BUILDING_TYPE] = temple.Hash
local can = CityManager.CanStartOperation(city, CityOperationTypes.BUILD, t)
local dmt = SDP_Overlay.With(pid, SDP_Overlay.Evaluate,
  { { Key = "BUILDING_TEMPLE_ARTEMIS", Type = "WONDER", X = w:GetX(), Y = w:GetY() } }, {}, { YIELD_GOLD = 1 }).Placements[1]
local n = 0
for _ in pairs(set) do n = n + 1 end
print(string.format('ASK {"Targets":%%d,"Target":%%s,"CanStart":%%s,"DMT":%%s}', n, tostring(set[w:GetIndex()] == true),
  tostring(can == true), tostring(dmt.CanPlace == true)))
"""


def main():
    if run("GameCore_Tuner", "print(GameInfo.Buildings['BUILDING_TEMPLE_ARTEMIS'] ~= nil)") != ["true"]:
        raise SystemExit("no Temple of Artemis in this ruleset")
    setup = tagged(run("GameCore_Tuner", SETUP), "SETUP")
    time.sleep(2)
    picks = tagged(run("GameCore_Tuner", PICK % setup), "PICK")
    rows = []
    for pick in picks:
        args = dict(setup, wx=pick["WX"], wy=pick["WY"])
        time.sleep(1)
        before = tagged(run("SDP_Panel", ASK % args), "ASK")
        owner = "Game.GetLocalPlayer()" if pick["Kind"] != "none" else "-1"
        run("GameCore_Tuner", SET_CAMP % dict(x=pick["CX"], y=pick["CY"], type='GameInfo.Improvements["IMPROVEMENT_CAMP"].Index',
                                               owner=owner))
        time.sleep(2)
        after = tagged(run("SDP_Panel", ASK % args), "ASK")
        run("GameCore_Tuner", SET_CAMP % dict(x=pick["CX"], y=pick["CY"], type="-1", owner="-1"))
        time.sleep(1)
        row = dict(pick, Before=before, After=after)
        rows.append(row)
        print("%-5s W %d,%d (%s) camp %d,%d: before target %s; with camp target %s, can start %s, DMT allows %s" % (
            pick["Kind"], pick["WX"], pick["WY"], pick["W"], pick["CX"], pick["CY"], before["Target"], after["Target"],
            after["CanStart"], after["DMT"]))
    print("SDP_PROBE_CAMP " + json.dumps({"setup": setup, "rows": rows}))


if __name__ == "__main__":
    main()
