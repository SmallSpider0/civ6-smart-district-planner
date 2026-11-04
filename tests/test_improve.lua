-- @state SDP_Panel
-- @timeout 300
-- @setup GameCore_Tuner tests/fixtures/improve_setup.lua
-- @teardown GameCore_Tuner tests/fixtures/improve_teardown.lua
-- Improvements planned with the districts (issue 227): with the real DMT,
-- an improvement tack next to a district gives it the adjacency the rules
-- say; the plan's own numbers equal DMT's with every tack on the map; the
-- tacks go down and come off with the districts. The fixture puts a bonus
-- resource whose improvement gives a district adjacency one for one (a
-- Quarry's stone next to an Industrial Zone) two rings from the capital.
-- Needs a capital: game.py newgame --capital.
local test, T = ...

local pid = Game.GetLocalPlayer()
local cfg = PlayerConfigurations[pid]
local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- The fixture's choice again: the district, the improvement, its row and
-- the resource; and the resource's tile two rings from the capital.
local function Setup()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  for link in GameInfo.District_Adjacencies() do
    local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
    if row ~= nil and row.AdjacentImprovement ~= nil and (row.TilesRequired or 1) == 1 then
      for r in GameInfo.Improvement_ValidResources() do
        local res = GameInfo.Resources[r.ResourceType]
        if r.ImprovementType == row.AdjacentImprovement and res ~= nil and res.ResourceClassType == "RESOURCECLASS_BONUS" then
          for dx = -2, 2 do
            for dy = -2, 2 do
              local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 2)
              if p ~= nil and Map.GetPlotDistance(city:GetX(), city:GetY(), p:GetX(), p:GetY()) == 2
                  and p:GetResourceType() == res.Index and p:GetImprovementType() == -1 then
                return city, link.DistrictType, row, p
              end
            end
          end
          T.skip("the fixture's resource is not two rings from the capital")
        end
      end
    end
  end
  T.skip("no improvement gives a district adjacency one for one in this ruleset")
end

local function PinAt(x, y)
  for _, pin in pairs(cfg:GetMapPins()) do
    if pin:GetHexX() == x and pin:GetHexY() == y then return pin end
  end
  return nil
end

local function Find(plan, districtType)
  for _, p in ipairs(plan) do
    if p.Type == districtType then return p end
  end
  return nil
end

test("DMT counts an improvement tack next to a district as the rules say; the model plans it", function()
  local city, district, row, plot = Setup()
  local rules = SDP_Improve.Rules(pid)
  local found = false
  for _, g in ipairs(rules.Gives[district] or {}) do
    if g.Improvement == row.AdjacentImprovement then found = true end
  end
  T.ok(found, "the rules read: " .. district .. " from " .. row.AdjacentImprovement)
  -- A district on a free tile next to the resource.
  local scan = SDP_City.Scan(pid, city:GetID())
  local at = nil
  for _, c in ipairs(scan.Candidates) do
    if at == nil and Map.GetPlotDistance(c.X, c.Y, plot:GetX(), plot:GetY()) == 1 then at = c end
  end
  if at == nil then T.skip("no candidate tile next to the resource") end
  local model = SDP_Improve.New({ PlayerID = pid, Weights = WEIGHTS, Ownable = scan.Reach.Reached, Taken = {}, Fixed = {} })
  local plan = model:Assign({ { Type = district, Kind = "DISTRICT", Index = at.Index } })
  local planned = nil
  for _, item in ipairs(plan) do
    if item.Index == plot:GetIndex() then planned = item end
  end
  T.ok(planned ~= nil and planned.Type == row.AdjacentImprovement, "the improvement planned on the resource")
  SDP_Overlay.With(pid, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local subjects = { SDP_Overlay.Subject(district, at.X, at.Y) }
    local without = SDP_Overlay.Evaluate(subjects, fixed, WEIGHTS)
    local with = SDP_Overlay.Evaluate(subjects, fixed, WEIGHTS,
      { { Key = row.AdjacentImprovement, Type = "IMPROVEMENT", X = plot:GetX(), Y = plot:GetY() } })
    local a, b = without.Placements[1].Yields[row.YieldType] or 0, with.Placements[1].Yields[row.YieldType] or 0
    T.eq(b - a, row.YieldChange, "DMT: the tack adds the row's yield")
  end)
end)

