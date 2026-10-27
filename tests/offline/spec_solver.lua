-- Offline: SDP_Solver on the fake world against brute force.
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
include("SDP_Solver")

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

-- Best legal gain over every placement of the districts, with the fake DMT.
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

test("campus + holy site: exhaustive and optimal", function()
  NewWorld()
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES })
  T.ok(result.Ok, tostring(result.Error))
  T.eq(result.Stats.Method, "exhaustive", "method")
  T.eq(result.Gain, BruteForce(districts, ONES), "gain vs brute force")
end)

test("the shortlist path finds the same optimum", function()
  NewWorld()
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Params = { ExactLimit = 0 } })
  T.eq(result.Stats.Method, "shortlist", "method")
  T.eq(result.Gain, BruteForce(districts, ONES), "gain vs brute force")
end)

test("a bonus the adjacency table does not hold still counts in the bound (issue 36)", function()
  -- As Japan's districts: a trait replaces the campus's +1 science per two
  -- districts with +1 per district. Only DMT knows it, the table does not.
  NewWorld({ traitNeighbour = { DISTRICT_CAMPUS = { "YIELD_SCIENCE", 1, "District_Science" } } })
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }
  local best = BruteForce(districts, ONES)
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Params = { ExactLimit = 0 } })
  T.eq(result.Stats.Method, "shortlist", "method")
  T.eq(result.Gain, best, "gain vs brute force")
  T.ok(result.Quality.Bound ~= nil and result.Quality.Bound >= best - 1e-9,
    "bound " .. tostring(result.Quality.Bound) .. " >= best " .. tostring(best))
end)

-- Best gain over every placement including the land part.
local function BruteForceLand(districts, weights)
  local scan = SDP_City.Scan(0, 1)
  return SDP_Overlay.With(0, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local baseline = SDP_Overlay.Evaluate({}, fixed, weights).Total
    local specialty = #districts
    local land = SDP_Land.ForScan(scan, fixed, SDP_Land.PlotWeights(SDP_Land.Scale(weights)), math.max(scan.Population, SDP_Land.RequiredPopulation(specialty)))
    local best = nil
    for _, p in ipairs(scan.Candidates) do
      for _, q in ipairs(scan.Candidates) do
        if p.Index ~= q.Index then
          local res = SDP_Overlay.Evaluate({ SDP_Overlay.Subject(districts[1], p.X, p.Y), SDP_Overlay.Subject(districts[2], q.X, q.Y) },
            fixed, weights)
          local gain = res.Total - baseline + SDP_Land.Score(land, { [p.Index] = true, [q.Index] = true }) - land.Base
          if res.Legal and (best == nil or gain > best) then best = gain end
        end
      end
    end
    return best
  end)
end

test("with the land part: exhaustive equals brute force", function()
  NewWorld()
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }
  local weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1, YIELD_FOOD = 2, FEATURE = 2 }
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = weights, Land = true })
  T.eq(result.Stats.Method, "exhaustive", "method")
  T.ok(result.Quality.Exhaustive, "exhaustive quality flag")
  T.ok(not result.Quality.CanContinue, "nothing to continue")
  T.ok(result.LandDelta <= 0, "the land part is a loss")
  T.near(result.Gain, BruteForceLand(districts, weights), 1e-9, "gain vs brute force")
  T.near(result.Gain, result.Adjacency + result.LandDelta, 1e-9, "gain = adjacency + land")
  -- Plots weigh the same whatever the yield weights (issue 53): food and
  -- harvest weights, which the panel no longer has, change nothing.
  local plain = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Land = true,
    Weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 } })
  T.same(plain.Plan, result.Plan, "same plan without the food and harvest weights")
  T.near(plain.LandDelta, result.LandDelta, 1e-9, "same land part")
  -- The land weight scales the whole land part (issue 53).
  local heavy = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1, LAND = 2.5 }
  local scaled = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = heavy, Land = true })
  T.near(scaled.Gain, BruteForceLand(districts, heavy), 1e-9, "land weight 2.5: gain vs brute force")
  T.ok(scaled.LandDelta >= 2.5 * result.LandDelta - 1e-9 or scaled.Adjacency < result.Adjacency,
    "a heavier land part costs more, or moves the plan")
  T.eq(SDP_Land.PlotWeights(2.5).YIELD_GOLD, 2.5 / 4, "gold: 1/4 of the land weight")
  T.eq(SDP_Land.PlotWeights(2.5).FEATURE, 1, "one-time yields scale with the yields, not twice")
  local off = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = weights })
  T.eq(off.LandDelta, 0, "land part off")
  T.ok(off.Adjacency >= result.Adjacency, "without land losses adjacency can only be higher")
