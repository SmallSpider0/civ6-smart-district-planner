-- Offline benchmark of picking districts from a pool (single city): quality
-- against the best of every combination solved on its own, and cost, per
-- tier, on the random maps of bench_single.lua.
--   node tools/offline_tests.mjs -v tests/offline/bench_pools.lua [-k p1]
-- Reference: each combination solved with the STANDARD tier and every
-- continue (exhaustive when small), the best of them. SDP_BENCH_REFS keeps
-- references between runs, SDP_BENCH_TIERS / SDP_BENCH_PARAMS as there.
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

local POOL = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_ENCAMPMENT", "DISTRICT_ENTERTAINMENT_COMPLEX",
  "DISTRICT_HOLY_SITE", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_THEATER" }
local CASES = {
  p1 = { Required = {}, Count = 3 },                                                       -- 3 of 7: 35 combinations
  p2 = { Required = { "DISTRICT_CAMPUS" }, Count = 4 },                                    -- 3 of 6: 20
  p3 = { Required = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_AQUEDUCT" }, Count = 5 }, -- 3 of 5: 10
  p4 = { Required = {}, Count = 5 },                                                       -- 5 of 7: 21
}
local SEEDS = { 11, 23, 37, 41 }
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function Scenario(seed)
  local spec = World.RandomSpec(seed, 15, 13)
  local cx, cy = 7, 6
  local row = spec.rows[cy + 1]
  spec.rows[cy + 1] = row:sub(1, cx) .. "." .. row:sub(cx + 2)
  spec.cities = { { id = 1, x = cx, y = cy, population = 10, capital = true, radius = 3 } }
  return World.New(spec)
end

local OVERRIDES = {}
for tier, key, value in (os.getenv("SDP_BENCH_PARAMS") or ""):gmatch("(%u+)%.(%w+)=([%w%.]+)") do
  OVERRIDES[tier] = OVERRIDES[tier] or {}
  if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end
  OVERRIDES[tier][key] = value
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
  for _, k in ipairs(keys) do lines[#lines + 1] = string.format("  [%q] = { %.17g, %q },", k, refs[k][1], refs[k][2]) end
  lines[#lines + 1] = "}"
  sdp_write_file(REFS_FILE, table.concat(lines, "\n"))
end

-- Every combination of `pick` pool districts.
local function Combinations(pool, pick)
  local out, chosen = {}, {}
  local function Walk(start, depth)
    if depth > pick then
      local c = {}
      for i, v in ipairs(chosen) do c[i] = v end
      out[#out + 1] = c
      return
    end
    for i = start, #pool - (pick - depth) do
      chosen[depth] = pool[i]
      Walk(i + 1, depth + 1)
      chosen[depth] = nil
    end
  end
  Walk(1, 1)
  return out
end

local function Reference(case, seed)
  local key = table.concat(case.Required, "+") .. "/" .. case.Count .. "/" .. seed
  if refs[key] ~= nil then return refs[key][1], refs[key][2] end
  local pool = {}
  local required = {}
  for _, t in ipairs(case.Required) do required[t] = true end
  for _, t in ipairs(POOL) do
    if not required[t] then pool[#pool + 1] = t end
  end
  local specialty = 0
  for _, t in ipairs(case.Required) do
    if t ~= "DISTRICT_AQUEDUCT" then specialty = specialty + 1 end
  end
  local best, bestCombo = -math.huge, ""
  for _, combo in ipairs(Combinations(pool, case.Count - specialty)) do
    local districts = {}
    for _, t in ipairs(case.Required) do districts[#districts + 1] = t end
    for _, t in ipairs(combo) do districts[#districts + 1] = t end
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = districts, Weights = ONES, Tier = "STANDARD" })
    for _ = 1, 3 do r = SDP_Solver.Continue(r) end
    if r.Ok and r.Gain > best then best, bestCombo = r.Gain, table.concat(combo, "+") end
  end
  refs[key] = { best, bestCombo }
  SaveRefs()
  return best, bestCombo
end

local function Run(name)
  local case = CASES[name]
  local sums, rows = {}, {}
  for _, seed in ipairs(SEEDS) do
    local world = Scenario(seed)
    local ref = Reference(case, seed)
    local line = string.format("seed %3d  ref %6.2f", seed, ref)
    for _, tier in ipairs(TIERS) do
      world:ResetCalls()
      local t0 = os.clock()
      local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = case.Required, Pool = POOL, Count = case.Count,
        Weights = ONES, Tier = tier, Params = OVERRIDES[tier] })
      local seconds = os.clock() - t0
      T.ok(result.Ok, tostring(result.Error))
      T.ok(not result.Stats.Mismatch, "board and full evaluation disagree")
      if result.Gain > ref + 1e-9 then
        print(string.format("  note: %s beat the reference on seed %d (%.2f > %.2f)", tier, seed, result.Gain, ref))
        ref = result.Gain
      end
      local ratio = ref > 0 and result.Gain / ref or (result.Gain >= ref and 1 or 0)
      local ms = (result.Stats.Calls + result.Stats.Evaluations * SDP_Tiers.UNITS_PER_TRY
        + result.Stats.Nodes / SDP_Tiers.NODES_PER_UNIT) * 0.05
      local s = sums[tier] or { ratio = 0, worst = 1, n = 0, opt = 0, ms = 0, seconds = 0, sol = 0 }
      s.ratio, s.n, s.worst = s.ratio + ratio, s.n + 1, math.min(s.worst, ratio)
      if result.Gain >= ref - 1e-9 then s.opt = s.opt + 1 end
      s.ms, s.seconds, s.sol = s.ms + ms, s.seconds + seconds, s.sol + #result.Solutions
      sums[tier] = s
      line = line .. string.format("  %s %6.2f %4.0f%% %5.0fms", tier:sub(1, 4), result.Gain, ratio * 100, ms)
    end
    rows[#rows + 1] = line
  end
  print(name .. string.format(" (required %d, count %d)", #case.Required, case.Count))
  for _, line in ipairs(rows) do print(line) end
  for _, tier in ipairs(TIERS) do
    local s = sums[tier]
    print(string.format("  %-8s avg %5.1f%%  worst %5.1f%%  best combination %d/%d  est %5.0fms  solutions %.1f  vm %.2fs",
      tier, 100 * s.ratio / s.n, 100 * s.worst, s.opt, s.n, s.ms / s.n, s.sol / s.n, s.seconds / s.n))
  end
end

for _, name in ipairs({ "p1", "p2", "p3", "p4" }) do
  test(name, function() Run(name) end)
end
