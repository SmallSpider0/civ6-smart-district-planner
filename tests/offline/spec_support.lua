-- Offline: a wonder that must stand next to an improvement (issue 51; the
-- Temple of Artemis next to a Camp): the plan places the Camp with it, the
-- tacks go down and come off together.
local test, T = ...

local UI_Mock = include("ui")
include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

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

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local TEMPLE, CAMP = "BUILDING_TEMPLE_ARTEMIS", "IMPROVEMENT_CAMP"

-- The capital at (4,5) owning its first ring; deer where asked.
local function NewWorld(extra)
  local spec = {
    rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" }, campWonder = true,
    cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
  }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local function Solve(extra)
  local request = { PlayerID = 0, Tier = "FAST", Weights = ONES, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" },
    Wonders = { TEMPLE }, Only = { [1] = true } }
  for k, v in pairs(extra or {}) do request[k] = v end
  local result = SDP_Multi.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree (legality included)")
  return result
end

local function TempleOf(result)
  for _, p in ipairs(result.Plan) do
    if p.Type == TEMPLE then return p end
  end
  return nil
end

local function ReasonOf(result, wonderType)
  for _, u in ipairs(result.Unplaced) do
    if u.Type == wonderType then return u end
  end
  return nil
end

local DEER = { { 6, 5, "RESOURCE_DEER" }, { 2, 3, "RESOURCE_DEER" } }

