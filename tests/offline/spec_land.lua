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
  T.eq(model.Base, 5 + 4 + 1, "base: best two plus every one-time value")
  T.eq(model.Loss[10], 5 - 3, "best plot")
  T.eq(model.Loss[11], 4 - 3, "second plot")
  T.eq(model.Loss[12], 1, "an unworked plot loses its one-time value only")
  T.eq(model.Loss[14], 0, "an unworked plot without one-time value is free")
  for index, loss in pairs(model.Loss) do
    T.eq(model.Base - SDP_Land.Score(model, { [index] = true }), loss, "loss of plot " .. index)
  end
  -- Two of the best taken: the next two are worked.
  T.eq(SDP_Land.Score(model, { [10] = true, [11] = true }), 3 + 2 + 1, "both best taken: plots 12 and 13 are worked")
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

test("plot values read yields, removable features and harvests from the data", function()
  local w = World.New({
    rows = { ".fjsMd" },
    resources = { { 0, 0, "RESOURCE_WHEAT" }, { 5, 0, "RESOURCE_COPPER" } },
  })
  local weights = SDP_Land.Weights({})
  local oneTime = SDP_Land.OneTimeYields()
  local function Values(x) return SDP_Land.PlotValues(w:Plot(x, 0), weights, oneTime) end
  local tile, once = Values(0) -- grassland with wheat: 2 + 1 food; harvest 20 food
  T.eq(tile, 3, "grassland wheat tile")
  T.eq(once, 1, "wheat harvest")
  tile, once = Values(1) -- woods: 2 food 1 production; clearing gives 20 production
  T.eq(tile, 3, "woods tile")
  T.eq(once, 1, "woods clearing")
  tile, once = Values(2) -- rainforest on plains: 1+1 food, 1 production; 10 + 10
  T.eq(tile, 3, "rainforest tile")
  T.eq(once, 1, "rainforest clearing")
  tile, once = Values(4)
  T.eq(tile, 0, "mountain")
  T.eq(once, 0, "mountain one-time")
  tile, once = Values(5) -- desert copper: 2 gold, harvest 40 gold
  T.eq(tile, 2, "desert copper tile")
  T.eq(once, 2, "copper harvest")
  local heavy = SDP_Land.Weights({ YIELD_PRODUCTION = 3, FEATURE = 2 })
  tile, once = SDP_Land.PlotValues(w:Plot(1, 0), heavy, oneTime)
  T.eq(tile, 2 + 3, "weighted woods tile")
  T.eq(once, 20 * 3 * 2 / 20, "weighted clearing")
  local off = SDP_Land.Weights({ FEATURE = 0 })
  tile, once = SDP_Land.PlotValues(w:Plot(1, 0), off, oneTime)
  T.eq(once, 0, "feature weight 0")
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
