-- Offline: the appeal part (SDP_Appeal; 2026-10-21 feedback). A
-- neighborhood is worth its housing, which depends on its plot's appeal; a
-- preserve its own housing and its grove and sanctuary yields on the
-- unimproved plots around it. Appeal changes with the plan: districts add
-- their Districts.Appeal to the plots around, building clears a feature and
-- its appeal. Checked against an independent brute force.
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

-- Bare grassland around a capital at (5, 3); appeal is set per plot below
-- (the game's current appeal; the plan's changes come on top).
local MAP = {
  "~~~~~~~~~~~~",
  "~..........~",
  "~..........~",
  "~...f......~",
  "~..........~",
  "~..........~",
  "~..........~",
  "~~~~~~~~~~~~",
}
local APPEAL = { { 8, 2, 4 }, { 7, 2, 3 }, { 3, 4, 2 }, { 2, 2, 1 }, { 6, 5, -4 }, { 4, 3, 1 }, { 3, 2, 3 } }

local function NewWorld(extra)
  local spec = { rows = MAP, appeal = APPEAL, cities = { { id = 1, x = 5, y = 3, population = 6, capital = true } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local HOOD, PRESERVE, IZ, HOLY = "DISTRICT_NEIGHBORHOOD", "DISTRICT_PRESERVE", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_HOLY_SITE"

local function Weights(extra)
  local w = {}
  for k, v in pairs(ONES) do w[k] = v end
  for k, v in pairs(extra or {}) do w[k] = v end
  return w
end

-- Independent reference: housing of every neighborhood or preserve in a
-- plan (weighted, summed), appeal = the plot's set appeal + each planned neighbour's district
-- appeal - the appeal of the feature a planned neighbour clears. (No
-- preserve tiles here; those have their own test.)
local function RefHousing(world, plan, weight)
  local appealOf = { [HOLY] = 1, [IZ] = -1, DISTRICT_THEATER = 1, DISTRICT_ENTERTAINMENT_COMPLEX = 1, [PRESERVE] = 1,
    DISTRICT_ENCAMPMENT = -1 }
  local at = {}
  for _, p in ipairs(plan) do at[p.X .. "," .. p.Y] = p.Type end
  local total = 0
  for _, p in ipairs(plan) do
    if p.Type == HOOD or p.Type == PRESERVE then
      local plot = world:Plot(p.X, p.Y)
      -- Cleared woods (positive appeal) stop counting for the plot itself;
      -- cleared rainforest or marsh do not (tests/bench/probe_ownplot.py).
      local appeal = plot:GetAppeal()
      if plot.feature ~= nil and plot.feature.Removable and (plot.feature.Appeal or 0) > 0 then
        appeal = appeal - plot.feature.Appeal
      end
      for dir = 0, 5 do
        local n = Map.GetAdjacentPlot(p.X, p.Y, dir)
        local t = n and at[n:GetX() .. "," .. n:GetY()]
        if t ~= nil then
          appeal = appeal + (appealOf[t] or 0)
          if n.feature ~= nil and n.feature.Removable then appeal = appeal - (n.feature.Appeal or 0) end
        end
      end
      local change = (appeal >= 4 and 2) or (appeal >= 2 and 1) or (appeal >= -1 and 0) or (appeal >= -3 and -1)
        or (p.Type == HOOD and -2 or -1)
      total = total + weight * ((p.Type == HOOD and 4 or 1) + change)
    end
  end
  return total
end

-- What housing `total` adds to the test city (issue 55): its housing now
-- (water, 2 here) plus the plan's, valued 1 each up to its target
-- population (6: its population; one specialty district needs 1), half
-- the one before after that.
local CITY_HOUSING, CITY_TARGET = 2, 6
local function HousingWorth(total, weight)
  if weight == 0 then return 0 end
  local function Value(n)
    if n <= CITY_TARGET then return n end
    local v, step = CITY_TARGET, 1
    for _ = CITY_TARGET + 1, math.floor(n) do
      step = step / 2
      v = v + step
    end
    return v
  end
  return weight * (Value(CITY_HOUSING + total) - Value(CITY_HOUSING))
end

-- Best value over every placement of `districts`: DMT adjacency (fake) plus
-- the reference housing.
local function BruteForce(world, districts, weights)
  local scan = SDP_City.Scan(0, 1)
  return SDP_Overlay.With(0, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local w = Weights(weights)
    local baseline = SDP_Overlay.Evaluate({}, fixed, w).Total
    local best = nil
    local used, layout = {}, {}
    local function Walk(m)
      if m > #districts then
        local subjects, plan = {}, {}
        for i, c in ipairs(layout) do
          subjects[i] = SDP_Overlay.Subject(districts[i], c.X, c.Y)
          plan[i] = { Type = districts[i], X = c.X, Y = c.Y }
        end
        local res = SDP_Overlay.Evaluate(subjects, fixed, w)
        if res.Legal then
          local value = res.Total - baseline + HousingWorth(RefHousing(world, plan, 1), w.HOUSING or 1)
          if best == nil or value > best then best = value end
        end
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

local function Entry(result, districtType)
  for _, p in ipairs(result.Plan) do
    if p.Type == districtType then return p end
  end
end

test("rules: housing by appeal from AppealHousingChanges, preserve yields from Adjacent_AppealYieldChanges", function()
  NewWorld()
  local rules = SDP_Appeal.Rules()
  local want = { [6] = 6, [4] = 6, [3] = 5, [2] = 5, [1] = 4, [-1] = 4, [-2] = 3, [-3] = 3, [-4] = 2, [-9] = 2 }
  for appeal, housing in pairs(want) do T.eq(SDP_Appeal.Housing(rules, HOOD, appeal), housing, "neighborhood at " .. appeal) end
  T.eq(SDP_Appeal.Housing(rules, PRESERVE, 4), 3, "preserve, breathtaking")
  T.eq(SDP_Appeal.Housing(rules, PRESERVE, -5), 0, "preserve, disgusting")
  T.eq(SDP_Appeal.Housing(rules, "DISTRICT_CAMPUS", 4), nil, "a campus has no housing rows")
  T.eq(#rules.Tiles[PRESERVE], 10, "ten tile rows")
  T.eq(rules.Appeal[IZ], -1, "district appeal")
  T.ok(SDP_Appeal.Counts(HOOD) and SDP_Appeal.Counts(PRESERVE) and not SDP_Appeal.Counts("DISTRICT_CAMPUS"), "counts")
end)

test("a neighborhood goes to the most appealing plot; its housing is in the gain and the plan", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { HOOD }, Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  local p = Entry(result, HOOD)
  T.eq(p.X .. "," .. p.Y, "8,2", "on the breathtaking plot")
  T.eq(p.Appeal, 4, "its appeal")
  T.eq(p.Housing, 6, "six housing")
  -- Housing 2 -> 8 against a target of 6: 4 + 0.5 + 0.25 (issue 55).
  T.eq(result.AppealDelta, 4.75, "the appeal part")
  T.eq(result.Gain, result.Adjacency + 4.75, "in the gain")
  local double = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { HOOD }, Weights = Weights({ HOUSING = 2 }) })
  T.eq(double.AppealDelta, 9.5, "weighted")
  local campus = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS" }, Weights = ONES })
  T.eq(campus.AppealDelta, nil, "no appeal part without such a district")
end)

test("districts change appeal: the plan matches a brute force over every layout", function()
  local world = NewWorld()
  for _, case in ipairs({
    { districts = { HOOD, IZ }, weights = { HOUSING = 2 } },
    { districts = { HOOD, HOLY }, weights = { HOUSING = 1 } },
    { districts = { HOOD, IZ }, weights = { HOUSING = 0 } },
    { districts = { HOOD, "DISTRICT_CAMPUS" }, weights = { HOUSING = 1 } },
  }) do
    local label = table.concat(case.districts, "+") .. " housing x" .. case.weights.HOUSING
    local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = case.districts, Weights = Weights(case.weights),
      Tier = "FINE" })
    T.ok(result.Ok, label .. ": " .. tostring(result.Error))
    T.ok(not result.Stats.Mismatch, label .. ": board and full evaluation agree")
    local plan = {}
    for i, p in ipairs(result.Plan) do plan[i] = { Type = p.Type, X = p.X, Y = p.Y } end
    T.ok(math.abs((result.AppealDelta or 0) - HousingWorth(RefHousing(world, plan, 1), case.weights.HOUSING)) < 1e-9,
      label .. ": housing as the reference counts it")
    local best = BruteForce(world, case.districts, case.weights)
    T.ok(math.abs(result.Gain - best) < 1e-9, string.format("%s: %.2f = brute force %.2f", label, result.Gain, best))
  end
end)

