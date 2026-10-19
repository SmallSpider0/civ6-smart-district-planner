-- @state SDP_Panel
-- @timeout 30
-- @max_seconds 2.5
-- Guard: even eight districts (beyond the 3-4 in the acceptance list) must not
-- freeze the game; the solver's budgets keep the stall around 2 s.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("solve eight districts within the budgets", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
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
