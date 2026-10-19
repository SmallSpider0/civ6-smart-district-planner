-- Offline benchmark of the multi-city solver (SDP_Multi): quality against a
-- reference and expected time in the game (run at once, as bench_single.lua),
-- per tier, on deterministic random maps with the capital and three
-- city-center pins. A task over several frames takes about 2.5 times as long.
--   node tools/offline_tests.mjs -v tests/offline/bench_multi.lua [-k land]
-- Environment: SDP_BENCH_REFS (reference cache file), SDP_BENCH_TIERS,
-- SDP_BENCH_PARAMS (as bench_single.lua), SDP_BENCH_SEEDS ("1,2,3").
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

local PLAN = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_GOVERNMENT" }
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local SEEDS = {}
for seed in (os.getenv("SDP_BENCH_SEEDS") or "11,23,37,41"):gmatch("%d+") do SEEDS[#SEEDS + 1] = tonumber(seed) end

local SITES = { { 10, 4 }, { 10, 10 }, { 15, 7 } }
local CAPITAL = { 5, 7 }

local function Scenario(seed)
  local spec = World.RandomSpec(seed, 21, 15)
  local function Land(x, y)
    local row = spec.rows[y + 1]
    spec.rows[y + 1] = row:sub(1, x) .. "." .. row:sub(x + 2)
  end
  Land(CAPITAL[1], CAPITAL[2])
  for _, s in ipairs(SITES) do Land(s[1], s[2]) end
  spec.cities = { { id = 1, x = CAPITAL[1], y = CAPITAL[2], population = 8, capital = true, radius = 2 } }
  spec.pins = {}
  for n, s in ipairs(SITES) do spec.pins[n] = { s[1], s[2], "ICON_DISTRICT_CITY_CENTER", "site " .. n } end
  return World.New(spec)
end

local function Request(tier, params, land)
  return { PlayerID = 0, Tier = tier, Params = params, Weights = ONES, Districts = PLAN, Land = land }
end

local REFS_FILE = os.getenv("SDP_BENCH_REFS")
local refs = {}
if REFS_FILE then
  local chunk = sdp_read_file(REFS_FILE)
  if chunk then refs = loadstring(chunk)() or {} end
end
local function SaveRefs()
  if not REFS_FILE then return end
  local keys = {}
  for k in pairs(refs) do keys[#keys + 1] = k end
  table.sort(keys)
  local lines = { "return {" }
  for _, k in ipairs(keys) do lines[#lines + 1] = string.format("  [%q] = %.17g,", k, refs[k]) end
  lines[#lines + 1] = "}"
  sdp_write_file(REFS_FILE, table.concat(lines, "\n"))
end

local OVERRIDES = {}
for tier, key, value in (os.getenv("SDP_BENCH_PARAMS") or ""):gmatch("(%u+)%.(%w+)=([%w%.]+)") do
  OVERRIDES[tier] = OVERRIDES[tier] or {}
  if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end
  OVERRIDES[tier][key] = value
end
local TIERS = {}
for tier in (os.getenv("SDP_BENCH_TIERS") or "FAST,STANDARD,FINE"):gmatch("%u+") do TIERS[#TIERS + 1] = tier end

-- Simulated annealing on the session's exact values (fixed pseudo-random
-- sequence, test code only).
local function Anneal(search, start, iterations, seed)
  local rng = World.Rng(seed)
  local k, n, legal = search.K, search.N, search.Legal
  local layout = { unpack(start) }
  local current = search:Evaluate(layout)
  local best = current
  for it = 1, iterations do
    local temperature = 3 * (1 - it / iterations) + 0.05
    local trial = { unpack(layout) }
    if rng() < 0.3 then
      local a, b = rng(k), rng(k)
      trial[a], trial[b] = trial[b], trial[a]
    else
      local m, i = rng(k), rng(n)
      local used = false
      for mm = 1, k do
        if trial[mm] == i then used = true end
      end
      if not used then trial[m] = i end
    end
    local ok = true
    for m = 1, k do
      if trial[m] == 0 or not legal[m][trial[m]] then ok = false end
    end
    if ok then
      local g, isLegal = search:Evaluate(trial)
      if isLegal and (g >= current or rng() < math.exp((g - current) / temperature)) then
        layout, current = trial, g
        if g > best then best = g end
      end
    end
  end
  return best
end

local function Reference(seed, land)
  local key = "multi/" .. (land and "land/" or "") .. seed
  if refs[key] ~= nil then return refs[key] end
  local fine = SDP_Multi.Solve(Request("FINE", nil, land))
  fine = SDP_Multi.Continue(fine)
  local best = fine.Gain
  local session = fine.Session
  local annealed = SDP_Overlay.With(0, function()
    local search = session.Search
    local start = {}
    for m = 1, search.K do start[m] = search.BestLayout[m] end
    local a = Anneal(search, start, 20000, 5)
    search.Board:Clear()
    return a
  end)
  best = math.max(best, annealed)
  refs[key] = best
  SaveRefs()
  return best
end

local function Run(name, land)
  local sums, rows = {}, {}
  for _, seed in ipairs(SEEDS) do
    local world = Scenario(seed)
    local ref = Reference(seed, land)
    local line = string.format("seed %3d  ref %6.2f", seed, ref)
    for _, tier in ipairs(TIERS) do
      world:ResetCalls()
      local t0 = os.clock()
      local result = SDP_Multi.Solve(Request(tier, OVERRIDES[tier], land))
      local seconds = os.clock() - t0
      T.ok(result.Ok, tostring(result.Error))
      T.ok(not result.Stats.Mismatch, "board and full evaluation disagree")
      T.ok(result.Gain >= result.FirstGain - 1e-9, "worse than city by city")
      if result.Gain > ref + 1e-9 then
        refs["multi/" .. (land and "land/" or "") .. seed] = result.Gain
        SaveRefs()
        ref = result.Gain
      end
      local ratio = ref > 0 and result.Gain / ref or 1
      -- SDP_Tiers units at about 0.05 ms each when run at once (measured in the game)
      local ms = (result.Stats.Calls + result.Stats.Evaluations * SDP_Tiers.UNITS_PER_TRY
        + result.Stats.Nodes / SDP_Tiers.NODES_PER_UNIT) * 0.05
      local s = sums[tier] or { ratio = 0, worst = 1, n = 0, ms = 0, calls = 0, evals = 0, seconds = 0, first = 0 }
      s.ratio, s.n, s.ms = s.ratio + ratio, s.n + 1, s.ms + ms
      s.worst = math.min(s.worst, ratio)
      s.calls, s.evals, s.seconds = s.calls + result.Stats.Calls, s.evals + result.Stats.Evaluations, s.seconds + seconds
      s.first = s.first + (ref > 0 and result.FirstGain / ref or 1)
      sums[tier] = s
      line = line .. string.format("  %s %6.2f %4.0f%% %6.0fms", tier:sub(1, 4), result.Gain, ratio * 100, ms)
    end
    rows[#rows + 1] = line
  end
  print(name)
  for _, line in ipairs(rows) do print(line) end
  for _, tier in ipairs(TIERS) do
    local s = sums[tier]
    print(string.format("  %-8s avg %5.1f%%  worst %5.1f%%  city-by-city %5.1f%%  est %6.0fms  calls %7.0f  evaluations %7.0f  vm %.1fs",
      tier, 100 * s.ratio / s.n, 100 * s.worst, 100 * s.first / s.n, s.ms / s.n, s.calls / s.n, s.evals / s.n, s.seconds / s.n))
  end
end

test("multi adjacency", function() Run("4 cities x 5-6 districts, adjacency only", false) end)
test("multi land", function() Run("4 cities x 5-6 districts, with land part", true) end)
