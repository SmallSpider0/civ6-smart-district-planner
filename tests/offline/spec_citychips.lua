-- Offline: who takes part on the Several cities tab (issue 63). The panel
-- follows the city selected on the map when it opens; the default group is
-- that city (else the capital) and the nearest cities and city-center pins
-- joined to it within NEAR plots, at most DEFAULT_CITIES; the list is a grid
-- of chips with "clear all" and "default" buttons, at most MAX_CITIES on.
-- Everything goes through the controls' own callbacks (Click).
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

-- Four cities and five city-center pins: nine in all, one more than can
-- take part at once.
local CITIES = {
  { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 },
  { id = 2, x = 8, y = 3, population = 4, radius = 1 },
  { id = 3, x = 17, y = 5, population = 3, radius = 1 },
  { id = 4, x = 3, y = 11, population = 2, radius = 1 },
}
local PINS = {
  { 9, 6, "ICON_DISTRICT_CITY_CENTER", "A" }, { 13, 9, "ICON_DISTRICT_CITY_CENTER", "B" },
  { 20, 10, "ICON_DISTRICT_CITY_CENTER", "C" }, { 7, 11, "ICON_DISTRICT_CITY_CENTER", "D" },
  { 12, 2, "ICON_DISTRICT_CITY_CENTER", "E" },
}