end)

local SIX = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX" }

test("every tier is deterministic", function()
  NewWorld()
  for _, tier in ipairs(SDP_Tiers.ORDER) do
    local request = { PlayerID = 0, CityID = 1, Districts = SIX, Tier = tier, Land = true }
    local first, second = SDP_Solver.Solve(request), SDP_Solver.Solve(request)
    T.ok(first.Ok, tostring(first.Error))
    T.ok(not first.Stats.Mismatch, tier .. ": incremental and full evaluation agree")
    T.same(second.Plan, first.Plan, tier .. " plan")
    T.same(second.Stats, first.Stats, tier .. " stats")
    T.eq(first.Stats.Tier, tier, "tier recorded")
  end
end)

test("continue never gets worse and is reproducible", function()
  NewWorld()
  local request = { PlayerID = 0, CityID = 1, Districts = SIX, Tier = "FAST", Land = true }
  local a = SDP_Solver.Solve(request)
  local b = SDP_Solver.Solve(request)
  T.ok(a.Quality.CanContinue, "can continue")
  local previous = a.Gain
  for n = 1, 3 do
    if not a.Quality.CanContinue then break end
    a = SDP_Solver.Continue(a)
    b = SDP_Solver.Continue(b)
    T.ok(a.Gain >= previous, "continue " .. n .. " is not worse")
    T.eq(a.Stats.Continues, n, "continue count")
    T.same(b.Plan, a.Plan, "same plan after " .. n .. " continues")
    T.ok(a.Quality.Converged ~= nil, "convergence known after a continue")
    previous = a.Gain
  end
end)

test("unavailable, duplicate and unplaceable districts are reported", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES,
    Districts = { "DISTRICT_CAMPUS", "DISTRICT_CAMPUS", "DISTRICT_ACROPOLIS", "DISTRICT_NOPE" } })
  T.eq(#result.Plan, 1, "plan size")
  T.eq(result.Plan[1].Type, "DISTRICT_CAMPUS", "placed")
  T.same(result.Unplaced, { { Type = "DISTRICT_ACROPOLIS", Reason = "NOT_AVAILABLE" }, { Type = "DISTRICT_NOPE", Reason = "NOT_AVAILABLE" } },
    "unplaced")
end)

test("feature removal off keeps woods, rainforest and marsh", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = SIX, AllowFeatureRemoval = false, Land = true })
  for _, p in ipairs(result.Plan) do
    local feature = Map.GetPlot(p.X, p.Y):GetFeatureType()
    T.ok(feature == -1 or not GameInfo.Features[feature].Removable, p.Type .. " clears a removable feature")
  end
end)

test("locked pins are never built over and count as neighbours", function()
  local w = NewWorld()
  w:AddPin(4, 4, "ICON_DISTRICT_GOVERNMENT", "plaza")
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = SIX, Land = true })
  local plaza = Map.GetPlotIndex(4, 4)
  local next = false
  for _, p in ipairs(result.Plan) do
    T.ok(p.Index ~= plaza, p.Type .. " on the pinned plot")
    if Map.GetPlotDistance(p.X, p.Y, 4, 4) == 1 then next = true end
  end
  T.ok(next, "the plan uses the plaza's bonus")
end)

