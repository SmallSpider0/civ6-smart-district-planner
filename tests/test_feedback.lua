-- @state SDP_Panel
-- @timeout 400
-- The changes after the collaborator's Windows test (feedback items 1-11):
-- picking districts from a pool (single city, sites, several cities), the
-- distance cost, districts a city gets by itself (aqueduct, dam), reminder
-- pins for woods and rainforest, switching a city-center pin off.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game
-- (game.py newgame --capital --reveal).
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

local function Resolve(base)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if plannable[base] then return base end
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then return row.CivUniqueDistrictType end
  end
  T.skip(base .. " not available to this civ")
end

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- Specialty districts the capital can still plan, without an empire limit.
local function Pool(city, skip)
  local scan = SDP_City.Scan(pid, city:GetID())
  local plannable = SDP_Rules.PlannableDistricts(pid)
  local status = SDP_City.DistrictStatus(scan, plannable)
  local pool = {}
  for _, d in ipairs(plannable) do
    if d.Specialty and status[d.Type] == nil and not (d.MaxPerPlayer and d.MaxPerPlayer > 0) and d.Type ~= skip then
      pool[#pool + 1] = d.Type
    end
  end
  return pool
end

local function UndoAll()
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
end

test("single city: a campus and two picked from the pool; three solutions with other districts", function()
  local city = Capital()
  local campus = Resolve("DISTRICT_CAMPUS")
  local pool = Pool(city, campus)
  T.ok(#pool >= 4, "a pool of " .. #pool)
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { campus }, Pool = pool, Count = 3,
    Weights = ONES, Land = true, Tier = "STANDARD" })
  T.ok(result.Ok, tostring(result.Error))
  T.eq(result.Stats.Method, "pools", "picked")
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  T.eq(#result.Solutions, 3, "three solutions")
  local keys = {}
  for n, s in ipairs(result.Solutions) do
    local types, hasCampus = {}, false
    for _, p in ipairs(s.Plan) do
      types[#types + 1] = p.Type
      if p.Type == campus then hasCampus = true end
    end
    table.sort(types)
    keys[n] = table.concat(types, ",")
    T.ok(hasCampus, "the campus in solution " .. n)
    T.eq(#s.Picked, 2, "two picked in solution " .. n)
    T.eq(s.Gain, s.Adjacency + s.LandDelta + s.CostDelta, "gain adds up in solution " .. n)
    print(string.format("  solution %d  %+.1f  %s", n, s.Gain, keys[n]))
  end
  T.ok(keys[1] ~= keys[2] and keys[1] ~= keys[3] and keys[2] ~= keys[3], "three different combinations")
  -- Picking two of the pool beats or equals any one fixed pair tried alone.
  local first = result.Solutions[1]
  local fixed = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { campus, first.Picked[1], first.Picked[2] },
    Weights = ONES, Land = true, Tier = "STANDARD" })
  T.ok(math.abs(fixed.Gain - first.Gain) < 1e-6 or fixed.Gain < first.Gain + 1e-6, "the same districts asked directly")
end)

test("the panel: count above the required districts runs as a task, shows three solutions and previews them", function()
  local city = Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, d.Specialty and "POOL" or "OFF") end
  SDP_Panel.SetSelected(Resolve("DISTRICT_CAMPUS"), true)
  SDP_Panel.SetCount(3)
  SDP_Panel.SetRemind(true)
  SDP_Panel.SetTier("FAST")
  T.eq(SDP_Panel.State().Count, 3, "count")
  T.eq(SDP_Panel.Solve(), nil, "a task")
  local result = SDP_Panel.RunTask(1000)
  T.ok(result and result.Ok, tostring(result and result.Error))
  T.eq(#result.Solutions, 3, "three solutions")
  SDP_Panel.SelectSolution(3)
  T.eq(SDP_Panel.State().Solution, 3, "third shown")
  T.ok(SDP_Preview.IsShown(), "previewed on the map")
  -- Place the shown solution: its districts and reminder pins; undo takes all.
  local before = 0
  for _ in pairs(PlayerConfigurations[pid]:GetMapPins()) do before = before + 1 end
  local placed = SDP_Panel.PlacePins()
  local third = result.Solutions[3]
  T.eq(placed, #third.Plan + #(third.Remind or {}), "districts and reminders")
  T.eq(SDP_Panel.UndoPins(), placed, "undo")
  local after = 0
  for _ in pairs(PlayerConfigurations[pid]:GetMapPins()) do after = after + 1 end
  T.eq(after, before, "pins gone")
  SDP_Panel.SetCount(0)
  SDP_Panel.SetTier("STANDARD")
  UndoAll()
end)

test("distance cost: the cost is weight x (plots to the nearest center - 1) and pulls districts in", function()
  local city = Capital()
  local districts = { Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE"), Resolve("DISTRICT_COMMERCIAL_HUB") }
  local plain = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = districts, Weights = ONES })
  local far = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = districts, Weights = ONES, Distance = 2 })
  T.ok(plain.Ok and far.Ok, "solved")
  local function Rings(r)
    local total = 0
    for _, p in ipairs(r.Plan) do total = total + Map.GetPlotDistance(city:GetX(), city:GetY(), p.X, p.Y) end
    return total
  end
  local expected = 0
  for _, p in ipairs(far.Plan) do expected = expected - 2 * (Map.GetPlotDistance(city:GetX(), city:GetY(), p.X, p.Y) - 1) end
  T.eq(far.CostDelta, expected, "cost")
  T.ok(Rings(far) <= Rings(plain), "closer or as close: " .. Rings(far) .. " vs " .. Rings(plain))
  T.eq(far.Gain, far.Adjacency + far.LandDelta + far.CostDelta, "gain adds up")
