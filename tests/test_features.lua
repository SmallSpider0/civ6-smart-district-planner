-- @state SDP_Panel
-- @timeout 300
-- The functions taken over from AMT and Empire Planner
-- (docs/multicity-design.md section 18): the open key, wonders on the
-- single-city tab, the good-places map, the pin record kept with the game,
-- replacing this mod's earlier pins, a city's own list on the multi tab.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game
-- (game.py newgame --capital --reveal).
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

local function Resolve(base)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if plannable[base] then return base end
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then return row.CivUniqueDistrictType end
  end
  T.skip(base .. " not available to this civ")
end

-- Single-city tab: the capital, only `districts`, standard tier.
local function Reset(districts)
  local city = Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, "OFF") end
  SDP_Panel.SetCount(0)
  SDP_Panel.SetRemind(false)
  for _, w in ipairs(SDP_Wonders.List(pid)) do SDP_Panel.SetWonder(w.Type, false) end
  for _, d in ipairs(districts) do SDP_Panel.SetSelected(d, true) end
  SDP_Panel.SetReplace(false)
  SDP_Panel.SetTier("STANDARD")
  return city
end

local function UndoAll()
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
end

local function Finally(fn)
  local ok, err = pcall(fn)
  UndoAll()
  SDP_Panel.ShowHeat(nil)
  SDP_Panel.SetReplace(false)
  for _, w in ipairs(SDP_Wonders.List(pid)) do SDP_Panel.SetWonder(w.Type, false) end
  if not ok then error(err, 0) end
end

test("the open key is in the game's input actions", function()
  local id = Input.GetActionId("SDP_OpenPlanner")
  T.ok(id ~= nil and id ~= -1, "action id " .. tostring(id))
end)

