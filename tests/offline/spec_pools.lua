-- Offline: candidate pools (the solver picks districts), the distance cost,
-- districts a city gets by itself (aqueduct, dam), reminder pins for woods
-- and rainforest, sites scored with their best districts, and city-center
-- pins switched off in the multi-city tab.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Search")
include("SDP_Remind")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")
include("SDP_Pins")
include("SDP_Sites")
include("SDP_SiteSolver")

local MAP = {
  "~~~~~~~~~~~~",
  "~..f.M..h..~",
  "~.fMj..p.d.~",
  "~h..f.j..M.~",
  "~.pM...f.h.~",
  "~..j.p..q..~",
  "~f..h.M.j..~",
  "~.s..f..p.~~",
  "~..p...h...~",
  "~~~~~~~~~~~~",
}

local function NewWorld(extra)
  local spec = { rows = MAP, rivers = { "6,4", "7,4", "7,5", "6,6" }, cities = { { id = 1, x = 5, y = 4, population = 7, capital = true } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local POOL = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }

-- Best legal gain over every placement of `districts`, with the fake DMT.
local function BruteForce(districts, weights)
  local scan = SDP_City.Scan(0, 1)
  return SDP_Overlay.With(0, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local baseline = SDP_Overlay.Evaluate({}, fixed, weights).Total
    local best = nil
    local used, layout = {}, {}
    local function Walk(m)
      if m > #districts then
        local subjects = {}
        for i, c in ipairs(layout) do subjects[i] = SDP_Overlay.Subject(districts[i], c.X, c.Y) end
        local res = SDP_Overlay.Evaluate(subjects, fixed, weights)
        if res.Legal and (best == nil or res.Total - baseline > best) then best = res.Total - baseline end
        return
      end
      for _, c in ipairs(scan.Candidates) do
        if not used[c.Index] then
          used[c.Index], layout[m] = true, c
          Walk(m + 1)
          used[c.Index], layout[m] = nil, nil
        end
      end
    end
    Walk(1)
    return best
  end)
end

local function Set(list)
  local set = {}
  for _, v in ipairs(list or {}) do set[v] = true end
  return set
end

local function Same(a, b)
  if #a.Plan ~= #b.Plan or a.Gain ~= b.Gain then return false end
  for i, p in ipairs(a.Plan) do
    if p.Type ~= b.Plan[i].Type or p.Index ~= b.Plan[i].Index then return false end
  end
  return true
end

-- ===========================================================================
-- Single city
-- ===========================================================================
test("a count no higher than the required districts picks nothing: the plan is as before", function()
  NewWorld()
  local plain = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }, Weights = ONES })
  local pooled = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" },
    Pool = POOL, Count = 2, Weights = ONES })
  T.ok(plain.Ok and pooled.Ok, "solved")
  T.ok(Same(plain, pooled), "same plan and gain")
  T.ok(pooled.Stats.Method ~= "pools", "no picking: " .. tostring(pooled.Stats.Method))
end)

