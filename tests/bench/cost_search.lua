-- @state SDP_Panel
-- @timeout 300
-- Calibration (run alone: python3 -I tools/run_tests.py -v tests/bench/cost_search.lua).
-- Solves with fixed budgets and prints the counts; with the file's wall
-- time and cost_dmt.lua's cost per DMT call this gives the cost of a layout
-- evaluation and of a model search node. Not a regular test.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Districts(count)
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #list < count then list[#list + 1] = d.Type end
  end
  return list
end

test("6 districts, 20000 tries, beam 400", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = Districts(6), Land = true, Tier = "FINE",
    Params = { ExactLimit = 0, Beam = 400, Shortlist = 50, Starts = 40, Kicks = 0, TryLimit = 20000, CallLimit = 10 ^ 9, MaxPasses = 50 } })
  T.ok(result.Ok, tostring(result.Error))
  print(string.format("calls %d, evaluations %d, tries %d, nodes %d, hits %d", result.Stats.Calls, result.Stats.Evaluations,
    result.Stats.Tries, result.Stats.Nodes, result.Stats.Hits))
end)
