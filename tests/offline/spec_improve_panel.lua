-- Offline: the panel's improvement switches, rows, preview and tacks
-- (issue 227) on both tabs, through the controls' own handlers.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~~~~~",
  "~................~",
  "~................~",
  "~....hh.....hh...~",
  "~................~",
  "~................~",
  "~................~",
  "~~~~~~~~~~~~~~~~~~",
}

local w = World.New({
  rows = MAP, improvementRules = true, improveAdjacency = true,
  cities = { { id = 1, x = 4, y = 4, population = 7, capital = true }, { id = 2, x = 11, y = 4, population = 7 } },
})
UI_Mock.Install()
include("SDP_Panel")

local IZ = "DISTRICT_INDUSTRIAL_ZONE"

local function Kept(tab) return PlayerConfigurations[0]:GetValue("SDP_Settings_" .. tab) or "" end

local function Count(list, key)
  local n = 0
  for _, row in ipairs(list) do
    if tostring(row.Name or ""):find(key, 1, true) ~= nil then n = n + 1 end
  end
  return n
end

local function Improvements(plan)
  local list = {}
  for _, p in ipairs(plan) do
    for _, e in ipairs(p.Improvements or {}) do list[#list + 1] = e end
  end
  return list
end

test("single-city tab: the switches, the rows, the preview, place and undo", function()
  local c = UI_Mock.Controls
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetRemind(false)
  SDP_Panel.SetSelected(IZ, true)
  SDP_Panel.SetTier("FAST")
  SDP_Panel.SetCount(1) -- the industrial zone alone: picking more is slow here
  T.eq(c.ImproveCheck:IsChecked(), true, "improvements: on by default")
  T.eq(c.WorkedCheck:IsChecked(), false, "worked tiles: off by default")
  T.eq(SDP_Panel.State().Improve, true, "state")
  T.eq(SDP_Panel.State().Worked, false, "state")
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solve: " .. tostring(result and result.Error))
  local improvements = Improvements(result.Plan)
  T.eq(#improvements, 2, "two mines with the industrial zone")
  T.eq(Count(SDP_Panel.State().ResultRows, "LOC_SDP_RESULT_IMPROVEMENTS("), 1, "a row for them")
  T.eq(Count(SDP_Panel.State().ResultRows, "LOC_SDP_RESULT_WORKED("), 0, "no worked tiles' row")
  local row = nil
  for _, r in ipairs(SDP_Panel.State().ResultRows) do
    if r.Name:find("LOC_SDP_RESULT_IMPROVEMENTS(", 1, true) then row = r end
  end
  T.ok(row.Detail:find("LOC_SDP_RESULT_IMPROVEMENTS_FOR", 1, true) ~= nil, "what they add to the district: " .. row.Detail)
  T.ok(row.ToolTip:find("LOC_SDP_RESULT_IMPROVEMENT_LINE", 1, true) ~= nil, "a line per tack on hover")
  T.ok(row.ToolTip:find("LOC_SDP_RESULT_UNOWNED", 1, true) ~= nil, "an unowned tile marked")
  local icons = 0
  for _, icon in ipairs(SDP_UI.CityIcons(result)) do
    if icon.Icon == "ICON_IMPROVEMENT_MINE" then icons = icons + 1 end
  end
  T.eq(icons, 2, "the preview shows the mines")
  local pins = #w:Pins()
  T.eq(SDP_Panel.PlacePins(), #result.Plan + 2, "a tack per district and per mine")
  local mines = 0
  for i = pins + 1, #w:Pins() do
    local pin = w:Pins()[i]
    if pin:GetIconName() == "ICON_IMPROVEMENT_MINE" then
      mines = mines + 1
      T.eq(pin:GetName(), "1", "named with the city's number")
    end
  end
  T.eq(mines, 2, "mine tacks")
  T.eq(SDP_Panel.UndoPins(), #result.Plan + 2, "undo takes them all")
  T.eq(#w:Pins(), pins, "gone")

  -- Worked tiles on through the box: a row with the counts, their tacks too.
  c.WorkedCheck:Toggle()
  T.eq(SDP_Panel.State().Worked, true, "on through the box")
  T.ok(Kept("SINGLE"):find("WORKED=1", 1, true) ~= nil, "kept in the save: " .. Kept("SINGLE"))
  result = SDP_Panel.Solve()
  T.ok(result.Worked ~= nil and #result.Worked > 0, "worked tiles' tacks")
  T.eq(Count(SDP_Panel.State().ResultRows, "LOC_SDP_RESULT_WORKED("), 1, "one row for the city")
  T.eq(SDP_Panel.PlacePins(), #result.Plan + 2 + #result.Worked, "their tacks go down too")
  T.eq(SDP_Panel.UndoPins(), #result.Plan + 2 + #result.Worked, "and come off")
  c.WorkedCheck:Toggle()

  -- Improvements off through the box: no mines, none of their rows.
  c.ImproveCheck:Toggle()
  T.eq(SDP_Panel.State().Improve, false, "off through the box")
  T.ok(Kept("SINGLE"):find("IMPROVE=0", 1, true) ~= nil, "kept in the save: " .. Kept("SINGLE"))
  T.eq(SDP_Panel.State().Result, nil, "the result goes: the plan would change")
  result = SDP_Panel.Solve()
  T.eq(#Improvements(result.Plan), 0, "no improvements")
  T.eq(Count(SDP_Panel.State().ResultRows, "LOC_SDP_RESULT_IMPROVEMENTS("), 0, "no row")
  c.ImproveCheck:Toggle()
  T.ok(Kept("SINGLE"):find("IMPROVE", 1, true) == nil, "on is the default: not kept")
  SDP_Panel.SetRemind(true)
  SDP_Panel.Close()
end)

test("several cities tab: the switches, a row per city, place and undo", function()
  local c = UI_Mock.Controls
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetCount(0) -- the required districts only: picking makes it slow
  multi.SetSelected(IZ, true)
  multi.SetTier("FAST")
  T.eq(c.MultiImproveCheck:IsChecked(), true, "improvements: on by default")
  T.eq(c.MultiWorkedCheck:IsChecked(), false, "worked tiles: off by default")
  T.eq(multi.Request().Improvements, true, "in the request")
  c.MultiWorkedCheck:Toggle()
  T.eq(multi.Request().WorkedImprovements, true, "worked tiles on through the box")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "multi result: " .. tostring(result and result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  local improvements = Improvements(result.Plan)
  T.eq(#improvements, 4, "two mines for each city's industrial zone")
  T.eq(Count(multi.State().View.Results, "LOC_SDP_RESULT_IMPROVEMENTS("), 2, "a row under each zone")
  local worked, cities = 0, 0
  for _, city in ipairs(result.Cities) do
    if city.Worked ~= nil and #city.Worked > 0 then
      cities = cities + 1
      worked = worked + #city.Worked
    end
  end
  T.eq(Count(multi.State().View.Results, "LOC_SDP_RESULT_WORKED("), cities, "a worked tiles' row per city")
  local icons = 0
  for _, icon in ipairs(multi.State().View.PreviewIcons) do
    if icon.Icon == "ICON_IMPROVEMENT_MINE" then icons = icons + 1 end
  end
  T.ok(icons >= 4, "the preview shows the mines")
  local pins = #w:Pins()
  local placed = multi.Place()
  T.eq(placed, #result.Plan + #improvements + worked, "districts, their improvements and the worked tiles' tacks")
  T.eq(#w:Pins(), pins + placed, "on the map")
  T.eq(multi.Undo(), placed, "undo")
  c.MultiWorkedCheck:Toggle()
  T.eq(multi.Request().WorkedImprovements, false, "off again")
  c.MultiImproveCheck:Toggle()
  T.eq(multi.Request().Improvements, false, "improvements off through the box")
  c.MultiImproveCheck:Toggle()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Close()
end)
