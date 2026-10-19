-- Offline benchmark of the single-city solver: quality against a reference
-- and cost, per tier, on deterministic random maps. "est" is the expected
-- time in the game: 2 us per model search node (measured on macOS), and
-- about 70 us per DMT call and per evaluated layout (estimates from the
-- measured joint evaluation and this VM's cost of a layout evaluation).
--   node tools/offline_tests.mjs -v tests/offline/bench_single.lua [-k k4]
-- Reference: exhaustive search (k <= 3 and k = 4 when affordable) or the best
-- of a long simulated annealing run and the FINE tier with every continue.
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

local SETS = {
  k3 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" },
  k4 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" },
  k6 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
    "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_AQUEDUCT" },
  k8 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
    "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_AQUEDUCT", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_GOVERNMENT" },
}
local SEEDS = { 11, 23, 37, 41, 59, 61 }
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- A random map with the capital in the middle; even seeds also get a built
-- built encampment two plots east (a fixed neighbour).
local function Scenario(seed)
  local spec = World.RandomSpec(seed, 15, 13)
  local cx, cy = 7, 6
  local row = spec.rows[cy + 1]
  spec.rows[cy + 1] = row:sub(1, cx) .. "." .. row:sub(cx + 2)
  spec.cities = { { id = 1, x = cx, y = cy, population = 10, capital = true, radius = 3 } }
  local w = World.New(spec)
  if seed % 2 == 0 then
    -- A built district two plots away, if the plot allows it.
    local plot = w:Plot(cx + 2, cy)
    if not plot:IsMountain() and not plot:IsWater() then w:AddDistrict(1, "DISTRICT_ENCAMPMENT", cx + 2, cy) end
  end
  return w
end

local function Request(districts, tier, params, land)
  return { PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Tier = tier, Params = params, Land = land }
end

-- Simulated annealing on exact values (deterministic random numbers), from
-- `start` (candidate positions per district).
local function Anneal(session, start, iterations, seed)
  local rng = World.Rng(seed)
  local k, n, legal = session.K, session.N, session.Legal
  local layout = { unpack(start) }
  local current = session:Evaluate(layout)
  local best = current
  for it = 1, iterations do
    local temperature = 3 * (1 - it / iterations) + 0.05
    local trial = { unpack(layout) }
    if k >= 2 and rng() < 0.3 then
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
      if not legal[m][trial[m]] then ok = false end
    end
    if ok then
      local g, isLegal = session:Evaluate(trial)
      if isLegal and (g >= current or rng() < math.exp((g - current) / temperature)) then
        layout, current = trial, g
        if g > best then best = g end
      end
    end
  end
  return best
end

-- A legal layout from random numbers (or nil).
local function RandomLayout(session, rng)
  for _ = 1, 200 do
    local layout, used, ok = {}, {}, true
    for m = 1, session.K do
      local i = rng(session.N)
      if used[i] or not session.Legal[m][i] then ok = false break end
      used[i], layout[m] = true, i
    end
    if ok then return layout end
  end
  return nil
end

