-- Offline benchmark of picking districts per city on the multi-city tab
-- (feedback item 11): the capital and three city-center pins of
-- bench_multi.lua, every city required to build a campus and to pick two
-- more from a pool of five.
--   node tools/offline_tests.mjs -v tests/offline/bench_multipools.lua
-- Two references:
--   alone   each city's best combination found on its own (the single-city
--           solver, FINE, with only that city's plots), then those lists
--           solved jointly without picking: what a player gets by deciding
--           per city first
--   best    the best value any tier, FINE with two continues, or "alone"
--           reached (SDP_BENCH_REFS keeps it between runs)
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Search")
include("SDP_Remind")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

local REQUIRED = { "DISTRICT_CAMPUS" }
local POOL = { "DISTRICT_COMMERCIAL_HUB", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_HOLY_SITE", "DISTRICT_INDUSTRIAL_ZONE",
  "DISTRICT_THEATER" }
local COUNT = 3
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local SEEDS = {}
for seed in (os.getenv("SDP_BENCH_SEEDS") or "11,23,37"):gmatch("%d+") do SEEDS[#SEEDS + 1] = tonumber(seed) end
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

local TIERS = {}
for tier in (os.getenv("SDP_BENCH_TIERS") or "FAST,STANDARD,FINE"):gmatch("%u+") do TIERS[#TIERS + 1] = tier end

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

local function Request(tier, extra)
  local r = { PlayerID = 0, Tier = tier, Weights = ONES, Districts = REQUIRED, Pool = POOL, Count = COUNT, Land = true }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

-- Each city's own best combination (single-city search over a combination
-- pool), then every list solved jointly at STANDARD without picking.
local function Alone()
  local plans = {}
  local all = SDP_Multi.Participants(0)
  for _, part in ipairs(all) do
    -- Only this city takes part: the other sites switched off, the capital
    -- only when it is the one.
    local sites = {}
    for _, other in ipairs(all) do
      if other.Kind == "SITE" and other.Key ~= part.Key then sites[other.Key] = false end
    end
    local only = SDP_Multi.Solve({ PlayerID = 0, Tier = "FINE", Weights = ONES, Districts = REQUIRED, Pool = POOL, Count = COUNT,
      Land = true, Existing = { [1] = part.Kind == "CITY" }, Sites = sites })
    local types = {}
    for _, p in ipairs(only.Plan or {}) do types[#types + 1] = p.Type end
    plans[part.Key] = types
  end
  local joint = SDP_Multi.Solve({ PlayerID = 0, Tier = "STANDARD", Weights = ONES, Districts = REQUIRED, Plans = plans, Land = true })
  return joint.Gain
end

local function Run()
  local rows, sums = {}, {}
  for _, seed in ipairs(SEEDS) do
    local world = Scenario(seed)
    local alone = Alone()
    local key = "multipools/" .. seed
    local ref = refs[key]
    if ref == nil then
      local fine = SDP_Multi.Solve(Request("FINE"))
      fine = SDP_Multi.Continue(SDP_Multi.Continue(fine))
      ref = math.max(fine.Gain, alone)
      refs[key] = ref
      SaveRefs()
    end
    ref = math.max(ref, alone)
    local line = string.format("seed %3d  ref %6.2f  alone %6.2f (%3.0f%%)", seed, ref, alone, 100 * alone / ref)
    for _, tier in ipairs(TIERS) do
      world:ResetCalls()
      local result = SDP_Multi.Solve(Request(tier))
      T.ok(result.Ok, tostring(result.Error))
      T.ok(not result.Stats.Mismatch, "board and full evaluation disagree")
      if result.Gain > ref + 1e-9 then
        refs[key] = result.Gain
        SaveRefs()
        ref = result.Gain
      end
      local ms = (result.Stats.Calls + result.Stats.Evaluations * SDP_Tiers.UNITS_PER_TRY
        + result.Stats.Nodes / SDP_Tiers.NODES_PER_UNIT) * 0.05
      local ratio = result.Gain / ref
      local s = sums[tier] or { ratio = 0, worst = 1, n = 0, ms = 0, beatAlone = 0 }
      s.ratio, s.n, s.worst, s.ms = s.ratio + ratio, s.n + 1, math.min(s.worst, ratio), s.ms + ms
      if result.Gain >= alone - 1e-9 then s.beatAlone = s.beatAlone + 1 end
      sums[tier] = s
      line = line .. string.format("  %s %6.2f %4.0f%% %6.0fms", tier:sub(1, 4), result.Gain, ratio * 100, ms)
    end
    rows[#rows + 1] = line
  end
  print("4 cities, each a campus + 2 of 5 (land part on)")
  for _, line in ipairs(rows) do print(line) end
  for _, tier in ipairs(TIERS) do
    local s = sums[tier]
    print(string.format("  %-8s avg %5.1f%%  worst %5.1f%%  >= alone %d/%d  est %6.0fms", tier, 100 * s.ratio / s.n,
      100 * s.worst, s.beatAlone, s.n, s.ms / s.n))
  end
end

test("multi pools", function() Run() end)
