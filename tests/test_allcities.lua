-- @state SDP_Panel
-- @timeout 900
-- "All cities" on the Several cities tab (issue 142): every city and
-- city-center pin takes part; more than SDP_Multi.GROUP_ABOVE are planned in
-- groups of nearby cities, each searched with the others' districts in
-- place. Needs a game with more than GROUP_ABOVE cities and pins: a late save
-- (tools/stress.py run pangaea-gs adds city pins to make up the number,
-- SDP_Stress.GroupSites). Changes nothing on the map.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Count()
  local n = 0
  for _ in Players[pid]:GetCities():Members() do n = n + 1 end
  return n + #SDP_City.Sites(pid)
end

test("all cities: every city and pin on, planned in groups, one district per plot", function()
  local n = Count()
  if n <= SDP_Multi.GROUP_ABOVE then
    T.skip(n .. " cities and pins: load a late save (tools/stress.py load pangaea-gs)")
  end
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.SetCenter(nil)
  multi.DefaultCities()
  local ok, err = pcall(function()
    multi.AllCities()
    T.eq(#multi.Participants(), n, "every city and pin takes part")
    T.ok(Controls.MultiCityAll:IsDisabled(), "all on: the button is used up")
    for _, c in ipairs(multi.State().View.Cities) do T.ok(c.Included and not c.Disabled, c.Key .. " on") end
    for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB" }) do multi.SetSelected(d, true) end
    multi.SetTier("FAST")
    T.ok(multi.Solve(), "started")
    SDP_Panel.RunTask(500)
    local r = multi.State().Result
    T.ok(r and r.Ok, "result: " .. tostring(r and r.Error))
    T.eq(r.Stats.Groups, math.ceil(n / SDP_Multi.GROUP_SIZE), "in groups")
    T.ok(not r.Stats.Mismatch, "board and full evaluation agree")
    T.ok(r.Gain >= r.FirstGain - 1e-9, "not worse than city by city")
    local used, cities = {}, {}
    for _, c in ipairs(r.Cities) do cities[c.Key] = c end
    for _, p in ipairs(r.Plan) do
      T.ok(not used[p.Index], "plot used twice: " .. p.X .. "," .. p.Y)
      used[p.Index] = true
      local city = cities[p.City]
      T.ok(city ~= nil and Map.GetPlotDistance(p.X, p.Y, city.X, city.Y) <= 3, p.Type .. " within its city's rings")
    end
    print(string.format("SDP_ALLCITIES cities=%d groups=%d placed=%d unplaced=%d gain=%.1f first=%.1f calls=%s",
      n, r.Stats.Groups, #r.Plan, #r.Unplaced, r.Gain, r.FirstGain, tostring(r.Stats.Calls)))
    T.ok(Controls.MultiBody:GetSizeY() <= Controls.MultiPage:GetSizeY(), "the page fits")
  end)
  for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB" }) do multi.SetSelected(d, false) end
  multi.SetTier("STANDARD")
  multi.DefaultCities()
  SDP_Panel.Close()
  if not ok then error(err, 0) end
end)
