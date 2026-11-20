-- @state SDP_Panel
-- @timeout 120
-- Disaster tiles (issue 360): the planner's judgement of each plot against
-- the game's own managers, the switch's row, and a solve with it on.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function City()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

local function GS()
  if SDP_Rules.Ruleset() ~= "RULESET_EXPANSION_2" then T.skip("not Gathering Storm") end
end

test("disaster rules: on only in Gathering Storm, the switch row with them", function()
  local on = SDP_City.HazardsOn()
  T.eq(on, SDP_Rules.Ruleset() == "RULESET_EXPANSION_2", "disasters in " .. SDP_Rules.Ruleset())
  SDP_Panel.Refresh()
  SDP_Panel.SelectTab("SINGLE")
  T.eq(SDP_Panel.State().HazardShown, on, "the single-city row shown")
  if not on then
    -- Outside Gathering Storm the kept switch must not reach the request.
    local was = SDP_Panel.State().AvoidHazards
    SDP_Panel.SetAvoidHazards(true)
    local scan = SDP_City.Scan(pid, City():GetID(), {})
    for _, c in ipairs(scan.Candidates) do T.eq(c.Hazard, nil, "no risk at " .. c.X .. "," .. c.Y) end
    SDP_Panel.SetAvoidHazards(was)
  end
end)

-- Each candidate's risk against what the game itself says of the plot: the
-- eruption warning (active or dormant), floodable floodplains of a river no
-- dam or Great Bath guards, coastal lowland the game does not protect.
test("each plot's risk agrees with the game's managers", function()
  GS()
  local city = City()
  local scan = SDP_City.Scan(pid, city:GetID(), {})
  local counts = { Volcano = 0, Flood = 0, Lowland = 0 }
  for _, c in ipairs(scan.Candidates) do
    local plot = Map.GetPlotByIndex(c.Index)
    local h = c.Hazard or {}
    local erupts = MapFeatureManager.CanSufferEruption(plot) == true
    T.eq(h.Volcano ~= nil, erupts, "eruption at " .. c.X .. "," .. c.Y)
    if erupts then
      counts.Volcano = counts.Volcano + 1
    end
    local floods = RiverManager.CanBeFlooded(plot) == true
    if not floods then T.eq(h.Flood, nil, "no flood at " .. c.X .. "," .. c.Y) end
    if h.Flood ~= nil then counts.Flood = counts.Flood + 1 end
    local lowland = TerrainManager.GetCoastalLowlandType(plot) ~= -1 and not TerrainManager.IsProtected(plot)
    T.eq(h.Lowland ~= nil, lowland, "lowland at " .. c.X .. "," .. c.Y)
    if lowland then counts.Lowland = counts.Lowland + 1 end
  end
  print(string.format("capital %d,%d: %d candidates; volcano %d, flood %d, lowland %d",
    city:GetX(), city:GetY(), #scan.Candidates, counts.Volcano, counts.Flood, counts.Lowland))
end)

-- A floodplain the game can flood counts unless something guards its river:
-- a built dam or Great Bath on that river, or a dam tack the plan keeps.
test("a floodable floodplain counts exactly when nothing guards its river", function()
  GS()
  local city = City()
  local scan = SDP_City.Scan(pid, city:GetID(), {})
  local ctx = SDP_City.HazardContext(pid, city:GetID(), {})
  local seen = 0
  for _, c in ipairs(scan.Candidates) do
    local plot = Map.GetPlotByIndex(c.Index)
    if RiverManager.CanBeFlooded(plot) then
      seen = seen + 1
      local river = SDP_City.FloodRiver(c.X, c.Y)
      T.ok(river ~= nil and river >= 0, "a floodable plot has a river at " .. c.X .. "," .. c.Y)
      local guarded = false
      for _, index in ipairs(RiverManager.GetFloodplainPlots(river) or {}) do
        local p = Map.GetPlotByIndex(index)
        local d, w = p:GetDistrictType(), p:GetWonderType()
        if d ~= -1 and GameInfo.Districts[d] ~= nil and ctx.Rules.Guards[GameInfo.Districts[d].DistrictType] then guarded = true end
        if w ~= -1 and GameInfo.Buildings[w] ~= nil and ctx.Rules.Guards[GameInfo.Buildings[w].BuildingType] then guarded = true end
      end
      if not guarded and not ctx.FloodImmune and not ctx.Shielded and not TackGuarded(river) then
        T.eq(c.Hazard and c.Hazard.Flood, river, "flood risk at " .. c.X .. "," .. c.Y)
      end
    end
  end
  if seen == 0 then T.skip("no floodable floodplain near the capital") end
  print(seen .. " floodable candidates")
end)

-- A dam on the plan guards the river's floodplains: the risk drops from the
-- plan's other districts on them.
test("a dam on the plan guards its river's floodplains", function()
  GS()
  local city = City()
  local scan = SDP_City.Scan(pid, city:GetID(), {})
  local flood = nil
  for _, c in ipairs(scan.Candidates) do
    if c.Hazard ~= nil and c.Hazard.Flood ~= nil and c.Hazard.Volcano == nil and c.Hazard.Lowland == nil then flood = c break end
  end
  if flood == nil then T.skip("no floodplain at risk near the capital") end
  local guard = GuardDistrict()
  if guard == nil then T.skip("no district guards floodplains") end
  local plan = {
    { Type = "DISTRICT_CAMPUS", X = flood.X, Y = flood.Y, Index = flood.Index, Hazard = flood.Hazard },
    { Type = guard, X = flood.X, Y = flood.Y, Index = flood.Index, Hazard = flood.Hazard },
  }
  SDP_City.PlanHazards(plan, function(p) return p.Hazard end)
  T.eq(plan[1].Hazard, nil, guard .. " guards the campus's floodplain")
end)

-- The switch on: the plan's districts stand on safe plots where the city has
-- any; one with no safe plot is still placed and keeps its mark.
test("the switch on: districts on safe plots, none dropped", function()
  GS()
  local city = City()
  local scan = SDP_City.Scan(pid, city:GetID(), {})
  local safe, risky = 0, 0
  for _, c in ipairs(scan.Candidates) do
    if c.Hazard == nil then safe = safe + 1 else risky = risky + 1 end
  end
  if risky == 0 then T.skip("no plot at risk near the capital") end
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  local districts = {}
  for _, t in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }) do
    if plannable[t] then districts[#districts + 1] = t end
  end
  local request = { PlayerID = pid, CityID = city:GetID(), Districts = districts, Weights = ONES }
  local off = SDP_Solver.Solve(request)
  T.ok(off.Ok, "off: " .. tostring(off.Error))
  request.AvoidHazards = true
  local on = SDP_Solver.Solve(request)
  T.ok(on.Ok, "on: " .. tostring(on.Error))
  T.eq(#on.Plan, #off.Plan, "the switch drops no district")
  local function Count(plan)
    local n = 0
    for _, p in ipairs(plan) do if p.Hazard ~= nil then n = n + 1 end end
    return n
  end
  T.ok(Count(on.Plan) <= Count(off.Plan), "no more marked districts on: " .. Count(on.Plan) .. " > " .. Count(off.Plan))
  if safe >= #districts then T.eq(Count(on.Plan), 0, "enough safe plots: none marked") end
  print(string.format("%d safe, %d at risk; marked off %d, on %d; gain off %.2f, on %.2f",
    safe, risky, Count(off.Plan), Count(on.Plan), off.Gain or 0, on.Gain or 0))
end)
