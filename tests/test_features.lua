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
    local wonder
    for _, w in ipairs(SDP_Wonders.List(pid)) do
      if wonder == nil and w.Status == nil and w.AdjacentDistrict == "DISTRICT_CAMPUS" then wonder = w.Type end
    end
    if wonder == nil then T.skip("no free wonder next to a campus") end
    SDP_Panel.SetWonder(wonder, true)
    T.eq(SDP_Panel.Solve(), nil, "solved as a task")
    local result = SDP_Panel.RunTask(5000)
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    for _, u in ipairs(result.Unplaced) do
      T.ok(not (u.Type == wonder and u.Reason == "NO_FREE_PLOT"), "left off although it had a plot")
    end
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
