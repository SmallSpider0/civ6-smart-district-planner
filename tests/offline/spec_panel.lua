-- Offline: the planner panel's logic on every tab, with stub controls
-- (tests/offline/ui.lua). Catches script errors and wiring mistakes; the
-- layout and real clicks are checked in the game.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~..f.M..h...f..M..h..~",
  "~.fMj..p.d...fMj..p..~",
  "~h..f.j..M.h..f.j..M.~",
  "~.pM...f.h..pM...f.h.~",
  "~..j.p..q....j.p..q..~",
  "~f..h.M.j..f..h.M.j..~",
  "~.s..f..p...s..f..p..~",
  "~..p...h...p...h.....~",
  "~.M..f..j..M..f..j...~",
  "~..h..p...h..p...h...~",
  "~.f..M..p..f..M..p...~",
  "~..j...h..j...h..j...~",
  "~~~~~~~~~~~~~~~~~~~~~~",
}

local w = World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
  cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
  pins = { { 13, 9, "ICON_DISTRICT_CITY_CENTER", "" } },
})
UI_Mock.Install()
include("SDP_Panel")

local SINGLE = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }

test("single-city tab: solve now, solve as a task, continue, place and undo", function()
  SDP_Panel.Open()
  T.ok(SDP_Panel.IsOpen(), "open")
  SDP_Panel.SelectCity(1)
  for _, d in ipairs(SINGLE) do SDP_Panel.SetSelected(d, true) end
  T.ok(SDP_Panel.State().EstimateText ~= "", "estimate shown")
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solve: " .. tostring(result and result.Error))
  T.ok(#SDP_Panel.State().ResultRows >= 3, "result rows")
  SDP_Panel.SetTier("FINE")
  T.eq(SDP_Panel.Solve(), nil, "the fine tier runs as a task")
  T.ok(SDP_Panel.State().Running, "running")
  local fine = SDP_Panel.RunTask(50)
  T.ok(fine and fine.Ok, "task result: " .. tostring(fine and fine.Error))
  T.eq(fine.Stats.Tier, "FINE", "tier")
  SDP_Panel.SetTier("STANDARD")
  SDP_Panel.Solve()
  local pins = #w:Pins()
  T.eq(SDP_Panel.PlacePins(), 3, "three pins")
  T.eq(#w:Pins(), pins + 3, "pins on the map")
  T.eq(SDP_Panel.UndoPins(), 3, "undo")
  T.eq(#w:Pins(), pins, "pins gone")
end)

test("city sites tab: solve, select, place the site tacks", function()
  SDP_Panel.SelectTab("SITES")
  T.eq(SDP_Panel.Tab(), "SITES", "tab")
  local sites = SDP_Panel.Sites
  sites.SetCount(2)
  sites.SetDistance(7)
  sites.SetSelected("DISTRICT_CAMPUS", true)
  sites.SetSelected("DISTRICT_HOLY_SITE", true)
  T.ok(sites.State().EstimateText ~= "", "estimate")
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(200)
  local result = sites.State().Result
  T.ok(result and result.Ok, "sites result: " .. tostring(result and result.Error))
  T.ok(#sites.State().View.Solutions >= 1, "solutions listed")
  T.ok(UI_Mock.Lenses.hexes.Hex_Coloring_Placement > 0, "previewed on the map")
  if #result.Solutions > 1 then
    sites.SelectSolution(2)
    T.eq(sites.State().Solution, 2, "second solution selected")
  end
  local pins = #w:Pins()
  T.eq(sites.Place(), 2, "two site tacks")
  T.eq(#w:Pins(), pins + 2, "on the map")
  T.eq(UI_Mock.Lenses.hexes.Hex_Coloring_Placement, 0, "preview cleared after placing")
end)

test("several cities tab: the new site tacks take part; solve; solutions; place", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  local sites = 0
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Kind == "SITE" then sites = sites + 1 end
  end
  T.ok(sites >= 3, "the pin and the two site tacks: " .. sites)
  for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_GOVERNMENT" }) do
    multi.SetSelected(d, true)
  end
  multi.SetWonder("BUILDING_HANGING_GARDENS", true)
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "multi result: " .. tostring(result and result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  T.ok(#multi.State().View.Results > 0, "rows")
  local pins = #w:Pins()
  local placed = multi.Place()
  T.ok(placed > 0, "placed")
  T.eq(#w:Pins(), pins + placed, "pins on the map")
  local named = false
  for _, pin in ipairs(w:Pins()) do
    if pin:GetName():find("LOC_SDP_PIN_IN_CITY", 1, true) then named = true end
  end
  T.ok(named, "pins named after their city")
  T.eq(multi.Undo(), placed, "undo")
end)

test("closing the panel clears the preview; a background result marks the launch button", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SetTier("FINE")
  SDP_Panel.Solve()
  SDP_Panel.Close()
  T.eq(UI_Mock.Lenses.hexes.Hex_Coloring_Placement or 0, 0, "no preview while closed")
  SDP_Panel.RunTask(1000)
  T.ok(SDP_Panel.State().LaunchMark, "mark on the launch button")
  SDP_Panel.Open()
  T.ok(not SDP_Panel.State().LaunchMark, "mark gone after opening")
  SDP_Panel.SetTier("STANDARD")
end)
