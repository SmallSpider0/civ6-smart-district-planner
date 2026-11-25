-- Offline benchmark: what a fourth workable ring costs (issue 379).
--
-- The planner assumes three rings everywhere (SDP_City.RADIUS). Mods that
-- widen the workable range replace the game's GameCore DLL, and the Lua side
-- has no way to read the new radius; before deciding whether to follow such a
-- mod at all, this measures the work: the same world and request are solved
-- with RADIUS = 3 and RADIUS = 4 and the two are compared.
--
-- Units are SDP_Tiers work units (one DMT call = 1 unit), the amount the frame
-- slicing and the time estimates count; they do not depend on this VM's speed.
-- Seconds are fengari's (about 20 times the game's) and only the ratio between
-- the two radii means anything.
--
-- The fake DMT does not check that districts stay within three rings, so a
-- four-ring plan here would be illegal in the game: this measures work, never
-- quality.
--
--   node tools/offline_tests.mjs -v tests/offline/bench_radius.lua
-- Environment: SDP_BENCH_SEEDS ("11,23"), SDP_BENCH_TIERS (multi tier, FAST).
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
include("SDP_Wonders")
include("SDP_Multi")
include("SDP_Sites")
include("SDP_SiteSolver")

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local PLAN = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_GOVERNMENT" }
local SETS = {
  k4 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" },
  k6 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
    "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_AQUEDUCT" },
  k8 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
    "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_AQUEDUCT", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_GOVERNMENT" },
}
local SEEDS = {}
for seed in (os.getenv("SDP_BENCH_SEEDS") or "11"):gmatch("%d+") do SEEDS[#SEEDS + 1] = tonumber(seed) end
local MULTI_TIER = os.getenv("SDP_BENCH_TIERS") or "FAST"

-- Units of a finished solve, as SDP_Tiers counts them.
local function UnitsOf(result)
  local s = result.Stats
  return s.Calls + (s.Evaluations or 0) * SDP_Tiers.UNITS_PER_TRY + (s.Nodes or 0) / SDP_Tiers.NODES_PER_UNIT
end

-- Count SDP_Land.PlotValues calls between StartCount() and StopCount().
local m_plotValues, m_realPlotValues = 0, nil
local function StartCount()
  if m_realPlotValues == nil then m_realPlotValues = SDP_Land.PlotValues end
  m_plotValues = 0
  SDP_Land.PlotValues = function(...)
    m_plotValues = m_plotValues + 1
    return m_realPlotValues(...)
  end
end
local function StopCount()
  if m_realPlotValues ~= nil then SDP_Land.PlotValues = m_realPlotValues end
  return m_plotValues
end

local function Measure(label, radius, world, solve)
  SDP_City.RADIUS = radius
  if SDP_Overlay.ResetEngine ~= nil then SDP_Overlay.ResetEngine() end
  world:ResetCalls()
  local t0 = os.clock()
  local result = solve()
  local seconds = os.clock() - t0
  T.ok(result.Ok, tostring(result.Error))
  local run = { Label = label, Radius = radius, Seconds = seconds, Units = UnitsOf(result),
    Calls = result.Stats.Calls or 0, Tries = result.Stats.Tries or 0, Nodes = result.Stats.Nodes or 0,
    Gain = result.Gain or 0, Truncated = result.Stats.Truncated }
  print(string.format("  %-24s r=%d  calls %6.0f  tries %7.0f  nodes %8.0f  units %8.0f  vm %7.2fs  gain %6.2f%s",
    label, radius, run.Calls, run.Tries, run.Nodes, run.Units, seconds, run.Gain, run.Truncated and "  TRUNCATED" or ""))
  return run
end

-- One world per radius, then the same solve. `makeWorld` builds the world,
-- `solve` is the solve function itself.
local function Pair(label, makeWorld, solve, radii)
  local rows = {}
  for _, radius in ipairs(radii or { 3, 4 }) do
    local world = makeWorld()
    rows[#rows + 1] = Measure(label, radius, world, solve)
  end
  local a, b = rows[1], rows[2]
  print(string.format("    %-24s units x%.2f  vm x%.2f", label,
    b.Units / math.max(a.Units, 1), b.Seconds / math.max(a.Seconds, 0.001)))
  return rows
end

-- One city with the capital in the middle of a random 15 x 13 map.
local function SingleWorld(seed)
  local spec = World.RandomSpec(seed, 15, 13)
  local cx, cy = 7, 6
  local row = spec.rows[cy + 1]
  spec.rows[cy + 1] = row:sub(1, cx) .. "." .. row:sub(cx + 2)
  spec.cities = { { id = 1, x = cx, y = cy, population = 10, capital = true, radius = 3 } }
  return World.New(spec)
end

local function SingleSolve(districts, tier)
  return function()
    return SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Tier = tier, Land = true })
  end
end

-- The capital and city-center pins, as bench_multi.lua.
local SITES = { { 10, 4 }, { 10, 10 }, { 15, 7 } }
local CAPITAL = { 5, 7 }