test("picking two of four: the best combination, as brute force over every pair finds it", function()
  NewWorld()
  local best, bestPair = nil, nil
  for a = 1, #POOL do
    for b = a + 1, #POOL do
      local gain = BruteForce({ POOL[a], POOL[b] }, ONES)
      if gain ~= nil and (best == nil or gain > best) then best, bestPair = gain, POOL[a] .. "+" .. POOL[b] end
    end
  end
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = {}, Pool = POOL, Count = 2, Weights = ONES, Tier = "FINE" })
  T.ok(result.Ok, tostring(result.Error))
  T.eq(result.Stats.Method, "pools", "picked")
  T.eq(#result.Plan, 2, "two districts")
  T.eq(result.Gain, best, "gain vs the best pair " .. bestPair)
  T.eq(#result.Picked, 2, "both picked")
end)

test("three solutions: other combinations first, best first; solution 1 is the plan", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS" }, Pool = POOL, Count = 3,
    Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  T.eq(#result.Solutions, 3, "three solutions")
  local keys = {}
  for n, s in ipairs(result.Solutions) do
    T.eq(#s.Plan, 3, "three districts in solution " .. n)
    local types = {}
    for _, p in ipairs(s.Plan) do types[#types + 1] = p.Type end
    table.sort(types)
    T.ok(Set(types).DISTRICT_CAMPUS, "the required campus in solution " .. n)
    keys[n] = table.concat(types, ",")
    if n > 1 then T.ok(s.Gain <= result.Solutions[n - 1].Gain, "best first") end
  end
  T.ok(keys[1] ~= keys[2] and keys[2] ~= keys[3] and keys[1] ~= keys[3], "different combinations")
  T.ok(Same(result, result.Solutions[1]), "solution 1 at the top level")
  T.eq(#result.Picked, 2, "two picked")
end)

test("without a pool, the other solutions put districts elsewhere", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" },
    Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(#result.Solutions >= 2, "alternatives: " .. #result.Solutions)
  for n = 2, #result.Solutions do
    local diff = 0
    for i, p in ipairs(result.Solutions[n].Plan) do
      if p.Index ~= result.Plan[i].Index then diff = diff + 1 end
    end
    T.ok(diff >= 2, "solution " .. n .. " moves at least two districts")
  end
end)

test("picking is deterministic, and continue never gets worse", function()
  NewWorld()
  local request = { PlayerID = 0, CityID = 1, Districts = {}, Pool = POOL, Count = 3, Weights = ONES, Tier = "FAST" }
  local a = SDP_Solver.Solve(request)
  local b = SDP_Solver.Solve(request)
  T.ok(Same(a, b), "same result twice")
  local before = a.Gain
  local c = SDP_Solver.Continue(a)
  T.ok(c.Ok and c.Gain >= before, "continue: " .. tostring(c.Gain) .. " >= " .. before)
end)

-- ===========================================================================
-- Distance cost
-- ===========================================================================
local function Rings(result)
  local total = 0
  for _, p in ipairs(result.Plan) do total = total + Map.GetPlotDistance(5, 4, p.X, p.Y) end
  return total
end

test("distance cost: weight 0 changes nothing; a high weight pulls districts in and is taken off the gain", function()
  NewWorld()
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" }
  local plain = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES })
  local zero = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Distance = 0 })
  T.ok(Same(plain, zero), "weight 0: same plan")
  T.eq(zero.CostDelta, 0, "no cost")
  local far = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Distance = 3 })
  T.ok(far.Ok, tostring(far.Error))
  T.ok(Rings(far) <= Rings(plain), "closer: " .. Rings(far) .. " <= " .. Rings(plain))
  local expected = 0
  for _, p in ipairs(far.Plan) do expected = expected - 3 * (Map.GetPlotDistance(5, 4, p.X, p.Y) - 1) end
  T.eq(far.CostDelta, expected, "cost = weight x (rings - 1)")
  T.eq(far.Gain, far.Adjacency + far.LandDelta + far.CostDelta + (far.AppealDelta or 0), "gain adds up")
end)

-- ===========================================================================
-- Districts a city gets by itself
-- ===========================================================================
local FLOOD_MAP = {
  "~~~~~~~~~~~~",
  "~..........~",
  "~...FFF....~",
  "~..FF.M....~",
  "~...F......~",
  "~..........~",
  "~~~~~~~~~~~~",
}