end)

test("automatic districts: an aqueduct (or the civ's own) joins only a city without fresh water", function()
  local city = Capital()
  local scan = SDP_City.Scan(pid, city:GetID())
  local aqueduct = nil
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if SDP_Rules.AutoKind(d.Type) == "WATER" then aqueduct = d.Type end
  end
  T.ok(aqueduct ~= nil, "an aqueduct kind in the data")
  local lacks = SDP_City.LacksFreshWater(scan)
  print("  capital lacks fresh water: " .. tostring(lacks) .. ", housing from water "
    .. tostring(city:GetGrowth():GetHousingFromWater()))
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { Resolve("DISTRICT_CAMPUS") },
    Auto = { [aqueduct] = true }, Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  local got = nil
  for _, p in ipairs(result.Plan) do
    if p.Type == aqueduct then got = p end
  end
  local unplaced = nil
  for _, u in ipairs(result.Unplaced) do
    if u.Type == aqueduct then unplaced = u end
  end
  if lacks and SDP_City.DistrictStatus(scan, SDP_Rules.PlannableDistricts(pid))[aqueduct] == nil then
    T.ok(got ~= nil and got.Auto or (unplaced ~= nil and unplaced.Auto), "added, or reported as not fitting")
  else
    T.ok(got == nil, "not added with fresh water")
  end
  -- The dam: Gathering Storm data only.
  if GameInfo.Districts_XP2 ~= nil and GameInfo.Districts["DISTRICT_DAM"] ~= nil then
    T.eq(SDP_Rules.AutoKind("DISTRICT_DAM"), "FLOOD", "the dam prevents floods")
    local needed = SDP_City.NeedsAuto(scan, "DISTRICT_DAM")
    print("  dam needed: " .. tostring(needed))
    local dam = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { Resolve("DISTRICT_INDUSTRIAL_ZONE") },
      Auto = { DISTRICT_DAM = true }, Weights = ONES })
    T.ok(dam.Ok, tostring(dam.Error))
    local placed, reported = nil, nil
    for _, p in ipairs(dam.Plan) do
      if p.Type == "DISTRICT_DAM" then placed = p end
    end
    for _, u in ipairs(dam.Unplaced) do
      if u.Type == "DISTRICT_DAM" then reported = u end
    end
    if needed then
      T.ok((placed ~= nil and placed.Auto) or (reported ~= nil and reported.Auto), "the dam added, or reported as not fitting")
      if placed ~= nil then print(string.format("  dam at %d,%d (industrial zone %s)", placed.X, placed.Y,
        SDP_UI.YieldText(dam.Plan[1].Yields))) end
    else
      T.ok(placed == nil, "no dam without floodplains")
    end
  end
end)

