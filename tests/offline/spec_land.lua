-- Offline: SDP_Land, the land part of the objective.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Land")
include("SDP_Appeal")

test("a taken plot costs its value minus the (P+1)-th best", function()
  local plots = {
    { Index = 10, Tile = 5, Once = 0 }, { Index = 11, Tile = 4, Once = 0 }, { Index = 12, Tile = 3, Once = 1 },
    { Index = 13, Tile = 2, Once = 0 }, { Index = 14, Tile = 1, Once = 0 },
  }
  local model = SDP_Land.Model(plots, 2)
  T.eq(model.P, 2, "P")
  T.eq(model.Base, 5 + 4, "base: the best two")
  T.eq(model.OnceTotal, 1, "one-time values, kept whatever is built (issue 52)")
  T.eq(model.Loss[10], 5 - 3, "best plot")
  T.eq(model.Loss[11], 4 - 3, "second plot")
  T.eq(model.Loss[12], 0, "an unworked plot is free: its one-time value is taken before building")
  T.eq(model.Loss[14], 0, "an unworked plot without one-time value is free")
  for index, loss in pairs(model.Loss) do
    T.eq(model.Base - SDP_Land.Score(model, { [index] = true }), loss, "loss of plot " .. index)
  end
  -- Two of the best taken: the next two are worked.
  T.eq(SDP_Land.Score(model, { [10] = true, [11] = true }), 3 + 2, "both best taken: plots 12 and 13 are worked")
end)

test("P is capped by the plots there are; ties go by plot index", function()
  local model = SDP_Land.Model({ { Index = 7, Tile = 2, Once = 0 }, { Index = 3, Tile = 2, Once = 0 } }, 5)
  T.eq(model.P, 2, "P")
  T.eq(model.Plots[1].Index, 3, "tie order")
  T.eq(model.Loss[3], 2, "nothing left to work instead")
end)

test("required population inverts the specialty slot formula", function()
  for specialty = 1, 6 do
    local pop = SDP_Land.RequiredPopulation(specialty)
    T.eq(SDP_City.SpecialtyCapacity(pop), specialty, "slots at the required population")
    if pop > 1 then T.eq(SDP_City.SpecialtyCapacity(pop - 1), specialty - 1, "one less population") end
  end
end)

test("plot values: one-time yields count against keeping a feature or resource, not against building", function()
  local w = World.New({
    rows = { ".fjsMd" },
    resources = { { 0, 0, "RESOURCE_WHEAT" }, { 5, 0, "RESOURCE_COPPER" } },
  })
  local ctx = SDP_Land.Context(0, {}, true)
  T.eq(ctx.Growth, 1, "no technologies or civics yet: one-time yields as listed")
  local function Values(x) return SDP_Land.PlotValues(w:Plot(x, 0), ctx) end
  -- No improvement rules in this world: a plot is worth its yields, or its
  -- yields without what it would remove plus nothing, whichever is more.
  local tile, once = Values(0) -- grassland wheat 3 food; harvested: 2 food, +1 a turn from 20 food
  T.eq(tile, 2, "grassland wheat: harvest it (2) rather than keep it (3 - 1)")
  T.eq(once, 1, "wheat harvest")
  tile, once = Values(1) -- woods: 2 food 1 production; cleared: 2 food, 20 production
  T.eq(tile, 2, "woods: 3 - 1 kept, 2 cleared")
  T.eq(once, 1, "woods clearing")
  tile, once = Values(2) -- rainforest on plains: 2 food 1 production; cleared: 1 food 1 production
  T.eq(tile, 2, "rainforest: 3 - 1 kept, 2 cleared")
  tile, once = Values(4)
  T.eq(tile, 0, "mountain")
  T.eq(once, 0, "mountain one-time")
  tile, once = Values(5) -- desert copper: 2 gold, harvest 40 gold
  T.eq(tile, 0, "desert copper: harvested 0, kept 2 - 2")
  T.eq(once, 2, "copper harvest")
  local heavy = SDP_Land.Context(0, { YIELD_PRODUCTION = 3, FEATURE = 2 }, true)
  tile, once = SDP_Land.PlotValues(w:Plot(1, 0), heavy)
  T.eq(once, 20 * 3 * 2 / 20, "weighted clearing")
  T.eq(tile, 2, "kept 5 - 6, cleared 2")
  local off = SDP_Land.Context(0, { FEATURE = 0 }, true)
  tile, once = SDP_Land.PlotValues(w:Plot(1, 0), off)
  T.eq(once, 0, "feature weight 0")
  T.eq(tile, 3, "nothing forgone by keeping")
  local keep = SDP_Land.Context(0, {}, false)
  tile, once = SDP_Land.PlotValues(w:Plot(1, 0), keep)
  T.eq(tile, 3, "feature removal off: woods are kept")
  T.eq(once, 0, "and never cleared")
end)