test("the solver's improvements: DMT gives the plan what it reports, and no worse than without", function()
  local city, district = Setup()
  local request = { PlayerID = pid, CityID = city:GetID(), Tier = "FAST", Weights = WEIGHTS, Districts = { district } }
  local off = SDP_Solver.Solve(request)
  T.ok(off.Ok, tostring(off.Error))
  request.Improvements = true
  local on = SDP_Solver.Solve(request)
  T.ok(on.Ok, tostring(on.Error))
  T.ok(not on.Stats.Mismatch, "board and full evaluation agree")
  T.ok(on.Gain >= off.Gain - 1e-9, "no worse: " .. on.Gain .. " >= " .. off.Gain)
  local p = Find(on.Plan, district)
  T.ok(p ~= nil, "placed")
  local scan = SDP_City.Scan(pid, city:GetID())
  SDP_Overlay.With(pid, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local extra = {}
    for _, e in ipairs(p.Improvements or {}) do
      T.eq(Map.GetPlotDistance(e.X, e.Y, p.X, p.Y), 1, "next to the district")
      T.eq(Map.GetPlot(e.X, e.Y):GetImprovementType(), -1, "no improvement there yet")
      extra[#extra + 1] = { Key = e.Type, Type = "IMPROVEMENT", X = e.X, Y = e.Y }
    end
    local check = SDP_Overlay.Evaluate({ SDP_Overlay.Subject(district, p.X, p.Y) }, fixed, WEIGHTS, extra)
    T.ok(check.Legal, "legal")
    T.eq(check.Placements[1].Score, p.Score, "DMT's score with the tacks = the plan's")
  end)
end)

test("single-city tab: the improvements' row, their tacks placed and undone with the district's", function()
  local city, district, row = Setup()
  local ok, err = pcall(function()
    SDP_Panel.SelectTab("SINGLE")
    SDP_Panel.SelectCity(city:GetID())
    for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, "OFF") end
    SDP_Panel.SetState(district, "MUST")
    SDP_Panel.SetCount(1)
    SDP_Panel.SetRemind(false)
    SDP_Panel.SetTier("FAST")
    SDP_Panel.SetImprove(true)
    local result = SDP_Panel.Solve() or SDP_Panel.RunTask(500)
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    local p = Find(result.Plan, district)
    T.ok(p ~= nil, "placed")
    if p.Improvements == nil or #p.Improvements == 0 then T.skip("the plan put the district where no improvement adds") end
    local found = nil
    for _, r in ipairs(SDP_Panel.State().ResultRows) do
      if r.Icon == "ICON_" .. p.Improvements[1].Type and r.X ~= nil then found = r end
    end
    T.ok(found ~= nil, "a row for the improvements")
    T.ok(found.Name:find(Locale.Lookup(GameInfo.Improvements[p.Improvements[1].Type].Name), 1, true) ~= nil,
      "named with the game's name: " .. found.Name)
    local placed = SDP_Panel.PlacePins()
    T.eq(placed, #result.Plan + #p.Improvements, "the district's tacks and the improvements'")
    for _, e in ipairs(p.Improvements) do
      local pin = PinAt(e.X, e.Y)
      T.ok(pin ~= nil, "an improvement tack")
      T.eq(pin:GetIconName(), "ICON_" .. e.Type, "its icon")
      local subject = GetMapPinSubject(pid, e.X, e.Y)
      T.ok(subject ~= nil and subject.Type == "IMPROVEMENT" and subject.Key == e.Type, "DMT knows it as an improvement")
    end
    T.eq(SDP_Panel.UndoPins(), placed, "undo takes them all")
    for _, e in ipairs(p.Improvements) do T.eq(PinAt(e.X, e.Y), nil, "improvement tack gone") end
    T.eq(PinAt(p.X, p.Y), nil, "district tack gone")
  end)
  SDP_Panel.SetTier("STANDARD")
  SDP_Panel.SetRemind(true)
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
  if not ok then error(err, 0) end
end)