local function MultiWorld(seed, pins)
  local spec = World.RandomSpec(seed, 21, 15)
  local function Land(x, y)
    local row = spec.rows[y + 1]
    spec.rows[y + 1] = row:sub(1, x) .. "." .. row:sub(x + 2)
  end
  Land(CAPITAL[1], CAPITAL[2])
  for n = 1, pins do Land(SITES[n][1], SITES[n][2]) end
  spec.cities = { { id = 1, x = CAPITAL[1], y = CAPITAL[2], population = 8, capital = true, radius = 2 } }
  spec.pins = {}
  for n = 1, pins do spec.pins[n] = { SITES[n][1], SITES[n][2], "ICON_DISTRICT_CITY_CENTER", "site " .. n } end
  return World.New(spec)
end

local function MultiSolve(tier)
  return function()
    return SDP_Multi.Solve({ PlayerID = 0, Tier = tier, Weights = ONES, Districts = PLAN, Land = true })
  end
end

test("land model cost", function()
  print("land model (one city, SDP_Land.ForScan)")
  local rows = {}
  for _, radius in ipairs({ 3, 4 }) do
    local world = SingleWorld(SEEDS[1])
    SDP_City.RADIUS = radius
    local scan = SDP_City.Scan(0, 1)
    local workable = SDP_Land.Workable(scan)
    local rounds = 50
    StartCount()
    local t0 = os.clock()
    local model
    for _ = 1, rounds do model = SDP_Land.ForScan(scan, {}, ONES, 10) end
    local seconds = (os.clock() - t0) / rounds
    local calls = StopCount() / rounds
    local perPlot = seconds / math.max(#workable, 1)
    rows[#rows + 1] = { Radius = radius, Candidates = #scan.Candidates, Workable = #workable,
      Plots = #model.Plots, Seconds = seconds, PlotValues = calls, PerPlot = perPlot }
    print(string.format("  land model  r=%d  candidates %3d  workable %3d  plots %3d  PlotValues %5.1f  vm %6.3fs  per plot %6.4fs",
      radius, #scan.Candidates, #workable, #model.Plots, calls, seconds, perPlot))
  end
  local three, four = rows[1], rows[2]
  print(string.format("    candidates x%.2f  workable x%.2f  per plot x%.2f", four.Candidates / three.Candidates,
    four.Workable / math.max(three.Workable, 1), four.PerPlot / math.max(three.PerPlot, 1e-9)))
  -- Districts stay inside three rings: the fourth ring only adds workable plots.
  print(string.format("    land only (36 -> 60 plots, no district moves) x%.2f of the r=3 model",
    (three.Seconds + 24 * four.PerPlot) / math.max(three.Seconds, 1e-9)))
  SDP_City.RADIUS = 3
end)

test("site coarse scores cost", function()
  print("site coarse score (SDP_Sites.Coarse, the sites page's unit)")
  local rows = {}
  for _, radius in ipairs({ 3, 4 }) do
    local spec = World.RandomSpec(7, 24, 16)
    local function Land(x, y)
      local row = spec.rows[y + 1]
      spec.rows[y + 1] = row:sub(1, x) .. "." .. row:sub(x + 2)
    end
    Land(4, 8)
    spec.cities = { { id = 1, x = 4, y = 8, population = 6, capital = true, radius = 2 } }
    World.New(spec)
    SDP_City.RADIUS = radius
    local list, centers = SDP_Sites.Candidates(0, { K = 3, D = 5 })
    local ctx = SDP_Sites.Context(0, { PlayerID = 0, K = 3, D = 5, Districts = PLAN }, 3)
    local sample = math.min(#list, 20)
    local t0 = os.clock()
    for n = 1, sample do SDP_Sites.Coarse(ctx, list[n], centers) end
    local seconds = os.clock() - t0
    rows[#rows + 1] = { Radius = radius, Candidates = #list, Seconds = seconds,
      PerSite = seconds / math.max(sample, 1) }
    print(string.format("  coarse      r=%d  candidate sites %4d  sample %2d  vm %6.3fs  per site %6.4fs",
      radius, #list, sample, seconds, seconds / math.max(sample, 1)))
  end
  local three, four = rows[1], rows[2]
  print(string.format("    candidates x%.2f  per site x%.2f", four.Candidates / three.Candidates,
    four.PerSite / math.max(three.PerSite, 1e-9)))
  SDP_City.RADIUS = 3
end)

for _, setName in ipairs({ "k4", "k6", "k8" }) do
  test("single " .. setName .. " STANDARD", function()
    for _, seed in ipairs(SEEDS) do
      print(string.format("single %s STANDARD seed %d", setName, seed))
      Pair(string.format("%s STANDARD s%d", setName, seed),
        function() return SingleWorld(seed) end,
        SingleSolve(SETS[setName], "STANDARD"))
    end
    SDP_City.RADIUS = 3
  end)
end

for _, pins in ipairs({ 2, 3 }) do
  test(string.format("multi %d cities %s", pins + 1, MULTI_TIER), function()
    for _, seed in ipairs(SEEDS) do
      print(string.format("multi %d cities %s seed %d", pins + 1, MULTI_TIER, seed))
      Pair(string.format("%d cities %s s%d", pins + 1, MULTI_TIER:sub(1, 4), seed),
        function() return MultiWorld(seed, pins) end,
        MultiSolve(MULTI_TIER))
    end
    SDP_City.RADIUS = 3
  end)
end
