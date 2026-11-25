-- Probe for #379: with a fourth-ring mod installed, can a city build a
-- district on ring 4, and what does CITY_MAX_BUY_PLOT_RANGE say?
-- Read-only.
--
--   python -I tools/civ6tuner.py exec -s SDP_Panel -f tests/bench/probe_radius.lua
--
-- Run it after the city owns plots out to ring 4 (Workable 4th Ring lets the
-- borders grow there; on a throwaway game tests/fixtures/unlock_all.lua plus
-- WorldBuilder.CityManager():SetPlotOwner can hand them over).
-- Prints one line per city: the parameter, the rings the city owns, the
-- farthest ring the engine offers for a campus and for a canal, and samples.

local pid = Game.GetLocalPlayer()
local player = Players[pid]

local function Param(name)
  local row = GameInfo.GlobalParameters[name]
  return row ~= nil and tostring(row.Value) or "nil"
end

local function Ring(city, plot)
  return Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY())
end

local function Targets(city, districtType)
  local row = GameInfo.Districts[districtType]
  if row == nil or CityManager == nil or CityManager.GetOperationTargets == nil then return nil end
  local params = {}
  params[CityOperationTypes.PARAM_DISTRICT_TYPE] = row.Hash
  local ok, results = pcall(CityManager.GetOperationTargets, city, CityOperationTypes.BUILD, params)
  local plots = ok and type(results) == "table" and results[CityOperationResults.PLOTS] or nil
  if type(plots) ~= "table" then return nil end
  return plots
end

local function DescribeTargets(city, plotList)
  if plotList == nil then return "nolist" end
  local byRing, maxRing, ring4 = {}, 0, {}
  for _, index in ipairs(plotList) do
    local plot = Map.GetPlotByIndex(index)
    if plot ~= nil then
      local ring = Ring(city, plot)
      byRing[ring] = (byRing[ring] or 0) + 1
      if ring > maxRing then maxRing = ring end
      if ring >= 4 then ring4[#ring4 + 1] = string.format("%d,%d", plot:GetX(), plot:GetY()) end
    end
  end
  local rings = {}
  for ring = 0, 6 do
    if byRing[ring] ~= nil then rings[#rings + 1] = ring .. ":" .. byRing[ring] end
  end
  return string.format("count %d, rings %s, max ring %d, ring4+ [%s]",
    #plotList, table.concat(rings, " "), maxRing, table.concat(ring4, " "))
end

print("# CITY_MAX_BUY_PLOT_RANGE " .. Param("CITY_MAX_BUY_PLOT_RANGE"))
print("# CITY_MAX_DISTRICT_RANGE " .. Param("CITY_MAX_DISTRICT_RANGE"))

for _, city in player:GetCities():Members() do
  local ownedRings, ownedMax, owned4 = {}, 0, 0
  -- Plots out to ring 5, by ownership (city:GetOwnedPlots is not exposed in
  -- every Lua state).
  for dx = -5, 5 do
    for dy = -5, 5 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 5)
      if plot ~= nil and plot:GetOwner() == pid then
        local owner = Cities.GetPlotPurchaseCity(plot)
        if owner ~= nil and owner:GetID() == city:GetID() then
          local ring = Ring(city, plot)
          ownedRings[ring] = (ownedRings[ring] or 0) + 1
          if ring > ownedMax then ownedMax = ring end
          if ring >= 4 then owned4 = owned4 + 1 end
        end
      end
    end
  end
  local owned = {}
  for ring = 0, 6 do
    if ownedRings[ring] ~= nil then owned[#owned + 1] = ring .. ":" .. ownedRings[ring] end
  end
  print(string.format("# city %d (%d,%d) pop %d owns %s, max ring %d, ring4+ %d",
    city:GetID(), city:GetX(), city:GetY(), city:GetPopulation(), table.concat(owned, " "), ownedMax, owned4))
  print("#   campus " .. DescribeTargets(city, Targets(city, "DISTRICT_CAMPUS")))
  print("#   canal  " .. DescribeTargets(city, Targets(city, "DISTRICT_CANAL")))
end
