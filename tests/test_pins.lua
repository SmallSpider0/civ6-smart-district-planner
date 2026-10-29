-- @state SDP_Panel
-- @timeout 60
-- Map tacks from a plan: created with district icons, known to DMT with the
-- same values the result list showed, and truly deleted by undo.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()
local cfg = PlayerConfigurations[pid]

local function Resolve(base)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if plannable[base] then return base end
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then return row.CivUniqueDistrictType end
  end
  T.skip(base .. " not available to this civ")
end

local function PinAt(x, y)
  for _, pin in pairs(cfg:GetMapPins()) do
    if pin:GetHexX() == x and pin:GetHexY() == y then return pin end
  end
  return nil
end

local function SolveFromPanel(districts)
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, "OFF") end
  SDP_Panel.SetCount(0)
  SDP_Panel.SetRemind(false)
  for _, y in ipairs(SDP_Rules.YIELDS) do SDP_Panel.SetWeight(y, 1) end
  SDP_Panel.SetAllowFeatureRemoval(true)
  for _, d in ipairs(districts) do SDP_Panel.SetSelected(d, true) end
  local result = SDP_Panel.Solve()
  T.ok(result ~= nil and result.Ok, "solve failed")
  return result
end

-- Undo whatever the tests placed, even after a failure.
local function UndoAll()
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
end

test("placed tacks carry district icons and DMT shows the planned values", function()
  local ok, err = pcall(function()
    local result = SolveFromPanel({ Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE"), Resolve("DISTRICT_THEATER") })
    T.eq(SDP_Panel.PlacePins(), #result.Plan, "pins placed")
    T.eq(SDP_Panel.State().PlaceDisabled, true, "place still enabled after placing")
    T.eq(SDP_Panel.State().UndoDisabled, false, "undo disabled after placing")
    for _, p in ipairs(result.Plan) do
      local pin = PinAt(p.X, p.Y)
      T.ok(pin ~= nil, p.Type .. ": no pin")
      T.eq(pin:GetIconName(), "ICON_" .. p.Type, p.Type .. " icon")
      -- The icon says which district; the name says which city (its number).
      T.eq(pin:GetName(), tostring(SDP_City.CityNumbers(pid)[SDP_Panel.State().CityID]), p.Type .. " name")
      local stored = GetMapPinSubject(pid, p.X, p.Y)
      T.ok(stored ~= nil, p.Type .. ": DMT knows nothing of the pin")
      T.eq(stored.Key, p.Type, "DMT subject")
      T.eq(stored.YieldToolTip, p.ToolTip, p.Type .. ": DMT tooltip differs from the plan's")
    end
  end)
  UndoAll()
  if not ok then error(err, 0) end
end)

test("undo deletes exactly the placed tacks", function()
  local ok, err = pcall(function()
    local result = SolveFromPanel({ Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_THEATER") })
    -- A pin of the player's own, away from the plan, must survive the undo.
    local scan = SDP_City.Scan(pid, SDP_Panel.State().CityID)
    local own
    for _, c in ipairs(scan.Candidates) do
      local used = false
      for _, p in ipairs(result.Plan) do if p.Index == c.Index then used = true end end
      if not used and own == nil then own = c end
    end
    local ownPin = cfg:GetMapPin(own.X, own.Y)
    ownPin:SetIconName("ICON_MAP_PIN_CIRCLE")
    local ownID = ownPin:GetID()
    Network.BroadcastPlayerInfo()

    SDP_Panel.PlacePins()
    T.eq(SDP_Panel.UndoPins(), #result.Plan, "pins removed")
    for _, p in ipairs(result.Plan) do
      T.eq(PinAt(p.X, p.Y), nil, p.Type .. ": pin still on the map")
      T.eq(GetMapPinSubject(pid, p.X, p.Y), nil, p.Type .. ": DMT still remembers the pin")
    end
    T.ok(cfg:GetMapPinID(ownID) ~= nil, "the player's own pin was deleted")
    T.eq(SDP_Panel.State().UndoDisabled, true, "undo still enabled")
    T.eq(SDP_Panel.State().PlaceDisabled, false, "plan cannot be placed again after undo")
    cfg:DeleteMapPin(ownID)
    Network.BroadcastPlayerInfo()
  end)
  UndoAll()
  if not ok then error(err, 0) end
end)

test("placed tacks are locked for the next solve", function()
  local ok, err = pcall(function()
    local campus = Resolve("DISTRICT_CAMPUS")
    local holy = Resolve("DISTRICT_HOLY_SITE")
    local first = SolveFromPanel({ campus })
    SDP_Panel.PlacePins()
    -- The tacked campus is greyed out and not planned again (issue 165).
    local status = nil
    for _, r in ipairs(SDP_Panel.State().DistrictRows) do
      if r.Type == campus then status = r.Status end
    end
    T.eq(status, "TACKED", "the tacked campus is greyed out")
    local second = SolveFromPanel({ campus, holy })
    for _, p in ipairs(second.Plan) do
      T.ok(p.Type ~= campus, "a second campus beside the tack")
      T.ok(p.Index ~= first.Plan[1].Index, "planned on top of the placed tack")
    end
    local seen = false
    for _, n in ipairs(second.Neighbours) do
      if n.Subject.X == first.Plan[1].X and n.Subject.Y == first.Plan[1].Y then seen = true end
    end
    for _, s in ipairs(SDP_Overlay.With(pid, SDP_Overlay.FixedSubjects, SDP_City.Scan(pid, SDP_Panel.State().CityID))) do
      if s.X == first.Plan[1].X and s.Y == first.Plan[1].Y then seen = true end
    end
    T.ok(seen, "placed tack not treated as a fixed neighbour")
  end)
  UndoAll()
  if not ok then error(err, 0) end
end)