test("the wonder list goes by era, then production cost, then type (issue 7)", function()
  local list = SDP_Wonders.List(pid)
  T.ok(#list > 10, "wonders: " .. #list)
  local eras = {}
  for n, w in ipairs(list) do
    -- The era straight from the rules: the later of the tech's and the civic's.
    local row = GameInfo.Buildings[w.Type]
    local expected = 0
    if row.PrereqTech then
      expected = GameInfo.Eras[GameInfo.Technologies[row.PrereqTech].EraType].ChronologyIndex
    end
    if row.PrereqCivic then
      expected = math.max(expected, GameInfo.Eras[GameInfo.Civics[row.PrereqCivic].EraType].ChronologyIndex)
    end
    T.eq(w.Era, expected, w.Type .. " era")
    T.eq(w.Cost, row.Cost, w.Type .. " cost")
    eras[w.Era] = true
    local prev = list[n - 1]
    if prev then
      local ordered = prev.Era < w.Era or (prev.Era == w.Era and (prev.Cost < w.Cost
        or (prev.Cost == w.Cost and prev.Type < w.Type)))
      T.ok(ordered, prev.Type .. " before " .. w.Type)
    end
  end
  local count = 0
  for _ in pairs(eras) do count = count + 1 end
  T.ok(count >= 5, "wonders from several eras: " .. count)
  print(("%d wonders, first %s, last %s"):format(#list, list[1].Type, list[#list].Type))
end)

test("single-city tab: a wonder planned with the districts and pinned with its icon", function()
  Finally(function()
    Reset({ Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE") })
    -- A wonder without a required neighbour district, not built or pinned.
    local wonder
    for _, w in ipairs(SDP_Wonders.List(pid)) do
      if wonder == nil and w.Status == nil and w.AdjacentDistrict == nil then wonder = w.Type end
    end
    if wonder == nil then T.skip("no free wonder") end
    SDP_Panel.SetWonder(wonder, true)
    T.eq(SDP_Panel.Solve(), nil, "solved as a task")
    local result = SDP_Panel.RunTask(5000)
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    local planned = {}
    for _, p in ipairs(result.Plan) do planned[p.Type] = p end
    if planned[wonder] == nil then
      -- No legal plot for it near this capital: then it is listed as unplaced.
      local listed = false
      for _, u in ipairs(result.Unplaced) do if u.Type == wonder then listed = true end end
      T.ok(listed, "the wonder is neither planned nor listed as unplaced")
      return
    end
    T.eq(SDP_Panel.PlacePins(), #result.Plan, "pins")
    local p = planned[wonder]
    local stored = GetMapPinSubject(pid, p.X, p.Y)
    T.ok(stored ~= nil and stored.Key == wonder, "DMT knows the wonder pin")
  end)
end)

test("a wonder that must touch a district is not lost when the districts cluster", function()
  Finally(function()
    local campus = Resolve("DISTRICT_CAMPUS")
    local wanted = { campus }
    for _, base in ipairs({ "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" }) do
      local ok, d = pcall(Resolve, base)
      if ok then wanted[#wanted + 1] = d end
    end
    Reset(wanted)
    -- Every free wonder that must touch a campus, one at a time: some have no
    -- legal plot near this capital at all (Amundsen-Scott wants tundra or
    -- snow), so at least one must actually be placed for the test to count.
    local tried, placed = 0, 0
    for _, w in ipairs(SDP_Wonders.List(pid)) do
      if w.Status == nil and w.AdjacentDistrict == "DISTRICT_CAMPUS" then
        tried = tried + 1
        SDP_Panel.SetWonder(w.Type, true)
        T.eq(SDP_Panel.Solve(), nil, "solved as a task")
        local result = SDP_Panel.RunTask(5000)
        T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
        for _, p in ipairs(result.Plan) do
          if p.Type == w.Type then placed = placed + 1 end
        end
        for _, u in ipairs(result.Unplaced) do
          T.ok(not (u.Type == w.Type and u.Reason == "NO_FREE_PLOT"), w.Type .. " left off although it had a plot")
        end
        SDP_Panel.SetWonder(w.Type, false)
      end
    end
    if tried == 0 then T.skip("no free wonder next to a campus") end
    if placed == 0 then T.skip("no wonder next to a campus has a legal plot here") end
    print(("%d of %d wonders next to a campus placed"):format(placed, tried))
  end)
end)

test("the good-places map: legal plots best first, the best not beaten by any one placement", function()
  Finally(function()
    local campus = Resolve("DISTRICT_CAMPUS")
    Reset({ campus })
    SDP_Panel.SetLand(false)
    SDP_Panel.ShowHeat(campus)
    local spots = SDP_Panel.Heat()
    T.ok(spots ~= nil and #spots > 0, "spots")
    for i = 2, #spots do T.ok(spots[i - 1].Gain >= spots[i].Gain, "best first") end
    T.ok(SDP_Preview.IsShown(), "drawn on the map")
    local solo = SDP_Panel.Solve()
    T.ok(solo and solo.Ok, "solve")
    T.near(solo.Adjacency, spots[1].Gain, 1e-9, "the solver's single campus is the best spot")
    T.ok(not SDP_Preview.IsShown() or SDP_Panel.State().HeatDistrict == nil, "solving takes the map down")
    SDP_Panel.SetLand(true)
  end)
end)

test("the pin record survives a reload; replace plans over this mod's pins; undo brings them back", function()
  Finally(function()
    local city = Reset({ Resolve("DISTRICT_CAMPUS") })
    local number = SDP_City.CityNumbers(pid)[city:GetID()]
    local first = SDP_Panel.Solve()
    local plot = first.Plan[1].Index
    T.eq(SDP_Panel.PlacePins(), 1, "placed")
    -- What a save and load leaves: the record in the player's configuration.
    T.ok(type(PlayerConfigurations[pid]:GetValue(SDP_Pins.CONFIG_KEY)) == "string", "record saved")
    SDP_Pins.Reset()
    T.ok(SDP_Pins.CanUndo(), "undo after re-reading the record")
    T.eq(#SDP_Pins.Own(pid, { number }), 1, "the pin is ours")

    local locked = SDP_Panel.Solve()
    T.ok(locked.Plan[1].Index ~= plot, "without replace the pinned plot is taken")
    SDP_Panel.SetReplace(true)
    local again = SDP_Panel.Solve()
    T.eq(again.Plan[1].Index, plot, "with replace the old pin's plot is free")
    local before = #PlayerConfigurations[pid]:GetMapPins()
    T.eq(SDP_Panel.PlacePins(), 1, "placed")
    T.eq(#PlayerConfigurations[pid]:GetMapPins(), before, "replaced, not added")
    T.eq(SDP_Panel.UndoPins(), 1, "undo")
    T.eq(#PlayerConfigurations[pid]:GetMapPins(), before, "the old pin is back")
    local back = SDP_Pins.Own(pid, { number })[1]
    T.ok(back ~= nil and Map.GetPlotIndex(back.X, back.Y) == plot, "at its plot")
    local subject = GetMapPinSubject(pid, back.X, back.Y)
    T.ok(subject ~= nil and subject.Key == first.Plan[1].Type, "DMT knows the restored pin")
  end)
end)

test("multi tab: the government plaza stays in the one city whose own list has it", function()
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = d end
  if plannable.DISTRICT_GOVERNMENT == nil then T.skip("no Government Plaza in this ruleset") end
  local city = Capital()
  local multi = SDP_Panel.Multi
  SDP_Panel.SelectTab("MULTI")
  multi.Refresh()
  multi.SetExisting(city:GetID(), true)
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ Resolve("DISTRICT_CAMPUS") })
  local key = "C" .. city:GetID()
  multi.SetPlanFor(key)
  multi.SetSelected("DISTRICT_GOVERNMENT", true)
  local ok, err = pcall(function()
    multi.SetTier("FAST")
    T.ok(multi.Solve(), "started")
    local result = SDP_Panel.RunTask(5000)
    result = multi.State().Result
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    for _, p in ipairs(result.Plan) do
      if p.Type == "DISTRICT_GOVERNMENT" then T.eq(p.City, key, "in the capital") end
    end
  end)
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({})
  multi.SetExisting(city:GetID(), nil)
  SDP_Panel.SelectTab("SINGLE")
  if not ok then error(err, 0) end
end)

-- A city-center pin `distance` plots from the capital on revealed land, as
-- the DMT popup makes one; returns its ID (pin objects go stale: pitfall 21).
-- A city-center pin on free revealed land `distance` plots from the city
-- (the first distance in the list that has one) and, when `away` is given,
-- more than `beyond` plots from it.
local function SitePin(city, distances, away, beyond)
  if type(distances) ~= "table" then distances = { distances } end
  local cfg = PlayerConfigurations[pid]
  for _, distance in ipairs(distances) do
    for index = 0, Map.GetPlotCount() - 1 do
      local plot = Map.GetPlotByIndex(index)
      if Map.GetPlotDistance(plot:GetX(), plot:GetY(), city:GetX(), city:GetY()) == distance
          and (away == nil or Map.GetPlotDistance(plot:GetX(), plot:GetY(), away.X, away.Y) > beyond)
          and PlayersVisibility[pid]:IsRevealed(index) and not plot:IsWater() and not plot:IsMountain()
          and not plot:IsImpassable() and plot:GetOwner() == -1 then
        local pin = cfg:GetMapPin(plot:GetX(), plot:GetY())
        pin:SetIconName("ICON_DISTRICT_CITY_CENTER")
        pin:SetName("")
        LuaEvents.DMT_MapPinAdded(pin)
        Network.BroadcastPlayerInfo()
        return pin:GetID(), plot:GetX(), plot:GetY()
      end
    end
  end
  T.skip("no free revealed land " .. table.concat(distances, "/") .. " plots from the capital")
end

local function RemovePin(id)
  local cfg = PlayerConfigurations[pid]
  local pin = cfg:GetMapPinID(id)
  if pin == nil then return end
  LuaEvents.DMT_MapPinRemoved(pin)
  cfg:DeleteMapPin(id)
  Network.BroadcastPlayerInfo()
end

test("multi tab: with the coverage weight the industrial zone moves to reach a planned city that has none", function()
  local city = Capital()
  local zone = Resolve("DISTRICT_INDUSTRIAL_ZONE")
  local reach = SDP_Coverage.Reaches(pid)[zone]
  if reach == nil then T.skip("no regional building for the industrial zone in this ruleset") end
  local multi = SDP_Panel.Multi
  local pinID, sx, sy
  local function SolveZone(weight)
    multi.Refresh()
    multi.SetExisting(city:GetID(), true)
    multi.SetPlanFor("ALL")
    multi.ApplyPlan({})
    multi.SetPlanFor("C" .. city:GetID())
    multi.ApplyPlan({ zone })
    multi.SetTier("FAST")
    multi.SetWeight("COVERAGE", weight)
    T.ok(multi.Solve(), "started")
    SDP_Panel.RunTask(5000)
    local result = multi.State().Result
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    for _, p in ipairs(result.Plan) do
      if p.Type == zone then return result, p end
    end
    T.ok(false, "the industrial zone is planned")
  end
  local ok, err = pcall(function()
    SDP_Panel.SelectTab("MULTI")
    -- Where the zone goes without coverage; the site goes out of its reach.
    local _, alone = SolveZone(0)
    -- Within reach of the capital's third ring at most.
    pinID, sx, sy = SitePin(city, { reach.Range, reach.Range + 1, reach.Range + 2 }, alone, reach.Range)
    local _, plain = SolveZone(0)
    T.ok(Map.GetPlotDistance(plain.X, plain.Y, sx, sy) > reach.Range,
      "without coverage the zone at " .. plain.X .. "," .. plain.Y .. " does not reach the site at " .. sx .. "," .. sy)
    local result = SolveZone(3)
    T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
    T.ok(math.abs(result.Gain - (result.Adjacency + result.LandDelta + result.CoverageDelta + result.CostDelta
      + (result.AppealDelta or 0))) < 1e-6, "the gain adds up")
    local placed = nil
    for _, p in ipairs(result.Plan) do
      if p.Type == zone then placed = p end
    end
    T.ok(Map.GetPlotDistance(placed.X, placed.Y, sx, sy) <= reach.Range,
      "with weight 3 the zone at " .. placed.X .. "," .. placed.Y .. " reaches the site at " .. sx .. "," .. sy)
    print(string.format("zone %d,%d without coverage, %d,%d with weight 3; site %d,%d; range %d",
      plain.X, plain.Y, placed.X, placed.Y, sx, sy, reach.Range))
    local site = nil
    for _, c in ipairs(result.Cities) do
      if c.Kind == "SITE" and c.X == sx and c.Y == sy then site = c.Key end
    end
    local listed = false
    for _, entry in ipairs(result.CoveredBy) do
      for _, key in ipairs(entry.Keys) do
        if key == site then listed = true end
      end
    end
    T.ok(listed, "the site is among the newly covered cities")
  end)
  multi.SetWeight("COVERAGE", 0)
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
  multi.SetExisting(city:GetID(), nil)
  SDP_Panel.SelectTab("SINGLE")
  if pinID ~= nil then RemovePin(pinID) end
  if not ok then error(err, 0) end
end)

-- Issue 61: the coverage column on the single-city tab.
-- The industrial zone's row and the result's lists: what each key says.
local function CheckCoverage(result, zone, placed, range)
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  T.ok(math.abs(result.Gain - (result.Adjacency + result.LandDelta + result.CoverageDelta + result.CostDelta
    + (result.AppealDelta or 0))) < 1e-6, "the gain adds up")
  T.ok(math.abs(result.CoverageDelta - 3 * result.Covered) < 1e-6, "weight x newly covered cities")
  -- Counted again here, from the targets: in reach of the zone and not
  -- covered by a built or pinned district of its group.
  local model = SDP_Coverage.New({ PlayerID = pid, Weight = 3, Sites = SDP_Coverage.SiteTargets(pid) })
  local want = {}
  for _, id in ipairs(model:InReach(zone, placed.X, placed.Y)) do
    if not model.Covered[id] then want[#want + 1] = model:Pair(id).Key end
  end
  T.same(placed.Reach, want, "the row lists the cities the zone newly covers")
  local listed = {}
  for _, entry in ipairs(result.CoveredBy) do
    for _, key in ipairs(entry.Keys) do listed[#listed + 1] = key end
  end
  table.sort(listed)
  table.sort(want)
  T.same(listed, want, "the summary's newly covered cities")
  for _, key in ipairs(want) do
    for _, target in ipairs(model.Targets) do
      if target.Key == key then
        T.ok(Map.GetPlotDistance(placed.X, placed.Y, target.X, target.Y) <= range, key .. " in reach")
      end
    end
  end
  return model, want
end

local function SingleZone(zone, weight)
  Reset({ zone })
  SDP_Panel.SetLand(false)
  SDP_Panel.SetWeight("COVERAGE", weight)
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.eq(result.Session.Request.Coverage, weight, "the weight is in the request")
  for _, p in ipairs(result.Plan) do
    if p.Type == zone then return result, p end
  end
  T.ok(false, "the industrial zone is planned")
end

test("single-city tab: with the coverage weight the industrial zone moves to reach a city-center pin", function()
  local city = Capital()
  local zone = Resolve("DISTRICT_INDUSTRIAL_ZONE")
  local reach = SDP_Coverage.Reaches(pid)[zone]
  if reach == nil then T.skip("no regional building for the industrial zone in this ruleset") end
  local pinID, sx, sy
  local ok, err = pcall(function()
    local off, alone = SingleZone(zone, 0)
    T.eq(off.Covered, nil, "no coverage figures at weight 0")
    T.eq(alone.Reach, nil, "no reach on the row at weight 0")
    pinID, sx, sy = SitePin(city, { reach.Range, reach.Range + 1, reach.Range + 2 }, alone, reach.Range)
    local _, plain = SingleZone(zone, 0)
    T.ok(Map.GetPlotDistance(plain.X, plain.Y, sx, sy) > reach.Range,
      "without coverage the zone at " .. plain.X .. "," .. plain.Y .. " does not reach the pin at " .. sx .. "," .. sy)
    local result, placed = SingleZone(zone, 3)
    T.ok(Map.GetPlotDistance(placed.X, placed.Y, sx, sy) <= reach.Range,
      "with weight 3 the zone at " .. placed.X .. "," .. placed.Y .. " reaches the pin at " .. sx .. "," .. sy)
    local _, want = CheckCoverage(result, zone, placed, reach.Range)
    local site = "S" .. Map.GetPlotIndex(sx, sy)
    local listed = false
    for _, key in ipairs(want) do
      if key == site then listed = true end
    end
    T.ok(listed, "the pin is among the newly covered cities")
    print(string.format("single: zone %d,%d without coverage, %d,%d with weight 3 (adjacency %+g -> %+g); pin %d,%d; range %d",
      plain.X, plain.Y, placed.X, placed.Y, off.Adjacency, result.Adjacency, sx, sy, reach.Range))
  end)
  SDP_Panel.SetWeight("COVERAGE", 0)
  SDP_Panel.SetLand(true)
  if pinID ~= nil then RemovePin(pinID) end
  if not ok then error(err, 0) end
end)

-- On a save with several cities (tools/stress.py load ...): a city that can
-- still plan an industrial zone, with another of the player's cities in reach
-- of its third ring that no industrial zone covers yet.
test("single-city tab: on a save with several cities, the neighbours the zone can reach are counted", function()
  local zone = Resolve("DISTRICT_INDUSTRIAL_ZONE")
  local reach = SDP_Coverage.Reaches(pid)[zone]
  if reach == nil then T.skip("no regional building for the industrial zone in this ruleset") end
  local cities = {}
  for _, c in Players[pid]:GetCities():Members() do cities[#cities + 1] = c end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  if #cities < 2 then T.skip("one city: load a save with several (tools/stress.py load pangaea-gs)") end
  local model = SDP_Coverage.New({ PlayerID = pid, Weight = 1, Sites = SDP_Coverage.SiteTargets(pid) })
  local uncovered = {}
  for t, target in ipairs(model.Targets) do
    if target.CityID ~= nil and not model.Covered[(model.GroupIndex[reach.Group] - 1) * #model.Targets + t] then
      uncovered[#uncovered + 1] = target
    end
  end
  local chosen, neighbours = nil, nil
  for _, c in ipairs(cities) do
    local scan = SDP_City.Scan(pid, c:GetID(), SDP_City.ScanOptions({}))
    local status = scan and SDP_City.DistrictStatus(scan, SDP_Rules.PlannableDistricts(pid))[zone]
    if chosen == nil and scan ~= nil and status == nil then
      local near = {}
      for _, target in ipairs(uncovered) do
        if target.CityID ~= c:GetID() and Map.GetPlotDistance(c:GetX(), c:GetY(), target.X, target.Y) <= reach.Range + 3 then
          near[#near + 1] = target
        end
      end
      if #near > 0 then chosen, neighbours = c, near end
    end
  end
  if chosen == nil then T.skip("no city that can plan an industrial zone with an uncovered city in reach") end
  local function Solve(weight)
    SDP_Panel.SelectTab("SINGLE")
    SDP_Panel.SelectCity(chosen:GetID())
    for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, "OFF") end
    SDP_Panel.SetCount(0)
    SDP_Panel.SetRemind(false)
    for _, w in ipairs(SDP_Wonders.List(pid)) do SDP_Panel.SetWonder(w.Type, false) end
    SDP_Panel.SetSelected(zone, true)
    SDP_Panel.SetReplace(false)
    SDP_Panel.SetTier("STANDARD")
    SDP_Panel.SetLand(false)
    SDP_Panel.SetWeight("COVERAGE", weight)
    local result = SDP_Panel.Solve()
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    for _, p in ipairs(result.Plan) do
      if p.Type == zone then return result, p end
    end
    T.ok(false, "the industrial zone is planned")
  end
  local ok, err = pcall(function()
    local off, plain = Solve(0)
    local result, placed = Solve(3)
    local _, want = CheckCoverage(result, zone, placed, reach.Range)
    -- Newly covered at weight 0's place, counted with the same model.
    local before = 0
    for _, id in ipairs(model:InReach(zone, plain.X, plain.Y)) do
      if not model.Covered[id] then before = before + 1 end
    end
    T.ok(result.Covered >= before, "covers at least as many as without coverage: " .. result.Covered .. " vs " .. before)
    T.ok(result.Gain >= off.Gain + 3 * before - 1e-6, "at least as good under its own objective")
    local names = {}
    for _, n in ipairs(neighbours) do names[#names + 1] = n.Key end
    local others = 0
    for _, key in ipairs(want) do
      if key ~= "C" .. chosen:GetID() then others = others + 1 end
    end
    print(string.format("city %d (%s): zone %d,%d -> %d,%d, adjacency %+g -> %+g, newly covered %d -> %d (%d other cities: %s); uncovered near: %s",
      chosen:GetID(), Locale.Lookup(chosen:GetName()), plain.X, plain.Y, placed.X, placed.Y, off.Adjacency, result.Adjacency,
      before, result.Covered, others, table.concat(want, " "), table.concat(names, " ")))
  end)
  SDP_Panel.SetWeight("COVERAGE", 0)
  SDP_Panel.SetLand(true)
  if not ok then error(err, 0) end
end)
