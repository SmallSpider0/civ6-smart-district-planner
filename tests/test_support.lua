-- @state SDP_Panel
-- @timeout 300
-- @setup GameCore_Tuner tests/fixtures/camp_setup.lua
-- @teardown GameCore_Tuner tests/fixtures/camp_teardown.lua
-- A wonder that must stand next to an improvement (issue 51): the Temple of
-- Artemis is planned with a Camp next to it, and their tacks go down and
-- come off together. The fixture puts deer two rings from the capital (Rise
-- and Fall, Gathering Storm; the base game has no such wonder: skipped).
-- Needs a capital: game.py newgame --capital.
local test, T = ...

local pid = Game.GetLocalPlayer()
local cfg = PlayerConfigurations[pid]
local TEMPLE = "BUILDING_TEMPLE_ARTEMIS"
local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function Capital()
  local row = GameInfo.Buildings[TEMPLE]
  if row == nil or row.AdjacentImprovement == nil then T.skip("no wonder next to an improvement in this ruleset") end
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  for _, w in ipairs(SDP_Wonders.List(pid)) do
    if w.Type == TEMPLE and w.Status ~= nil then T.skip("the temple is " .. w.Status) end
  end
  return city, row.AdjacentImprovement
end

local function PinAt(x, y)
  for _, pin in pairs(cfg:GetMapPins()) do
    if pin:GetHexX() == x and pin:GetHexY() == y then return pin end
  end
  return nil
end

local function TempleOf(result)
  for _, p in ipairs(result.Plan) do
    if p.Type == TEMPLE then return p end
  end
  return nil
end

-- Resources the improvement can go on (Improvement_ValidResources).
local function ValidResources(improvementType)
  local valid = {}
  for row in GameInfo.Improvement_ValidResources() do
    if row.ImprovementType == improvementType then valid[GameInfo.Resources[row.ResourceType].Index] = true end
  end
  return valid
end

test("the temple is planned with a camp next to it on a tile a camp can go on", function()
  local city, improvement = Capital()
  local result = SDP_Multi.Solve({ PlayerID = pid, Tier = "FAST", Weights = WEIGHTS, Districts = {}, Wonders = { TEMPLE },
    Only = { [city:GetID()] = true } })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree (legality included)")
  local temple = TempleOf(result)
  T.ok(temple ~= nil, "temple placed")
  local s = temple.Support
  T.ok(s ~= nil, "a camp planned with it (no camp of the player is next to the capital's tiles)")
  T.eq(s.Type, improvement, "the improvement the rules name")
  T.eq(Map.GetPlotDistance(s.X, s.Y, temple.X, temple.Y), 1, "next to the temple")
  local plot = Map.GetPlot(s.X, s.Y)
  T.ok(ValidResources(improvement)[plot:GetResourceType()], "on a resource the camp takes")
  T.eq(plot:GetImprovementType(), -1, "no improvement there yet")
  T.ok(plot:GetOwner() == pid or plot:GetOwner() == -1, "the player's or unowned")
  for _, p in ipairs(result.Plan) do T.ok(p.Index ~= s.Index, p.Type .. " not on the camp's tile") end
  -- DMT: legal with the camp on the map, not without it.
  SDP_Overlay.With(pid, function()
    local subjects = { { Key = TEMPLE, Type = "WONDER", X = temple.X, Y = temple.Y } }
    T.ok(SDP_Overlay.Evaluate(subjects, {}, WEIGHTS, { { Key = improvement, Type = "IMPROVEMENT", X = s.X, Y = s.Y } }).Legal,
      "legal with the camp")
    T.ok(not SDP_Overlay.Evaluate(subjects, {}, WEIGHTS).Legal, "not legal without it")
  end)
  -- Same request, same camp.
  local again = TempleOf(SDP_Multi.Solve({ PlayerID = pid, Tier = "FAST", Weights = WEIGHTS, Districts = {}, Wonders = { TEMPLE },
    Only = { [city:GetID()] = true } }))
  T.eq(again.X .. "," .. again.Y .. " " .. again.Support.X .. "," .. again.Support.Y,
    temple.X .. "," .. temple.Y .. " " .. s.X .. "," .. s.Y, "deterministic")
end)

test("single-city tab: the camp's row, and its tack placed and undone with the temple's", function()
  local city, improvement = Capital()
  local ok, err = pcall(function()
    SDP_Panel.SelectTab("SINGLE")
    SDP_Panel.SelectCity(city:GetID())
    for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, "OFF") end
    SDP_Panel.SetCount(0)
    SDP_Panel.SetRemind(false)
    SDP_Panel.SetTier("FAST")
    SDP_Panel.SetWonder(TEMPLE, true)
    T.eq(SDP_Panel.Solve(), nil, "with a wonder the city is solved as a task")
    local result = SDP_Panel.RunTask(500)
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    local temple = TempleOf(result)
    T.ok(temple ~= nil and temple.Support ~= nil, "temple with a camp")
    local s = temple.Support
    local row = nil
    for _, r in ipairs(SDP_Panel.State().ResultRows) do
      if r.Icon == "ICON_" .. improvement then row = r end
    end
    T.ok(row ~= nil, "a result row for the camp")
    T.ok(row.Name:find(Locale.Lookup(GameInfo.Improvements[improvement].Name), 1, true) ~= nil, "named with the game's name")
    local placed = SDP_Panel.PlacePins()
    T.eq(placed, #result.Plan + 1, "the plan's tacks and the camp's")
    local number = tostring(SDP_City.CityNumbers(pid)[city:GetID()])
    local pin = PinAt(s.X, s.Y)
    T.ok(pin ~= nil, "the camp's tack")
    T.eq(pin:GetIconName(), "ICON_" .. improvement, "camp icon")
    T.eq(pin:GetName(), number, "named with the city's number")
    local subject = GetMapPinSubject(pid, s.X, s.Y)
    T.ok(subject ~= nil and subject.Type == "IMPROVEMENT" and subject.Key == improvement, "DMT knows it as an improvement")
    T.ok(PinAt(temple.X, temple.Y) ~= nil, "the temple's tack")
    T.eq(SDP_Panel.UndoPins(), placed, "undo takes both")
    T.eq(PinAt(s.X, s.Y), nil, "camp tack gone")
    T.eq(PinAt(temple.X, temple.Y), nil, "temple tack gone")
    T.eq(GetMapPinSubject(pid, s.X, s.Y), nil, "DMT forgot the camp")
  end)
  SDP_Panel.SetWonder(TEMPLE, false)
  SDP_Panel.SetTier("STANDARD")
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
  if not ok then error(err, 0) end
end)
