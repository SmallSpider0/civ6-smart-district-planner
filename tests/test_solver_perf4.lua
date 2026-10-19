-- @state SDP_Panel
-- @timeout 30
-- @max_seconds 2.5
-- Acceptance: 4 districts solve without freezing the game (stall <= ~2 s).
local test, T = ...

local pid = Game.GetLocalPlayer()
local BASES = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" }

test("solve 4 districts", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  local districts = {}
  for i = 1, 4 do
    local base = BASES[i]
    for row in GameInfo.DistrictReplaces() do
      if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then base = row.CivUniqueDistrictType end
    end
    districts[i] = base
  end
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = districts })
  T.ok(result.Ok, "solve failed: " .. tostring(result.Error))
  T.eq(#result.Plan, 4, "plan size")
  print(string.format("gain %s via %s: %d layouts counted, %d nodes, %d DMT evaluations, truncated %s",
    tostring(result.Gain), result.Stats.Method, result.Stats.Layouts, result.Stats.Nodes,
    result.Stats.Evaluations, tostring(result.Stats.Truncated)))
end)
