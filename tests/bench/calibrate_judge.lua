-- @state SDP_Panel
-- @timeout 180
-- @setup GameCore_Tuner tests/fixtures/calibration_setup.lua
-- Engine calibration of the comparison's judge (docs/multicity-design.md
-- 18.1, item 6): the judge scores plans with DMT's GetBonusYields; here DMT
-- is compared with the game engine's own adjacency numbers.
--   A  every district at every plot the engine lets the capital build it on:
--      plot:GetAdjacencyYield (what the game's placement lens shows) against
--      DMT for a hypothetical district there.
--   B  the districts the setup built next to each other: their real
--      adjacency (district:GetAdjacencyYield) against DMT for the same plots.
-- A known DMT deviation is listed apart, not failed (AGENTS pitfall 28): DMT
-- counts any visible resource on water as a sea resource, artifacts such as
-- shipwrecks included, and the engine does not.
-- Not a regular test (no test_ prefix): the setup unlocks everything and
-- builds districts, so run it alone on a throwaway game:
--   python3 -I tools/run_tests.py tests/bench/calibrate_judge.lua
local test, T = ...

local pid = Game.GetLocalPlayer()

local function DMTYields(districtType, x, y)
  local out = {}
  local ok, yields = pcall(GetBonusYields, pid, { Key = districtType, Type = "DISTRICT", X = x, Y = y })
  if ok and yields then
    for yieldType, amount in pairs(yields) do out[yieldType] = amount end
  end
  return out
end

local function Same(engine, dmt)
  for row in GameInfo.Yields() do
    if (engine[row.YieldType] or 0) ~= (dmt[row.YieldType] or 0) then return false end
  end
  return true
end

local function Text(yields)
  local parts = {}
  for row in GameInfo.Yields() do
    local v = yields[row.YieldType] or 0
    if v ~= 0 then parts[#parts + 1] = row.YieldType:gsub("YIELD_", "") .. " " .. v end
  end
  return table.concat(parts, ", ")
end

-- Districts with a sea-resource adjacency, and whether an artifact lies on
-- a neighbouring water plot: only there can the known deviation apply.
local seaDistricts = {}
for row in GameInfo.District_Adjacencies() do
  local change = GameInfo.Adjacency_YieldChanges[row.YieldChangeId]
  if change and change.AdjacentSeaResource then seaDistricts[row.DistrictType] = true end
end

local function ArtifactAtSea(plot)
  for dir = 0, 5 do
    local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
    if n and n:IsWater() and n:GetResourceType() ~= -1
        and GameInfo.Resources[n:GetResourceType()].ResourceClassType == "RESOURCECLASS_ARTIFACT" then
      return true
    end
  end
  return false
end

test("A: the placement lens's adjacency equals DMT's, plot by plot", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  pcall(UpdatePinYields, pid, {})
  local compared, mismatched, known = 0, 0, 0
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    local row = GameInfo.Districts[d.Type]
    local params = {}
    params[CityOperationTypes.PARAM_DISTRICT_TYPE] = row.Hash
    local results = CityManager.GetOperationTargets(city, CityOperationTypes.BUILD, params)
    for _, index in ipairs((results and results[CityOperationResults.PLOTS]) or {}) do
      local plot = Map.GetPlotByIndex(index)
      local engine = {}
      for y in GameInfo.Yields() do
        local v = plot:GetAdjacencyYield(pid, city:GetID(), row.Index, y.Index)
        if v ~= 0 then engine[y.YieldType] = v end
      end
      pcall(UpdatePinYields, pid, {})
      local dmt = DMTYields(d.Type, plot:GetX(), plot:GetY())
      compared = compared + 1
      if not Same(engine, dmt) then
        local why = ""
        if seaDistricts[d.Type] and ArtifactAtSea(plot) then
          known = known + 1
          why = " (known: artifact at sea)"
        else
          mismatched = mismatched + 1
        end
        if mismatched + known <= 25 then
          print(string.format("%s at %d,%d: engine [%s] DMT [%s]%s", d.Type, plot:GetX(), plot:GetY(), Text(engine), Text(dmt), why))
        end
      end
    end
  end
  print(string.format("A: %d district x plot compared, %d differ, %d more by the known deviation", compared, mismatched, known))
  T.ok(compared > 0, "nothing compared (no engine targets)")
  T.eq(mismatched, 0, "DMT differs from the engine")
end)

test("B: built districts next to each other: the engine's adjacency equals DMT's", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  pcall(UpdatePinYields, pid, {})
  local compared, mismatched = 0, 0
  for _, district in city:GetDistricts():Members() do
    local row = GameInfo.Districts[district:GetType()]
    if not row.CityCenter then
      local engine = {}
      for y in GameInfo.Yields() do
        local v = district:GetAdjacencyYield(y.Index)
        if v ~= 0 then engine[y.YieldType] = v end
      end
      local dmt = DMTYields(row.DistrictType, district:GetX(), district:GetY())
      compared = compared + 1
      print(string.format("%s at %d,%d: engine [%s] DMT [%s]", row.DistrictType, district:GetX(), district:GetY(), Text(engine), Text(dmt)))
      if not Same(engine, dmt) then mismatched = mismatched + 1 end
    end
  end
  print(string.format("B: %d built districts compared, %d differ", compared, mismatched))
  T.ok(compared > 0, "no built districts")
  T.eq(mismatched, 0, "DMT differs from the engine for built districts")
end)
