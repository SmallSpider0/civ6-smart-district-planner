-- Offline: plot yields of the player's traits in the land part (issue 361).
-- The game gives a trait's plot yields only on the plots the player owns
-- (the fake world's Plot:GetYield does the same), so a plot the city still
-- has to grow into, and every plot of a new city, has to be counted with
-- them; an improvement-conditioned one counts with the improvement the land
-- part assumes, and never twice. The traits are the world's test traits
-- (spec.traitPlotYields), not any civilization's.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Improve")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")
include("SDP_Sites")

-- One row of `char` plots; our city at (1, 1) owns its first ring: (2, 1)
-- is owned, (4, 1) and (5, 1) are not.
local function NewWorld(char, extra)
  local row = string.rep(char, 7)
  local spec = { rows = { row, row, row }, traitPlotYields = true,
    cities = { { id = 1, x = 1, y = 1, population = 3, capital = true, radius = 1 } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local function Value(w, x, y, ctx) return (SDP_Land.PlotValues(w:Plot(x, y), ctx)) end

test("a trait on terrain: plots the player does not own count it as owned ones do", function()
  local w = NewWorld("t", { traits = { "TRAIT_TEST_TUNDRA" } })
  T.eq(w:Plot(2, 1):GetOwner(), 0, "(2, 1) is the city's")
  T.eq(w:Plot(4, 1):GetOwner(), -1, "(4, 1) is not")
  local production = GameInfo.Yields["YIELD_PRODUCTION"].Index
  T.eq(w:Plot(2, 1):GetYield(production), 1, "the game gives the trait on the city's plot")
  T.eq(w:Plot(4, 1):GetYield(production), 0, "and not on a plot nobody owns")
  local ctx = SDP_Land.Context(0, {}, true)
  T.eq(Value(w, 2, 1, ctx), 3, "owned tundra: 1 food, 1 production, 1 faith (not counted twice)")
  T.eq(Value(w, 4, 1, ctx), 3, "unowned tundra: the same")
  local now, unheld = SDP_Land.TraitYields(w:Plot(4, 1), ctx)
  T.eq(now.YIELD_FAITH, 1, "trait yields of the plot")
  T.eq(unheld.YIELD_PRODUCTION, 1, "not in the game's yields yet")
  local _, held = SDP_Land.TraitYields(w:Plot(2, 1), ctx)
  T.eq(next(held), nil, "the owned plot's yields hold them")
  -- Without the trait the same plots are worth their terrain's.
  local plain = NewWorld("t")
  local none = SDP_Land.Context(0, {}, true)
  T.eq(#none.Traits.Yields, 0, "no trait modifiers")
  T.eq(Value(plain, 4, 1, none), 1, "tundra: 1 food")
end)

test("a city site counts the trait on its plots", function()
  local function Farm(traits)
    NewWorld("t", { traits = traits })
    local ctx = SDP_Sites.Context(0, { Districts = { "DISTRICT_CAMPUS" }, Raw = true })
    local site = SDP_Sites.Coarse(ctx, { X = 5, Y = 1, Index = Map.GetPlotIndex(5, 1), Unrevealed = 0 }, SDP_Sites.Centers(0))
    return site.Land.Base
  end
  local with, without = Farm({ "TRAIT_TEST_TUNDRA" }), Farm({})
  T.ok(with > without + 1e-9, string.format("tundra site with the trait %s > without %s", with, without))
end)

test("a trait on an improvement counts with the improvement the land part assumes", function()
  local w = NewWorld("h", { improvementRules = true, traits = { "TRAIT_TEST_MINE" } })
  local ctx = SDP_Land.Context(0, {}, true)
  -- Grassland hills 2 food 1 production; a mine +1 production; the trait
  -- +4 gold -1 production on a mine.
  T.eq(Value(w, 4, 1, ctx), 3 + 1 + 4 - 1, "unowned hills with a mine")
  T.eq(Value(w, 2, 1, ctx), 3 + 1 + 4 - 1, "owned hills with a mine")
  local o = SDP_Land.AssumedImprovement(w:Plot(4, 1), ctx)
  T.eq(o and o.Entry.Type, "IMPROVEMENT_MINE", "a mine")
  T.eq(o.Gain, 1 + 4 - 1, "its gain holds the trait")
  -- The improvement tack's yields (issue 227) hold them too.
  local model = SDP_Improve.New({ PlayerID = 0, PlotWeights = SDP_Land.PlotWeights(1), Lands = {} })
  local entry = model:Entry({ Index = Map.GetPlotIndex(4, 1), Type = "IMPROVEMENT_MINE" }, {})
  T.eq(entry.Yields.YIELD_GOLD, 4, "tack: +4 gold")
  T.eq(entry.Yields.YIELD_PRODUCTION, 1, "tack: 1 + 1 - 1 production")
  -- A mine built on an owned plot: the game's yields hold the trait already.
  local built = NewWorld("h", { improvementRules = true, traits = { "TRAIT_TEST_MINE" }, improvements = { { 2, 1, "IMPROVEMENT_MINE" } } })
  local _ = built
  local again = SDP_Land.Context(0, {}, true)
  local gold = GameInfo.Yields["YIELD_GOLD"].Index
  T.eq(Map.GetPlot(2, 1):GetYield(gold), 4, "the game gives the built mine its gold")
  T.eq(Value(built, 2, 1, again), 2 + 0 + 4, "built mine: its yields as the game gives them, nothing added")
end)

test("a trait lost by improving: woods without an improvement", function()
  local w = NewWorld("f", { improvementRules = true, traits = { "TRAIT_TEST_WOODS" } })
  local ctx = SDP_Land.Context(0, {}, true)
  -- Woods 2 food 1 production, +1 production unimproved (the trait); a
  -- lumber mill +2 production ends the trait's; clearing gives 20
  -- production once (1 a turn here) and ends it too.
  for _, x in ipairs({ 2, 4 }) do
    local tile, once, bare = SDP_Land.PlotValues(w:Plot(x, 1), ctx)
    T.eq(once, 1, x .. ": clearing")
    T.eq(bare, 4 - 1, x .. ": left unimproved with its woods: the trait's production, less the clearing it forgoes")
    T.eq(tile, 4 - 1 + 2 - 1, x .. ": a lumber mill, which ends the trait's +1")
  end
end)

test("a trait that adds valid terrains: farms on tundra, and a civic requirement", function()
  local w = NewWorld("t", { improvementRules = true, traits = { "TRAIT_TEST_TUNDRA_FARM" } })
  local ctx = SDP_Land.Context(0, {}, true)
  local types = {}
  for _, entry in ipairs(SDP_Land.ValidImprovements(ctx, false, "TERRAIN_TUNDRA", nil, nil)) do types[#types + 1] = entry.Type end
  T.eq(table.concat(types, ","), "IMPROVEMENT_FARM", "a farm on tundra")
  T.eq(Value(w, 4, 1, ctx), 1 + 1 + 2, "tundra farm: 1 food, +1 farm, +2 the trait")
  NewWorld("t", { improvementRules = true, traits = { "TRAIT_TEST_TUNDRA_FARM" }, civics = { "CIVIC_CONSERVATION" } })
  local late = SDP_Land.Context(0, {}, true)
  T.eq(SDP_Land.PlotValues(Map.GetPlot(4, 1), late), 1 + 1 + 2 + 1, "with the civic: +1 more")
  -- Other players' tundra takes no farm.
  NewWorld("t", { improvementRules = true })
  local other = SDP_Land.Context(0, {}, true)
  T.eq(#SDP_Land.ValidImprovements(other, false, "TERRAIN_TUNDRA", nil, nil), 0, "no farm on tundra without the trait")
end)

test("a trait with a requirement the planner does not read is left out", function()
  local w = NewWorld("t", { traits = { "TRAIT_TEST_UNKNOWN" } })
  local ctx = SDP_Land.Context(0, {}, true)
  T.eq(#ctx.Traits.Yields, 0, "not read")
  T.eq(Value(w, 4, 1, ctx), 1, "tundra: 1 food, no science")
end)

test("a city-center pin's production counts the trait on its plots", function()
  NewWorld("t", { traits = { "TRAIT_TEST_TUNDRA" } })
  local scan = SDP_City.ScanSite(0, 5, 1, {})
  local production = SDP_Multi.Production(0, { Kind = "SITE", Scan = scan, X = 5, Y = 1, PlanPopulation = 2 })
  T.eq(production, 1 + 2, "the centre and two worked plots, all tundra: +1 each once owned")
end)