test("clearing woods lowers the appeal around; an industrial zone next door lowers it too", function()
  NewWorld()
  -- Woods at (4, 3), next to (3, 2)... use the model directly.
  local scan = SDP_City.Scan(0, 1)
  local positions = {}
  for i, c in ipairs(scan.Candidates) do positions[c.X .. "," .. c.Y] = i end
  local model = SDP_Appeal.New({ Types = { HOOD, "DISTRICT_CAMPUS", IZ }, Kinds = { "DISTRICT", "DISTRICT", "DISTRICT" },
    Candidates = scan.Candidates, Fixed = {}, Weights = {}, Lands = {}, Workable = {} })
  T.ok(model ~= nil, "a model")
  local function HoodAt(layout)
    local detail = {}
    model:Score(layout, detail)
    return detail[1]
  end
  -- (3, 3) touches the woods plot (4, 3); its set appeal is 0.
  local hood = positions["3,3"]
  T.ok(hood ~= nil and positions["4,3"] ~= nil, "plots")
  T.eq(HoodAt({ hood, 0, 0 }).Appeal, 0, "alone: the game's appeal")
  T.eq(HoodAt({ hood, positions["4,3"], 0 }).Appeal, -1, "a campus on the woods next door clears them: -1")
  T.eq(HoodAt({ hood, 0, positions["2,3"] }).Appeal, -1, "an industrial zone next door: -1")
  T.eq(HoodAt({ hood, positions["4,3"], positions["2,3"] }).Appeal, -2, "both")
  T.eq(HoodAt({ hood, positions["4,3"], positions["2,3"] }).Housing, 3, "housing follows")
  -- On the woods itself: they are cleared and stop counting for the plot too.
  T.eq(HoodAt({ positions["4,3"], 0, 0 }).Appeal, 1 - 1, "on the woods: the game's 1, minus the woods")
  local at = model:AppealsUnder({ positions["4,3"], 0, 0 }, { scan.Candidates[positions["4,3"]].Index,
    scan.Candidates[positions["3,3"]].Index })
  T.eq(at[scan.Candidates[positions["3,3"]].Index], -1, "and next to it: -1")
end)

