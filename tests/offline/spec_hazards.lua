-- Offline: disaster tiles (issue 360, Gathering Storm). The judgement of a
-- plot (next to a volcano, floodplains of a river without a dam, coastal
-- lowland without a flood barrier, and what protects them), the result rows'
-- note and hover lines, the switch "avoid disaster tiles" on both tabs
-- through its check box, and the solvers with it: safe plots first, never
-- a district left out for it, a dam planned with the plan guarding its
-- river; with the switch off the plan is the one without disaster rules.
local test, T = ...

local UI_Mock = include("ui")

-- Three mountains in a row north-west of the city; the middle one is an
-- active volcano, the western one a dormant volcano.
local MAP = {
  "~~~~~~~~~~~~~~",
  "~............~",
  "~............~",
  "~...MMM......~",
  "~............~",
  "~............~",
  "~............~",
  "~............~",
  "~~~~~~~~~~~~~~",
}
local VOLCANOES = { { 5, 3, true }, { 4, 3, false } }
local CITY = { id = 1, x = 6, y = 5, population = 7, capital = true }

local CAMPUS, HOLY, HUB, DAM = "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_DAM"

local w = World.New({ rows = MAP, cities = { CITY }, disasters = { volcanoes = VOLCANOES } })
UI_Mock.Install()
include("SDP_Panel")

local function Solve(extra)
  local request = { PlayerID = 0, CityID = 1, Districts = { CAMPUS }, Tier = "STANDARD" }
  for k, v in pairs(extra or {}) do request[k] = v end
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, "solved: " .. tostring(result.Error))
  T.eq(result.Stats.Mismatch, nil, "the board's value matches the full evaluation")
  return result
end

local function Entry(plan, districtType)
  for _, p in ipairs(plan) do
    if p.Type == districtType then return p end
  end
  return nil
end

local function HazardOf(index)
  for _, c in ipairs(SDP_City.Scan(0, 1).Candidates) do
    if c.Index == index then return c.Hazard end
  end
  return nil
end

test("a plot's risk: the game's eruption warning, active or dormant", function()
  T.ok(SDP_City.HazardsOn(), "Gathering Storm rules")
  local scan = SDP_City.Scan(0, 1)
  local active, dormant = 0, 0
  for _, c in ipairs(scan.Candidates) do
    local plot = Map.GetPlotByIndex(c.Index)
    local warned = MapFeatureManager.CanSufferEruption(plot)
    T.eq(c.Hazard ~= nil, warned, "marked where the game warns: " .. c.X .. "," .. c.Y)
    if warned then
      local nextToActive = false
      for _, n in ipairs(Map.GetAdjacentPlots(c.X, c.Y)) do
        if n ~= nil and MapFeatureManager.IsActiveVolcano(n) then nextToActive = true end
      end
      T.eq(c.Hazard.Volcano, nextToActive and "ACTIVE" or "DORMANT", "active or dormant: " .. c.X .. "," .. c.Y)
      if nextToActive then active = active + 1 else dormant = dormant + 1 end
    end
  end
  T.ok(active > 0 and dormant > 0, "both kinds in range: " .. active .. " " .. dormant)
end)

test("a governor shielding the city: no risk; not yet established: the risk stays", function()
  w:SetGovernor(1, { "GOVERNOR_PROMOTION_TEST_REINFORCED" })
  for _, c in ipairs(SDP_City.Scan(0, 1).Candidates) do T.eq(c.Hazard, nil, "shielded: " .. c.X .. "," .. c.Y) end
  w:SetGovernor(1, { "GOVERNOR_PROMOTION_TEST_REINFORCED" }, false)
  local any = false
  for _, c in ipairs(SDP_City.Scan(0, 1).Candidates) do any = any or c.Hazard ~= nil end
  T.ok(any, "not established: still at risk")
  w:SetGovernor(1, {})
  any = false
  for _, c in ipairs(SDP_City.Scan(0, 1).Candidates) do any = any or c.Hazard ~= nil end
  T.ok(any, "other promotions: still at risk")
end)

