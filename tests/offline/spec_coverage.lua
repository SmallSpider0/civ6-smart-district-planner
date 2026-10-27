-- Offline: SDP_Coverage, the coverage part of the multi-city and
-- single-city objective (docs/multicity-design.md section 19).
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Coverage")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~..f.M..h...f..M..h..~",
  "~.fMj..p.d...fMj..p..~",
  "~h..f.j..M.h..f.j..M.~",
  "~.pM...f.h..pM...f.h.~",
  "~..j.p..q....j.p..q..~",
  "~f..h.M.j..f..h.M.j..~",
  "~.s..f..p...s..f..p..~",
  "~..p...h...p...h.....~",
  "~.M..f..j..M..f..j...~",
  "~..h..p...h..p...h...~",
  "~.f..M..p..f..M..p...~",
  "~..j...h..j...h..j...~",
  "~~~~~~~~~~~~~~~~~~~~~~",
}

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local IZ, EC = "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX"

-- City 1 at (4,5) and city 2 at (11,5), 7 apart: an industrial zone of city
-- 1 reaches city 2 only from the plots on its side. City 3 at (4,11).
local function NewWorld(extra)
  local spec = {
    rows = MAP, rivers = { "6,4", "7,4", "7,5" },
    cities = {
      { id = 1, x = 4, y = 5, population = 10, capital = true, radius = 1 },
      { id = 2, x = 11, y = 5, population = 3, radius = 1 },
      { id = 3, x = 4, y = 11, population = 3, radius = 1 },
    },
  }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local function Keys(model, ids)
  local keys = {}
  for _, id in ipairs(ids) do keys[#keys + 1] = model:Pair(id).Key end
  table.sort(keys)
  return keys
end

-- Target keys within `range` of x, y, worked out here from the targets.
local function Within(model, x, y, range, skip)
  local keys = {}
  for _, target in ipairs(model.Targets) do
    if Map.GetPlotDistance(x, y, target.X, target.Y) <= range and not (skip and skip[target.Key]) then
      keys[#keys + 1] = target.Key
    end
  end
  table.sort(keys)
  return keys
end

test("reaches come from the rules: regional buildings by base district, the player's own, wonders", function()
  NewWorld()
  local r = SDP_Coverage.Reaches(0)
  T.eq(r[IZ].Range, 6, "factory")
  T.eq(r[IZ].Group, IZ, "group: the base district")
  T.eq(r[EC].Range, 6, "zoo")
  T.eq(r.BUILDING_COLOSSEUM.Range, 6, "a wonder's own reach")
  T.eq(r.BUILDING_COLOSSEUM.Group, "BUILDING_COLOSSEUM", "a wonder is its own group")
  T.eq(r.DISTRICT_CAMPUS, nil, "no regional building")
  T.eq(r.BUILDING_HANGING_GARDENS, nil, "a wonder without a reach")
  -- The made-up civilization building (range 9) counts only for that civilization.
  NewWorld({ traits = { "TRAIT_CIVILIZATION_DISTRICT_ACROPOLIS" } })
  T.eq(SDP_Coverage.Reaches(0)[IZ].Range, 9, "the player's own building reaches further")
end)

test("counting: every city in reach once per group; built and pinned districts cover already", function()
  local w = NewWorld()
  local model = SDP_Coverage.New({ PlayerID = 0, Weight = 1, Sites = { { Key = "S1", X = 9, Y = 9, Name = "" } } })
  local keys = {}
  for _, target in ipairs(model.Targets) do keys[#keys + 1] = target.Key end
  T.same(keys, { "C1", "C2", "C3", "S1" }, "the player's cities by ID, then the new ones")
  local a = model:List(IZ, Map.GetPlotIndex(7, 5), 7, 5)
  T.same(Keys(model, a), Within(model, 7, 5, 6), "an industrial zone at 7,5")
  T.ok(#a >= 2, "it reaches city 1 and city 2")
  local b = model:List(IZ, Map.GetPlotIndex(2, 7), 2, 7)
  local union = {}
  for _, id in ipairs(a) do union[id] = true end
  for _, id in ipairs(b) do union[id] = true end
  local distinct = 0
  for _ in pairs(union) do distinct = distinct + 1 end
  T.eq(model:Count({ a, b }, 2), distinct, "the same group twice: a city counts once")
  local e = model:List(EC, Map.GetPlotIndex(7, 5), 7, 5)
  T.eq(model:Count({ a, e }, 2), #a + #e, "another group counts again")
  T.eq(model:List("DISTRICT_CAMPUS", Map.GetPlotIndex(7, 5), 7, 5), nil, "a campus has no reach")

  -- A built industrial zone in city 2 and a pinned one near city 3.
  w:AddDistrict(2, IZ, 12, 5, true)
  local pin = w:AddPin(4, 9, "ICON_" .. IZ, "x")
  local covered = {}
  for _, k in ipairs(Within(model, 12, 5, 6)) do covered[k] = true end
  for _, k in ipairs(Within(model, 4, 9, 6)) do covered[k] = true end
  local before = SDP_Coverage.New({ PlayerID = 0, Weight = 1, Sites = { { Key = "S1", X = 9, Y = 9, Name = "" } } })
  T.same(Keys(before, before:List(IZ, Map.GetPlotIndex(7, 5), 7, 5)), Within(before, 7, 5, 6, covered),
    "what is covered already does not count")
  T.same(Keys(before, before:List(EC, Map.GetPlotIndex(7, 5), 7, 5)), Within(before, 7, 5, 6),
    "another group is not covered by them")
  -- The pin being replaced (this mod's earlier pin): only the built one covers.
  local replaced = SDP_Coverage.New({ PlayerID = 0, Weight = 1, Sites = { { Key = "S1", X = 9, Y = 9, Name = "" } },
    IgnorePins = { [pin:GetID()] = true } })
  local builtOnly = {}
  for _, k in ipairs(Within(replaced, 12, 5, 6)) do builtOnly[k] = true end
  T.same(Keys(replaced, replaced:List(IZ, Map.GetPlotIndex(7, 5), 7, 5)), Within(replaced, 7, 5, 6, builtOnly),
    "a pin being replaced does not cover")
end)

-- City 1 plans an industrial zone; cities 2 and 3 plan nothing and do not
-- take part, but they are cities to cover.
local function Request(coverage, extra)
  local r = { PlayerID = 0, Tier = "STANDARD", Weights = ONES, Land = false, Districts = {},
    Existing = { [1] = true }, Plans = { C1 = { IZ, "DISTRICT_CAMPUS" } }, Coverage = coverage }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local function Find(result, districtType)
  for _, p in ipairs(result.Plan) do
    if p.Type == districtType then return p end
  end
  return nil
end

test("weight 0 or none: the solve is exactly as without the coverage part", function()
  NewWorld()
  local none = SDP_Multi.Solve(Request(nil))
  NewWorld()
  local zero = SDP_Multi.Solve(Request(0))
  T.ok(none.Ok and zero.Ok, "solved")
  T.same(zero.Plan, none.Plan, "same plan")
  T.eq(zero.Gain, none.Gain, "same gain")
  T.eq(zero.Covered, nil, "no coverage figures when off")
  T.eq(zero.CoverageDelta, 0, "no coverage part")
  T.eq(Find(zero, IZ).Reach, nil, "no reach on the rows when off")
end)

test("the coverage part moves an industrial zone to reach a city without one", function()
  NewWorld()
  local off = SDP_Multi.Solve(Request(nil))
  NewWorld()
  local on = SDP_Multi.Solve(Request(3))
  T.ok(off.Ok and on.Ok, "solved: " .. tostring(off.Error) .. " " .. tostring(on.Error))
  T.ok(not on.Stats.Mismatch, "board and full evaluation agree")
  T.near(on.Gain, on.Adjacency + on.LandDelta + on.CoverageDelta + on.CostDelta + (on.AppealDelta or 0), 1e-9,
    "the gain adds up")
  T.eq(on.CoverageDelta, 3 * on.Covered, "weight x newly covered cities")
  -- Counted again here: what the plan made without coverage reaches.
  local model = SDP_Coverage.New({ PlayerID = 0, Weight = 3 })
  local offZone, onZone = Find(off, IZ), Find(on, IZ)
  local offCovered = #model:List(IZ, offZone.Index, offZone.X, offZone.Y, "C1")
  print(("without coverage: zone at %d,%d covers %d; weight 3: %d,%d covers %d, adjacency %+g -> %+g"):format(
    offZone.X, offZone.Y, offCovered, onZone.X, onZone.Y, on.Covered, off.Adjacency, on.Adjacency))
  T.ok(on.Covered >= offCovered, "covers at least as much: " .. on.Covered .. " vs " .. offCovered)
  T.ok(on.Gain >= off.Adjacency + 3 * offCovered - 1e-9, "at least as good under its own objective")
  T.ok(Map.GetPlotDistance(onZone.X, onZone.Y, 11, 5) <= 6, "the zone reaches city 2: " .. onZone.X .. "," .. onZone.Y)
  T.same(onZone.Reach, Within(model, onZone.X, onZone.Y, 6, { C1 = true }), "the row lists the other cities in reach")
  T.eq(#on.CoveredBy, 1, "one group")
  T.eq(on.CoveredBy[1].Group, IZ, "the industrial zones")
  T.eq(#on.CoveredBy[1].Keys, on.Covered, "the newly covered cities")
  -- Same input, same plan (constraint 6).
  NewWorld()
  local again = SDP_Multi.Solve(Request(3))
  T.same(again.Plan, on.Plan, "deterministic")
end)

test("a planned city counts as a city to cover; an existing industrial zone keeps it from counting twice", function()
  local w = NewWorld({ pins = { { 8, 9, "ICON_DISTRICT_CITY_CENTER", "A" } } })
  local r = SDP_Multi.Solve(Request(3, { Existing = { [1] = true }, Plans = { C1 = { IZ } } }))
  T.ok(r.Ok, tostring(r.Error))
  local site = nil
  for _, c in ipairs(r.Cities) do
    if c.Kind == "SITE" then site = c.Key end
  end
  T.ok(site ~= nil, "the site takes part")
  local zone = Find(r, IZ)
  local reaches = Map.GetPlotDistance(zone.X, zone.Y, 8, 9) <= 6
  local listed = false
  for _, key in ipairs(r.CoveredBy[1] and r.CoveredBy[1].Keys or {}) do
    if key == site then listed = true end
  end
  T.eq(listed, reaches, "the site is covered when in reach")
  print(("zone at %d,%d; the site in reach: %s"):format(zone.X, zone.Y, tostring(reaches)))
  -- City 2 builds an industrial zone: city 2 is covered already and no
  -- longer counts.
  w:AddDistrict(2, IZ, 12, 5, true)
  local r2 = SDP_Multi.Solve(Request(3, { Existing = { [1] = true }, Plans = { C1 = { IZ } } }))
  for _, key in ipairs(r2.CoveredBy[1] and r2.CoveredBy[1].Keys or {}) do
    T.ok(key ~= "C2", "city 2 is covered by its own zone already")
  end
end)

test("several cities tab: the coverage weight is off by default and goes into the request", function()
  local UI_Mock = include("ui")
  NewWorld()
  UI_Mock.Install()
  include("SDP_Panel")
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  -- The capital alone (the default group would take cities 2 and 3 too).
  multi.SetExisting(1, true)
  multi.SetExisting(2, false)
  multi.SetExisting(3, false)
  multi.SetSelected(IZ, true)
  multi.SetCount(0) -- the zone only (the default count is 3, issue 71)
  T.eq(multi.Request().Coverage, 0, "off by default")
  multi.SetWeight("COVERAGE", 2)
  T.eq(multi.Request().Coverage, 2, "the weight is sent")
  multi.SetWeight("COVERAGE", 7)
  T.eq(multi.Request().Coverage, SDP_UI.MAX_WEIGHT, "clamped")
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.ok(result.Covered ~= nil, "coverage figures")
  local rows = 0
  for _, row in ipairs(multi.State().View.Results) do
    if row.Detail:find("LOC_SDP_COVERAGE_ROW", 1, true) then rows = rows + 1 end
  end
  T.eq(rows, 1, "the industrial zone's row shows its reach")
end)

-- The single-city tab (issue 61, design 19.7): SDP_Solver with the same model.
local function SingleRequest(coverage, extra)
  local r = { PlayerID = 0, CityID = 1, Tier = "STANDARD", Weights = ONES, Land = false,
    Districts = { IZ, "DISTRICT_CAMPUS" }, Coverage = coverage }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

test("single city: weight 0 or none gives exactly the plan without the coverage part", function()
  NewWorld()
  local none = SDP_Solver.Solve(SingleRequest(nil))
  NewWorld()
  local zero = SDP_Solver.Solve(SingleRequest(0))
  T.ok(none.Ok and zero.Ok, "solved")
  T.eq(#zero.Solutions, #none.Solutions, "as many solutions")
  for n, s in ipairs(none.Solutions) do
    T.same(zero.Solutions[n].Plan, s.Plan, "same plan, solution " .. n)
    T.eq(zero.Solutions[n].Gain, s.Gain, "same gain, solution " .. n)
  end
  T.eq(zero.Stats.Calls, none.Stats.Calls, "same DMT calls")
  T.eq(zero.Covered, nil, "no coverage figures when off")
  T.eq(zero.CoverageDelta, 0, "no coverage part")
  T.eq(Find(zero, IZ).Reach, nil, "no reach on the rows when off")
end)

test("single city: the coverage part moves the industrial zone towards the other city", function()
  NewWorld()
  local off = SDP_Solver.Solve(SingleRequest(nil))
  NewWorld()
  local on = SDP_Solver.Solve(SingleRequest(3))
  T.ok(off.Ok and on.Ok, "solved: " .. tostring(off.Error) .. " " .. tostring(on.Error))
  T.ok(not on.Stats.Mismatch, "board and full evaluation agree")
  T.near(on.Gain, on.Adjacency + on.LandDelta + on.CoverageDelta + on.CostDelta + (on.AppealDelta or 0), 1e-9,
    "the gain adds up")
  T.eq(on.CoverageDelta, 3 * on.Covered, "weight x newly covered cities")
  local model = SDP_Coverage.New({ PlayerID = 0, Weight = 3 })
  local offZone, onZone = Find(off, IZ), Find(on, IZ)
  local offCovered = #model:List(IZ, offZone.Index, offZone.X, offZone.Y, "C1")
  print(("single, without coverage: zone at %d,%d covers %d; weight 3: %d,%d covers %d, adjacency %+g -> %+g"):format(
    offZone.X, offZone.Y, offCovered, onZone.X, onZone.Y, on.Covered, off.Adjacency, on.Adjacency))
  T.ok(Map.GetPlotDistance(offZone.X, offZone.Y, 11, 5) > 6, "without coverage the zone does not reach city 2")
  T.ok(Map.GetPlotDistance(onZone.X, onZone.Y, 11, 5) <= 6, "with it, it does: " .. onZone.X .. "," .. onZone.Y)
  T.ok(on.Gain >= off.Adjacency + 3 * offCovered - 1e-9, "at least as good under its own objective")
  T.same(onZone.Reach, Within(model, onZone.X, onZone.Y, 6, { C1 = true }), "the row lists the newly covered cities")
  T.eq(Find(on, "DISTRICT_CAMPUS").Reach, nil, "a campus has no reach")
  T.eq(on.CoveredBy[1].Group, IZ, "by group")
  T.eq(#on.CoveredBy[1].Keys, on.Covered, "the newly covered cities")
  for _, s in ipairs(on.Solutions) do
    T.near(s.Gain, s.Adjacency + s.LandDelta + s.CoverageDelta + s.CostDelta + (s.AppealDelta or 0), 1e-9,
      "every solution adds up")
  end
  NewWorld()
  T.same(SDP_Solver.Solve(SingleRequest(3)).Plan, on.Plan, "deterministic")
end)

test("single city: city-center pins count, cities covered already do not, rows count only new ones", function()
  local w = NewWorld({ pins = { { 8, 9, "ICON_DISTRICT_CITY_CENTER", "A" } } })
  local site = "S" .. Map.GetPlotIndex(8, 9)
  local model = SDP_Coverage.New({ PlayerID = 0, Weight = 1, Sites = SDP_Coverage.SiteTargets(0) })
  local keys = {}
  for _, target in ipairs(model.Targets) do keys[#keys + 1] = target.Key end
  T.same(keys, { "C1", "C2", "C3", site }, "every city, then every city-center pin")
  local r = SDP_Solver.Solve(SingleRequest(3))
  T.ok(r.Ok, tostring(r.Error))
  local zone = Find(r, IZ)
  local listed = false
  for _, key in ipairs(zone.Reach) do
    if key == site then listed = true end
  end
  T.eq(listed, Map.GetPlotDistance(zone.X, zone.Y, 8, 9) <= 6, "the pin is a city to cover when in reach")
  -- City 2 builds an industrial zone: covered already, neither counted nor listed.
  w:AddDistrict(2, IZ, 12, 5, true)
  local r2 = SDP_Solver.Solve(SingleRequest(3))
  local zone2 = Find(r2, IZ)
  for _, key in ipairs(zone2.Reach) do T.ok(key ~= "C2", "city 2 is not listed on the row") end
  for _, key in ipairs(r2.CoveredBy[1] and r2.CoveredBy[1].Keys or {}) do T.ok(key ~= "C2", "nor counted") end
  local m2 = SDP_Coverage.New({ PlayerID = 0, Weight = 1, Sites = SDP_Coverage.SiteTargets(0) })
  local before = {}
  for _, key in ipairs(Within(m2, 12, 5, 6)) do before[key] = true end
  T.ok(before.C2, "the built zone covers city 2")
  T.same(m2:Reach(IZ, 7, 5), Within(m2, 7, 5, 6, before), "Reach: within range and not covered before")
end)

test("single city: picking from the pool counts coverage too", function()
  -- Count 1 from { campus, industrial zone }: the pick is the best under the
  -- whole objective, coverage included.
  local function Pick(coverage)
    NewWorld()
    return SDP_Solver.Solve(SingleRequest(coverage, { Districts = {}, Pool = { "DISTRICT_CAMPUS", IZ }, Count = 1 }))
  end
  local function Must(districtType, coverage)
    NewWorld()
    return SDP_Solver.Solve(SingleRequest(coverage, { Districts = { districtType } }))
  end
  local campus, zone, zoneOff = Must("DISTRICT_CAMPUS", 3), Must(IZ, 3), Must(IZ, nil)
  local picked, pickedOff = Pick(3), Pick(nil)
  T.ok(picked.Ok and pickedOff.Ok, "solved")
  T.ok(zone.Covered > 0, "an industrial zone covers a city")
  local best = math.max(campus.Gain, zone.Gain)
  T.near(picked.Gain, best, 1e-9, "the pick is the better of the two under the coverage objective")
  T.near(pickedOff.Gain, math.max(campus.Gain, zoneOff.Gain), 1e-9, "and without it, the better by adjacency")
  T.eq(picked.Picked[1], zone.Gain > campus.Gain and IZ or "DISTRICT_CAMPUS", "the one picked")
  print(("pick: campus %+g, industrial zone %+g (%+g with coverage 3): picked %s, without coverage %s"):format(
    campus.Gain, zoneOff.Gain, zone.Gain, picked.Picked[1], pickedOff.Picked[1]))
end)

-- Issue 91 (decided 2026-10-26): a district does not count the city it is
-- planned for; the other cities, participating ones too, count.
test("issue 91: the city being planned is not counted as covered by its own district", function()
  NewWorld()
  local model = SDP_Coverage.New({ PlayerID = 0, Weight = 1 })
  local at = Map.GetPlotIndex(5, 5)
  T.same(Keys(model, model:List(IZ, at, 5, 5)), Within(model, 5, 5, 6), "no owner: every city in reach")
  T.same(Keys(model, model:List(IZ, at, 5, 5, "C1")), Within(model, 5, 5, 6, { C1 = true }), "owner C1 left out")
  T.same(model:Reach(IZ, 5, 5, "C1"), Within(model, 5, 5, 6, { C1 = true }), "Reach leaves it out too")
  -- Single city: an industrial zone next to the capital with no other city
  -- in reach (city 2 is 7 away, city 3 6 away from the capital; the zone on
  -- the far side reaches neither): nothing covered, where the old count
  -- gave the capital 1.
  local r = SDP_Solver.Solve(SingleRequest(1))
  T.ok(r.Ok, tostring(r.Error))
  local zone = Find(r, IZ)
  for _, key in ipairs(zone.Reach) do T.ok(key ~= "C1", "the capital is not on its own zone's row") end
  for _, g in ipairs(r.CoveredBy or {}) do
    for _, key in ipairs(g.Keys) do T.ok(key ~= "C1", "nor counted") end
  end
  T.eq(r.Covered, #zone.Reach, "only the other cities count")
  -- Several cities: cities 1 and 2 each plan a zone. Neither counts its own
  -- city; each may count the other.
  NewWorld()
  local m = SDP_Multi.Solve(Request(1, { Existing = { [1] = true, [2] = true }, Plans = { C1 = { IZ }, C2 = { IZ } } }))
  T.ok(m.Ok, tostring(m.Error))
  for _, p in ipairs(m.Plan) do
    if p.Type == IZ then
      for _, key in ipairs(p.Reach or {}) do T.ok(key ~= p.City, p.City .. "'s zone does not list its own city") end
    end
  end
  local counted = 0
  for _, g in ipairs(m.CoveredBy or {}) do counted = counted + #g.Keys end
  T.eq(counted, m.Covered, "the summary counts what the rows list")
  local covered = {}
  for _, g in ipairs(m.CoveredBy or {}) do
    for _, key in ipairs(g.Keys) do covered[key] = true end
  end
  local z1, z2 = nil, nil
  for _, p in ipairs(m.Plan) do
    if p.Type == IZ and p.City == "C1" then z1 = p end
    if p.Type == IZ and p.City == "C2" then z2 = p end
  end
  T.eq(covered.C2 == true, Map.GetPlotDistance(z1.X, z1.Y, 11, 5) <= 6, "city 2 counts when city 1's zone reaches it")
  T.eq(covered.C1 == true, Map.GetPlotDistance(z2.X, z2.Y, 4, 5) <= 6, "city 1 counts when city 2's zone reaches it")
end)
