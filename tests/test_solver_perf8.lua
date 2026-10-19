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
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = districts })
  T.ok(result.Ok, "solve failed: " .. tostring(result.Error))
  T.ok(result.Stats.Nodes <= SDP_Solver.NODE_LIMIT + 1, "node budget exceeded")
  T.ok(result.Stats.Evaluations <= SDP_Solver.EVAL_LIMIT, "evaluation budget exceeded")
  print(string.format("placed %d, unplaced %d, gain %s via %s: %d nodes, %d DMT evaluations, truncated %s",
    #result.Plan, #result.Unplaced, tostring(result.Gain), result.Stats.Method, result.Stats.Nodes,
    result.Stats.Evaluations, tostring(result.Stats.Truncated)))
end)
