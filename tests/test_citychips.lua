-- @state SDP_Panel
-- @timeout 300
-- Who takes part on the Several cities tab (issue 63): the panel follows the
-- city selected on the map when it opens; the default group is that city
-- (else the capital) and the nearest cities and city-center pins joined to
-- it within NEAR plots, at most DEFAULT_CITIES; the chips fit the page.
-- Works with the capital alone; a late save (tools/stress.py load
-- pangaea-gs) also checks following another city. Leaves no city selected.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local capital = Players[pid]:GetCities():GetCapitalCity()
  if capital == nil then T.skip("no capital") end
  return capital
end

local function Keys(list)
  local keys = {}
  for _, part in ipairs(list) do keys[#keys + 1] = part.Key end
  table.sort(keys)
  return keys
end

local function GroupKeys(group)
  local keys = {}
  for id in pairs(group.Cities) do keys[#keys + 1] = "C" .. id end
  for key in pairs(group.Sites) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- Open and close once with nothing selected, so the next selection is new.
local function Unselect()
  UI.DeselectAllCities()
  SDP_Panel.Open()
  SDP_Panel.Close()
end

test("the default group around the capital: joined within NEAR, at most DEFAULT_CITIES", function()
  local capital = Capital()
  local multi = SDP_Panel.Multi
  multi.SetCenter(nil)
  multi.DefaultCities()
  local group = SDP_Multi.DefaultGroup(pid, nil)
  T.eq(group.Center.Key, "C" .. capital:GetID(), "the capital is the centre")
  local keys = GroupKeys(group)
  T.ok(#keys >= 1 and #keys <= SDP_Multi.DEFAULT_CITIES, "one to four: " .. #keys)
  local members = {}
  for _, e in ipairs(group.Order) do
    if group.Cities[e.CityID or -1] or group.Sites[e.Key] then members[#members + 1] = e end
  end
  for i = 2, #members do
    local near = false
    for j = 1, i - 1 do
      if Map.GetPlotDistance(members[i].X, members[i].Y, members[j].X, members[j].Y) <= SDP_Multi.NEAR then near = true end
    end
    T.ok(near, members[i].Key .. " joined to an earlier member")
  end
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  T.same(Keys(multi.Participants()), keys, "the tab takes the group")
  T.eq(multi.State().View.Center, "C" .. capital:GetID(), "the tab says so")
  for _, c in ipairs(multi.State().View.Cities) do
    T.ok(c.Chip ~= nil and not c.Chip:IsHidden(), c.Key .. ": a chip")
  end
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Close()
end)

test("opening the panel follows the city selected on the map", function()
  local capital = Capital()
  local cities = {}
  for _, city in Players[pid]:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  local other = cities[#cities]
  local ok, err = pcall(function()
    -- Away from the city first, then select it on the map.
    SDP_Panel.SelectCity(capital:GetID())
    SDP_Panel.Multi.SetCenter(nil)
    Unselect()
    UI.SelectCity(other)
    local selected = UI.GetHeadSelectedCity()
    T.ok(selected ~= nil and selected:GetID() == other:GetID(), "selected on the map")
    SDP_Panel.Open()
    T.eq(SDP_Panel.State().CityID, other:GetID(), "the single-city tab follows")
    SDP_Panel.SelectTab("MULTI")
    T.eq(SDP_Panel.Multi.State().View.Center, "C" .. other:GetID(), "the Several cities tab is around it")
    T.same(Keys(SDP_Panel.Multi.Participants()), GroupKeys(SDP_Multi.DefaultGroup(pid, other:GetID())), "its group")
    SDP_Panel.SelectTab("SINGLE")
    -- The same selection again: the player's own choice stays.
    SDP_Panel.SelectCity(capital:GetID())
    SDP_Panel.Close()
    SDP_Panel.Open()
    T.eq(SDP_Panel.State().CityID, capital:GetID(), "not taken back")
    SDP_Panel.Close()
  end)
  UI.DeselectAllCities()
  SDP_Panel.Close()
  SDP_Panel.Multi.SetCenter(nil)
  SDP_Panel.SelectCity(capital:GetID())
  if not ok then error(err, 0) end
end)

-- Five rows of chips at most; the page stays inside the window, with a
-- result of three solutions too (the result list, then the chip list give way).
test("the chip list and the result fit the page", function()
  Capital()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.SetCenter(nil)
  multi.DefaultCities()
  local chips = #multi.State().View.Cities
  local rows = math.min(5, math.max(1, math.ceil(chips / 3)))
  local function Report(when)
    print(string.format("SDP_CHIPS %s chips=%d body=%d page=%d cities=%d results=%d", when, chips,
      Controls.MultiBody:GetSizeY(), Controls.MultiPage:GetSizeY(), Controls.MultiCityScroll:GetSizeY(),
      Controls.MultiResultScroll:GetSizeY()))
    T.ok(Controls.MultiBody:GetSizeY() <= Controls.MultiPage:GetSizeY(), when .. ": inside the page")
  end
  Report("before")
  T.eq(Controls.MultiCityScroll:GetSizeY(), rows * 26 + (rows - 1) * 4, "sized to " .. rows .. " rows")
  -- Every chip on (up to eight) and a result with solutions.
  for _, c in ipairs(multi.State().View.Cities) do
    for _, now in ipairs(multi.State().View.Cities) do
      if now.Key == c.Key and not now.Included and not now.Disabled then
        if now.Kind == "SITE" then multi.SetSite(now.Key, true) else multi.SetExisting(now.CityID, true) end
      end
    end
  end
  multi.SetSelected("DISTRICT_CAMPUS", true)
  multi.SetTier("FAST")
  local ok, err = pcall(function()
    T.ok(multi.Solve(), "started")
    SDP_Panel.RunTask(500)
    local r = multi.State().Result
    T.ok(r and r.Ok, "result: " .. tostring(r and r.Error))
    Report("result with " .. #r.Solutions .. " solutions")
  end)
  multi.SetSelected("DISTRICT_CAMPUS", false)
  multi.SetTier("STANDARD")
  multi.DefaultCities()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Close()
  if not ok then error(err, 0) end
end)
