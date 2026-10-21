-- Offline: SDP_Coverage, the coverage part of the multi-city objective
-- (docs/multicity-design.md section 19).
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
  local offCovered = #model:List(IZ, offZone.Index, offZone.X, offZone.Y)
  print(("without coverage: zone at %d,%d covers %d; weight 3: %d,%d covers %d, adjacency %+g -> %+g"):format(
    offZone.X, offZone.Y, offCovered, onZone.X, onZone.Y, on.Covered, off.Adjacency, on.Adjacency))
  T.ok(on.Covered >= offCovered, "covers at least as much: " .. on.Covered .. " vs " .. offCovered)
  T.ok(on.Gain >= off.Adjacency + 3 * offCovered - 1e-9, "at least as good under its own objective")
  T.ok(Map.GetPlotDistance(onZone.X, onZone.Y, 11, 5) <= 6, "the zone reaches city 2: " .. onZone.X .. "," .. onZone.Y)
  T.same(onZone.Reach, Within(model, onZone.X, onZone.Y, 6), "the row lists the cities in reach")
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
  multi.SetExisting(1, true)
  multi.SetSelected(IZ, true)
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