-- References are slow to compute: SDP_BENCH_REFS names a file that keeps
-- them between runs (a Lua chunk returning { [key] = gain }).
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
  for _, k in ipairs(keys) do lines[#lines + 1] = string.format("  [%q] = { %.17g, %q },", k, refs[k][1], refs[k][2]) end
  lines[#lines + 1] = "}"
  sdp_write_file(REFS_FILE, table.concat(lines, "\n"))
end

-- SDP_BENCH_PARAMS overrides tier parameters, e.g.
-- "STANDARD.NodeLimit=60000,STANDARD.Swap=false".
local OVERRIDES = {}
for tier, key, value in (os.getenv("SDP_BENCH_PARAMS") or ""):gmatch("(%u+)%.(%w+)=([%w%.]+)") do
  OVERRIDES[tier] = OVERRIDES[tier] or {}
  if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end
  OVERRIDES[tier][key] = value
end

-- SDP_BENCH_TIERS limits the tiers run, e.g. "FAST,STANDARD".
local TIERS = {}
for tier in (os.getenv("SDP_BENCH_TIERS") or "FAST,STANDARD,FINE"):gmatch("%u+") do TIERS[#TIERS + 1] = tier end

local function ComputeReference(districts, land)
  if #districts <= 3 then
    local exact = SDP_Solver.Solve(Request(districts, "FINE", { ExactLimit = 60000, CallLimit = 10 ^ 9, TryLimit = 10 ^ 9 }, land))
    if exact.Quality.Exhaustive then return exact.Gain, "exact" end
  end
  local fine = SDP_Solver.Solve(Request(districts, "FINE", nil, land))
  for _ = 1, 3 do fine = SDP_Solver.Continue(fine) end
  local best = fine.Gain
  local scan = SDP_City.Scan(0, 1)
  local annealed = SDP_Overlay.With(0, function()
    local session = SDP_Solver.NewSession(Request(districts, "FINE", nil, land), scan).Search
    local starts = { {} }
    for m, p in ipairs(fine.Plan) do
      for i, c in ipairs(session.Candidates) do
        if c.Index == p.Index then starts[1][m] = i end
      end
    end
    local rng = World.Rng(97)
    starts[2], starts[3] = RandomLayout(session, rng), RandomLayout(session, rng)
    local a = -math.huge
    for r, start in ipairs(starts) do
      if start ~= nil then a = math.max(a, Anneal(session, start, 15000, 1000 + r)) end
    end
    session.Board:Clear()
    return a
  end)
  if annealed > best then best = annealed end
  return best, "best known"
end

local function Reference(districts, land, seed)
  local key = table.concat(districts, "+") .. (land and "/land" or "") .. "/" .. seed
  if refs[key] == nil then
    local gain, kind = ComputeReference(districts, land)
    refs[key] = { gain, kind }
    SaveRefs()
  end
  return refs[key][1], refs[key][2]
end

local function Run(name, setName, land)
  local districts = SETS[setName]
  local rows = {}
  local sums = {}
  for _, seed in ipairs(SEEDS) do
    local world = Scenario(seed)
    local ref, kind = Reference(districts, land, seed)
    local line = string.format("seed %3d  ref %6.2f (%s)", seed, ref, kind)
    for _, tier in ipairs(TIERS) do
      world:ResetCalls()
      local t0 = os.clock()
      local result = SDP_Solver.Solve(Request(districts, tier, OVERRIDES[tier], land))
      local seconds = os.clock() - t0
      T.ok(result.Ok, tostring(result.Error))
      T.ok(not result.Stats.Mismatch, "board and full evaluation disagree")
      if result.Gain > ref + 1e-9 then
        print(string.format("  note: %s beat the reference on seed %d (%.2f > %.2f); reference updated", tier, seed, result.Gain, ref))
        refs[table.concat(districts, "+") .. (land and "/land" or "") .. "/" .. seed] = { result.Gain, "best known" }
        SaveRefs()
        ref = result.Gain
      end
      local ratio = ref > 0 and result.Gain / ref or (result.Gain >= ref and 1 or 0)
      local s = sums[tier] or { ratio = 0, worst = 1, calls = 0, tries = 0, nodes = 0, n = 0, opt = 0, seconds = 0 }
      s.seconds = s.seconds + seconds
      s.ratio, s.n = s.ratio + ratio, s.n + 1
      s.worst = math.min(s.worst, ratio)
      s.calls, s.tries, s.nodes = s.calls + result.Stats.Calls, s.tries + result.Stats.Tries, s.nodes + result.Stats.Nodes
      if result.Gain >= ref - 1e-9 then s.opt = s.opt + 1 end
      sums[tier] = s
      local ms = result.Stats.Nodes * 0.002 + result.Stats.Evaluations * 0.07 + result.Stats.Calls * 0.07
      s.ms = (s.ms or 0) + ms
      line = line .. string.format("  %s %6.2f %4.0f%% %5.0fms", tier:sub(1, 4), result.Gain, ratio * 100, ms)
    end
    rows[#rows + 1] = line
  end
  print(name)
  for _, line in ipairs(rows) do print(line) end
  for _, tier in ipairs(TIERS) do
    local s = sums[tier]
    print(string.format("  %-8s avg %5.1f%%  worst %5.1f%%  optimal %d/%d  est %5.0fms  calls %6.0f  tries %7.0f  nodes %8.0f  vm %.2fs",
      tier, 100 * s.ratio / s.n, 100 * s.worst, s.opt, s.n, s.ms / s.n, s.calls / s.n, s.tries / s.n, s.nodes / s.n, s.seconds / s.n))
  end
end

for _, setName in ipairs({ "k3", "k4", "k6", "k8" }) do
  test(setName .. " adjacency", function() Run(setName .. " adjacency only", setName, false) end)
  test(setName .. " land", function() Run(setName .. " with land part", setName, true) end)
end