test("the switch off: the best plot, next to the volcano, marked; on: the best safe plot", function()
  local heat = SDP_Solver.Heat({ PlayerID = 0, CityID = 1, District = CAMPUS, Weights = {} })
  T.ok(HazardOf(heat[1].Index) ~= nil, "the best campus plot is next to a volcano (the test's premise)")
  local safe = nil
  for _, spot in ipairs(heat) do
    if safe == nil and HazardOf(spot.Index) == nil then safe = spot end
  end
  T.ok(safe ~= nil and safe.Gain < heat[1].Gain, "a safe plot, worth less")

  local off = Solve()
  local campus = Entry(off.Plan, CAMPUS)
  T.eq(campus.Index, heat[1].Index, "off: the best plot")
  T.ok(campus.Hazard ~= nil and campus.Hazard.Volcano ~= nil, "off: its risk on the entry")
  T.eq(off.Gain, heat[1].Gain, "off: its gain")

  local on = Solve({ AvoidHazards = true })
  campus = Entry(on.Plan, CAMPUS)
  T.eq(campus.Index, safe.Index, "on: the best safe plot")
  T.eq(campus.Hazard, nil, "on: no risk")
  T.eq(on.Gain, safe.Gain, "on: the gain shown leaves the hazard part out")
  T.eq(#on.Unplaced, 0, "nothing left out")
end)

local function RowFor(rows, icon)
  for _, r in ipairs(rows) do
    if r.Icon == icon then return r end
  end
  return nil
end

local function Kept(tab) return PlayerConfigurations[0]:GetValue("SDP_Settings_" .. tab) or "" end

test("single-city tab: the switch, the note and the hover lines", function()
  local c = UI_Mock.Controls
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetRemind(false)
  SDP_Panel.SetState(CAMPUS, "MUST")
  SDP_Panel.SetCount(1)
  SDP_Panel.SetTier("STANDARD")
  T.eq(c.HazardCheck:IsChecked(), false, "off by default")
  T.eq(SDP_Panel.State().HazardShown, true, "shown in Gathering Storm")
  T.eq(SDP_Panel.Request().AvoidHazards, nil, "not in the request")
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solved")
  local row = RowFor(SDP_Panel.State().ResultRows, "ICON_" .. CAMPUS)
  T.ok(row.Detail:find("LOC_SDP_RESULT_HAZARD(", 1, true) ~= nil, "the note in the detail: " .. row.Detail)
  T.ok(row.ToolTip:find("LOC_SDP_HAZARD_LINE_VOLCANO_ACTIVE", 1, true) ~= nil, "the line on hover: " .. row.ToolTip)

  c.HazardCheck:Toggle()
  T.eq(SDP_Panel.State().AvoidHazards, true, "on through the box")
  T.eq(SDP_Panel.Request().AvoidHazards, true, "in the request")
  T.ok(Kept("SINGLE"):find("AVOID_HAZARDS=1", 1, true) ~= nil, "kept in the save: " .. Kept("SINGLE"))
  T.eq(SDP_Panel.State().Result, nil, "the result goes: the plan would change")
  T.ok(SDP_Panel.State().FoldText:find("LOC_SDP_FOLD_HAZARD", 1, true) ~= nil, "in the folded line")
  result = SDP_Panel.Solve()
  T.eq(Entry(result.Plan, CAMPUS).Hazard, nil, "the campus on a safe plot")
  row = RowFor(SDP_Panel.State().ResultRows, "ICON_" .. CAMPUS)
  T.ok(row.Detail:find("LOC_SDP_RESULT_HAZARD(", 1, true) == nil, "no note")
  c.HazardCheck:Toggle()
  T.ok(Kept("SINGLE"):find("AVOID_HAZARDS", 1, true) == nil, "off is the default: not kept")
  SDP_Panel.SetRemind(true)
  SDP_Panel.Close()
end)

test("several cities tab: the switch reaches the request and the plan", function()
  local c = UI_Mock.Controls
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetCount(0)
  multi.SetSelected(CAMPUS, true)
  multi.SetTier("FAST")
  T.eq(c.MultiHazardCheck:IsChecked(), false, "off by default")
  T.eq(multi.State().HazardShown, true, "shown")
  T.eq(multi.Request().AvoidHazards, nil, "not in the request")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "solved")
  T.ok(Entry(result.Plan, CAMPUS).Hazard ~= nil, "off: the campus by the volcano, marked")
  c.MultiHazardCheck:Toggle()
  T.eq(multi.Request().AvoidHazards, true, "on through the box")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  result = multi.State().Result
  T.ok(result and result.Ok, "solved")
  T.eq(Entry(result.Plan, CAMPUS).Hazard, nil, "on: a safe plot")
  c.MultiHazardCheck:Toggle()
  SDP_Panel.Close()
end)

