-- @state SDP_Panel
-- @timeout 600
-- Site selection with the real map and DMT (docs/multicity-design.md 3).
-- Needs a city: run tests/fixtures/found_capital.lua first;
-- game.py newgame --capital --reveal also reveals the land around it.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("game data the site score reads", function()
  T.ok(GlobalParameters.CITY_MIN_RANGE ~= nil, "CITY_MIN_RANGE")
  T.ok(GlobalParameters.CITY_POPULATION_RIVER_LAKE ~= nil, "CITY_POPULATION_RIVER_LAKE")
  local resources = Players[pid]:GetResources()
  for row in GameInfo.Resources() do
    T.ok(resources:IsResourceVisible(row.Hash) ~= nil, row.ResourceType .. " visibility")
  end
  if SDP_Rules.Ruleset() == "RULESET_EXPANSION_2" then T.ok(GameInfo.Resource_Consumption ~= nil, "GS extraction rates") end
end)

test("candidates follow the rules on the real map", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local list, centers = SDP_Sites.Candidates(pid, { K = 2, D = 5 })
  if #list == 0 then T.skip("no candidate: explore first (game.py newgame --capital --reveal)") end
  local minRange = SDP_Sites.MinRange()
  for _, c in ipairs(list) do
    local plot = Map.GetPlotByIndex(c.Index)
    T.ok(PlayersVisibility[pid]:IsRevealed(c.Index), "unrevealed candidate")
    T.ok(not plot:IsWater() and not plot:IsMountain(), "terrain")
    for _, center in ipairs(centers) do
      T.ok(Map.GetPlotDistance(c.X, c.Y, center.X, center.Y) > minRange, "too close")
    end
  end
  print(string.format("%d candidates", #list))
end)

test("two sites: spaced, linked back, deterministic", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local request = { PlayerID = pid, Tier = "FAST", K = 2, D = 5, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" } }
  local a = SDP_SiteSolver.Solve(request)
  if not a.Ok and a.Error == "NO_SITE" then T.skip("no room for two sites yet") end
  T.ok(a.Ok, tostring(a.Error))
  local b = SDP_SiteSolver.Solve(request)
  T.eq(b.Solutions[1].Value, a.Solutions[1].Value, "same value")
  local s = a.Solutions[1].Sites
  if #s == 2 then T.ok(Map.GetPlotDistance(s[1].X, s[1].Y, s[2].X, s[2].Y) > SDP_Sites.MinRange(), "spacing") end
  print(string.format("best %.1f with %d candidates, %d refined, %d DMT calls", a.Solutions[1].Value, a.Stats.Candidates,
    a.Stats.Refined, a.Stats.Calls))
end)

-- The player's cities and city-center pins, for distances.
local function OwnCenters()
  local list = {}
  for _, c in ipairs(SDP_Sites.Centers(pid)) do
    if c.Own then list[#list + 1] = c end
  end
  return list
end

local function Nearest(list, x, y, skip)
  local best = nil
  for _, c in ipairs(list) do
    if c ~= skip then
      local d = Map.GetPlotDistance(x, y, c.X, c.Y)
      if best == nil or d < best then best = d end
    end
  end
  return best
end

-- Checks one result: the sites' values and resource shares add up, every
-- visible luxury or strategic copy on their workable plots counted once,
-- both distances as counted on the map. Returns how many sites list resources.
local function CheckSolutions(result, ctx)
  local own = OwnCenters()
  local listed = 0
  for n, solution in ipairs(result.Solutions) do
    local sum, shares = 0, 0
    local onMap, counted, seen = {}, {}, {}
    for _, site in ipairs(solution.Sites) do
      sum = sum + site.Value
      shares = shares + site.Parts.Luxury + site.Parts.Strategic
      local scan = SDP_City.ScanSite(pid, site.X, site.Y, { population = ctx.Population })
      for _, index in ipairs(SDP_Land.Workable(scan)) do
        local plot = Map.GetPlotByIndex(index)
        local resource = plot:GetResourceType()
        if not seen[index] and resource ~= -1 then
          seen[index] = true
          local row = GameInfo.Resources[resource]
          if ctx.Visible[row.ResourceType] and (row.ResourceClassType == "RESOURCECLASS_LUXURY"
              or row.ResourceClassType == "RESOURCECLASS_STRATEGIC") then
            onMap[row.ResourceType] = (onMap[row.ResourceType] or 0) + math.max(1, plot:GetResourceCount())
          end
        end
      end
      for _, copies in ipairs({ site.Luxury, site.Strategic }) do
        for kind, count in pairs(copies) do
          counted[kind] = (counted[kind] or 0) + count
          listed = listed + 1
        end
      end
      T.eq(site.OwnDistance, Nearest(own, site.X, site.Y), "solution " .. n .. ": distance to our cities and pins")
      T.eq(site.SiteDistance, Nearest(solution.Sites, site.X, site.Y, site), "solution " .. n .. ": distance to the other sites")
    end
    T.ok(math.abs(sum - solution.Conflict - solution.Value) < 1e-6, "solution " .. n .. ": site values add up")
    T.ok(math.abs(shares - solution.Resources) < 1e-6, "solution " .. n .. ": resource shares add up")
    T.same(counted, onMap, "solution " .. n .. ": copies counted once")
  end
  return listed
end

test("each site's resources and distances, as on the map (issues 8, 9)", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local request = { PlayerID = pid, Tier = "FAST", K = 3, D = 5, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" } }
  local result = SDP_SiteSolver.Solve(request)
  if not result.Ok and result.Error == "NO_SITE" then T.skip("no room for three sites yet") end
  T.ok(result.Ok, tostring(result.Error))
  local listed = CheckSolutions(result, result.Session.Ctx)
  print(("%d solutions, %d resource kinds listed at their sites"):format(#result.Solutions, listed))

  -- A city-center pin on the map counts as one of ours: a site tack there,
  -- then solve again.
  local first = result.Solutions[1].Sites[1]
  T.eq(SDP_Pins.Place(pid, { { Type = "DISTRICT_CITY_CENTER", X = first.X, Y = first.Y, Name = "test" } }), 1, "site tack")
  local ok, err = pcall(function()
    local again = SDP_SiteSolver.Solve(request)
    if not again.Ok and again.Error == "NO_SITE" then return end
    T.ok(again.Ok, tostring(again.Error))
    CheckSolutions(again, again.Session.Ctx)
    for _, solution in ipairs(again.Solutions) do
      for _, site in ipairs(solution.Sites) do
        T.ok(site.OwnDistance <= Map.GetPlotDistance(site.X, site.Y, first.X, first.Y), "the site tack counts")
      end
    end
  end)
  SDP_Pins.UndoLast(pid)
  if not ok then error(err, 0) end
end)

test("the sites tab shows each site's resources and both distances", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local sites = SDP_Panel.Sites
  SDP_Panel.SelectTab("SITES")
  sites.SetCount(2)
  sites.SetTier("FAST")
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do sites.SetSelected(d.Type, false) end
  sites.SetSelected("DISTRICT_CAMPUS", true)
  sites.SetDistrictCount(1)
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(5000)
  local result = sites.State().Result
  if result and not result.Ok and result.Error == "NO_SITE" then T.skip("no room for two sites yet") end
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  local solution = result.Solutions[sites.State().Solution]
  for s, site in ipairs(solution.Sites) do
    local tip = sites.State().View.Results[s].ToolTip
    T.ok(tip:find(Locale.Lookup("LOC_SDP_SITES_SITE_DISTANCE", site.SiteDistance), 1, true), "distance to the other site")
    for _, copies in ipairs({ site.Luxury, site.Strategic }) do
      for kind, count in pairs(copies) do
        local name = Locale.Lookup(GameInfo.Resources[kind].Name)
        local item = site.NewKinds[kind] and Locale.Lookup("LOC_SDP_SITES_NEW_KIND", name, count) or (name .. " " .. count)
        T.ok(tip:find(item, 1, true), kind .. " in the tooltip")
      end
    end
    -- The parts in points (issue 88): every text found in the game's
    -- language (no key left), the districts part on the row.
    local row = sites.State().View.Results[s]
    T.ok(not row.Detail:find("LOC_SDP_", 1, true), "row text found: " .. row.Detail)
    T.ok(not tip:find("LOC_SDP_", 1, true), "tooltip text found")
    local district = Locale.Lookup("LOC_SDP_SITES_ITEM_SHORT", Locale.Lookup("LOC_SDP_SITES_W_DISTRICT_SHORT"),
      SDP_UI.Number(math.floor(site.Parts.District * 10 + 0.5) / 10))
    T.ok(row.Detail:find(district, 1, true), "the districts part: " .. district)
    print(sites.State().View.Results[s].Name .. " | " .. sites.State().View.Results[s].Detail .. " | "
      .. tip:gsub("%[NEWLINE%]", " / "))
  end
  sites.SetSelected("DISTRICT_CAMPUS", false)
  sites.SetDistrictCount(3)
  SDP_Panel.SelectTab("SINGLE")
end)

-- Issue 90 (decided 2026-10-26): candidates by default, except the Preserve,
-- the Encampment and the Aerodrome, which the rule finds from the game data
-- (no adjacency yield, no amenities; SDP_Rules.Functional). Checked against
-- the decision's three in every ruleset; the unique districts replacing
-- them come along through their base district.
test("issue 90: the districts left out by default are the decision's three", function()
  local named = { DISTRICT_PRESERVE = true, DISTRICT_ENCAMPMENT = true, DISTRICT_AERODROME = true }
  local functional = SDP_Rules.Functional(pid)
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    local base = SDP_Rules.BaseDistrict(d.Type)
    if d.Specialty and named[base] then T.ok(functional[d.Type], d.Type .. " left out by default") end
    if functional[d.Type] then
      T.ok(named[base], d.Type .. " is one of the three")
      list[#list + 1] = d.Type
    end
  end
  table.sort(list)
  print(SDP_Rules.Ruleset() .. ": " .. table.concat(list, " "))
end)

-- A cell's Click is the function the cell itself calls on a click (the
-- game's controls cannot be clicked from Lua; realclick.py clicks them).
test("issue 90: the sites tab's district grid through its cells; solved with the defaults", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local sites = SDP_Panel.Sites
  SDP_Panel.SelectTab("SITES")
  local function Row(districtType)
    for _, r in ipairs(sites.State().View.Districts) do
      if r.Type == districtType then return r end
    end
  end
  local campus = nil
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if SDP_Rules.BaseDistrict(d.Type) == "DISTRICT_CAMPUS" then campus = d.Type end
  end
  T.eq(Row(campus).State, "POOL", "campus: a candidate")
  T.eq(sites.State().DistrictCount, 3, "count 3")
  Row(campus).Click()
  T.eq(Row(campus).State, "MUST", "a click: required")
  T.eq(#sites.Request().Districts, 1, "sent as required")
  T.eq(sites.Request().Pick, 2, "two more picked")
  Row(campus).Click()
  Row(campus).Click()
  T.eq(Row(campus).State, "POOL", "round to a candidate")
  sites.SetCount(2)
  sites.SetTier("STANDARD")
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(5000)
  local result = sites.State().Result
  if result and not result.Ok and result.Error == "NO_SITE" then T.skip("no room for two sites yet") end
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  for _, site in ipairs(result.Solutions[1].Sites) do
    local types = {}
    for _, d in ipairs(site.Districts or {}) do types[#types + 1] = d.Type end
    T.ok(#types <= 3, "at most three districts: " .. table.concat(types, " "))
    print(string.format("site %d,%d  %.1f  districts %.1f  %s", site.X, site.Y, site.Value, site.Parts.District or 0,
      table.concat(types, " ")))
  end
  SDP_Panel.SelectTab("SINGLE")
end)