test("issue 126: each district's parts add up to the plan's; tiles by leaving one district out", function()
  local w = NewWorld()
  w:AddPin(4, 4, "ICON_DISTRICT_COMMERCIAL_HUB", "hub")
  local request = { PlayerID = 0, CityID = 1, Weights = ONES, Land = true, Distance = 1,
    Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_INDUSTRIAL_ZONE" } }
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  for n, s in ipairs(result.Solutions) do World.CheckParts(T, s, "solution " .. n) end
  -- The pinned hub's gain from its new neighbours is no new district's.
  local gained = 0
  for _, n in ipairs(result.Neighbours) do gained = gained + n.After - n.Before end
  T.near(result.Rest.Adjacency, gained, 1e-9, "the existing districts' change")
  T.ok(gained > 0, "the hub gains from the plan")
  -- A district's tiles share: the land part with it left out, others in place.
  local search = result.Session.Search
  local layout = search.BestLayout
  for n, p in ipairs(result.Plan) do
    local m = nil
    for slot = 1, search.K do
      if layout[slot] ~= 0 and search.Candidates[layout[slot]].Index == p.Index then m = slot end
    end
    local without = SDP_Search.Copy(layout)
    without[m] = 0
    T.near(p.Parts.Land, result.LandDelta - search:LandDelta(without), 1e-9, p.Type .. ": tiles share")
    T.ok(p.Parts.Land <= 1e-9, p.Type .. ": a district only takes tiles")
    T.ok(p.Parts.Distance <= 0, p.Type .. ": distance only costs")
    T.eq(p.Parts.Adjacency, result.Plan[n].Score, "adjacency: DMT's weighted score")
  end
  -- One district: its shares are the whole parts.
  local one = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS" }, Weights = ONES, Land = true })
  World.CheckParts(T, one, "one district")
  T.near(one.Rest.Land, 0, 1e-9, "nothing left over")
  T.same(SDP_Solver.Solve(request).Rest, result.Rest, "deterministic")
end)

test("a Government Plaza pinned for another city counts toward the empire limit", function()
  local w = NewWorld()
  -- The plan for another city (outside this city's range) already has it.
  w:AddPin(10, 8, "ICON_DISTRICT_GOVERNMENT", "plaza elsewhere")
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES,
    Districts = { "DISTRICT_CAMPUS", "DISTRICT_GOVERNMENT" } })
  T.eq(#result.Plan, 1, "only the campus")
  T.same(result.Unplaced, { { Type = "DISTRICT_GOVERNMENT", Reason = "MAX_PER_PLAYER" } }, "unplaced")
end)

test("luxury and strategic resources block districts, bonus resources do not", function()
  -- The fake DMT refuses them itself; the scan must exclude them too, since
  -- the real DMT's CanPlacePin lets a district pin onto them.
  local w = NewWorld({ resources = { { 6, 5, "RESOURCE_WINE" }, { 4, 5, "RESOURCE_IRON" }, { 6, 3, "RESOURCE_WHEAT" } },
    techs = { "TECH_BRONZE_WORKING" } })
  local scan = SDP_City.Scan(0, 1)
  T.eq(scan.Excluded[Map.GetPlotIndex(6, 5)], "RESOURCE", "wine")
  T.eq(scan.Excluded[Map.GetPlotIndex(4, 5)], "RESOURCE", "iron")
  T.eq(scan.Excluded[Map.GetPlotIndex(6, 3)], nil, "wheat can be harvested")
end)

test("plots the game refuses are left out; districts the engine says nothing about are not", function()
  -- The engine only speaks for plots the city owns: give it all three rings.
  local OWNS_ALL = { { id = 1, x = 5, y = 4, population = 7, capital = true, radius = 3 } }
  NewWorld({ cities = OWNS_ALL })
  SDP_Overlay.ResetEngine()
  local first = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" } })
  local best = first.Plan[1]
  T.ok(best ~= nil, "a campus plan")
  -- The engine lists every plot in range but that one (as for a canal that
  -- would join no water: DMT allows it, the game does not).
  local allowed = {}
  for _, p in ipairs(SDP_City.PlotsInRange(5, 4, 3)) do
    if p.Index ~= best.Index then allowed[#allowed + 1] = p.X .. "," .. p.Y end
  end
  NewWorld({ cities = OWNS_ALL, engine = { DISTRICT_CAMPUS = allowed } })
  SDP_Overlay.ResetEngine()
  local second = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" } })
  T.ok(second.Plan[1] ~= nil and second.Plan[1].Index ~= best.Index, "the refused plot is not planned")
  local item = SDP_Overlay.With(0, SDP_Overlay.Evaluate, { SDP_Overlay.Subject("DISTRICT_CAMPUS", best.X, best.Y) }, {}, ONES).Placements[1]
  T.eq(item.CanPlace, false, "not placeable")
  T.eq(item.EngineRefused, true, "because of the engine")
  -- No list for the holy site: DMT alone decides, the plot stays open.
  local holy = SDP_Overlay.With(0, SDP_Overlay.Evaluate, { SDP_Overlay.Subject("DISTRICT_HOLY_SITE", best.X, best.Y) }, {}, ONES).Placements[1]
  T.eq(holy.EngineRefused, nil, "no engine list, no refusal")
  SDP_Overlay.ResetEngine()
end)

test("an unowned plot cut off from the city's territory is left out (issue 35)", function()
  -- Another player's territory all around ring 2: ring 3 cannot be reached.
  local w = NewWorld({ cities = {
    { id = 1, x = 5, y = 4, population = 7, capital = true, radius = 1 },
    { id = 9, x = 2, y = 8, owner = 1, radius = 0 },
  } })
  local open = SDP_City.Scan(0, 1)
  local ring3 = 0
  for _, c in ipairs(open.Candidates) do
    if c.Ring == 3 then ring3 = ring3 + 1 end
    T.eq(open.Excluded[c.Index], nil, "a candidate is not excluded")
    T.eq(c.Unowned, c.Ring > 1 or nil, "owned within the first ring only")
  end
  T.ok(ring3 > 0, "ring 3 reachable with open land around")
  local foreign = w:City(9, 1)
  for _, p in ipairs(SDP_City.PlotsInRange(5, 4, 3)) do
    if p.Ring == 2 then w:Own(p.X, p.Y, 1, foreign) end
  end
  local walled = SDP_City.Scan(0, 1)
  local unreachable = 0
  for _, c in ipairs(walled.Candidates) do T.ok(c.Ring <= 1, "only the owned ring stays: " .. c.X .. "," .. c.Y) end
  for _, p in ipairs(SDP_City.PlotsInRange(5, 4, 3)) do
    if p.Ring == 3 and open.Excluded[p.Index] == nil then
      T.eq(walled.Excluded[p.Index], "UNREACHABLE", "ring 3 behind the wall")
      unreachable = unreachable + 1
    end
  end
  T.eq(unreachable, ring3, "every former ring-3 candidate")
  T.ok(walled.Reach.Reached[Map.GetPlotIndex(5, 4)], "the center is reached")
end)

test("flooded coastal lowland is left out (issue 44)", function()
  NewWorld({ cities = { { id = 1, x = 5, y = 4, population = 7, capital = true, radius = 1 } } })
  local before = SDP_City.Scan(0, 1)
  local flooded, dry = before.Candidates[1], before.Candidates[2]
  -- Two lowland plots, one of them flooded; TerrainManager exists only in Gathering Storm.
  TerrainManager = { -- lint: allow global-assign
    GetCoastalLowlandType = function(plot)
      return (plot:GetIndex() == flooded.Index or plot:GetIndex() == dry.Index) and 0 or -1
    end,
    IsFlooded = function(plot) return plot:GetIndex() == flooded.Index end,
    IsSubmerged = function() return false end,
  }
  local ok, after = pcall(SDP_City.Scan, 0, 1)
  TerrainManager = nil -- lint: allow global-assign
  T.ok(ok, tostring(after))
  T.eq(after.Excluded[flooded.Index], "FLOODED", "the flooded plot")
  T.eq(after.Excluded[dry.Index], nil, "lowland that is not flooded stays")
  T.eq(#after.Candidates, #before.Candidates - 1, "one candidate fewer")
  local plan = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" } })
  T.ok(plan.Plan[1] ~= nil, "no TerrainManager: nothing is flooded")
end)

test("a plan says which plots the city must own first and which features need a technology", function()
  -- A city next to the marsh at (2,7); clearing marsh takes irrigation.
  local function Plan(techs)
    NewWorld({ cities = { { id = 1, x = 3, y = 6, population = 7, capital = true, radius = 1 } }, techs = techs })
    local scan = SDP_City.Scan(0, 1)
    local marsh = GameInfo.Features["FEATURE_MARSH"].Index
    local onMarsh = nil
    for _, c in ipairs(scan.Candidates) do
      if Map.GetPlotByIndex(c.Index):GetFeatureType() == marsh then onMarsh = c end
    end
    T.ok(onMarsh ~= nil, "a marsh candidate")
    return scan, onMarsh
  end
  local scan, onMarsh = Plan({})
  T.eq(onMarsh.RemoveTech, "TECH_IRRIGATION", "irrigation missing")
  for _, c in ipairs(scan.Candidates) do
    if c.Ring <= 1 then T.eq(c.Unowned, nil, "owned") else T.eq(c.Unowned, true, "not owned yet") end
  end
  local _, withTech = Plan({ "TECH_IRRIGATION" })
  T.eq(withTech.RemoveTech, nil, "irrigation known")
  -- The plan carries the same flags for the plot it picks.
  Plan({})
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" } })
  local p = result.Plan[1]
  T.ok(p ~= nil, "a campus plan")
  local c = nil
  for _, entry in ipairs(SDP_City.Scan(0, 1).Candidates) do
    if entry.Index == p.Index then c = entry end
  end
  T.eq(p.Unowned, c.Unowned, "Unowned as the scan says")
  T.eq(p.RemoveTech, c.RemoveTech, "RemoveTech as the scan says")
end)

test("a plot another of our cities owns is a candidate when it can be swapped (issue 54)", function()
  -- Capital at (2,4) and city 2 at (6,4), each owning its first ring; city 2
  -- also owns a plot two from its center that touches the capital's ring.
  local flat = {}
  for y = 1, 9 do flat[y] = "~..........~" end
  flat[1], flat[9] = "~~~~~~~~~~~~", "~~~~~~~~~~~~"
  local w = World.New({ rows = flat, cities = { { id = 1, x = 2, y = 4, population = 7, capital = true, radius = 1 },
    { id = 2, x = 6, y = 4, population = 4, radius = 1 } } })
  local swap = nil
  for _, p in ipairs(SDP_City.PlotsInRange(2, 4, 2)) do
    local plot = Map.GetPlotByIndex(p.Index)
    if swap == nil and plot:GetOwner() == -1 and Map.GetPlotDistance(6, 4, plot:GetX(), plot:GetY()) == 2 then swap = plot end
  end
  T.ok(swap ~= nil, "a plot two from each center")
  w:Own(swap:GetX(), swap:GetY(), 0, w:City(2))
  local ring = Map.GetPlotIndex(5, 4) -- next to city 2's center, three from the capital
  -- Off by default (the player's switch): the plot stays city 2's.
  T.eq(SDP_City.Scan(0, 1).Excluded[swap:GetIndex()], "OTHER_CITY", "not swapped unless asked")
  local scan = SDP_City.Scan(0, 1, { allowSwap = true })
  local found = nil
  for _, c in ipairs(scan.Candidates) do
    if c.Index == swap:GetIndex() then found = c end
  end
  T.ok(found ~= nil, "the swappable plot is a candidate")
  T.eq(found.Swap, 2, "swapped from city 2")
  T.eq(found.Unowned, nil, "not a plot to buy")
  T.eq(scan.Excluded[ring], "OTHER_CITY", "next to the other city's center: not swappable")
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" }, Land = true,
    Swap = true })
  T.ok(result.Ok, tostring(result.Error))
  for _, p in ipairs(result.Plan) do
    T.eq(p.Swap, p.Index == swap:GetIndex() and 2 or nil, "swap note at " .. p.X .. "," .. p.Y)
  end
end)

test("unowned plots another city is nearer to are that city's to work (issue 54)", function()
  local flat = {}
  for y = 1, 9 do flat[y] = "~..........~" end
  flat[1], flat[9] = "~~~~~~~~~~~~", "~~~~~~~~~~~~"
  World.New({ rows = flat, cities = { { id = 1, x = 2, y = 4, population = 7, capital = true, radius = 1 },
    { id = 2, x = 7, y = 4, population = 4, radius = 1 } } })
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" }, Land = true })
  T.ok(result.Ok, tostring(result.Error))
  -- The solver's land model leaves out the unowned plots nearer city 2.
  local land = SDP_Overlay.With(0, function()
    return SDP_Solver.NewSession({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CAMPUS" }, Land = true },
      SDP_City.Scan(0, 1)).Land
  end)
  local nearer, kept = 0, 0
  for _, p in ipairs(SDP_City.PlotsInRange(2, 4, 3)) do
    local plot = Map.GetPlotByIndex(p.Index)
    if plot:GetOwner() == -1 and not plot:IsWater() then
      local d1, d2 = Map.GetPlotDistance(2, 4, plot:GetX(), plot:GetY()), Map.GetPlotDistance(7, 4, plot:GetX(), plot:GetY())
      if d2 < d1 then
        nearer = nearer + 1
        T.ok(land.ByIndex[p.Index] == nil, "nearer city 2: " .. plot:GetX() .. "," .. plot:GetY())
      elseif land.ByIndex[p.Index] ~= nil then
        kept = kept + 1
      end
    end
  end
  T.ok(nearer > 0 and kept > 0, "both kinds present")
end)
