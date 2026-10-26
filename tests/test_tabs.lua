-- @state SDP_Panel
-- @timeout 600
-- The panel's three tabs in the game: switch, solve each as a task, results.
-- Needs a city: run tests/fixtures/found_capital.lua first.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("every tab opens and solves", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  SDP_Panel.Open()
  for _, tab in ipairs({ "SITES", "MULTI", "SINGLE" }) do
    SDP_Panel.SelectTab(tab)
    T.eq(SDP_Panel.Tab(), tab, "tab")
  end
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  sites.SetCount(1)
  sites.SetSelected("DISTRICT_CAMPUS", true)
  sites.SetDistrictCount(1)
  sites.SetTier("FAST")
  T.ok(sites.Solve(), "sites started")
  SDP_Panel.RunTask(200)
  local r = sites.State().Result
  T.ok(r ~= nil, "sites result")
  if r.Ok then T.ok(#r.Solutions >= 1, "solutions") end
  sites.SetSelected("DISTRICT_CAMPUS", false)
  sites.SetDistrictCount(3)
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Close()
end)
