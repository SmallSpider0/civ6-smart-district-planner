-- @state SDP_Panel
-- @timeout 400
-- The second round of feedback (2026-10-21): the harbor and the commercial
-- hub kept apart (SDP_Rules.Apart), a neighborhood's housing and a
-- preserve's yields by appeal (SDP_Appeal), switching a city-center pin off
-- on the multi-city tab, "replace" leaving city-center pins alone. The rules
-- are the game's here. Needs a city: run tests/fixtures/found_capital.lua
-- first on a fresh game (game.py newgame --capital --reveal).
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

local function Resolve(base)
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if SDP_Rules.BaseDistrict(d.Type) == base then return d.Type end
  end
  T.skip(base .. " not available to this civ")
end

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function UndoAll()
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
end

local function Has(plan, districtType)
  for _, p in ipairs(plan) do
    if p.Type == districtType then return p end
  end
  return nil
end

test("the game's rules: the lighthouse needs a city without a market; housing and preserve yields by appeal", function()
  local apart = SDP_Rules.Apart()
  local found = nil
  for _, pair in ipairs(apart.Pairs) do
    if pair.A == "DISTRICT_HARBOR" and pair.B == "DISTRICT_COMMERCIAL_HUB" then found = pair end
  end
  T.ok(found ~= nil, "the harbor / commercial hub pair is read from the modifiers")
  T.eq(found.Building, "BUILDING_LIGHTHOUSE", "the lighthouse loses its route")
  T.eq(found.Other, "BUILDING_MARKET", "to a market")
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == "DISTRICT_HARBOR" then
      T.ok(apart.Partners[row.CivUniqueDistrictType]["DISTRICT_COMMERCIAL_HUB"], row.CivUniqueDistrictType .. " counts as a harbor")
    end
  end
  local rules = SDP_Appeal.Rules()
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_NEIGHBORHOOD", 4), 6, "breathtaking: 6")
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_NEIGHBORHOOD", 0), 4, "average: 4")
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_NEIGHBORHOOD", -4), 2, "disgusting: 2")
  T.ok(rules.Housing.DISTRICT_PRESERVE ~= nil and rules.Tiles.DISTRICT_PRESERVE ~= nil, "the preserve has both")
  if GameInfo.Districts.DISTRICT_MBANZA ~= nil then T.eq(rules.Housing.DISTRICT_MBANZA, nil, "the mbanza ignores appeal") end
end)

test("single city: the pool never gives the capital both the harbor and the commercial hub", function()
  local city = Capital()
  local hub, harbor = Resolve("DISTRICT_COMMERCIAL_HUB"), Resolve("DISTRICT_HARBOR")
  local request = { PlayerID = pid, CityID = city:GetID(), Districts = {}, Weights = ONES, Tier = "STANDARD",
    Pool = { Resolve("DISTRICT_CAMPUS"), hub, harbor, Resolve("DISTRICT_HOLY_SITE") }, Count = 2 }
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  for n, sol in ipairs(result.Solutions) do
    T.ok(not (Has(sol.Plan, hub) and Has(sol.Plan, harbor)), "solution " .. n .. ": " .. table.concat(sol.Picked, ","))
  end
  request.Apart = false
  local off = SDP_Solver.Solve(request)
  T.ok(off.Ok, tostring(off.Error))
  print(string.format("  on %.2f (%s), off %.2f (%s)", result.Gain, table.concat(result.Picked, ","), off.Gain,
    table.concat(off.Picked, ",")))
  T.ok(off.Gain >= result.Gain - 1e-9, "the rule never gains adjacency")
end)

test("a neighborhood: its housing follows the game's appeal of its plot", function()
  local city = Capital()
  local hood = Resolve("DISTRICT_NEIGHBORHOOD")
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { hood }, Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  local p = Has(result.Plan, hood)
  T.ok(p ~= nil, "placed")
  local appeal = Map.GetPlot(p.X, p.Y):GetAppeal()
  T.eq(p.Appeal, appeal, "alone: the game's appeal")
  T.eq(p.Housing, SDP_Appeal.Housing(SDP_Appeal.Rules(), hood, appeal), "housing by that appeal")
  -- Nowhere better: the best plot's appeal is the highest among the plots it may take.
  local best = -math.huge
  local scan = SDP_City.Scan(pid, city:GetID())
  SDP_Overlay.With(pid, function()
    for _, c in ipairs(scan.Candidates) do
      if SDP_Overlay.CanPlace(SDP_Overlay.Subject(hood, c.X, c.Y)) then
        best = math.max(best, SDP_Appeal.Housing(SDP_Appeal.Rules(), hood, Map.GetPlotByIndex(c.Index):GetAppeal()))
      end
    end
  end)
  T.eq(p.Housing, best, "the most housing any plot gives")
  print(string.format("  neighborhood at (%d, %d): appeal %d, housing %d; gain %.2f", p.X, p.Y, appeal, p.Housing, result.Gain))
end)

test("the multi-city tab: a city-center pin unticked stays out; replace leaves city-center pins alone", function()
  local city = Capital()
  local site = nil
  for _, entry in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 7)) do
    local plot = Map.GetPlotByIndex(entry.Index)
    if site == nil and Map.GetPlotDistance(city:GetX(), city:GetY(), entry.X, entry.Y) == 6 and not plot:IsWater()
        and not plot:IsMountain() and plot:GetOwner() == -1 and PlayersVisibility[pid]:IsRevealed(entry.Index) then
      site = entry
    end
  end
  if site == nil then T.skip("no free plot six away") end
  local _, count = SDP_City.CityNumbers(pid)
  SDP_Pins.Place(pid, { { Type = "DISTRICT_CITY_CENTER", X = site.X, Y = site.Y, Name = tostring(count + 1) } })
  local ok, err = pcall(function()
    SDP_Panel.SelectTab("MULTI")
    local multi = SDP_Panel.Multi
    multi.Refresh()
    local key = nil
    for _, c in ipairs(multi.State().View.Cities) do
      if c.Kind == "SITE" then key = c.Key end
    end
    T.ok(key ~= nil, "the pin is listed")
    multi.SetSite(key, false)
    for _, c in ipairs(multi.State().View.Cities) do
      if c.Key == key then T.eq(c.Included, false, "unticked: off") end
    end
    for _, part in ipairs(multi.Participants()) do T.ok(part.Key ~= key, "takes no part") end
    multi.SetSite(key, true)
    for _, record in ipairs(multi.OwnPins()) do T.ok(record.Icon ~= "ICON_DISTRICT_CITY_CENTER", "not a pin to replace") end
  end)
  SDP_Panel.SelectTab("SINGLE")
  UndoAll()
  if not ok then error(err, 0) end
end)

test("the panel: the switch names the pair and starts on", function()
  Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Refresh()
  T.eq(Controls.ApartBox:IsHidden(), false, "shown")
  -- The tooltip names the pair; the short label too in Chinese ("Keep apart" in English).
  local harbor = Locale.Lookup(GameInfo.Districts.DISTRICT_HARBOR.Name)
  T.ok(Controls.ApartLabel:GetText() ~= "", "labelled")
  T.ok(Controls.ApartBox:GetToolTipString():find(harbor, 1, true) ~= nil, "named: " .. Controls.ApartBox:GetToolTipString())
  T.eq(SDP_Panel.State().Apart, true, "on")
  T.eq(Controls.ApartCheck:IsChecked(), true, "ticked")
end)