test("building clears a feature only with its removal tech (Features.RemoveTech); water keeps its appeal", function()
  local rows = { "~~~~~~~~~~~~", "~..........~", "~..........~", "~...s......~", "~..........~", "~..........~", "~..........~",
    "~~~~~~~~~~~~" }
  local function HoodNextToCampusOnMarsh(techs)
    NewWorld({ rows = rows, techs = techs })
    local scan = SDP_City.Scan(0, 1)
    local positions = {}
    for i, c in ipairs(scan.Candidates) do positions[c.X .. "," .. c.Y] = i end
    local model = SDP_Appeal.New({ PlayerID = 0, Types = { HOOD, "DISTRICT_CAMPUS" }, Kinds = { "DISTRICT", "DISTRICT" },
      Candidates = scan.Candidates, Fixed = {}, Weights = {}, Lands = {}, Workable = {} })
    local detail = {}
    model:Score({ positions["3,3"], positions["4,3"] }, detail)
    -- A campus on the shore: the coast plot next to it keeps its appeal.
    local water = Map.GetPlotIndex(5, 0)
    local onWater = model:AppealsUnder({ 0, positions["5,1"] }, { water })[water]
    -- On the marsh itself: cleared, but a negative feature never counted for
    -- its own plot, so the plot keeps the game's appeal.
    local marsh = scan.Candidates[positions["4,3"]].Index
    local own = model:AppealsUnder({ positions["4,3"], 0 }, { marsh })[marsh]
    T.eq(own, Map.GetPlotByIndex(marsh):GetAppeal(), "a neighborhood on the marsh keeps the plot's appeal")
    return detail[1].Appeal, onWater
  end
  local without, water = HoodNextToCampusOnMarsh({ "TECH_BRONZE_WORKING" })
  T.eq(without, 0, "no Irrigation: the marsh stays under the campus")
  T.eq(water, 0, "a coast plot keeps its appeal")
  local with = HoodNextToCampusOnMarsh({ "TECH_BRONZE_WORKING", "TECH_IRRIGATION" })
  T.eq(with, 1, "with Irrigation the marsh goes: +1 around")
end)

