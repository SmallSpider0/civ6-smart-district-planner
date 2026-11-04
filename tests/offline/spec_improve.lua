-- Offline: improvements planned with the districts (issue 227,
-- docs/notes/issue-227-improvement-tacks.md). The world's rules (world.lua
-- spec.improveAdjacency): the industrial zone gets +1 production per two
-- adjacent mines and +1 per adjacent quarry; a farm gets +1 food per
-- adjacent campus; the trait TRAIT_TEST_IMPROVE gives a campus +1 science
-- per adjacent farm and a farm next to a holy site +2 food. The tests read
-- what to expect from those rules (SDP_Improve.Rules), not from a civ.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Wonders")
include("SDP_Improve")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Multi")

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local IZ, CAMPUS, HOLY, THEATER = "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER"
local MINE, QUARRY, FARM = "IMPROVEMENT_MINE", "IMPROVEMENT_QUARRY", "IMPROVEMENT_FARM"

-- Grassland, two hills at (5,3) and (6,3) (rings 2 and 3 of the capital at
-- (4,4)); (6,2) and (6,4) touch both.
local TWO_HILLS = {
  "~~~~~~~~~~~~",
  "~..........~",
  "~..........~",
  "~....hh....~",
  "~..........~",
  "~..........~",
  "~..........~",
  "~~~~~~~~~~~~",
}
local ONE_HILL = {
  "~~~~~~~~~~~~",
  "~..........~",
  "~..........~",
  "~.....h....~",
  "~..........~",
  "~..........~",
  "~..........~",
  "~~~~~~~~~~~~",
}

