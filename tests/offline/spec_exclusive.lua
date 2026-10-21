-- Offline: districts one city cannot have together (SDP_Rules.Exclusive,
-- the game's MutuallyExclusiveDistricts: the entertainment complex and the
-- water park), and required districts that need the same plots (place what
-- fits). Both found in the late-game stress test, 2026-10-21: DMT let a plan
-- hold both districts, and a harbor and a water park with one coastal plot
-- between them gave no plan at all.
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

local EC, WEC = "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_WATER_ENTERTAINMENT_COMPLEX"
local HARBOR, CAMPUS, HOLY = "DISTRICT_HARBOR", "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE"
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- A coastal capital at (5, 2) with room for both districts.
local COAST = {
  "~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~",
  "~~~......~~~~~",
  "~~........~~~~",
  "~~........~~~~",
  "~~.........~~~",
  "~~.........~~~",
  "~~.........~~~",
  "~~~~~~~~~~~~~~",
}
-- Land with one coastal plot in reach of the capital at (3, 3): the harbor
-- and the water park can only go there.
local INLET = {
  "............",
  "............",
  "............",
  ".....~......",
  "............",
  "............",
  "............",
}

local function NewWorld(rows, extra)
  local x, y = 5, 2
  if rows == INLET then x, y = 3, 3 end
  local spec = { rows = rows, cities = { { id = 1, x = x, y = y, population = 13, capital = true } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local function Types(plan)
  local out = {}
  for _, p in ipairs(plan or {}) do out[p.Type] = true end
  return out
end

local function Reason(result, districtType)
  for _, u in ipairs(result.Unplaced or {}) do
    if u.Type == districtType then return u.Reason, u.Other end
  end
  return nil
end

test("the rule is read from the rules both ways", function()
  NewWorld(COAST)
  local ex = SDP_Rules.Exclusive()
  T.ok(ex[EC] and ex[EC][WEC], "complex excludes the water park")
  T.ok(ex[WEC] and ex[WEC][EC], "and back")
  T.eq(SDP_Rules.ExcludedBy(WEC, { [EC] = true, [CAMPUS] = true }), EC, "excluded by")
  T.eq(SDP_Rules.ExcludedBy(CAMPUS, { [EC] = true }), nil, "a campus is not")
end)

test("single city: both required, the first asked is placed and the second reported", function()
  NewWorld(COAST)
  for _, tier in ipairs({ "FAST", "STANDARD" }) do
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { EC, WEC, CAMPUS }, Weights = ONES, Tier = tier })
    T.ok(r.Ok, tostring(r.Error))
    local types = Types(r.Plan)
    T.ok(types[EC] and types[CAMPUS] and not types[WEC], tier .. ": complex and campus placed")
    local reason, other = Reason(r, WEC)
    T.eq(reason, "EXCLUSIVE", tier .. ": reason")
    T.eq(other, EC, tier .. ": names the complex")
  end
  local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { WEC, EC }, Weights = ONES })
  T.ok(Types(r.Plan)[WEC] and not Types(r.Plan)[EC], "the order decides")
end)

test("single city: picking from the pool never takes both; the count is capped by what can stand together", function()
  NewWorld(COAST)
  local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = {}, Pool = { EC, WEC, CAMPUS, HOLY }, Count = 2,
    Weights = ONES, Tier = "STANDARD" })
  T.ok(r.Ok and #r.Solutions > 0, tostring(r.Error))
  for n, s in ipairs(r.Solutions) do
    local types = Types(s.Plan)
    T.ok(not (types[EC] and types[WEC]), "solution " .. n .. " has not both")
  end
  local four = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = {}, Pool = { EC, WEC, CAMPUS, HOLY }, Count = 4,
    Weights = ONES, Tier = "STANDARD" })
  T.eq(#four.Plan, 3, "three of four can stand together")
  T.ok(not (Types(four.Plan)[EC] and Types(four.Plan)[WEC]), "not both")
  local must = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { EC }, Pool = { WEC, CAMPUS, HOLY }, Count = 3,
    Weights = ONES, Tier = "STANDARD" })
  T.ok(not Types(must.Plan)[WEC], "a required complex keeps the water park out of the picks")
  T.eq(#must.Plan, 3, "the other two picked")
end)

test("a built complex: the water park is marked, never planned", function()
  NewWorld(COAST, { districts = { { city = 1, type = EC, x = 5, y = 4, complete = true } } })
  local scan = SDP_City.Scan(0, 1)
  local status = SDP_City.DistrictStatus(scan, SDP_Rules.PlannableDistricts(0))
  T.eq(status[WEC], "EXCLUSIVE", "status")
  local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { WEC, CAMPUS }, Weights = ONES })
  T.ok(not Types(r.Plan)[WEC], "not planned")
  local reason, other = Reason(r, WEC)
  T.eq(reason, "EXCLUSIVE", "reason")
  T.eq(other, EC, "names the built complex")
end)

test("required districts that need the same plot: the plan places what fits and reports the rest", function()
  NewWorld(INLET)
  for _, tier in ipairs({ "FAST", "STANDARD", "FINE" }) do
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { HARBOR, WEC, CAMPUS }, Weights = ONES, Tier = tier })
    T.ok(r.Ok, tier .. ": " .. tostring(r.Error))
    local types = Types(r.Plan)
    T.eq(#r.Plan, 2, tier .. ": two placed")
    T.ok(types[CAMPUS], tier .. ": the campus")
    T.ok(types[HARBOR] ~= types[WEC], tier .. ": one of the harbor and the water park")
    local left = types[HARBOR] and WEC or HARBOR
    T.eq(Reason(r, left), "NO_FREE_PLOT", tier .. ": the other reported")
    T.eq(r.Gain, r.Adjacency + r.LandDelta + r.CostDelta + (r.AppealDelta or 0), tier .. ": gain adds up")
  end
  local a = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { HARBOR, WEC, CAMPUS }, Weights = ONES })
  local b = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { HARBOR, WEC, CAMPUS }, Weights = ONES })
  T.same(a.Plan, b.Plan, "deterministic")
end)

test("several cities: required both in one city reported; no city picks both from the pool", function()
  World.New({ rows = COAST, cities = { { id = 1, x = 5, y = 2, population = 13, capital = true } },
    pins = { { 9, 6, "ICON_DISTRICT_CITY_CENTER", "2" } } })
  local r = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Districts = { EC, WEC }, Weights = ONES,
    Existing = { [1] = true } })
  T.ok(r.Ok, tostring(r.Error))
  local byCity = {}
  for _, p in ipairs(r.Plan) do
    byCity[p.City] = byCity[p.City] or {}
    byCity[p.City][p.Type] = true
  end
  for city, types in pairs(byCity) do T.ok(not (types[EC] and types[WEC]), "city " .. tostring(city)) end
  local reported = 0
  for _, u in ipairs(r.Unplaced) do
    if u.Type == WEC and u.Reason == "EXCLUSIVE" then reported = reported + 1 end
  end
  T.ok(reported >= 1, "the water park reported")
  local pooled = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Districts = {}, Pool = { EC, WEC, CAMPUS }, Count = 2,
    Weights = ONES, Existing = { [1] = true } })
  T.ok(pooled.Ok, tostring(pooled.Error))
  byCity = {}
  for _, p in ipairs(pooled.Plan) do
    byCity[p.City] = byCity[p.City] or {}
    byCity[p.City][p.Type] = true
  end
  for city, types in pairs(byCity) do T.ok(not (types[EC] and types[WEC]), "pool, city " .. tostring(city)) end
end)