test("auto districts: an aqueduct only without fresh water, a dam only on enough floodplains", function()
  -- No river, lake or oasis at the capital: it lacks fresh water; a mountain
  -- next to the center makes an aqueduct possible.
  World.New({ rows = FLOOD_MAP, rivers = { "4,2", "5,2", "6,2", "3,3", "4,3", "4,4" },
    cities = { { id = 1, x = 5, y = 3, population = 7, capital = true } } })
  local scan = SDP_City.Scan(0, 1)
  T.ok(SDP_City.LacksFreshWater(scan), "no fresh water")
  T.eq(SDP_Rules.AutoKind("DISTRICT_AQUEDUCT"), "WATER", "aqueduct kind from the data")
  T.eq(SDP_Rules.AutoKind("DISTRICT_DAM"), "FLOOD", "dam kind from the data")
  T.eq(SDP_Rules.AutoKind("DISTRICT_CAMPUS"), nil, "campus is not automatic")
  T.ok(SDP_City.NeedsAuto(scan, "DISTRICT_DAM"), "enough floodplains")
  local auto = { DISTRICT_AQUEDUCT = true, DISTRICT_DAM = true }
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_INDUSTRIAL_ZONE" }, Auto = auto, Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  local got = {}
  for _, p in ipairs(result.Plan) do got[p.Type] = p end
  T.ok(got.DISTRICT_AQUEDUCT and got.DISTRICT_AQUEDUCT.Auto, "aqueduct added and marked")
  T.ok(got.DISTRICT_DAM and got.DISTRICT_DAM.Auto, "dam added and marked")
  T.ok(not got.DISTRICT_INDUSTRIAL_ZONE.Auto, "the asked district is not automatic")
  local without = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_INDUSTRIAL_ZONE" }, Weights = ONES })
  T.eq(#without.Plan, 1, "without Auto nothing is added")

  -- A river at the center: fresh water, no aqueduct.
  World.New({ rows = FLOOD_MAP, rivers = { "5,3", "4,2", "5,2" },
    cities = { { id = 1, x = 5, y = 3, population = 7, capital = true } } })
  local fresh = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_INDUSTRIAL_ZONE" }, Auto = auto, Weights = ONES })
  for _, p in ipairs(fresh.Plan) do T.ok(p.Type ~= "DISTRICT_AQUEDUCT", "no aqueduct with fresh water") end

  -- Two floodplains only: no dam.
  World.New({ rows = { "~~~~~~~~~~~~", "~..........~", "~...FF.....~", "~.....M....~", "~..........~", "~..........~", "~~~~~~~~~~~~" },
    rivers = { "4,2", "5,2" }, cities = { { id = 1, x = 5, y = 3, population = 7, capital = true } } })
  T.ok(not SDP_City.NeedsAuto(SDP_City.Scan(0, 1), "DISTRICT_DAM"), "two floodplains are not enough")
end)

-- ===========================================================================
-- Reminders
-- ===========================================================================
test("reminders: woods and rainforest whose clearing costs a planned district adjacency", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_HOLY_SITE", "DISTRICT_CAMPUS" },
    Weights = ONES, Remind = true })
  T.ok(result.Ok, tostring(result.Error))
  -- The fake rules: holy site +1 faith per two woods, campus +1 science per
  -- two rainforest. Clearing one costs 1 exactly when the count is even.
  local planned = {}
  for _, p in ipairs(result.Plan) do planned[p.Index] = true end
  local expected = {}
  for _, p in ipairs(result.Plan) do
    local feature = p.Type == "DISTRICT_HOLY_SITE" and "FEATURE_FOREST" or "FEATURE_JUNGLE"
    local plots = {}
    for dir = 0, 5 do
      local n = Map.GetAdjacentPlot(p.X, p.Y, dir)
      if n ~= nil and not planned[n:GetIndex()] and n:GetFeatureType() ~= -1
          and GameInfo.Features[n:GetFeatureType()].FeatureType == feature then
        plots[#plots + 1] = n:GetIndex()
      end
    end
    if #plots >= 2 and #plots % 2 == 0 then
      for _, index in ipairs(plots) do expected[index] = p.Type end
    end
  end
  local found = {}
  for _, r in ipairs(result.Remind) do
    found[r.Index] = true
    T.ok(expected[r.Index] ~= nil, "reminder at an expected plot " .. r.Index)
    T.eq(r.Losses[1].Type, expected[r.Index], "loss of the right district")
  end
  for index in pairs(expected) do T.ok(found[index], "expected reminder at " .. index) end
  -- A reminder pin is this mod's pin of the city (replace takes it along).
  local first = result.Remind[1]
  if first ~= nil then
    SDP_Pins.Reset()
    T.eq(SDP_Pins.Place(0, { { Icon = SDP_Pins.REMIND_ICON, X = first.X, Y = first.Y, Name = "1 keep, woods" } }), 1, "placed")
    local own = SDP_Pins.Own(0, { 1 })
    T.eq(#own, 1, "ours for city 1")
    T.eq(own[1].Name, "1 keep  woods", "no separator in the name")
    SDP_Pins.UndoLast(0)
  end
end)

test("reminders only for removable features next to districts, none for a plan without them", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_COMMERCIAL_HUB" }, Weights = ONES, Remind = true })
  T.eq(#result.Remind, 0, "the commercial hub takes nothing from features")
end)

-- ===========================================================================
-- Sites scored with their best districts
-- ===========================================================================
test("sites: with more districts ticked than PlanCount each site picks its best; at most PlanCount, as before", function()
  local w = World.New({
    rows = {
      "~~~~~~~~~~~~~~~~~~~~",
      "~..f.M..h...f..M...~",
      "~.fMj..p.d...fMj...~",
      "~h..f.j..M.h..f.j..~",
      "~.pM...f.h..pM...f.~",
      "~..j.p..q....j.p...~",
      "~f..h.M.j..f..h.M..~",
      "~.s..f..p...s..f...~",
      "~..p...h...p...h...~",
      "~~~~~~~~~~~~~~~~~~~~",
    },
    rivers = { "6,4", "7,4" }, cities = { { id = 1, x = 4, y = 4, population = 4, capital = true, radius = 1 } },
  })
  local _ = w
  local two = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }
  local a = SDP_SiteSolver.Solve({ PlayerID = 0, K = 1, D = 5, Districts = two, Tier = "FAST" })
  local b = SDP_SiteSolver.Solve({ PlayerID = 0, K = 1, D = 5, Districts = two, PlanCount = 3, Tier = "FAST" })
  T.ok(a.Ok and b.Ok, "solved")
  T.eq(a.Solutions[1].Value, b.Solutions[1].Value, "two ticked, count 3: the same scores")
  local four = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" }
  local c = SDP_SiteSolver.Solve({ PlayerID = 0, K = 1, D = 5, Districts = four, PlanCount = 2, Tier = "FAST" })
  T.ok(c.Ok, tostring(c.Error))
  for _, site in ipairs(c.Solutions[1].Sites) do
    T.ok(#(site.Districts or {}) <= 2, "at most two districts per site")
  end
end)

-- ===========================================================================
-- Several cities
-- ===========================================================================
local MULTI_MAP = {
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
  "~~~~~~~~~~~~~~~~~~~~~~",
}

local function MultiWorld()
  return World.New({
    rows = MULTI_MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
    cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
    pins = { { 9, 6, "ICON_DISTRICT_CITY_CENTER", "A" }, { 15, 8, "ICON_DISTRICT_CITY_CENTER", "B" } },
  })
end

test("multi: each city places its required districts and picks the rest from its pool", function()
  MultiWorld()
  local request = { PlayerID = 0, Tier = "FAST", Districts = { "DISTRICT_CAMPUS" }, Pool = POOL, Count = 3, Weights = ONES,
    Plans = { C1 = { "DISTRICT_HOLY_SITE" } }, Counts = { C1 = 2 } }
  local result = SDP_Multi.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  for _, city in ipairs(result.Cities) do
    local count, types = 0, {}
    for _, p in ipairs(result.Plan) do
      if p.City == city.Key then
        count = count + 1
        types[p.Type] = true
      end
    end
    local want = city.Key == "C1" and 2 or 3
    T.eq(count, want, city.Key .. " districts")
    T.ok(types[city.Key == "C1" and "DISTRICT_HOLY_SITE" or "DISTRICT_CAMPUS"], city.Key .. " keeps its required district")
    T.eq(#city.Picked, want - 1, city.Key .. " picked")
  end
  local again = SDP_Multi.Solve(request)
  T.eq(again.Gain, result.Gain, "deterministic")
  -- Distinct solutions: other combinations or other plots.
  for n = 2, #result.Solutions do T.ok(result.Solutions[n].Gain <= result.Solutions[n - 1].Gain, "best first") end
end)

test("multi: a city-center pin switched off takes no part but stays a pin", function()
  MultiWorld()
  local parts, _, sites = SDP_Multi.Participants(0)
  T.eq(#sites, 2, "two pins listed")
  local off = sites[1].Key
  local fewer, existing, listed = SDP_Multi.Participants(0, { Sites = { [off] = false } })
  -- The capital (4,5) is within 7 plots of the first pin only: it drops out too.
  T.eq(#parts, 3, "two pins and the capital")
  T.eq(#fewer, 1, "the other pin alone")
  for _, part in ipairs(fewer) do T.ok(part.Key ~= off, "the switched-off pin is not planned") end
  T.ok(not listed[1].Included and listed[2].Included, "listed with its switch")
  local _ = existing
  local result = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" },
    Weights = ONES, Sites = { [off] = false } })
  T.ok(result.Ok, tostring(result.Error))
  for _, p in ipairs(result.Plan) do T.ok(p.City ~= off, "no district for the switched-off pin") end
end)

test("multi: distance cost and automatic districts add up in the gain", function()
  MultiWorld()
  local result = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Districts = { "DISTRICT_CAMPUS", "DISTRICT_INDUSTRIAL_ZONE" },
    Weights = ONES, Distance = 1, Auto = { DISTRICT_AQUEDUCT = true }, Remind = true })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(result.CostDelta <= 0, "a cost")
  T.eq(result.Gain, result.Adjacency + result.LandDelta + result.CoverageDelta + result.CostDelta
    + (result.AppealDelta or 0), "gain adds up")
  T.ok(type(result.Remind) == "table", "reminders listed")
end)