test("a pinned neighborhood counts: the plan pays for lowering its appeal", function()
  local world = NewWorld({ pins = { { 3, 4, "ICON_DISTRICT_NEIGHBORHOOD", "1" } } })
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { IZ }, Weights = Weights({ HOUSING = 3 }),
    Tier = "FINE" })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  local p = Entry(result, IZ)
  T.ok(Map.GetPlotDistance(p.X, p.Y, 3, 4) > 1, "the industrial zone keeps off the pinned neighborhood (charming: 5 housing)")
  T.eq(result.AppealDelta or 0, 0, "nothing lost")
  -- Forced next to it (the only plots left), the loss shows.
  local scan = SDP_City.Scan(0, 1)
  local model = SDP_Appeal.New({ Types = { IZ }, Kinds = { "DISTRICT" }, Candidates = scan.Candidates,
    Fixed = SDP_Overlay.FixedSubjects(scan), Weights = { HOUSING = 3 }, Lands = {}, Workable = {} })
  local at = nil
  for i, c in ipairs(scan.Candidates) do
    if c.X == 3 and c.Y == 3 then at = i end
  end
  T.eq(model:Score({ at }) - model.Base, -3, "next to it: one housing less, weighted 3")
  T.ok(world ~= nil, "world")
end)

test("a preserve: its own housing and its yields on the unimproved plots around, by their appeal", function()
  NewWorld({ improvements = { { 8, 3, "IMPROVEMENT_MINE" } } })
  local scan = SDP_City.Scan(0, 1)
  local workable = {}
  for _, index in ipairs(SDP_Land.Workable(scan)) do workable[index] = true end
  local position = nil
  for i, c in ipairs(scan.Candidates) do
    if c.X == 8 and c.Y == 2 then position = i end
  end
  local model = SDP_Appeal.New({ Types = { PRESERVE }, Kinds = { "DISTRICT" }, Candidates = scan.Candidates, Fixed = {},
    Weights = {}, Lands = {}, Workable = workable })
  local detail = {}
  local value = model:Score({ position }, detail)
  local d = detail[1]
  T.eq(d.Appeal, 4, "its plot")
  T.eq(d.Housing, 3, "1 + 2 housing")
  -- Neighbours of (8, 2): (7, 2) appeal 3 + 1 = 4 breathtaking; the mine at
  -- (8, 3) gets nothing; the other workable ones 0 + 1 = 1: nothing.
  local want = { YIELD_FOOD = 2, YIELD_FAITH = 2, YIELD_CULTURE = 2, YIELD_GOLD = 2, YIELD_SCIENCE = 2, YIELD_PRODUCTION = 2 }
  T.same(d.Tiles, want, "breathtaking yields on (7, 2) only")
  T.eq(value, 3 + 12, "land part off: counted in full, weighted 1")
  local lazy = SDP_Appeal.New({ Types = { PRESERVE }, Kinds = { "DISTRICT" }, Candidates = scan.Candidates, Fixed = {},
    Weights = { YIELD_FOOD = 0, YIELD_FAITH = 0, YIELD_CULTURE = 0, YIELD_GOLD = 0, YIELD_SCIENCE = 0, YIELD_PRODUCTION = 0,
      HOUSING = 1 }, Lands = {}, Workable = workable })
  T.eq(lazy:Score({ position }), 3, "weights 0: housing only")
  -- Picked from the pool (an optional slot): housing counts, the grove and
  -- sanctuary yields are reported but not scored (the user's call, 2026-10-22).
  local picked = SDP_Appeal.New({ Types = { PRESERVE }, Kinds = { "DISTRICT" }, Candidates = scan.Candidates, Fixed = {},
    Weights = {}, Lands = {}, Workable = workable, Optional = { true } })
  local pd = {}
  T.eq(picked:Score({ position }, pd), 3, "pool pick: housing only")
  T.same(pd[1].Tiles, want, "the yields still reported")
  T.eq(pd[1].TilesCounted, false, "marked as not scored")
  T.eq(d.TilesCounted, true, "a required preserve's are scored")
end)

test("a preserve with the land part on: its yields raise plots in the land model", function()
  NewWorld()
  local land = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { PRESERVE }, Weights = ONES, Land = true })
  T.ok(land.Ok, tostring(land.Error))
  T.ok(not land.Stats.Mismatch, "board and full evaluation agree")
  local p = Entry(land, PRESERVE)
  T.ok(p.Housing ~= nil and p.Tiles ~= nil, "housing and tiles reported")
  local off = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { PRESERVE }, Weights = ONES })
  T.ok(off.AppealDelta >= land.AppealDelta - 1e-9, "counted in full (land off) is at least what the worked plots get")
  -- Ranking with boosts: a boosted plot beats unboosted ones of the same base.
  local model = SDP_Land.Model({ { Index = 1, Tile = 3, Once = 0 }, { Index = 2, Tile = 2, Once = 0 }, { Index = 3, Tile = 1, Once = 0 } }, 2)
  T.eq(SDP_Land.ScoreTaken(model, {}, 0, {}), 5, "best two: 3 + 2")
  T.eq(SDP_Land.ScoreTaken(model, {}, 0, {}, { [3] = 3 }), 7, "plot 3 raised to 4: 4 + 3")
  T.eq(SDP_Land.ScoreTaken(model, { 3 }, 1, {}, { [3] = 3 }), 5, "taken: no boost")
  T.eq(SDP_Land.ScoreTaken(model, {}, 0, {}, { [1] = 1, [2] = 1 }), 7, "two raised: 4 + 3")
