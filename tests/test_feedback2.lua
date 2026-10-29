-- @state SDP_Panel
-- @timeout 400
-- The second round of feedback (2026-10-21): the harbor and the commercial
-- hub kept apart (SDP_Rules.Apart; always since issue 152), a neighborhood's housing and a
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

test("the game's rules: the harbor's route needs a city without a commercial hub; housing and preserve yields by appeal", function()
  local apart = SDP_Rules.Apart()
  local found = nil
  for _, pair in ipairs(apart.Pairs) do
    if pair.A == "DISTRICT_HARBOR" and pair.B == "DISTRICT_COMMERCIAL_HUB" then found = pair end
  end
  T.ok(found ~= nil, "the harbor / commercial hub pair is read from the modifiers")
  found = found or {}
  if SDP_Rules.Ruleset() == "RULESET_STANDARD" then
    -- The base game: the harbor district adds a route only in a city without
    -- a commercial hub (DistrictModifiers, issue 107); the Royal Navy
    -- Dockyard adds one always.
    T.eq(#apart.Pairs, 1, "one pair in the base game")
    T.eq(found.Building, "DISTRICT_HARBOR", "the harbor loses its route")
    T.eq(found.Other, "DISTRICT_COMMERCIAL_HUB", "to a commercial hub")
    for row in GameInfo.DistrictReplaces() do
      if row.ReplacesDistrictType == "DISTRICT_HARBOR" then
        T.eq(apart.Partners[row.CivUniqueDistrictType], nil, row.CivUniqueDistrictType .. " keeps its own route")
      end
    end
  else
    T.eq(found.Building, "BUILDING_LIGHTHOUSE", "the lighthouse loses its route")
    T.eq(found.Other, "BUILDING_MARKET", "to a market")
    for row in GameInfo.DistrictReplaces() do
      if row.ReplacesDistrictType == "DISTRICT_HARBOR" then
        T.ok(apart.Partners[row.CivUniqueDistrictType]["DISTRICT_COMMERCIAL_HUB"], row.CivUniqueDistrictType .. " counts as a harbor")
      end
    end
  end
  local rules = SDP_Appeal.Rules()
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_NEIGHBORHOOD", 4), 6, "breathtaking: 6")
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_NEIGHBORHOOD", 0), 4, "average: 4")
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_NEIGHBORHOOD", -4), 2, "disgusting: 2")
  -- The preserve comes with the Vietnam & Kublai Khan pack; an account without it has none.
  if GameInfo.Districts.DISTRICT_PRESERVE ~= nil then
    T.ok(rules.Housing.DISTRICT_PRESERVE ~= nil and rules.Tiles.DISTRICT_PRESERVE ~= nil, "the preserve has both")
  end
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

-- Issue 152: no switch; every request keeps partner districts apart.
test("the panel: no keep-apart switch, partner districts always kept apart (issue 152)", function()
  Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Refresh()
  for _, id in ipairs({ "ApartBox", "ApartCheck", "ApartLabel", "MultiApartBox", "MultiApartCheck", "MultiApartLabel" }) do
    T.eq(Controls[id], nil, "no " .. id)
  end
  local request = SDP_Panel.Request()
  if request == nil then T.skip("nothing to plan in the capital") end
  T.eq(request.Apart, true, "kept apart")
end)

-- Issue 106: with both the harbor and the commercial hub as candidates and
-- one to pick, a city whose center is on the coast without fresh water takes
-- the harbor (the side that stands on water), every other city the hub. The
-- game's own Plot tests decide; the map decides which case the capital is.
test("harbor or commercial hub by the city: the coastal one for a coastal city without fresh water", function()
  local city = Capital()
  local hub, harbor = Resolve("DISTRICT_COMMERCIAL_HUB"), Resolve("DISTRICT_HARBOR")
  if SDP_Rules.Apart().Partners[harbor] == nil then T.skip("this civ's harbor keeps its own route") end
  local plot = Map.GetPlot(city:GetX(), city:GetY())
  local coastal, fresh = plot:IsCoastalLand(), plot:IsFreshWater()
  local takesHarbor = coastal and not fresh
  local want, other = takesHarbor and harbor or hub, takesHarbor and hub or harbor
  local avoid = SDP_Rules.ApartAvoid(plot)
  T.eq(avoid[other], true, "leaves out " .. other)
  T.eq(avoid[want], nil, "keeps " .. want)
  local request = { PlayerID = pid, CityID = city:GetID(), Districts = {}, Weights = ONES, Tier = "STANDARD",
    Pool = { hub, harbor }, Count = 1 }
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  local alone = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { want }, Weights = ONES })
  local placeable = alone.Ok and Has(alone.Plan, want) ~= nil
  print(string.format("  capital coastal %s, fresh water %s: picked %s (%s placeable: %s)", tostring(coastal), tostring(fresh),
    table.concat(result.Picked, ","), want, tostring(placeable)))
  for n, sol in ipairs(result.Solutions) do
    if placeable then
      T.ok(Has(sol.Plan, want) ~= nil and Has(sol.Plan, other) == nil, "solution " .. n .. ": " .. table.concat(sol.Picked, ","))
    else
      T.ok(Has(sol.Plan, want) == nil, "solution " .. n .. ": " .. want .. " has no plot")
    end
  end
  request.Apart = false
  local off = SDP_Solver.Solve(request)
  T.ok(off.Ok, tostring(off.Error))
  print(string.format("  switch off: %s", table.concat(off.Picked, ",")))
end)