test("plot values: the best improvement the rules allow (issue 52)", function()
  local w = World.New({
    rows = { ".fhqfp" },
    resources = { { 0, 0, "RESOURCE_WHEAT" }, { 3, 0, "RESOURCE_HORSES" } },
    improvementRules = true,
    improvements = { { 5, 0, "IMPROVEMENT_FARM" } },
  })
  local ctx = SDP_Land.Context(0, {}, true)
  local function Tile(x) return (SDP_Land.PlotValues(w:Plot(x, 0), ctx)) end
  T.eq(Tile(0), 3, "wheat: its own improvement, the farm: 2 + 1 + 1 kept - 1 harvest = 3, harvested 2 + 1 = 3")
  T.eq(Tile(1), 4, "woods: a lumber mill (3 + 2 - 1) beats clearing and farming (2 + 1)")
  T.eq(Tile(2), 4, "grassland hills: a mine, 2 + 1 + 1")
  T.eq(Tile(3), 6, "plains hills with horses (not harvestable): only its own improvement, the pasture: 5 + 1")
  -- (4, 0) woods again; (5, 0) plains with a farm already: the game's yields as they are.
  T.eq(Tile(5), 2, "an improved plot keeps the game's yields")
  local masonry = World.New({ rows = { "h" }, improvementRules = true, techs = { "TECH_MASONRY" } })
  local ctx2 = SDP_Land.Context(0, {}, true)
  T.eq((SDP_Land.PlotValues(masonry:Plot(0, 0), ctx2)), 5, "the mine's bonus of a technology the player has")
end)

test("a city's workable plots: kept features count, built and pinned districts do not", function()
  World.New({
    rows = {
      "........",
      "..ff....",
      "...f....",
      "........",
      "........",
    },
    cities = { { id = 1, x = 3, y = 2, population = 3, capital = true } },
    pins = { { 4, 1, "ICON_DISTRICT_CAMPUS", "campus" }, { 2, 3, "ICON_IMPROVEMENT_FARM", "farm" } },
  })
  local scan = SDP_City.Scan(0, 1, { allowFeatureRemoval = false })
  local land = SDP_Overlay.With(0, function()
    return SDP_Land.ForScan(scan, SDP_Overlay.FixedSubjects(scan), {}, 3)
  end)
  local campusPin, farmPin = Map.GetPlotIndex(4, 1), Map.GetPlotIndex(2, 3)
  local woods = Map.GetPlotIndex(2, 1)
  T.ok(land.ByIndex[campusPin] == nil, "a district pin's plot is taken")
  T.ok(land.ByIndex[farmPin] ~= nil, "an improvement pin's plot is workable")
  T.ok(land.ByIndex[woods] ~= nil, "woods kept (feature removal off) are workable")
  T.ok(land.ByIndex[Map.GetPlotIndex(3, 2)] == nil, "the city center is not")
end)

-- ===========================================================================
-- The exact solver's land bound (tests/compare/cmp_oracle.lua, issue 48)
-- ===========================================================================
include("cmp_oracle")

