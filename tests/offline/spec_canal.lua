-- Offline: canals (issue 378). The rule that a canal joins water lives in the
-- game's DLL and DMT does not check it (pitfall 27); the engine's build
-- targets answer only for plots the city owns and a district it has unlocked,
-- so the planner asks them first and, when they say nothing, falls back to the
-- rules alone: SDP_Rules.IsCanal, District_ValidTerrains and
-- SDP_City.CanalCannotLink. These tests pin that fallback against the rule the
-- engine itself follows (measured in game, tests/bench/probe_canal.lua,
-- 2026-11-25): two sides two apart (a 60 degree bend, the side between them
-- land) or three apart (straight through, the other four land), where a side
-- is water — coast, ocean or lake —, a city center or a built canal. A river
-- is not a side.
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

-- A 12 x 10 map: water around the edge, land inside, an isthmus at (3, 4)
-- between two water plots, hills at (5, 3), a river at (3, 6). The capital at
-- (5, 6) reaches (7, 6), an inland plot four land neighbours away from any
-- water: a canal there can join nothing.
local MAP = {
  "~~~~~~~~~~~~",
  "~..........~",
  "~..........~",
  "~....h.....~",
  "~.~.~......~",
  "~..........~",
  "~..........~",
  "~..........~",
  "~..........~",
  "~~~~~~~~~~~~",
}

