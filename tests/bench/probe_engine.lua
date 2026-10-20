-- @state SDP_Panel
-- @timeout 120
-- @setup GameCore_Tuner tests/fixtures/unlock_all.lua
-- Probe for design choice 3 (docs/multicity-design.md section 18): do the
-- plots the engine lets a city build each district on (what the game's
-- placement lens shows: CityManager.GetOperationTargets, as in Base
-- AdjacencyBonusSupport.lua) agree with SDP's candidates + DMT's CanPlace?
-- Not a regular test (no test_ prefix): the setup gives the player every
-- technology, so run it alone on a throwaway game:
--   python3 -I tools/run_tests.py tests/bench/probe_engine.lua
local test, T = ...

local pid = Game.GetLocalPlayer()
local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function EngineTargets(city, districtHash)
  local params = {}
  params[CityOperationTypes.PARAM_DISTRICT_TYPE] = districtHash
  local results = CityManager.GetOperationTargets(city, CityOperationTypes.BUILD, params)
  local set, n = {}, 0
  local plots = results and results[CityOperationResults.PLOTS]
  for _, id in ipairs(plots or {}) do
    set[id] = true
    n = n + 1
  end
  return set, n
end

local function Describe(plot)
  local parts = { GameInfo.Terrains[plot:GetTerrainType()].TerrainType }
  if plot:GetFeatureType() ~= -1 then parts[#parts + 1] = GameInfo.Features[plot:GetFeatureType()].FeatureType end
  if plot:GetResourceType() ~= -1 then parts[#parts + 1] = GameInfo.Resources[plot:GetResourceType()].ResourceType end
  if plot:GetImprovementType() ~= -1 then parts[#parts + 1] = GameInfo.Improvements[plot:GetImprovementType()].ImprovementType end
  if plot:IsRiver() then parts[#parts + 1] = "river" end
  return table.concat(parts, " ")
end

test("engine placement targets vs SDP candidates and DMT", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  local scan = SDP_City.Scan(pid, city:GetID())
  local candidate = {}
  for _, c in ipairs(scan.Candidates) do candidate[c.Index] = true end
  -- The engine only offers plots the city owns; compare on those.
  local owned, inRange = {}, {}
  for _, p in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
    inRange[p.Index] = true
    local plot = Map.GetPlotByIndex(p.Index)
    local owner = Cities.GetPlotPurchaseCity(plot)
    if plot:GetOwner() == pid and owner ~= nil and owner:GetID() == city:GetID() then owned[#owned + 1] = p end
  end
  local tally = { districts = 0, locked = 0, plots = 0, agree = 0, sdpOnly = 0, engineOnly = 0, outside = 0 }
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    local targets, n = EngineTargets(city, GameInfo.Districts[d.Type].Hash)
    if n == 0 then
      tally.locked = tally.locked + 1
      print("no engine targets:", d.Type)
    else
      tally.districts = tally.districts + 1
      for index in pairs(targets) do
        if not inRange[index] then tally.outside = tally.outside + 1 end
      end
      for _, p in ipairs(owned) do
        local plot = Map.GetPlotByIndex(p.Index)
        local item = SDP_Overlay.With(pid, SDP_Overlay.Evaluate, { SDP_Overlay.Subject(d.Type, p.X, p.Y) }, {}, WEIGHTS).Placements[1]
        local sdp = candidate[p.Index] == true and item.CanPlace == true
        local engine = targets[p.Index] == true
        tally.plots = tally.plots + 1
        if sdp == engine then
          tally.agree = tally.agree + 1
        elseif sdp then
          tally.sdpOnly = tally.sdpOnly + 1
          print(string.format("SDP+DMT allow, engine refuses: %s at %d,%d (%s)", d.Type, p.X, p.Y, Describe(plot)))
        else
          tally.engineOnly = tally.engineOnly + 1
          print(string.format("engine allows, SDP refuses: %s at %d,%d (%s) excluded=%s dmt=%s %s", d.Type, p.X, p.Y,
            Describe(plot), tostring(scan.Excluded[p.Index]), tostring(item.CanPlace), tostring(item.Reason)))
          T.ok(scan.Excluded[p.Index] ~= SDP_City.EXCLUDED.RESOURCE,
            d.Type .. " at " .. p.X .. "," .. p.Y .. ": the engine allows a plot SDP excluded for its resource")
        end
      end
    end
  end
  print(string.format("districts compared %d (no targets %d), owned plots %d, district x plot %d: agree %d, SDP-only %d, engine-only %d; engine targets outside 3 rings %d",
    tally.districts, tally.locked, #owned, tally.plots, tally.agree, tally.sdpOnly, tally.engineOnly, tally.outside))
  T.ok(tally.districts > 0, "the engine listed no targets for any district")
end)