-- Issue 91 (decided 2026-10-26), with the game's rules: the preserve starts
-- off; its grove counts always and its sanctuary only with the civic that
-- unlocks it; its yields on the plots around it are in the tiles part.
test("issue 91: the preserve starts off; its buildings by the player's civics; its yields in the tiles part", function()
  local city = Capital()
  if GameInfo.Districts.DISTRICT_PRESERVE == nil then T.skip("no preserve in this ruleset or account") end
  local preserve = Resolve("DISTRICT_PRESERVE")
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if d.Type == preserve then T.eq(SDP_UI.DefaultState(d), "OFF", "the preserve starts off") end
  end
  -- The buildings: the grove comes with the preserve; the sanctuary needs its civic.
  local rules = SDP_Appeal.Rules()
  local rows = SDP_Appeal.TileRows(rules, preserve, Players[pid])
  local by = {}
  for _, row in ipairs(rows) do by[row.Building or "-"] = true end
  T.ok(by.BUILDING_GROVE, "the grove's rows count")
  local sanctuary = GameInfo.Buildings.BUILDING_SANCTUARY
  local civic = sanctuary and sanctuary.PrereqCivic and GameInfo.Civics[sanctuary.PrereqCivic]
  local has = civic ~= nil and Players[pid]:GetCulture():HasCivic(civic.Index)
  T.eq(by.BUILDING_SANCTUARY == true, has == true, "the sanctuary's rows only with " .. tostring(civic and civic.CivicType))
  -- Required, the tiles weight on: the appeal part is its housing; the
  -- yields are in the tiles part; the parts add up.
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { preserve }, Weights = ONES,
    Land = true })
  if not result.Ok and result.Error == "NO_LEGAL_PLOT" then T.skip("no plot for a preserve") end
  T.ok(result.Ok, tostring(result.Error))
  local p = Has(result.Plan, preserve)
  if p == nil then T.skip("the preserve was not placed") end
  local housing, tiles = result.Session.Search:AppealParts(result.Session.Search.BestLayout)
  T.ok(math.abs((result.AppealDelta or 0) - housing) < 1e-6, "the appeal part is the housing")
  T.ok(tiles >= 0, "the yields add to the tiles part: " .. tiles)
  T.ok(math.abs(result.Gain - (result.Adjacency + result.LandDelta + result.CostDelta + result.CoverageDelta
    + (result.AppealDelta or 0))) < 1e-6, "the parts add up")
  print(string.format("  preserve at (%d, %d): housing %.2f, tiles part %.2f (of it from the preserve's yields %.2f)",
    p.X, p.Y, housing, result.LandDelta, tiles))
end)

test("issue 91: the panel's summary leads with the adjacency, distance 0.5 by default", function()
  local city = Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
  SDP_Panel.SetPreset("BALANCED")
  T.eq(SDP_Panel.State().Weights.DISTANCE, 0.5, "distance 0.5 (a new game keeps no settings)")
  SDP_Panel.SetSelected(Resolve("DISTRICT_CAMPUS"), true)
  SDP_Panel.SetSelected(Resolve("DISTRICT_HOLY_SITE"), true)
  SDP_Panel.SetCount(0)
  SDP_Panel.SetTier("FAST")
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, tostring(result and result.Error))
  T.eq(result.Session.Request.Distance, 0.5, "sent")
  local parts = Locale.Lookup("LOC_SDP_LIST_JOIN", Locale.Lookup("LOC_SDP_PART_LAND", SDP_UI.Signed(result.LandDelta)),
    Locale.Lookup("LOC_SDP_PART_DISTANCE", SDP_UI.Signed(result.CostDelta)))
  T.eq(SDP_Panel.State().SummaryText, Locale.Lookup("LOC_SDP_RESULT_SUMMARY_OTHERS", SDP_UI.Signed(result.Adjacency), parts),
    "adjacency first, then tiles and distance")
  print("  " .. SDP_Panel.State().SummaryText)
  SDP_Panel.SetTier("STANDARD")
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
end)

test("issue 91: an industrial zone does not count its own city as covered; housing counts 1 up to max(target + 1, population + 2)", function()
  local city = Capital()
  local zone = Resolve("DISTRICT_INDUSTRIAL_ZONE")
  local r = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { zone }, Weights = ONES, Coverage = 1,
    Tier = "FAST" })
  T.ok(r.Ok, tostring(r.Error))
  local p = Has(r.Plan, zone)
  if p == nil then T.skip("no plot for an industrial zone") end
  local own = "C" .. city:GetID()
  for _, key in ipairs(p.Reach or {}) do T.ok(key ~= own, "the capital is not on its own zone's row") end
  T.eq(r.Covered or 0, #(p.Reach or {}), "only other cities count")
  T.eq(SDP_Land.HousingValue(8, 7, 5), 8, "housing one past the target counts 1")
  T.eq(SDP_Land.HousingValue(9, 7, 5), 8.5, "the next one half")
end)