test("the temple gets a camp on a deer tile next to it", function()
  local w = NewWorld({ resources = DEER })
  local result = Solve()
  local temple = TempleOf(result)
  T.ok(temple ~= nil, "temple placed")
  local s = temple.Support
  T.ok(s ~= nil, "a camp planned with it")
  T.eq(s.Type, CAMP, "a camp")
  T.eq(Map.GetPlotDistance(s.X, s.Y, temple.X, temple.Y), 1, "next to the temple")
  T.eq(w:Plot(s.X, s.Y):GetResourceType(), GameInfo.Resources.RESOURCE_DEER.Index, "on deer")
  for _, p in ipairs(result.Plan) do T.ok(p.Index ~= s.Index, p.Type .. " not on the camp's tile") end
  -- The plan with the camp on the map is legal; without it the temple is not.
  SDP_Overlay.With(0, function()
    local subjects = {}
    for _, p in ipairs(result.Plan) do subjects[#subjects + 1] = { Key = p.Type, Type = p.Kind, X = p.X, Y = p.Y } end
    local with = SDP_Overlay.Evaluate(subjects, {}, ONES, { { Key = CAMP, Type = "IMPROVEMENT", X = s.X, Y = s.Y } })
    T.ok(with.Legal, "legal with the camp")
    local without = SDP_Overlay.Evaluate(subjects, {}, ONES)
    T.ok(not without.Legal, "not legal without it")
  end)
  -- The camp is not scored: the plan's value is the subjects' alone.
  T.ok(math.abs(result.Gain - result.Session.Search.BestGain) < 1e-6, "gain as searched")
end)

test("same request, same plan and camp", function()
  NewWorld({ resources = DEER })
  local a, b = Solve(), Solve()
  T.eq(#a.Plan, #b.Plan, "plan size")
  for n, p in ipairs(a.Plan) do
    local q = b.Plan[n]
    T.eq(p.Type .. p.X .. "," .. p.Y, q.Type .. q.X .. "," .. q.Y, "entry " .. n)
    T.eq(p.Support and (p.Support.X .. "," .. p.Support.Y) or "-", q.Support and (q.Support.X .. "," .. q.Support.Y) or "-",
      "camp of entry " .. n)
  end
end)

test("a district moving onto the camp's tile moves the camp; the board stays consistent", function()
  NewWorld({ resources = { { 6, 5, "RESOURCE_DEER" }, { 5, 4, "RESOURCE_DEER" }, { 6, 4, "RESOURCE_DEER" } } })
  local result = Solve()
  local search = result.Session.Search
  local best = SDP_Search.Copy(search.BestLayout)
  local wonder = nil
  for _, m in ipairs(search.SupportList or {}) do wonder = m end
  T.ok(wonder ~= nil and best[wonder] ~= 0, "the temple is placed")
  local position = {}
  for i, c in ipairs(search.Candidates) do position[c.Index] = i end
  SDP_Overlay.With(0, function()
    local plots = search:SupportPlots(best)
    local first = plots[wonder]
    T.ok(first ~= nil, "a camp tile")
    -- Every district in turn on the camp's tile: the camp takes the next
    -- free tile of its list, or the layout is not legal.
    local tried = 0
    for m = 1, search.K do
      local i = position[first]
      if search.Kinds[m] == "DISTRICT" and i ~= nil and search.Legal[m][i] then
        local layout = SDP_Search.Copy(best)
        for mm = 1, search.K do
          if layout[mm] == i then layout[mm] = 0 end
        end
        layout[m] = i
        local _, legal = search:Evaluate(layout)
        local moved = search:SupportPlots(layout)[wonder]
        T.ok(moved ~= first, "the camp left the district's tile")
        if moved == nil then T.ok(not legal, "no camp tile: not legal") end
        tried = tried + 1
      end
    end
    T.ok(tried > 0, "some district can take the deer tile")
    local gain, legal = search:Evaluate(best)
    T.ok(legal, "back to the best layout: legal")
    T.ok(math.abs(gain - search.BestGain) < 1e-9, "same value as before")
  end)
end)

test("no tile can take a camp: the temple is left out with the reason", function()
  NewWorld()
  local result = Solve()
  T.eq(TempleOf(result), nil, "not placed")
  local u = ReasonOf(result, TEMPLE)
  T.ok(u ~= nil and u.Reason == "NEEDS_IMPROVEMENT", "reason: " .. tostring(u and u.Reason))
  T.eq(u.Other, CAMP, "names the camp")
  -- Deer on another player's tile does not help.
  local w = NewWorld({ resources = { { 6, 5, "RESOURCE_DEER" } } })
  w:Own(6, 5, 1)
  T.eq(ReasonOf(Solve(), TEMPLE).Reason, "NEEDS_IMPROVEMENT", "deer abroad")
end)

test("a camp tack or a built camp next to it: no new camp", function()
  local w = NewWorld({ resources = DEER })
  w:AddPin(6, 5, "ICON_" .. CAMP, "")
  local temple = TempleOf(Solve())
  T.ok(temple ~= nil, "placed")
  T.eq(temple.Support, nil, "no new camp")
  T.ok(Map.GetPlotDistance(temple.X, temple.Y, 6, 5) == 1 or Map.GetPlotDistance(temple.X, temple.Y, 2, 3) == 1,
    "next to the tack or a deer tile")
  w = NewWorld({ resources = { { 5, 4, "RESOURCE_DEER" } }, improvements = { { 5, 4, CAMP } } })
  local built = TempleOf(Solve())
  T.ok(built ~= nil and built.Support == nil and Map.GetPlotDistance(built.X, built.Y, 5, 4) == 1, "next to the built camp")
end)

-- The panel: result rows, preview, tacks placed and undone together.
test("both tabs: the camp's row, its preview icon, its tack placed and undone with the temple's", function()
  -- A city-center tack: the several cities tab plans the capital with it.
  local w = NewWorld({ resources = DEER, pins = { { 9, 6, "ICON_DISTRICT_CITY_CENTER", "" } } })
  UI_Mock.Install()
  include("SDP_Panel")
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetSelected("DISTRICT_CAMPUS", true)
  SDP_Panel.SetTier("FAST")
  SDP_Panel.SetWonder(TEMPLE, true)
  T.eq(SDP_Panel.Solve(), nil, "with a wonder the city is solved as a task")
  local result = SDP_Panel.RunTask(500)
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  local temple = TempleOf(result)
  T.ok(temple ~= nil and temple.Support ~= nil, "temple with a camp")
  local row = nil
  for _, r in ipairs(SDP_Panel.State().ResultRows) do
    if r.Icon == "ICON_" .. CAMP then row = r end
  end
  T.ok(row ~= nil, "a row for the camp")
  T.ok(row.Detail:find("LOC_SDP_RESULT_SUPPORT", 1, true) ~= nil, "says which wonder it serves")
  local pins = #w:Pins()
  Controls.PlaceButton:Click()
  local icons = {}
  for i = pins + 1, #w:Pins() do icons[w:Pins()[i]:GetIconName()] = w:Pins()[i] end
  T.eq(#w:Pins(), pins + #result.Plan + 1, "a tack per plan entry and one for the camp")
  T.ok(icons["ICON_" .. CAMP] ~= nil, "the camp's tack")
  T.eq(icons["ICON_" .. CAMP]:GetHexX(), temple.Support.X, "where planned")
  T.eq(icons["ICON_" .. CAMP]:GetName(), "1", "named with the city's number")
  Controls.UndoButton:Click()
  T.eq(#w:Pins(), pins, "undo takes the camp's tack too")
  SDP_Panel.SetWonder(TEMPLE, false)

  local multi = SDP_Panel.Multi
  SDP_Panel.SelectTab("MULTI")
  multi.Refresh()
  multi.SetSelected("DISTRICT_CAMPUS", true)
  multi.SetWonder(TEMPLE, true)
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local mresult = multi.State().Result
  T.ok(mresult and mresult.Ok, "multi result: " .. tostring(mresult and mresult.Error))
  local mtemple = TempleOf(mresult)
  T.ok(mtemple ~= nil and mtemple.Support ~= nil, "temple with a camp on the several cities tab")
  local camps = 0
  for _, r in ipairs(multi.State().View.Results) do
    if r.Icon == "ICON_" .. CAMP then camps = camps + 1 end
  end
  T.eq(camps, 1, "one camp row")
  local shown, show = nil, SDP_Preview.Show
  SDP_Preview.Show = function(pid, areas, icons)
    shown = icons
    return show(pid, areas, icons)
  end
  multi.Preview(1)
  SDP_Preview.Show = show
  local previewed = false
  for _, icon in ipairs(shown or {}) do
    if icon.Icon == "ICON_" .. CAMP and icon.X == mtemple.Support.X and icon.Y == mtemple.Support.Y then previewed = true end
  end
  T.ok(previewed, "the camp on the map preview")
  pins = #w:Pins()
  local placed = multi.Place()
  T.eq(placed, #mresult.Plan + 1, "tacks with the camp's")
  T.eq(multi.Undo(), placed, "undo takes them all")
  T.eq(#w:Pins(), pins, "gone")
end)
