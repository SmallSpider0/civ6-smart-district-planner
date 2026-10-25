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

test("the district planner weighs plot yields with fixed numbers (issue 53)", function()
  local W = SDP_Land.PLOT_WEIGHTS
  T.eq(W.YIELD_FOOD, 1, "food")
  T.eq(W.YIELD_PRODUCTION, 1, "production")
  T.eq(W.YIELD_GOLD, 1 / 4, "gold: 1 production = 4 gold")
  T.eq(W.YIELD_FAITH, 1 / 2, "faith: 1 production = 2 faith")
  T.eq(W.YIELD_SCIENCE, 5 / 6, "science")
  T.eq(W.YIELD_CULTURE, 5 / 6, "culture")
  local w = World.New({ rows = { "d" }, resources = { { 0, 0, "RESOURCE_COPPER" } } })
  local ctx = SDP_Land.Context(0, W, true)
  local tile, once = SDP_Land.PlotValues(w:Plot(0, 0), ctx)
  T.near(once, 40 * (1 / 4) / 20, 1e-12, "the copper harvest's gold weighs 1/4 too")
  T.near(tile, 0, 1e-12, "kept: 2 gold x 1/4 minus the forgone harvest")
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
