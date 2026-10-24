-- Offline: what a plan leaves out is listed first, and with no legal plot
-- the hover text is the game's own description of the district (issue 60:
-- a city without fresh water and no river, lake, oasis or mountain next to
-- its center cannot have an aqueduct; the row sat at the end of the list).
local test, T = ...

local UI_Mock = include("ui")

-- Flat grassland round the city: nothing an aqueduct could draw water from.
local MAP = {
  "~~~~~~~~~~~",
  "~.........~",
  "~.........~",
  "~.........~",
  "~.........~",
  "~.........~",
  "~.........~",
  "~~~~~~~~~~~",
}

World.New({ rows = MAP, cities = { { id = 1, x = 5, y = 3, population = 6, capital = true, radius = 2 } } })
UI_Mock.Install()
include("SDP_Panel")

test("single-city tab: an automatic aqueduct without a legal plot comes first, explained", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "AUTO")
  SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
  SDP_Panel.SetCount(1)
  SDP_Panel.SetTier("STANDARD")
  local result = SDP_Panel.Solve()
  T.ok(result ~= nil and result.Ok, "solved: " .. tostring(result and result.Error))
  local left = nil
  for _, u in ipairs(result.Unplaced) do if u.Type == "DISTRICT_AQUEDUCT" then left = u end end
  T.ok(left ~= nil and left.Auto and left.Reason == "NO_LEGAL_PLOT", "the aqueduct is left out for want of a legal plot")
  local rows = SDP_Panel.State().ResultRows
  T.eq(rows[1].Icon, "ICON_DISTRICT_AQUEDUCT", "listed first")
  T.eq(rows[1].ToolTip, Locale.Lookup("LOC_DISTRICT_AQUEDUCT_DESCRIPTION"), "the game's description on hover")
  T.eq(rows[2].Icon, "ICON_DISTRICT_CAMPUS", "then the plan")
end)

test("the hover text is empty for other reasons", function()
  T.eq(SDP_UI.UnplacedTip({ Type = "DISTRICT_AQUEDUCT", Reason = "NO_FREE_PLOT" }), "", "no free plot")
  T.eq(SDP_UI.UnplacedTip({ Type = "DISTRICT_AQUEDUCT", Reason = "NO_LEGAL_PLOT" }),
    Locale.Lookup("LOC_DISTRICT_AQUEDUCT_DESCRIPTION"), "no legal plot")
end)
