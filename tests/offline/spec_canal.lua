-- Offline: canals (issue 378). The rule that a canal joins water lives in the
-- game's DLL and DMT does not check it (pitfall 27); the engine's build
-- targets answer only for plots the city owns and a district it has unlocked,
-- so the planner asks them first and, when they say nothing, falls back to the
-- rules alone: SDP_Rules.IsCanal, District_ValidTerrains and
-- SDP_City.CanalCannotLink. These tests pin that fallback: it refuses only
-- plots that cannot join water, and never refuses one the engine allows.
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

test("water, a built canal or the city itself is a link", function()
  local w = NewWorld()
  w:AddDistrict(1, "DISTRICT_CANAL", 6, 4)
  SDP_Overlay.ResetEngine()
  for _, case in ipairs({ { 3, 4, "between two water plots" }, { 7, 4, "next to a built canal" },
    { 5, 5, "next to the city" } }) do
    local item = Item("DISTRICT_CANAL", case[1], case[2])
    T.eq(item.CanPlace, true, case[3])
    T.eq(item.EngineRefused, nil, case[3] .. ": not refused")
  end
end)

test("a planned city center next to a canal counts as a link", function()
  NewWorld({ cities = { { id = 1, x = 2, y = 2, population = 4, capital = true, radius = 1 } },
    pins = { { 5, 6, "ICON_DISTRICT_CITY_CENTER", "new city" } } })
  local item = Item("DISTRICT_CANAL", 5, 5)
  T.eq(item.CanPlace, true, "the plan puts a city next to it")
end)

test("hills, rivers and no plot at all are left to DMT", function()
  NewWorld()
  T.eq(Item("DISTRICT_CANAL", 5, 3).CanPlace, true, "hills: the rules list no canal there")
  T.eq(Item("DISTRICT_CANAL", 3, 6).CanPlace, true, "on a river: unknown, so allowed")
  T.eq(SDP_City.WaterLinkPossible(nil), true, "no plot: unknown, so allowed")
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