end)

test("a preserve in the pool is picked for its value; deterministic", function()
  NewWorld()
  local request = { PlayerID = 0, CityID = 1, Districts = {}, Pool = { PRESERVE, "DISTRICT_ENCAMPMENT" }, Count = 1, Weights = ONES }
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.same(result.Picked, { PRESERVE }, "the preserve, not the encampment (no adjacency)")
  local again = SDP_Solver.Solve(request)
  T.eq(again.Gain, result.Gain, "same gain")
  T.eq(Entry(again, PRESERVE).Index, Entry(result, PRESERVE).Index, "same plot")
  -- Its gain counts its housing, not its plots' yields; the plan shows them.
  T.ok(Entry(result, PRESERVE).TilesCounted ~= true, "a pool preserve's yields are not scored")
  local must = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { PRESERVE }, Weights = ONES })
  T.ok(must.AppealDelta >= result.AppealDelta, "required, the yields come on top")
end)

test("several cities: housing counts per city, the gain parts add up", function()
  NewWorld({ pins = { { 9, 5, "ICON_DISTRICT_CITY_CENTER", "" } } })
  local result = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Districts = { HOOD, "DISTRICT_CAMPUS" }, Weights = ONES,
    Existing = { [1] = true }, Land = false })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  local hoods = 0
  for _, p in ipairs(result.Plan) do
    if p.Type == HOOD then
      hoods = hoods + 1
      T.ok(p.Housing ~= nil and p.Appeal ~= nil, "housing reported")
    end
  end
  T.eq(hoods, 2, "a neighborhood per city")
  T.ok(math.abs(result.Gain - (result.Adjacency + result.LandDelta + result.CoverageDelta + result.CostDelta
    + (result.AppealDelta or 0))) < 1e-9, "parts add up")
end)

test("districts over farms: the city loses housing by its rounded-down total, reported with the plan", function()
  -- Three farms: 1.5 housing, rounded down to 1 (measured in the game).
  NewWorld({ appeal = {}, improvements = { { 6, 3, "IMPROVEMENT_FARM" }, { 5, 4, "IMPROVEMENT_FARM" },
    { 6, 4, "IMPROVEMENT_FARM" } } })
  local function At(x, y) return Map.GetPlotIndex(x, y) end
  T.eq(SDP_Appeal.ImprovementHousing(0, { At(6, 3) }), 0, "one farm: 1.5 -> 1.0, still 1")
  T.eq(SDP_Appeal.ImprovementHousing(0, { At(6, 3), At(5, 4) }), -1, "two farms: 1.5 -> 0.5, 1 -> 0")
  T.eq(SDP_Appeal.ImprovementHousing(0, { At(8, 6) }), 0, "a bare plot")
  -- The solver reports it; it is not part of the gain.
  local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS", HOLY }, Weights = ONES })
  T.ok(r.Ok, tostring(r.Error))
  T.eq(r.Gain, r.Adjacency + r.LandDelta + r.CostDelta + (r.AppealDelta or 0), "gain adds up without it")
  local taken = {}
  for n, p in ipairs(r.Plan) do taken[n] = p.Index end
  local lost = SDP_Appeal.ImprovementHousing(0, taken)
  T.eq(r.ImprovementHousing, lost < 0 and lost or nil, "reported as the plan takes farms")
end)