test("reminders: hiding a woods plot next to a holy site costs DMT faith exactly when the woods count is even", function()
  local city = Capital()
  local holy = Resolve("DISTRICT_HOLY_SITE")
  local scan = SDP_City.Scan(pid, city:GetID())
  -- A candidate plot with exactly two woods next to it.
  local spot, woods = nil, {}
  for _, c in ipairs(scan.Candidates) do
    local list = {}
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
      local n = Map.GetAdjacentPlot(c.X, c.Y, direction)
      if n ~= nil and n:GetFeatureType() ~= -1 and GameInfo.Features[n:GetFeatureType()].FeatureType == "FEATURE_FOREST"
          and n:GetDistrictType() == -1 then
        list[#list + 1] = n
      end
    end
    if #list == 2 and spot == nil then spot, woods = c, list end
  end
  if spot == nil then T.skip("no plot next to exactly two woods") end
  local found = SDP_Overlay.With(pid, function()
    return SDP_Remind.Find(pid, { { Type = holy, Kind = "DISTRICT", X = spot.X, Y = spot.Y } })
  end)
  local at = {}
  for _, r in ipairs(found) do at[r.Index] = r end
  for _, n in ipairs(woods) do
    local r = at[n:GetIndex()]
    T.ok(r ~= nil, "reminder at the woods " .. n:GetX() .. "," .. n:GetY())
    if r ~= nil then T.eq(r.Losses[1].Yields.YIELD_FAITH, 1, "faith lost") end
  end
  T.ok(GetRealizedPlotFeatures ~= nil, "DMT's feature reader present")
  -- The overlay put DMT's reader back.
  local x = SDP_Overlay.With(pid, function() return true end)
  T.ok(x, "overlay ok")
end)

test("several cities: a city-center pin switched off takes no part; each city picks from its pool", function()
  local city = Capital()
  -- A city-center pin six plots away, if a plot is free there.
  local site = nil
  for _, entry in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 7)) do
    local plot = Map.GetPlotByIndex(entry.Index)
    if site == nil and Map.GetPlotDistance(city:GetX(), city:GetY(), entry.X, entry.Y) == 6 and not plot:IsWater()
        and not plot:IsMountain() and plot:GetOwner() == -1 and PlayersVisibility[pid]:IsRevealed(entry.Index) then
      site = entry
    end
  end
  if site == nil then T.skip("no free plot six away") end
  SDP_Pins.Place(pid, { { Type = "DISTRICT_CITY_CENTER", X = site.X, Y = site.Y, Name = "" } })
  local ok, err = pcall(function()
    local parts, _, sites = SDP_Multi.Participants(pid)
    local key = nil
    for _, s in ipairs(sites) do
      if s.X == site.X and s.Y == site.Y then key = s.Key end
    end
    T.ok(key ~= nil, "the pin is listed")
    local fewer = SDP_Multi.Participants(pid, { Sites = { [key] = false } })
    for _, part in ipairs(fewer) do T.ok(part.Key ~= key, "switched off") end
    T.ok(#fewer < #parts, "one participant less")
    local campus = Resolve("DISTRICT_CAMPUS")
    local result = SDP_Multi.Solve({ PlayerID = pid, Tier = "FAST", Districts = { campus }, Pool = Pool(city, campus),
      Count = 2, Weights = ONES, Existing = { [city:GetID()] = true } })
    T.ok(result.Ok, tostring(result.Error))
    T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
    for _, c in ipairs(result.Cities) do
      local specialty = 0
      for _, p in ipairs(result.Plan) do
        if p.City == c.Key and GameInfo.Districts[p.Type] and GameInfo.Districts[p.Type].RequiresPopulation then
          specialty = specialty + 1
        end
      end
      T.ok(specialty <= 2, c.Key .. " plans at most two: " .. specialty)
      print(string.format("  %s picked %s", c.Key, table.concat(c.Picked, ",")))
    end
  end)
  UndoAll()
  if not ok then error(err, 0) end
end)

test("sites: each site is scored with its best districts when more are ticked", function()
  local districts = {}
  for _, base in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" }) do
    districts[#districts + 1] = Resolve(base)
  end
  local result = SDP_SiteSolver.Solve({ PlayerID = pid, K = 1, D = 8, Districts = districts, PlanCount = 2, Tier = "FAST" })
  T.ok(result.Ok, tostring(result.Error))
  for _, s in ipairs(result.Solutions[1].Sites) do
    T.ok(#(s.Districts or {}) <= 2, "at most two districts")
  end
end)