test("the switch off gives the plan without disaster rules", function()
  local districts = { CAMPUS, HOLY, HUB }
  local with = Solve({ Districts = districts })
  World.New({ rows = MAP, cities = { CITY } })
  T.ok(not SDP_City.HazardsOn(), "no disaster rules")
  local without = Solve({ Districts = districts, AvoidHazards = true }) -- inert without the rules
  T.eq(#with.Plan, #without.Plan, "as many districts")
  for _, p in ipairs(with.Plan) do
    local q = Entry(without.Plan, p.Type)
    T.eq(q.Index, p.Index, "same plot for " .. p.Type)
    T.eq(q.Hazard, nil, "no risk without the rules")
  end
  T.eq(with.Gain, without.Gain, "same value")
  w = World.New({ rows = MAP, cities = { CITY }, disasters = { volcanoes = VOLCANOES } })
end)

test("no safe plot in the city: the district is still placed and marked", function()
  local lowlands = {}
  for y = 1, #MAP - 2 do
    for x = 1, #MAP[1] - 2 do lowlands[#lowlands + 1] = { x, y, 1 } end
  end
  w = World.New({ rows = MAP, cities = { CITY }, disasters = { volcanoes = VOLCANOES, lowlands = lowlands } })
  local on = Solve({ Districts = { CAMPUS, HOLY }, AvoidHazards = true })
  T.eq(#on.Plan, 2, "both placed")
  T.eq(#on.Unplaced, 0, "nothing left out")
  for _, p in ipairs(on.Plan) do T.eq(p.Hazard and p.Hazard.Lowland, 1, "marked: 2 m lowland") end
  -- Volcano and lowland together: the best plot again, as with the switch off.
  local off = Solve({ Districts = { CAMPUS, HOLY } })
  T.eq(on.Gain, off.Gain, "every plot at risk: the best plan")
  -- A flood barrier protects the city's lowland.
  for _, l in ipairs(lowlands) do w:SetProtected(l[1], l[2], true) end
  local safe = 0
  for _, c in ipairs(SDP_City.Scan(0, 1).Candidates) do
    if c.Hazard == nil then safe = safe + 1 else T.eq(c.Hazard.Lowland, nil, "lowland protected") end
  end
  T.ok(safe > 0, "safe plots again")
  w = World.New({ rows = MAP, cities = { CITY }, disasters = { volcanoes = VOLCANOES } })
end)

-- Floodplains along one river all round the city.
local RIVER_MAP = {
  "~~~~~~~~~",
  "~FFFFFFF~",
  "~FFF.FFF~",
  "~FFFFFFF~",
  "~~~~~~~~~",
}
-- The floodplain candidates of the city (the others are water).
local function Floodplains(scan)
  local list = {}
  for _, c in ipairs((scan or SDP_City.Scan(0, 1)).Candidates) do
    local f = Map.GetPlotByIndex(c.Index):GetFeatureType()
    if f ~= -1 and GameInfo.Features[f].FeatureType == "FEATURE_FLOODPLAINS" then list[#list + 1] = c end
  end
  return list
end

local function RiverWorld(extra)
  local rivers = {}
  for y, row in ipairs(RIVER_MAP) do
    for x = 1, #row do
      if row:sub(x, x) == "F" then rivers[#rivers + 1] = (x - 1) .. "," .. (y - 1) end
    end
  end
  local spec = { rows = RIVER_MAP, rivers = rivers, disasters = {},
    cities = { { id = 1, x = 4, y = 2, population = 7, capital = true, radius = 3 } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

test("floodplains: at risk without a dam; a dam planned with the plan guards them", function()
  w = RiverWorld()
  local floodplains = 0
  for _, c in ipairs(Floodplains()) do
    floodplains = floodplains + 1
    T.ok(c.Hazard ~= nil and c.Hazard.Flood ~= nil, "flood risk: " .. c.X .. "," .. c.Y)
  end
  T.ok(floodplains > 0, "floodplains in range")
  local alone = Solve({ Districts = { HUB }, AvoidHazards = true })
  local hub = Entry(alone.Plan, HUB)
  T.ok(hub ~= nil and hub.Hazard ~= nil and hub.Hazard.Flood ~= nil, "no safe plot: placed and marked")
  local withDam = Solve({ Districts = { HUB, DAM }, AvoidHazards = true })
  T.ok(Entry(withDam.Plan, DAM) ~= nil, "the dam planned")
  T.eq(Entry(withDam.Plan, HUB).Hazard, nil, "the hub guarded by the planned dam")
  T.eq(Entry(withDam.Plan, DAM).Hazard, nil, "the dam guards itself")
  local off = Solve({ Districts = { HUB, DAM } })
  T.eq(Entry(off.Plan, HUB).Hazard, nil, "the switch off: the plan's dam guards too")
end)

test("floodplains: a built dam or a dam tack guards the river; Egypt's trait avoids floods", function()
  w = RiverWorld()
  w:AddDistrict(1, DAM, 2, 1, true)
  for _, c in ipairs(Floodplains()) do T.eq(c.Hazard, nil, "built dam: " .. c.X .. "," .. c.Y) end
  w = RiverWorld()
  w:AddPin(2, 1, "ICON_" .. DAM)
  for _, c in ipairs(Floodplains()) do T.eq(c.Hazard, nil, "dam tack: " .. c.X .. "," .. c.Y) end
  -- A tack being replaced does not guard.
  local pin = w:Pins()[1]
  local scan = SDP_City.Scan(0, 1, { ignorePins = { [pin:GetID()] = true } })
  T.ok(Floodplains(scan)[1].Hazard ~= nil, "replaced dam tack: no guard")
  w = RiverWorld({ traits = { "TRAIT_TEST_ITERU" } })
  for _, c in ipairs(Floodplains()) do T.eq(c.Hazard, nil, "Egypt: " .. c.X .. "," .. c.Y) end
  w = World.New({ rows = MAP, cities = { CITY }, disasters = { volcanoes = VOLCANOES } })
end)

test("a site's risk: how many plots for districts have each kind", function()
  local scan = SDP_City.ScanSite(0, 8, 2)
  local volcano = 0
  for _, c in ipairs(scan.Candidates) do
    if c.Hazard ~= nil and c.Hazard.Volcano ~= nil then volcano = volcano + 1 end
  end
  T.ok(volcano > 0, "plots next to a volcano in range")
  local d = SDP_Sites.Disaster(scan)
  T.eq(d.Volcano, volcano, "counted")
  T.eq(d.Flood, 0, "no floods")
  T.eq(SDP_Sites.Disaster(SDP_City.ScanSite(0, 11, 7)), nil, "far from the volcanoes: none")
end)

test("without disaster rules the switch does nothing", function()
  World.New({ rows = MAP, cities = { CITY } })
  SDP_Panel.SetAvoidHazards(true)
  SDP_Panel.SelectCity(1)
  T.eq(SDP_Panel.Request().AvoidHazards, nil, "not in the request")
  SDP_Panel.SetAvoidHazards(false)
end)