local m_selected = nil -- the city UI.GetHeadSelectedCity gives
local w
w = World.New({ rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" }, cities = CITIES, pins = PINS })
UI_Mock.Install()
UI.GetHeadSelectedCity = function() return m_selected and w:City(m_selected) or nil end
include("SDP_Panel")
local multi = SDP_Panel.Multi

local function Entries()
  local list = {}
  for _, c in ipairs(CITIES) do list[#list + 1] = { Key = "C" .. c.id, X = c.x, Y = c.y, Kind = "CITY", Order = c.id } end
  for _, p in ipairs(PINS) do
    list[#list + 1] = { Key = "S" .. Map.GetPlotIndex(p[1], p[2]), X = p[1], Y = p[2], Kind = "SITE",
      Order = Map.GetPlotIndex(p[1], p[2]) }
  end
  return list
end

-- The rule written out again: from the centre, repeatedly the nearest one
-- (ties: cities, then ID or plot index) within NEAR of a member.
local function Expected(centerKey)
  local entries = Entries()
  local center
  for _, e in ipairs(entries) do
    if e.Key == centerKey then center = e end
  end
  local members, taken = { center }, { [center.Key] = true }
  local function Before(a, b)
    local da = Map.GetPlotDistance(center.X, center.Y, a.X, a.Y)
    local db = Map.GetPlotDistance(center.X, center.Y, b.X, b.Y)
    if da ~= db then return da < db end
    if a.Kind ~= b.Kind then return a.Kind == "CITY" end
    return a.Order < b.Order
  end
  while #members < SDP_Multi.DEFAULT_CITIES do
    local best
    for _, e in ipairs(entries) do
      local near = false
      for _, m in ipairs(members) do
        if Map.GetPlotDistance(m.X, m.Y, e.X, e.Y) <= SDP_Multi.NEAR then near = true end
      end
      if not taken[e.Key] and near and (best == nil or Before(e, best)) then best = e end
    end
    if best == nil then break end
    members[#members + 1], taken[best.Key] = best, true
  end
  local keys = {}
  for _, m in ipairs(members) do keys[#keys + 1] = m.Key end
  table.sort(keys)
  return keys
end

local function Taking()
  local keys = {}
  for _, part in ipairs(multi.Participants()) do keys[#keys + 1] = part.Key end
  table.sort(keys)
  return keys
end

local function Chip(key)
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Key == key then return c end
  end
end

test("default group: the capital, then the nearest joined within NEAR, at most DEFAULT_CITIES", function()
  local group = SDP_Multi.DefaultGroup(0, nil)
  T.eq(group.Center.Key, "C1", "no city given: the capital")
  T.eq(#group.Order, 9, "every city and pin in the order")
  T.eq(group.Order[1].Key, "C1", "the centre first")
  for i = 3, #group.Order do
    T.ok(group.Order[i - 1].Distance <= group.Order[i].Distance, "then by distance")
  end
  local keys = {}
  for id in pairs(group.Cities) do keys[#keys + 1] = "C" .. id end
  for key in pairs(group.Sites) do keys[#keys + 1] = key end
  table.sort(keys)
  T.same(keys, Expected("C1"), "the rule")
  T.eq(#keys, SDP_Multi.DEFAULT_CITIES, "four take part")
  local around3 = SDP_Multi.DefaultGroup(0, 3)
  T.eq(around3.Center.Key, "C3", "around another city")
  local keys3 = {}
  for id in pairs(around3.Cities) do keys3[#keys3 + 1] = "C" .. id end
  for key in pairs(around3.Sites) do keys3[#keys3 + 1] = key end
  table.sort(keys3)
  T.same(keys3, Expected("C3"), "the rule around city 3")
  T.same(SDP_Multi.DefaultGroup(0, 3).Order, around3.Order, "same input, same order")
end)

test("opening the panel: no city selected, the tab is around the capital", function()
  m_selected = nil
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  T.eq(multi.State().View.Center, "C1", "around the capital")
  T.same(Taking(), Expected("C1"), "the default group takes part")
  local chips = multi.State().View.Cities
  T.eq(#chips, 9, "a chip for every city and pin")
  T.eq(chips[1].Kind, "SITE", "the pins first, as the participants")
  T.eq(chips[#chips].Key, "C4", "the cities by ID")
  for _, c in ipairs(chips) do
    T.eq(c.Included, c.Default, c.Key .. ": as the default")
    T.ok(c.Chip:GetToolTipString() ~= "", c.Key .. ": a tooltip")
  end
  T.ok(Chip("C1").Chip:GetToolTipString():find("LOC_SDP_MULTI_CENTER", 1, true), "the centre says so")
  T.ok(UI_Mock.Controls.MultiCityDefault:IsDisabled(), "already the default")
  T.ok(not UI_Mock.Controls.MultiCityClear:IsDisabled(), "something to clear")
  -- Three rows of chips: the list is sized to them, no scrolling.
  T.eq(UI_Mock.Controls.MultiCityScroll:GetSizeY(), 3 * 26 + 2 * 4, "three rows shown")
  SDP_Panel.Close()
end)

test("opening the panel follows the city selected on the map, once per selection", function()
  m_selected = 3
  SDP_Panel.Open()
  T.eq(SDP_Panel.State().CityID, 3, "the single-city tab switched to the selected city")
  SDP_Panel.SelectTab("MULTI")
  T.eq(multi.State().View.Center, "C3", "the Several cities tab is around it")
  T.same(Taking(), Expected("C3"), "its group takes part")
  -- The player picks another city; the same selection does not take it back.
  SDP_Panel.SelectCity(1)
  local off = nil
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Included and not c.Center then off = c.Key end
  end
  Chip(off).Chip:Click()
  SDP_Panel.Close()
  SDP_Panel.Open()
  T.eq(SDP_Panel.State().CityID, 1, "the player's choice stays")
  T.eq(Chip(off).Included, false, "the switch stays")
  T.eq(SDP_Panel.Tab(), "MULTI", "the same city still selected: the tab it was closed on (issue 76)")
  SDP_Panel.Close()
  -- Another city selected: followed, on the single-city tab (issue 76); the
  -- switches go with the old centre.
  m_selected = 2
  SDP_Panel.Open()
  T.eq(SDP_Panel.Tab(), "SINGLE", "another city selected: the single-city tab")
  T.ok(not UI_Mock.Controls.SinglePage:IsHidden() and UI_Mock.Controls.MultiPage:IsHidden(), "its page shown")
  T.eq(SDP_Panel.State().CityID, 2, "followed")
  T.eq(multi.State().View.Center, "C2", "new centre")
  T.same(Taking(), Expected("C2"), "its default group")
  SDP_Panel.Close()
  -- Nothing selected: the panel keeps what it shows, the tab too.
  SDP_Panel.SelectTab("SITES")
  SDP_Panel.Close()
  m_selected = nil
  SDP_Panel.Open()
  T.eq(SDP_Panel.Tab(), "SITES", "nothing selected: the tab it was closed on")
  T.eq(SDP_Panel.State().CityID, 2, "kept")
  T.eq(multi.State().View.Center, "C2", "kept")
  SDP_Panel.Close()
  -- The capital selected while the tab is around the capital already: the
  -- switches stay.
  multi.SetCenter(nil)
  local key = nil
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Included and not c.Center then key = c.Key end
  end
  Chip(key).Chip:Click()
  m_selected = 1
  SDP_Panel.Open()
  T.eq(multi.State().View.Center, "C1", "around the capital")
  T.eq(Chip(key).Included, false, "same centre: the switch stays")
  SDP_Panel.Close()
  multi.DefaultCities()
  m_selected = nil
  -- A city of another player is not followed.
  w:City(4).owner = 1
  m_selected = 4
  SDP_Panel.Open()
  T.eq(SDP_Panel.State().CityID, 1, "not ours: not followed")
  SDP_Panel.Close()
  w:City(4).owner = 0
  m_selected = nil
end)

test("a running computation is not cut short by a new selection", function()
  m_selected = 1
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  multi.SetSelected("DISTRICT_CAMPUS", true)
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.Close()
  m_selected = 3
  SDP_Panel.Open()
  T.ok(SDP_Panel.State().Running, "still running")
  T.eq(SDP_Panel.Tab(), "MULTI", "the tab stays (issue 76)")
  T.eq(SDP_Panel.State().CityID, 1, "the single-city tab stays")
  T.eq(multi.State().View.Center, "C1", "the centre stays")
  local result = SDP_Panel.RunTask(500)
  T.ok(result ~= nil or multi.State().Result ~= nil, "finished")
  T.ok(multi.State().Result and multi.State().Result.Ok, "a result")
  SDP_Panel.Close()
  -- The selection was passed over: reopening does not throw the result away.
  SDP_Panel.Open()
  T.eq(multi.State().View.Center, "C1", "still around the capital")
  T.ok(multi.State().Result ~= nil, "the result is still there")
  SDP_Panel.Close()
  multi.SetSelected("DISTRICT_CAMPUS", false)
  multi.SetTier("STANDARD")
  m_selected = nil
end)

test("chips: a click switches a city or a pin; clear all; default", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  multi.DefaultCities()
  local site, city = nil, nil
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Kind == "SITE" and site == nil then site = c.Key end
    if c.Kind == "CITY" and not c.Center and city == nil then city = c.Key end
  end
  for _, key in ipairs({ site, city }) do
    local was = Chip(key).Included
    Chip(key).Chip:Click()
    T.eq(Chip(key).Included, not was, key .. " switched by a click")
    local found = false
    for _, part in ipairs(multi.Participants()) do
      if part.Key == key then found = true end
    end
    T.eq(found, not was, key .. ": takes part as the chip shows")
    T.ok(not UI_Mock.Controls.MultiCityDefault:IsDisabled(), "not the default any more")
    Chip(key).Chip:Click()
    T.eq(Chip(key).Included, was, key .. " back")
  end
  UI_Mock.Controls.MultiCityClear:Click()
  T.eq(#multi.Participants(), 0, "clear all: nobody")
  for _, c in ipairs(multi.State().View.Cities) do T.eq(c.Included, false, c.Key .. " off") end
  T.ok(UI_Mock.Controls.MultiCityClear:IsDisabled(), "nothing left to clear")
  T.eq(multi.Request(), nil, "nothing to plan")
  UI_Mock.Controls.MultiCityDefault:Click()
  T.same(Taking(), Expected("C1"), "default: the group again")
  T.ok(UI_Mock.Controls.MultiCityDefault:IsDisabled(), "default reached")
  SDP_Panel.Close()
end)

test("chips: at most MAX_CITIES on; the others cannot be switched on", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  multi.DefaultCities()
  for _, c in ipairs(multi.State().View.Cities) do
    if not Chip(c.Key).Included and not Chip(c.Key).Disabled then Chip(c.Key).Chip:Click() end
  end
  T.eq(#multi.Participants(), SDP_Multi.MAX_CITIES, "eight on")
  local last
  for _, c in ipairs(multi.State().View.Cities) do
    if not c.Included then last = c end
  end
  T.ok(last ~= nil and last.Disabled, "the ninth is dimmed")
  T.ok(last.Chip:GetToolTipString():find("LOC_SDP_MULTI_FULL", 1, true), "and says why")
  last.Chip:Click()
  T.eq(#multi.Participants(), SDP_Multi.MAX_CITIES, "a click on it changes nothing")
  -- The request names every city and pin, so the solver sees the same cities.
  multi.SetSelected("DISTRICT_CAMPUS", true)
  local request = multi.Request()
  local parts = SDP_Multi.Participants(0, { Existing = request.Existing, Sites = request.Sites })
  local keys = {}
  for _, part in ipairs(parts) do keys[#keys + 1] = part.Key end
  table.sort(keys)
  T.same(keys, Taking(), "the request's cities are the chips' cities")
  multi.SetSelected("DISTRICT_CAMPUS", false)
  multi.DefaultCities()
  SDP_Panel.Close()
end)

test("the old switches still work: nil gives a city back to the default", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  multi.DefaultCities()
  local far
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Kind == "CITY" and not c.Default then far = c end
  end
  T.ok(far ~= nil, "a city outside the group")
  multi.SetExisting(far.CityID, true)
  T.eq(Chip(far.Key).Included, true, "switched on")
  multi.SetExisting(far.CityID, nil)
  T.eq(Chip(far.Key).Included, false, "back to the default")
  SDP_Panel.Close()
end)

-- Last: a world of its own replaces the panel's.
test("a lone city: nobody within NEAR, the group is the city alone", function()
  local lone = World.New({ rows = MAP, cities = {
    { id = 1, x = 2, y = 2, population = 3, capital = true, radius = 1 },
    { id = 2, x = 20, y = 12, population = 3, radius = 1 },
  } })
  local group = SDP_Multi.DefaultGroup(0, 2)
  T.eq(group.Center.Key, "C2", "centre")
  T.same(group.Cities, { [2] = true }, "alone")
  T.ok(lone ~= nil, "world")
end)