-- The same with a lake at (6, 5): (5, 5) then has water on one side and the
-- city on the other, 60 degrees apart — the bend the game accepts.
local BEND = {
  "~~~~~~~~~~~~",
  "~..........~",
  "~..........~",
  "~....h.....~",
  "~.~.~......~",
  "~.....~....~",
  "~..........~",
  "~..........~",
  "~..........~",
  "~~~~~~~~~~~~",
}
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function NewWorld(extra)
  local spec = { rows = MAP, rivers = { "3,6" }, canal = true,
    cities = { { id = 1, x = 5, y = 6, population = 4, capital = true, radius = 1 } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  local w = World.New(spec)
  SDP_Overlay.ResetEngine()
  return w
end

-- One placement evaluated as the solver sees it.
local function Item(districtType, x, y)
  return SDP_Overlay.With(0, SDP_Overlay.Evaluate, { SDP_Overlay.Subject(districtType, x, y) }, {}, ONES).Placements[1]
end

test("the rules mark a canal by its column, not its name", function()
  NewWorld()
  T.eq(SDP_Rules.IsCanal("DISTRICT_CANAL"), true, "Districts_XP2.Canal")
  T.eq(SDP_Rules.IsCanal("DISTRICT_DAM"), false, "a dam is not a canal")
  T.eq(SDP_Rules.IsCanal("DISTRICT_CAMPUS"), false, "nor is a campus")
  local terrains = SDP_Rules.ValidTerrains("DISTRICT_CANAL")
  T.ok(terrains ~= nil and terrains.TERRAIN_GRASS == true, "flat grass")
  T.eq(terrains.TERRAIN_GRASS_HILLS, nil, "hills are not listed")
  T.eq(SDP_Rules.ValidTerrains("DISTRICT_CAMPUS"), nil, "no rows, nothing to decide")
end)

test("a canal that joins no water is refused on a plot the city does not own", function()
  NewWorld()
  local item = Item("DISTRICT_CANAL", 7, 6)
  T.eq(item.CanPlace, false, "the game would refuse it")
  T.eq(item.EngineRefused, true, "and the planner says why")
end)

test("two sides at the right angle: across water, or between water and the city", function()
  NewWorld()
  local across = Item("DISTRICT_CANAL", 3, 4)
  T.eq(across.CanPlace, true, "water on opposite sides, straight through")
  T.eq(across.EngineRefused, nil, "not refused")
  local toCity = Item("DISTRICT_CANAL", 4, 5)
  T.eq(toCity.CanPlace, true, "water on one side, the city on the other")
  T.eq(toCity.EngineRefused, nil, "not refused")
end)

test("one side is not enough: the city alone, or water alone", function()
  NewWorld()
  local cityOnly = Item("DISTRICT_CANAL", 5, 5)
  T.eq(cityOnly.CanPlace, false, "next to the city but not to water")
  T.eq(cityOnly.EngineRefused, true, "refused by the rules")
  local waterOnly = Item("DISTRICT_CANAL", 10, 6)
  T.eq(waterOnly.CanPlace, false, "water on one side and nothing on the other")
end)

test("a 60 degree bend counts when the side between its ends is land", function()
  NewWorld({ rows = BEND })
  local item = Item("DISTRICT_CANAL", 5, 5)
  T.eq(item.CanPlace, true, "water 60 degrees from the city")
  T.eq(item.EngineRefused, nil, "not refused")
end)

test("water on three sides is not a passage unless two of them line up", function()
  NewWorld()
  -- (1, 6): water at directions 3, 4 and 5 — neighbours 4 and 5 are one apart,
  -- 3 and 5 are two apart with direction 4 (water) between them.
  local item = Item("DISTRICT_CANAL", 1, 6)
  T.eq(item.CanPlace, false, "no straight run and no bend with land between")
  T.eq(item.EngineRefused, true, "refused by the rules")
end)

test("a bend needs land outside it: a corner cut in open water joins nothing", function()
  -- Five water sides and one land corner (measured against the engine on a
  -- one-tile spit, 2026-11-25): the engine refuses it.
  T.eq(SDP_City.CanalSidesJoin({ [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }), false,
    "only a corner of land left")
  -- Four water sides: the bend still has a land side outside it.
  T.eq(SDP_City.CanalSidesJoin({ [0] = true, [1] = true, [3] = true, [4] = true }), true,
    "a bend with land outside")
end)

test("a canal may not touch a built canal", function()
  local w = NewWorld()
  w:AddDistrict(1, "DISTRICT_CANAL", 6, 4)
  SDP_Overlay.ResetEngine()
  -- (5, 4) has water on one side and the built canal on the other; the game
  -- still refuses it (a city can build many canals, but two may not touch).
  local pair = Item("DISTRICT_CANAL", 5, 4)
  T.eq(pair.CanPlace, false, "next to a built canal")
  T.eq(pair.EngineRefused, true, "refused by the rules")
  local alone = Item("DISTRICT_CANAL", 7, 4)
  T.eq(alone.CanPlace, false, "the canal next to it is the only side")
  T.eq(alone.EngineRefused, true, "refused by the rules")
end)

test("a planned city center counts as a side", function()
  NewWorld({ rows = BEND,
    cities = { { id = 1, x = 2, y = 2, population = 4, capital = true, radius = 1 } },
    pins = { { 5, 6, "ICON_DISTRICT_CITY_CENTER", "new city" } } })
  local item = Item("DISTRICT_CANAL", 5, 5)
  T.eq(item.CanPlace, true, "the plan puts a city on the other side of the water")
end)

test("a planned city center alone is not a passage", function()
  NewWorld({ cities = { { id = 1, x = 2, y = 2, population = 4, capital = true, radius = 1 } },
    pins = { { 5, 6, "ICON_DISTRICT_CITY_CENTER", "new city" } } })
  local item = Item("DISTRICT_CANAL", 5, 5)
  T.eq(item.CanPlace, false, "a city next to it and no water")
end)

test("a pin added after a plot was judged still counts (the cache holds the map only)", function()
  local w = NewWorld({ rows = BEND,
    cities = { { id = 1, x = 2, y = 2, population = 4, capital = true, radius = 1 } } })
  T.eq(Item("DISTRICT_CANAL", 5, 5).CanPlace, false, "no city next to the water yet")
  w:AddPin(5, 6, "ICON_DISTRICT_CITY_CENTER", "new city")
  local item = Item("DISTRICT_CANAL", 5, 5)
  T.eq(item.CanPlace, true, "the pin appears in the same turn and is seen")
end)

test("a canal planned next to another canal is refused", function()
  -- (3, 4) is a legal canal; a canal pin at (3, 5) sits next to it. Two canals
  -- may not touch, so the plan cannot keep both (measured 2026-11-25: after
  -- one canal the engine keeps a target two plots away and drops the neighbour).
  NewWorld({ pins = { { 3, 5, "ICON_DISTRICT_CANAL", "canal" } } })
  local item = Item("DISTRICT_CANAL", 3, 4)
  T.eq(item.CanPlace, false, "a planned canal next to it")
  T.eq(item.EngineRefused, true, "refused by the rule, not by DMT")
end)

test("hills and rivers: the rules leave hills to DMT, a river is not a side", function()
  NewWorld()
  T.eq(Item("DISTRICT_CANAL", 5, 3).CanPlace, true, "hills: the rules list no canal there")
  local river = Item("DISTRICT_CANAL", 3, 6)
  T.eq(river.CanPlace, false, "a river through the plot joins nothing")
  T.eq(river.EngineRefused, true, "refused by the rules")
  T.eq(next(SDP_City.CanalSides(nil)), nil, "no plot: no sides")
  T.eq(SDP_City.CanalCannotLink("DISTRICT_CANAL", nil, nil), false, "no plot: nothing to decide")
end)

test("other districts keep the rules they had", function()
  NewWorld()
  T.eq(Item("DISTRICT_CAMPUS", 7, 6).CanPlace, true, "DMT alone decides")
  T.eq(Item("DISTRICT_CAMPUS", 7, 6).EngineRefused, nil, "no engine refusal")
end)

test("the engine's own list wins when it has one", function()
  -- The city owns three rings, so the engine speaks for every plot in them.
  local OWNS = { { id = 1, x = 5, y = 6, population = 4, capital = true, radius = 3 } }
  local all = {}
  for _, p in ipairs(SDP_City.PlotsInRange(5, 6, 3)) do all[#all + 1] = p.X .. "," .. p.Y end
  NewWorld({ cities = OWNS, engine = { DISTRICT_CANAL = all } })
  local allowed = Item("DISTRICT_CANAL", 7, 6)
  T.eq(allowed.CanPlace, true, "the engine allows this plot, so the planner does")
  T.eq(allowed.EngineRefused, nil, "not refused")
  local without = {}
  for _, key in ipairs(all) do
    if key ~= "7,6" then without[#without + 1] = key end
  end
  NewWorld({ cities = OWNS, engine = { DISTRICT_CANAL = without } })
  local refused = Item("DISTRICT_CANAL", 7, 6)
  T.eq(refused.CanPlace, false, "the engine leaves it out")
  T.eq(refused.EngineRefused, true, "refused by the engine")
end)

test("the engine cannot see the plan: a planned canal beside an allowed plot refuses it", function()
  -- The plot is owned and the district unlocked, so the engine answers and
  -- allows it; a canal the plan puts next to it still refuses it (two canals
  -- may not touch, and the engine reads the map only).
  local OWNS = { { id = 1, x = 5, y = 6, population = 4, capital = true, radius = 3 } }
  local all = {}
  for _, p in ipairs(SDP_City.PlotsInRange(5, 6, 3)) do all[#all + 1] = p.X .. "," .. p.Y end
  NewWorld({ cities = OWNS, engine = { DISTRICT_CANAL = all },
    pins = { { 3, 5, "ICON_DISTRICT_CANAL", "canal" } } })
  local item = Item("DISTRICT_CANAL", 3, 4)
  T.eq(item.CanPlace, false, "the plan puts a canal on the plot next to it")
  T.eq(item.EngineRefused, true, "refused by the rule, not by the engine")
end)

test("the board re-judges a canal when the plan puts another beside it", function()
  -- Legality is memoized per plot; a canal's depends on its neighbours, so the
  -- second canal must not reuse the answer from when it stood alone.
  local OWNS = { { id = 1, x = 5, y = 6, population = 4, capital = true, radius = 3 } }
  local all = {}
  for _, p in ipairs(SDP_City.PlotsInRange(5, 6, 3)) do all[#all + 1] = p.X .. "," .. p.Y end
  NewWorld({ cities = OWNS, engine = { DISTRICT_CANAL = all } })
  local scan = SDP_City.Scan(0, 1)
  SDP_Overlay.With(0, function()
    local board = SDP_Board.New(0, SDP_Overlay.FixedSubjects(scan), ONES)
    board:Put(1, SDP_Overlay.Subject("DISTRICT_CANAL", 3, 4))
    local _, alone = board:Total()
    T.eq(alone, true, "one canal on its own")
    board:Put(2, SDP_Overlay.Subject("DISTRICT_CANAL", 3, 5))
    local _, pair = board:Total()
    T.eq(pair, false, "a second canal beside it")
    board:Clear()
  end)
end)

test("a canal before Steam Power is still checked", function()
  -- The engine answers nothing for a locked district: the rules decide.
  local OWNS = { { id = 1, x = 5, y = 6, population = 4, capital = true, radius = 3 } }
  NewWorld({ cities = OWNS })
  local item = Item("DISTRICT_CANAL", 7, 6)
  T.eq(item.CanPlace, false, "no engine list, the rules refuse it")
  T.eq(item.EngineRefused, true, "refused all the same")
end)

test("the solver does not plan a canal that joins no water", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Weights = ONES, Districts = { "DISTRICT_CANAL" } })
  T.ok(result.Ok, tostring(result.Error))
  T.eq(#result.Plan, 1, "one canal")
  T.ok(result.Plan[1].Index ~= Map.GetPlotIndex(7, 6), "not the inland plot")
end)