-- Every subset of a model's plots (bit masks over Plots[1..n]): the loss of
-- taking it, Base - ScoreTaken.
local function Losses(model)
  local n, losses = #model.Plots, {}
  for mask = 0, 2 ^ n - 1 do
    local taken, count, bit = {}, 0, mask
    for x = 1, n do
      if bit % 2 == 1 then
        count = count + 1
        taken[count] = model.Plots[x].Index
      end
      bit = math.floor(bit / 2)
    end
    losses[mask] = model.Base - SDP_Land.ScoreTaken(model, taken, count, {})
  end
  return losses
end

local function Taken(model, mask)
  local taken, bit = {}, mask
  for x = 1, #model.Plots do
    if bit % 2 == 1 then taken[model.Plots[x].Index] = true end
    bit = math.floor(bit / 2)
  end
  return taken
end

test("oracle land bound: one more plot costs max(0, t - c(S)), and only more as S grows", function()
  local sets = {
    { 5, 4, 4, 3, 3, 3, 2, 1, 0, 0 }, -- ties, zeros
    { 2.5, 2.5, 2.5, 1.25, 0.75, 0.75, 0, 3.5, 6, 1 },
    { 3, 1, 2 }, -- fewer plots than P + 1
  }
  for s, tiles in ipairs(sets) do
    local plots = {}
    for x, t in ipairs(tiles) do plots[x] = { Index = 100 + x, Tile = t, Once = 0 } end
    for population = 0, #tiles do
      local model = SDP_Land.Model(plots, population)
      local losses = Losses(model)
      local n = #model.Plots
      for mask = 0, 2 ^ n - 1 do
        local cut = CmpOracle.Cut(model, Taken(model, mask))
        for x = 1, n do
          local bitX = 2 ^ (x - 1)
          if math.floor(mask / bitX) % 2 == 0 then
            local exact = losses[mask + bitX] - losses[mask]
            local where = string.format("set %d, P %d, S %d, plot %d", s, model.P, mask, x)
            T.near(CmpOracle.Delta(model.Plots[x].Tile, cut), exact, 1e-9, "Delta " .. where)
            if x == 1 or exact > 0 then
              -- Supermodular: adding any y to S never lowers the cost of x.
              for y = 1, n do
                local bitY = 2 ^ (y - 1)
                if y ~= x and math.floor(mask / bitY) % 2 == 0 then
                  local later = losses[mask + bitY + bitX] - losses[mask + bitY]
                  T.ok(later >= exact - 1e-9, "supermodular " .. where .. " + " .. y)
                end
              end
            end
          end
        end
      end
    end
  end
end)

test("oracle land bound: the Deltas along a placement order add up to the land part", function()
  local plots = {}
  for x, t in ipairs({ 4, 4, 3, 2, 2, 1, 0 }) do plots[x] = { Index = 10 + x, Tile = t, Once = 0 } end
  for population = 0, 7 do
    local model = SDP_Land.Model(plots, population)
    for _, order in ipairs({ { 11, 12, 13 }, { 17, 11, 14, 15 }, { 13, 12, 11, 16, 15, 14, 17 } }) do
      local taken, total, list = {}, 0, {}
      for c, index in ipairs(order) do
        total = total + CmpOracle.Delta(model.ByIndex[index].Tile, CmpOracle.Cut(model, taken))
        taken[index] = true
        list[c] = index
        T.near(total, model.Base - SDP_Land.ScoreTaken(model, list, c, {}), 1e-9, "P " .. population .. " after " .. c)
      end
    end
  end
end)

include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Search")
include("SDP_Solver")

