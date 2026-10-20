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
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetSelected(d.Type, false) end
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
local function SitePin(city, distance)
  local cfg = PlayerConfigurations[pid]
  for index = 0, Map.GetPlotCount() - 1 do
    local plot = Map.GetPlotByIndex(index)
    if Map.GetPlotDistance(plot:GetX(), plot:GetY(), city:GetX(), city:GetY()) == distance
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
  T.skip("no free revealed land " .. distance .. " plots from the capital")
end

local function RemovePin(id)
  local cfg = PlayerConfigurations[pid]
  local pin = cfg:GetMapPinID(id)
  if pin == nil then return end
  LuaEvents.DMT_MapPinRemoved(pin)
  cfg:DeleteMapPin(id)
  Network.BroadcastPlayerInfo()
end

test("multi tab: with the coverage weight the industrial zone reaches a planned city that has none", function()
  local city = Capital()
  local zone = Resolve("DISTRICT_INDUSTRIAL_ZONE")
  local reach = SDP_Coverage.Reaches(pid)[zone]
  if reach == nil then T.skip("no regional building for the industrial zone in this ruleset") end
  local pinID, sx, sy = SitePin(city, reach.Range)
  local multi = SDP_Panel.Multi
  local ok, err = pcall(function()
    SDP_Panel.SelectTab("MULTI")
    multi.Refresh()
    multi.SetExisting(city:GetID(), true)
    multi.SetPlanFor("ALL")
    multi.ApplyPlan({})
    multi.SetPlanFor("C" .. city:GetID())
    multi.ApplyPlan({ zone })
    multi.SetTier("FAST")
    multi.SetWeight("COVERAGE", 3)
    T.ok(multi.Solve(), "started")
    SDP_Panel.RunTask(5000)
    local result = multi.State().Result
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
    T.ok(math.abs(result.Gain - (result.Adjacency + result.LandDelta + result.CoverageDelta)) < 1e-6, "the gain adds up")
    local placed = nil
    for _, p in ipairs(result.Plan) do
      if p.Type == zone then placed = p end
    end
    T.ok(placed ~= nil, "the industrial zone is planned")
    T.ok(Map.GetPlotDistance(placed.X, placed.Y, sx, sy) <= reach.Range,
      "the zone at " .. placed.X .. "," .. placed.Y .. " reaches the site at " .. sx .. "," .. sy)
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
  RemovePin(pinID)
  if not ok then error(err, 0) end
end)