local function NewWorld(extra)
  local spec = { rows = TWO_HILLS, improvementRules = true, improveAdjacency = true,
    cities = { { id = 1, x = 4, y = 4, population = 7, capital = true } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local function Solve(extra)
  local request = { PlayerID = 0, CityID = 1, Tier = "FAST", Weights = ONES, Districts = { IZ } }
  for k, v in pairs(extra or {}) do request[k] = v end
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  return result
end

local function Find(plan, districtType)
  for _, p in ipairs(plan) do
    if p.Type == districtType then return p end
  end
  return nil
end

local function Next(a, b) return Map.GetPlotDistance(a.X, a.Y, b.X, b.Y) == 1 end

local function Key(e) return e.Type .. "@" .. e.X .. "," .. e.Y end

-- The plan with its improvements on the layer, evaluated by DMT alone.
local function Evaluate(result, extraEntries)
  local scan = SDP_City.Scan(0, 1)
  return SDP_Overlay.With(0, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local subjects, extra = {}, {}
    for _, p in ipairs(result.Plan) do
      subjects[#subjects + 1] = SDP_Overlay.Subject(p.Type, p.X, p.Y)
      for _, e in ipairs(p.Improvements or {}) do
        extra[#extra + 1] = { Key = e.Type, Type = "IMPROVEMENT", X = e.X, Y = e.Y }
      end
    end
    for _, e in ipairs(extraEntries or {}) do
      extra[#extra + 1] = { Key = e.Type, Type = "IMPROVEMENT", X = e.X, Y = e.Y }
    end
    return SDP_Overlay.Evaluate(subjects, fixed, ONES, extra)
  end)
end

test("off (the solver's default): no improvement tacks, the plan as without the rules", function()
  NewWorld()
  local default = Solve()
  local off = Solve({ Improvements = false })
  T.eq(Key(default.Plan[1]), Key(off.Plan[1]), "the same plan")
  for _, r in ipairs({ default, off }) do
    T.eq(r.Plan[1].Improvements, nil, "no improvements")
    T.eq(r.Worked, nil, "no worked tiles' tacks")
    T.eq(r.Adjacency, 0, "an industrial zone with nothing next to it")
  end
end)

test("two hills: the industrial zone goes next to both, with a mine on each", function()
  NewWorld()
  local rules = SDP_Improve.Rules(0)
  local mineRule = nil
  for _, g in ipairs(rules.Gives[IZ] or {}) do
    if g.Improvement == MINE then mineRule = g end
  end
  T.ok(mineRule ~= nil and mineRule.Tiles == 2, "the rules: mines count by twos for the industrial zone")
  local r = Solve({ Improvements = true })
  local iz = Find(r.Plan, IZ)
  T.ok(Next(iz, { X = 5, Y = 3 }) and Next(iz, { X = 6, Y = 3 }), "next to both hills: " .. Key(iz))
  T.eq(#(iz.Improvements or {}), 2, "two improvements")
  table.sort(iz.Improvements, function(a, b) return a.Index < b.Index end)
  T.eq(Key(iz.Improvements[1]), MINE .. "@5,3", "a mine on the first hill")
  T.eq(Key(iz.Improvements[2]), MINE .. "@6,3", "a mine on the second")
  T.eq(iz.Yields.YIELD_PRODUCTION, mineRule.Amount, "the mines' adjacency, as DMT counts it")
  T.eq(iz.ImprovementYields and iz.ImprovementYields.YIELD_PRODUCTION, mineRule.Amount, "what the mines add")
  T.eq(r.Adjacency, mineRule.Amount, "the plan's adjacency")
  -- What the plan reports is what DMT gives with the tacks on the map.
  local check = Evaluate(r)
  T.ok(check.Legal, "legal")
  T.eq(check.Placements[1].Score, iz.Score, "the industrial zone's score with the tacks")
  -- The same request, the same plan.
  local again = Solve({ Improvements = true })
  T.eq(Key(Find(again.Plan, IZ)), Key(iz), "same plot")
  T.eq(#Find(again.Plan, IZ).Improvements, 2, "same improvements")
end)

test("one hill: one mine is not enough; a quarry is", function()
  NewWorld({ rows = ONE_HILL })
  local r = Solve({ Improvements = true })
  T.eq(Find(r.Plan, IZ).Improvements, nil, "no lone mine")
  T.eq(r.Adjacency, 0, "nothing to gain")
  -- Stone next to the hill: a quarry counts alone, the mine still does not.
  NewWorld({ rows = ONE_HILL, resources = { { 5, 3, "RESOURCE_STONE" } } })
  r = Solve({ Improvements = true })
  local iz = Find(r.Plan, IZ)
  T.ok(Next(iz, { X = 5, Y = 3 }), "next to the stone")
  T.eq(#(iz.Improvements or {}), 1, "one improvement")
  T.eq(Key(iz.Improvements[1]), QUARRY .. "@5,3", "a quarry on the stone")
  T.eq(iz.Improvements[1].Yields.YIELD_PRODUCTION, 1 + 1, "the tile once built: the stone's production and the quarry's")
  T.eq(iz.Improvements[1].Yields.YIELD_FOOD, 2, "and the grassland's food")
  T.eq(r.Adjacency, 1, "+1 for the quarry")
end)

test("a woods on a hill: cleared when allowed and marked; with clearing off no mines", function()
  local w = NewWorld()
  w:Plot(6, 3).feature = GameInfo.Features.FEATURE_FOREST
  local r = Solve({ Improvements = true })
  local iz = Find(r.Plan, IZ)
  T.eq(#(iz.Improvements or {}), 2, "two mines")
  local woods = nil
  for _, e in ipairs(iz.Improvements) do
    if e.X == 6 and e.Y == 3 then woods = e end
  end
  T.ok(woods ~= nil and woods.Clear == true, "the one on the woods clears it first")
  T.eq(r.Adjacency, 1, "both count")
  r = Solve({ Improvements = true, AllowFeatureRemoval = false })
  T.eq(Find(r.Plan, IZ).Improvements, nil, "clearing off: only one hill left, no mines")
end)

test("a feature a district next to it takes adjacency from is not cleared", function()
  local w = NewWorld()
  w:Plot(6, 3).feature = GameInfo.Features.FEATURE_FOREST
  local rules = SDP_Improve.Rules(0)
  T.ok(rules.Features[HOLY] ~= nil and rules.Features[HOLY].FEATURE_FOREST, "the rules: woods give a holy site adjacency")
  local scan = SDP_City.Scan(0, 1)
  local model = SDP_Improve.New({ PlayerID = 0, Weights = ONES, Ownable = scan.Reach.Reached, Taken = {}, Fixed = {} })
  local izAt = { Type = IZ, Kind = "DISTRICT", Index = Map.GetPlotIndex(6, 2) }
  local plan = model:Assign({ izAt })
  T.eq(#plan, 2, "the industrial zone alone: two mines, the woods cleared")
  local holyAt = { Type = HOLY, Kind = "DISTRICT", Index = Map.GetPlotIndex(6, 4) }
  plan = model:Assign({ izAt, holyAt })
  T.eq(#plan, 0, "a holy site next to the woods: they stay, and one mine is not enough")
end)

test("Assign by groups and kept choices: the same as choosing afresh for every layout", function()
  NewWorld({ rows = {
    "~~~~~~~~~~~~",
    "~...h..h...~",
    "~..hh.h....~",
    "~....hh..h.~",
    "~.h....h...~",
    "~..h.hh....~",
    "~...h...h..~",
    "~~~~~~~~~~~~",
  }, resources = { { 3, 4, "RESOURCE_STONE" }, { 7, 2, "RESOURCE_STONE" } } })
  local scan = SDP_City.Scan(0, 1)
  local function Model()
    return SDP_Improve.New({ PlayerID = 0, Weights = ONES, Ownable = scan.Reach.Reached, Taken = {}, Fixed = {} })
  end
  local shared = Model()
  local plots = {}
  for _, c in ipairs(scan.Candidates) do plots[#plots + 1] = c.Index end
  local function Text(plan)
    local parts = {}
    for _, item in ipairs(plan) do parts[#parts + 1] = item.Type .. "@" .. item.Index .. (item.Clear and "c" or "") end
    return table.concat(parts, " ")
  end
  local layouts, nonEmpty = 0, 0
  for a = 1, #plots, 2 do
    for b = 1, #plots, 3 do
      local c = (a + b) % #plots + 1
      if a ~= b and c ~= a and c ~= b then
        local placed = { { Type = IZ, Kind = "DISTRICT", Index = plots[a] }, { Type = IZ, Kind = "DISTRICT", Index = plots[b] },
          { Type = CAMPUS, Kind = "DISTRICT", Index = plots[c] } }
        local got = Text(shared:Assign(placed, nil))
        T.eq(got, Text(Model():Assign(placed, nil)), "layout " .. plots[a] .. "," .. plots[b])
        layouts = layouts + 1
        if got ~= "" then nonEmpty = nonEmpty + 1 end
      end
    end
  end
  T.ok(layouts > 100 and nonEmpty > 20, "enough layouts with improvements: " .. nonEmpty .. " of " .. layouts)
end)

test("a planned mine counts against a neighborhood's appeal as if built", function()
  local w = NewWorld()
  w:Plot(6, 3).feature = GameInfo.Features.FEATURE_FOREST
  local scan = SDP_City.Scan(0, 1)
  local model = SDP_Appeal.New({ PlayerID = 0, Types = { "DISTRICT_NEIGHBORHOOD" }, Kinds = { "DISTRICT" },
    Candidates = scan.Candidates, Fixed = {}, Weights = {}, Lands = {}, Workable = {} })
  local at = nil
  for i, c in ipairs(scan.Candidates) do
    if c.X == 6 and c.Y == 4 then at = i end
  end
  T.ok(model ~= nil and at ~= nil, "a model and the plot next to both hills")
  local function Appeal(improvements)
    local detail = {}
    model:Score({ at }, detail, improvements)
    return detail[1].Appeal
  end
  local alone = Appeal(nil)
  local mineAppeal = GameInfo.Improvements[MINE].Appeal
  T.ok(mineAppeal ~= nil and mineAppeal < 0, "the rules: a mine lowers appeal")
  T.eq(Appeal({ { Index = Map.GetPlotIndex(5, 3), Type = MINE } }), alone + mineAppeal, "a mine next door")
  local woods = GameInfo.Features.FEATURE_FOREST.Appeal or 0
  T.eq(Appeal({ { Index = Map.GetPlotIndex(5, 3), Type = MINE }, { Index = Map.GetPlotIndex(6, 3), Type = MINE, Clear = true } }),
    alone + 2 * mineAppeal - woods, "two mines, one clearing woods")
  T.eq(Appeal(nil), alone, "nothing left behind")
end)

test("tiles the city can come to own get a tack marked; tiles out of reach none", function()
  local w = NewWorld({ cities = { { id = 1, x = 4, y = 4, population = 7, capital = true, radius = 1 } } })
  w:Own(5, 3, 0, w:City(1))
  local r = Solve({ Improvements = true })
  local iz = Find(r.Plan, IZ)
  T.eq(#(iz.Improvements or {}), 2, "two mines")
  for _, e in ipairs(iz.Improvements) do
    local owned = Map.GetPlot(e.X, e.Y):GetOwner() == 0
    T.eq(e.Unowned == true, not owned, "marked when not owned yet: " .. Key(e))
  end
  local scan = SDP_City.Scan(0, 1)
  local model = SDP_Improve.New({ PlayerID = 0, Weights = ONES, Ownable = scan.Reach.Reached, Taken = {}, Fixed = {} })
  T.eq(#model:Options(Map.GetPlotIndex(9, 3)), 0, "a tile no city can come to own: no improvement")
  T.ok(#model:Options(Map.GetPlotIndex(6, 3)) > 0, "a hill in reach: a mine")
end)

test("a trait's improvement adjacency counts for a player that has it, by the rules", function()
  NewWorld({ traits = { "TRAIT_TEST_IMPROVE" } })
  local rules = SDP_Improve.Rules(0)
  local farmRule = nil
  for _, g in ipairs(rules.Gives[CAMPUS] or {}) do
    if g.Improvement == FARM then farmRule = g end
  end
  T.ok(farmRule ~= nil, "the trait's modifier read from the rules")
  T.eq(rules.Gives[THEATER], nil, "another trait's modifier: not this player's")
  local holyFood = false
  for _, row in ipairs(rules.Takes[FARM] or {}) do
    if row.District == HOLY and row.Once then holyFood = true end
  end
  T.ok(holyFood, "the trait's plot yield next to a holy site read from the rules")
  local r = Solve({ Improvements = true, Districts = { CAMPUS } })
  local campus = Find(r.Plan, CAMPUS)
  local farms = 0
  for _, e in ipairs(campus.Improvements or {}) do
    T.eq(e.Type, FARM, "farms")
    T.ok(Next(e, campus), "next to the campus")
    farms = farms + 1
  end
  T.ok(farms >= 3, "farms around the campus: " .. farms)
  T.eq(campus.Yields.YIELD_SCIENCE, farms * farmRule.Amount / farmRule.Tiles, "a science each, as DMT counts it")
  T.eq(r.Adjacency, campus.Score, "the plan's adjacency")
  -- Without the trait: nothing for the campus (the land part is off).
  NewWorld()
  rules = SDP_Improve.Rules(0)
  T.eq(rules.Gives[CAMPUS], nil, "no trait, no modifier")
  for _, row in ipairs(rules.Takes[FARM] or {}) do T.ok(row.District ~= HOLY, "no plot yield next to a holy site") end
  r = Solve({ Improvements = true, Districts = { CAMPUS, THEATER } })
  T.eq(Find(r.Plan, CAMPUS).Improvements, nil, "no farms")
  T.eq(Find(r.Plan, THEATER).Improvements, nil, "no mines for the theater")
end)

test("what districts give improvements goes into the land part (question 5)", function()
  local w = NewWorld({ improvements = { { 3, 3, FARM } } })
  w:Own(3, 3, 0, w:City(1))
  local r = Solve({ Improvements = true, Land = true, Districts = { CAMPUS } })
  local campus = Find(r.Plan, CAMPUS)
  local search = r.Session.Search
  local model = search.Improve
  T.ok(model ~= nil and model.LandOn, "the model with the land part")
  -- A campus next to the built farm: the farm's tile is worth its food more.
  local farmAt = Map.GetPlotIndex(3, 3)
  local entry = model:LandEntry(farmAt)
  T.ok(entry ~= nil, "the farm's tile is one the city can work")
  local at = nil
  for _, n in ipairs(model:Neighbours(farmAt)) do
    local plot = Map.GetPlotByIndex(n)
    if at == nil and not plot:IsCity() and n ~= farmAt then at = n end
  end
  local _, forced = model:Assign({ { Type = CAMPUS, Kind = "DISTRICT", Index = at } })
  T.ok(forced ~= nil and forced[farmAt] ~= nil, "the built farm's tile valued anew")
  T.ok(math.abs(forced[farmAt] - (entry.Tile + model.Ctx.W.YIELD_FOOD)) < 1e-9, "plus a food at the land part's weight")
  -- The planned farms next to the campus show the food they get.
  for _, e in ipairs(campus.Improvements or {}) do
    T.eq(e.Type, FARM, "farms")
    T.eq(e.Yields.YIELD_FOOD, 2 + 1 + 1, "the grassland's food, the farm's and the campus's: " .. Key(e))
  end
  local off = Solve({ Improvements = false, Land = true, Districts = { CAMPUS } })
  T.ok(r.LandDelta >= off.LandDelta - 1e-9, "the land part with the improvements is no lower")
end)

test("worked tiles: tacks only with their switch and the land part; the plan stays as it is", function()
  NewWorld()
  local base = { Improvements = true, Land = true, Districts = { IZ, THEATER } }
  local plain = Solve(base)
  T.eq(plain.Worked, nil, "switch off: none")
  local with = {}
  for k, v in pairs(base) do with[k] = v end
  with.WorkedImprovements = true
  local r = Solve(with)
  T.ok(r.Worked ~= nil and #r.Worked > 0, "switch on: some")
  T.eq(#r.Plan, #plain.Plan, "the same plan")
  for n, p in ipairs(r.Plan) do T.eq(Key(p), Key(plain.Plan[n]), "the same plot for " .. p.Type) end
  T.eq(r.Adjacency, plain.Adjacency, "the same adjacency")
  local planned, onPlan = {}, {}
  for _, p in ipairs(r.Plan) do
    onPlan[p.Index] = true
    for _, e in ipairs(p.Improvements or {}) do planned[e.Index] = true end
  end
  local rules = SDP_Improve.Rules(0)
  for _, e in ipairs(r.Worked) do
    T.ok(not onPlan[e.Index] and not planned[e.Index], "not on a district or a planned improvement: " .. Key(e))
    T.eq(Map.GetPlot(e.X, e.Y):GetImprovementType(), -1, "no improvement there yet")
    for _, p in ipairs(r.Plan) do
      if Next(e, p) then
        for _, g in ipairs(rules.Gives[p.Type] or {}) do
          T.ok(g.Improvement ~= e.Type, "gives no district next to it adjacency: " .. Key(e))
        end
      end
    end
  end
  -- With every tack on the map DMT gives the plan what it reported.
  local check = Evaluate(r, r.Worked)
  T.ok(check.Legal, "legal")
  for n, p in ipairs(r.Plan) do T.eq(check.Placements[n].Score, p.Score, "score of " .. p.Type) end
  -- Land weight 0: the plan does not look at the worked tiles, none.
  local zero = {}
  for k, v in pairs(ONES) do zero[k] = v end
  zero.LAND = 0
  with.Weights, with.Land = zero, false
  T.eq(Solve(with).Worked, nil, "land weight 0: none")
end)

test("worked tiles: the hills get mines (they gain the most over the game); a resource only its own", function()
  NewWorld()
  local r = Solve({ Improvements = false, Land = true, WorkedImprovements = true, Districts = { THEATER } })
  local byPlot = {}
  for _, e in ipairs(r.Worked or {}) do byPlot[e.X .. "," .. e.Y] = e.Type end
  T.eq(byPlot["5,3"], MINE, "a mine on the first hill")
  T.eq(byPlot["6,3"], MINE, "a mine on the second")
  -- Wheat on a hill: its farm (harvesting it for a mine is the land part's
  -- guess, not a tack).
  NewWorld({ resources = { { 5, 3, "RESOURCE_WHEAT" } } })
  r = Solve({ Improvements = false, Land = true, WorkedImprovements = true, Districts = { THEATER } })
  byPlot = {}
  for _, e in ipairs(r.Worked or {}) do byPlot[e.X .. "," .. e.Y] = e end
  T.ok(byPlot["5,3"] ~= nil, "the wheat hill is worked")
  T.eq(byPlot["5,3"].Type, FARM, "wheat: its farm")
  T.eq(byPlot["5,3"].Harvest, nil, "not harvested")
  for _, e in ipairs(r.Worked or {}) do
    if not Map.GetPlot(e.X, e.Y):IsHills() then T.eq(e.Type, FARM, "farms on the grassland: " .. Key(e)) end
  end
  -- Iron the player sees on grassland: only its own improvement (one the
  -- land part's rules leave out, as the oil well), never a farm (M12 of the
  -- compare: a farm tacked on oil).
  local grass = {}
  for _, e in ipairs(r.Worked or {}) do
    if not Map.GetPlot(e.X, e.Y):IsHills() then grass[#grass + 1] = e end
  end
  T.ok(#grass > 0, "a farm on the grassland to put iron under")
  local iron = grass[1]
  NewWorld({ resources = { { 5, 3, "RESOURCE_WHEAT" }, { iron.X, iron.Y, "RESOURCE_IRON" } }, techs = { "TECH_BRONZE_WORKING" } })
  T.ok(Players[0]:GetResources():IsResourceVisible(GameInfo.Resources["RESOURCE_IRON"].Hash), "the iron is seen")
  r = Solve({ Improvements = false, Land = true, WorkedImprovements = true, Districts = { THEATER } })
  for _, e in ipairs(r.Worked or {}) do
    T.ok(not (e.X == iron.X and e.Y == iron.Y), "no tack on the iron: " .. Key(e))
  end
end)

test("district improvements: a resource takes only its own, also one the rules leave out (Codex on #284)", function()
  -- A farm the trait's campus takes adjacency from, then iron under it:
  -- iron's only improvement (IMPROVEMENT_TEST_WELL, Buildable false as the
  -- oil well) is not in the land part's rules, and no farm may go there.
  NewWorld({ traits = { "TRAIT_TEST_IMPROVE" } })
  local r = Solve({ Improvements = true, Districts = { CAMPUS } })
  local farm = (Find(r.Plan, CAMPUS).Improvements or {})[1]
  T.ok(farm ~= nil and farm.Type == FARM, "a farm next to the campus to put iron under")
  NewWorld({ traits = { "TRAIT_TEST_IMPROVE" }, resources = { { farm.X, farm.Y, "RESOURCE_IRON" } },
    techs = { "TECH_BRONZE_WORKING" } })
  T.ok(Players[0]:GetResources():IsResourceVisible(GameInfo.Resources["RESOURCE_IRON"].Hash), "the iron is seen")
  local scan = SDP_City.Scan(0, 1)
  local model = SDP_Improve.New({ PlayerID = 0, Weights = ONES, Ownable = scan.Reach.Reached, Taken = {}, Fixed = {} })
  T.eq(#model:Options(Map.GetPlotIndex(farm.X, farm.Y)), 0, "no improvement on the iron")
  r = Solve({ Improvements = true, Districts = { CAMPUS } })
  local campus = Find(r.Plan, CAMPUS)
  T.ok(#(campus.Improvements or {}) > 0, "farms elsewhere")
  for _, e in ipairs(campus.Improvements or {}) do
    T.ok(not (e.X == farm.X and e.Y == farm.Y), "no farm on the iron: " .. Key(e))
  end
end)

test("worked tiles: no tack that changes a planned district's appeal (Codex on #284)", function()
  -- Appeal 2 on (6,4), next to both hills: a neighborhood there gets the
  -- housing of appeal 2; a mine on a worked hill next to it would take that
  -- below the band, so neither hill gets a worked tile's tack.
  NewWorld({ appeal = { { 6, 4, 2 } } })
  local HOOD = "DISTRICT_NEIGHBORHOOD"
  local r = Solve({ Improvements = true, Land = true, WorkedImprovements = true, Districts = { HOOD } })
  local hood = Find(r.Plan, HOOD)
  T.eq(Key(hood), HOOD .. "@6,4", "the neighborhood on the appealing plot")
  local rules = SDP_Appeal.Rules()
  local appeal = hood.Appeal
  for _, e in ipairs(r.Worked or {}) do
    if Next(e, hood) then
      appeal = appeal + (GameInfo.Improvements[e.Type].Appeal or 0)
      local feature = Map.GetPlot(e.X, e.Y):GetFeatureType()
      if e.Clear and feature ~= -1 then appeal = appeal - (GameInfo.Features[feature].Appeal or 0) end
    end
  end
  T.eq(SDP_Appeal.Housing(rules, HOOD, appeal), hood.Housing, "the housing it reported with every tack built")
  T.ok(r.Worked ~= nil and #r.Worked > 0, "the other worked tiles keep theirs")
  -- The same on the multi-city page.
  local m = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Weights = ONES, Plans = { C1 = { HOOD } }, Only = { [1] = true },
    Improvements = true, Land = true, WorkedImprovements = true })
  T.ok(m.Ok, tostring(m.Error))
  local mhood = Find(m.Plan, HOOD)
  T.eq(Key(mhood), HOOD .. "@6,4", "multi: the neighborhood on the appealing plot")
  local worked = m.Cities[1].Worked or {}
  T.ok(#worked > 0, "multi: some tacks")
  for _, e in ipairs(worked) do
    T.ok(not (Next(e, mhood) and (GameInfo.Improvements[e.Type].Appeal or 0) ~= 0), "multi: none next to it changes its appeal: " .. Key(e))
  end
  -- Without the neighborhood the hills get their mines (the filter is the appeal).
  r = Solve({ Improvements = true, Land = true, WorkedImprovements = true, Districts = { THEATER } })
  local mines = 0
  for _, e in ipairs(r.Worked or {}) do
    if e.Type == MINE then mines = mines + 1 end
  end
  T.eq(mines, 2, "mines on both hills")
end)

test("several cities: each city's industrial zone with its mines; worked tiles per city", function()
  World.New({
    rows = {
      "~~~~~~~~~~~~~~~~~~",
      "~................~",
      "~................~",
      "~....hh.....hh...~",
      "~................~",
      "~................~",
      "~................~",
      "~~~~~~~~~~~~~~~~~~",
    },
    improvementRules = true, improveAdjacency = true,
    cities = { { id = 1, x = 4, y = 4, population = 7, capital = true }, { id = 2, x = 11, y = 4, population = 7 } },
  })
  local function Request(extra)
    local r = { PlayerID = 0, Tier = "FAST", Weights = ONES, Plans = { C1 = { IZ }, C2 = { IZ } },
      Only = { [1] = true, [2] = true }, Improvements = true }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
  end
  local r = SDP_Multi.Solve(Request())
  T.ok(r.Ok, tostring(r.Error))
  T.ok(not r.Stats.Mismatch, "board and full evaluation agree")
  local zones, mines = 0, {}
  for _, p in ipairs(r.Plan) do
    if p.Type == IZ then
      zones = zones + 1
      T.eq(#(p.Improvements or {}), 2, "two mines for the zone at " .. Key(p))
      T.eq(p.Yields.YIELD_PRODUCTION, 1, "+1 from them")
      for _, e in ipairs(p.Improvements or {}) do
        T.ok(Next(e, p), "next to it")
        T.ok(mines[e.Index] == nil, "each mine once")
        mines[e.Index] = true
      end
    end
  end
  T.eq(zones, 2, "a zone in each city")
  local off = SDP_Multi.Solve(Request({ Improvements = false }))
  T.ok(r.Adjacency > off.Adjacency, "more adjacency than without: " .. r.Adjacency .. " > " .. off.Adjacency)
  -- The worked tiles' tacks, one list per city, the plan unchanged.
  local worked = SDP_Multi.Solve(Request({ Land = true, WorkedImprovements = true }))
  local plain = SDP_Multi.Solve(Request({ Land = true }))
  T.eq(worked.Gain, plain.Gain, "the same value")
  local seen, cities = {}, 0
  for _, city in ipairs(worked.Cities) do
    if city.Worked ~= nil and #city.Worked > 0 then cities = cities + 1 end
    for _, e in ipairs(city.Worked or {}) do
      T.ok(seen[e.Index] == nil, "a tile in one city's list only: " .. Key(e))
      seen[e.Index] = true
    end
    T.eq(plain.Cities[_].Worked, nil, "switch off: none")
  end
  T.eq(cities, 2, "both cities have some")
end)