test("oracle with land: the optimum of the whole objective equals brute force", function()
  World.New({
    rows = {
      "~~~~~~~~~",
      "~.fj.h..~",
      "~.fMp.f.~",
      "~h..q..j~",
      "~.p.M.f.~",
      "~~~~~~~~~",
    },
    rivers = { "4,2", "4,3" },
    resources = { { 1, 1, "RESOURCE_WHEAT" }, { 6, 3, "RESOURCE_COPPER" } },
    improvementRules = true,
    cities = { { id = 1, x = 4, y = 3, population = 24, capital = true } },
  })
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }
  local weights = { YIELD_FOOD = 1, YIELD_PRODUCTION = 2, FEATURE = 1 }
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = weights, Land = true,
    Tier = "FAST" })
  T.ok(result.Ok, tostring(result.Error))
  local search = result.Session.Search
  local options = { Land = true }
  -- No incumbent: the bound alone must lead to the optimum.
  local o = SDP_Overlay.With(0, CmpOracle.Run, search, nil, options)
  local brute, count = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 1e6, options)
  T.ok(count ~= nil and count > 1000, "layouts tried: " .. tostring(count))
  T.ok(o.Proven, "proven")
  T.eq(o.Violations, 0, "no layout above its bound")
  T.near(o.Value, brute, 1e-9, "optimum vs brute force")
  T.ok(o.Value >= result.Gain - 1e-9, "not below the tier's plan")
  T.ok(result.LandDelta < 0, "the land part counts here")
  local adjacencyOnly = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 1e6)
  T.ok(adjacencyOnly >= o.Adjacency - 1e-9, "adjacency of the land optimum at most the adjacency optimum")
  T.ok(o.Nodes < count, "the bound prunes: " .. o.Nodes .. " nodes for " .. count .. " layouts")
  -- A given layout (compare.mjs --refscore, issue 53) valued by the same
  -- search: the optimum's own layout, as placements, gives its value.
  local placements = {}
  for m = 1, search.K do
    local c = search.Candidates[o.Layout[m]]
    placements[#placements + 1] = { city = 1, type = search.Types[m], x = c.X, y = c.Y }
  end
  local scored = SDP_Overlay.With(0, CmpOracle.ScoreLayout, search, placements, function() return 1 end, options)
  T.near(scored.value, o.Value, 1e-9, "the optimum's layout valued again")
  T.near(scored.adjacency, o.Adjacency, 1e-9, "its adjacency")
  T.ok(scored.legal and scored.missing == nil and scored.unplaced == nil, "legal, all placed")
  placements[1] = { city = 1, type = placements[1].type, x = 0, y = 0 }
  local outside = SDP_Overlay.With(0, CmpOracle.ScoreLayout, search, placements, function() return 1 end, options)
  T.ok(outside.value == nil and outside.missing ~= nil and outside.missing[1].reason == "not a candidate", "a plot outside the candidates")
end)

test("oracle, adjacency only: the optimum equals brute force under whole and fractional weights (issue 53)", function()
  World.New({
    rows = {
      "~~~~~~~~~",
      "~.fj.h..~",
      "~.fMp.f.~",
      "~h..q..j~",
      "~.p.M.f.~",
      "~~~~~~~~~",
    },
    rivers = { "4,2", "4,3" },
    resources = { { 1, 1, "RESOURCE_WHEAT" }, { 6, 3, "RESOURCE_COPPER" } },
    cities = { { id = 1, x = 4, y = 3, population = 24, capital = true } },
  })
  local districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }
  local vectors = {
    {},
    { YIELD_GOLD = 0.5, YIELD_FAITH = 0.5, YIELD_SCIENCE = 0.75, YIELD_CULTURE = 0.75 },
    { YIELD_SCIENCE = 1.8, YIELD_CULTURE = 1.5, YIELD_FAITH = 1.6, YIELD_GOLD = 1.15, YIELD_PRODUCTION = 0.75 },
  }
  for x, w in ipairs(vectors) do
    local weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1, YIELD_FOOD = 1 }
    for k, v in pairs(w) do weights[k] = v end
    local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = weights, Tier = "FAST" })
    T.ok(result.Ok, tostring(result.Error))
    local search = result.Session.Search
    -- No incumbent: the bound alone must lead to the optimum.
    local o = SDP_Overlay.With(0, CmpOracle.Run, search, nil, {})
    local brute, count = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 1e6, {})
    T.ok(count ~= nil and count > 1000, "vector " .. x .. ": layouts tried " .. tostring(count))
    T.ok(o.Proven, "vector " .. x .. ": proven")
    T.near(o.Value, brute, 1e-9, "vector " .. x .. ": optimum vs brute force")
  end
end)
