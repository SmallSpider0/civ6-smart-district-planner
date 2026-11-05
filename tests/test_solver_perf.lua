-- @state SDP_Panel
-- @timeout 30
-- @max_seconds_each 2.5
-- Acceptance: 3 and 4 districts solve without freezing the game (stall <= ~2 s).
-- Guard: even eight districts (beyond the 3-4 in the acceptance list) must not
-- freeze the game; the solver's budgets keep the stall around 2 s.
-- Each test runs in its own exec and is timed on its own (run_tests.py
-- @max_seconds_each), as the three files they came from were (#302).
local test, T = ...

local pid = Game.GetLocalPlayer()
local BASES = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" }

local function capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

-- The first n of BASES, each replaced by the civilization's unique district when it has one.
local function basic(n)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  local districts = {}
  for i = 1, n do
    local base = BASES[i]
    for row in GameInfo.DistrictReplaces() do
      if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then base = row.CivUniqueDistrictType end
    end
    districts[i] = base
  end
  return districts
end

local function solve_basic(n)
  local city = capital()
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = basic(n) })
  T.ok(result.Ok, "solve failed: " .. tostring(result.Error))
  T.eq(#result.Plan, n, "plan size")
  print(string.format("%d: gain %s via %s: %d layouts counted, %d nodes, %d DMT calls, truncated %s", n,
    tostring(result.Gain), result.Stats.Method, result.Stats.Layouts, result.Stats.Nodes,
    result.Stats.Calls, tostring(result.Stats.Truncated)))
end

-- Names are literals: run_tests.py reads them to run each test on its own.
test("solve 3 districts", function() solve_basic(3) end)
test("solve 4 districts", function() solve_basic(4) end)

test("solve eight districts within the budgets", function()
  local city = capital()
  local districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #districts < 8 then districts[#districts + 1] = d.Type end
  end
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = districts, Land = true })
  local params = SDP_Tiers.Params(SDP_Tiers.Single, "STANDARD")
  T.ok(result.Ok, "solve failed: " .. tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "incremental and full evaluation disagree")
  T.ok(result.Stats.Nodes <= params.NodeLimit + 1, "node budget exceeded")
  -- The call budget is checked between evaluations; one evaluation adds at most ~20 calls.
  T.ok(result.Stats.Calls <= params.CallLimit + 100, "DMT call budget exceeded")
  print(string.format("placed %d, unplaced %d, gain %s via %s: %d nodes, %d DMT calls, %d tries, truncated %s",
    #result.Plan, #result.Unplaced, tostring(result.Gain), result.Stats.Method, result.Stats.Nodes,
    result.Stats.Calls, result.Stats.Tries, tostring(result.Stats.Truncated)))
end)
