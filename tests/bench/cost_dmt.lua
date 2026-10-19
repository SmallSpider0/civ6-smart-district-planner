-- @state SDP_Panel
-- @timeout 120
-- Calibration (run alone: python3 -I tools/run_tests.py tests/bench/cost_dmt.lua).
-- 20000 DMT calls (GetBonusYields and CanPlacePin alternately, with the DMT
-- cache cleared as SDP_Board does): seconds reported / 20000 = cost of one
-- call, the unit of SDP_Tiers. Not a regular test (no test_ prefix).
local test, T = ...

local pid = Game.GetLocalPlayer()

test("20000 DMT calls", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  local scan = SDP_City.Scan(pid, city:GetID())
  local weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
  local districts = SDP_Rules.PlannableDistricts(pid)
  SDP_Overlay.With(pid, function()
    local n, calls = #scan.Candidates, 0
    while calls < 20000 do
      for _, d in ipairs(districts) do
        for i = 1, n do
          local c = scan.Candidates[i]
          local subject = SDP_Overlay.Subject(d.Type, c.X, c.Y)
          SDP_Overlay.Put(c.X, c.Y, subject)
          SDP_Overlay.ClearCache()
          SDP_Overlay.ScoreOf(subject, weights)
          SDP_Overlay.CanPlace(subject)
          SDP_Overlay.Put(c.X, c.Y, nil)
          calls = calls + 2
          if calls >= 20000 then return end
        end
      end
    end
  end)
end)
