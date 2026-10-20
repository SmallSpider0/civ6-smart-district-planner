-- @state SDP_Panel
-- @timeout 60
-- SDP_Overlay against DMT itself: a hypothetical subject must get exactly the
-- values DMT computes and stores for a real pin at the same place.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()
local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function Scan()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return SDP_City.Scan(pid, city:GetID())
end

-- A real pin, made the way DMT's pin popup does on OK: create, set the icon,
-- broadcast, then tell DMT, which computes and stores the pin's values.
local function AddRealPin(districtType, x, y)
  local pin = PlayerConfigurations[pid]:GetMapPin(x, y)
  pin:SetName("SDP test")
  pin:SetIconName("ICON_" .. districtType)
  Network.BroadcastPlayerInfo()
  LuaEvents.DMT_MapPinAdded(pin)
  return pin:GetID()
end

-- Delete a pin the way DMT does (requirements pitfall 19).
local function RemoveRealPin(id)
  local cfg = PlayerConfigurations[pid]
  LuaEvents.DMT_MapPinRemoved(cfg:GetMapPinID(id))
  cfg:DeleteMapPin(id)
  Network.BroadcastPlayerInfo()
end

-- Run fn(); remove the listed pins whatever happens.
local function WithPins(ids, fn)
  local ok, err = pcall(fn)
  for i = #ids, 1, -1 do RemoveRealPin(ids[i]) end
  if not ok then error(err, 0) end
end

-- DMT's yield string, as a sorted list of its parts (DMT builds it with pairs()).
local function YieldParts(yieldString)
  local parts = {}
  for part in string.gmatch(yieldString or "", "%S+") do parts[#parts + 1] = part end
  table.sort(parts)
  return parts
end

-- District types with district adjacency rules, so the comparison exercises them.
local function DistrictsToCompare(limit)
  local adjacency = SDP_Rules.AdjacencyTable(pid)
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if adjacency[d.Type] and #list < limit then list[#list + 1] = d.Type end
  end
  return list
end

-- Every `step`-th candidate plot, up to `limit`.
local function SpreadCandidates(scan, limit)
  local list, step = {}, math.max(1, math.floor(#scan.Candidates / limit))
  for i = 1, #scan.Candidates, step do
    if #list < limit then list[#list + 1] = scan.Candidates[i] end
  end
  return list
end

test("overlay never writes the player's pin data and always restores DMT", function()
  local scan = Scan()
  local cfg = PlayerConfigurations[pid]
  local before = cfg:GetValue("DMT_MapPinSubjects")
  local realGet, realUpdate = GetMapPinSubject, UpdateMapPinSubject
  local plot = scan.Candidates[1]
  SDP_Overlay.With(pid, function()
    T.ok(GetMapPinSubject ~= realGet, "getter not replaced")
    UpdateMapPinSubject(pid, plot.X, plot.Y, SDP_Overlay.Subject("DISTRICT_CAMPUS", plot.X, plot.Y))
    T.eq(GetMapPinSubject(pid, plot.X, plot.Y).Key, "DISTRICT_CAMPUS", "write not visible on the layer")
    UpdateMapPinSubject(pid, plot.X, plot.Y, nil)
    T.eq(GetMapPinSubject(pid, plot.X, plot.Y), nil, "cleared subject still visible")
  end)
  T.ok(GetMapPinSubject == realGet and UpdateMapPinSubject == realUpdate, "globals not restored")
  T.eq(cfg:GetValue("DMT_MapPinSubjects"), before, "real pin data changed")

  local ok = pcall(SDP_Overlay.With, pid, function() error("boom") end)
  T.ok(not ok, "error swallowed")
  T.ok(not SDP_Overlay.IsInstalled() and GetMapPinSubject == realGet, "not restored after an error")
end)

test("single districts match real DMT pins", function()
  local scan = Scan()
  local districts = DistrictsToCompare(6)
  local plots = SpreadCandidates(scan, 6)
  T.ok(#districts >= 3 and #plots >= 3, "not enough districts or plots to compare")
  local compared, placeable = 0, 0
  for _, districtType in ipairs(districts) do
    for _, plot in ipairs(plots) do
      local subject = SDP_Overlay.Subject(districtType, plot.X, plot.Y)
      local result = SDP_Overlay.With(pid, SDP_Overlay.Evaluate, { subject }, {}, WEIGHTS)
      local item = result.Placements[1]
      local id = AddRealPin(districtType, plot.X, plot.Y)
      WithPins({ id }, function()
        local stored = GetMapPinSubject(pid, plot.X, plot.Y)
        local where = districtType .. " at " .. plot.X .. "," .. plot.Y
        T.ok(stored ~= nil, where .. ": DMT stored nothing")
        T.eq(item.ToolTip, stored.YieldToolTip, where .. " tooltip")
        T.same(YieldParts(ConvertToYieldString(item.Yields)), YieldParts(stored.YieldString), where .. " yields")
        T.eq(item.CanPlace, stored.CanPlace, where .. " can place")
        T.eq(item.Reason, stored.CanPlaceToolTip, where .. " reason")
      end)
      compared = compared + 1
      if item.CanPlace then placeable = placeable + 1 end
    end
  end
  print(string.format("compared %d placements (%d placeable)", compared, placeable))
end)

test("planned districts change a locked neighbour exactly like real pins do", function()
  local scan = Scan()
  local adjacency = SDP_Rules.AdjacencyTable(pid)
  -- Lock a campus pin, then plan two other districts next to it: a campus
  -- gets science per two adjacent districts.
  local anchor, partners = nil, nil
  for _, plot in ipairs(scan.Candidates) do
    local around = {}
    for _, other in ipairs(scan.Candidates) do
      if Map.GetPlotDistance(plot.X, plot.Y, other.X, other.Y) == 1 then around[#around + 1] = other end
    end
    if #around >= 2 then anchor, partners = plot, around break end
  end
  if anchor == nil then T.skip("no candidate with two candidate neighbours") end
  local others = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if d.Type ~= "DISTRICT_CAMPUS" and adjacency[d.Type] and #others < 2 then others[#others + 1] = d.Type end
  end
  local planned = {
    SDP_Overlay.Subject(others[1], partners[1].X, partners[1].Y),
    SDP_Overlay.Subject(others[2], partners[2].X, partners[2].Y),
  }

  local ids = { AddRealPin("DISTRICT_CAMPUS", anchor.X, anchor.Y) }
  WithPins(ids, function()
    local locked = GetMapPinSubject(pid, anchor.X, anchor.Y)
    local alone, together = SDP_Overlay.With(pid, function()
      return SDP_Overlay.Evaluate({}, { locked }, WEIGHTS), SDP_Overlay.Evaluate(planned, { locked }, WEIGHTS)
    end)
    for _, s in ipairs(planned) do ids[#ids + 1] = AddRealPin(s.Key, s.X, s.Y) end
    local stored = GetMapPinSubject(pid, anchor.X, anchor.Y)
    T.eq(together.Fixed[1].ToolTip, stored.YieldToolTip, "locked campus tooltip")
    T.same(YieldParts(ConvertToYieldString(together.Fixed[1].Yields)), YieldParts(stored.YieldString), "locked campus yields")
    local gained = (together.Fixed[1].Yields.YIELD_SCIENCE or 0) - (alone.Fixed[1].Yields.YIELD_SCIENCE or 0)
    -- One science per two adjacent districts, unless this civ's trait
    -- replaces that rule (Japan: more, via a modifier; Gaul: none). The
    -- comparison with DMT above holds for every civ.
    local replaced = false
    local traits = MapTacks.PlayerTraits(pid)
    for row in GameInfo.ExcludedAdjacencies() do
      if row.YieldChangeId == "District_Science" and traits[row.TraitType] then replaced = true end
    end
    if not replaced then T.eq(gained, 1, "two planned neighbours should add one science to the campus") end
  end)
end)

test("hiding a real pin on the layer evaluates as if it were gone", function()
  local scan = Scan()
  local plot = scan.Candidates[1]
  local ids = { AddRealPin("DISTRICT_CAMPUS", plot.X, plot.Y) }
  WithPins(ids, function()
    SDP_Overlay.With(pid, function()
      T.eq(GetMapPinSubject(pid, plot.X, plot.Y).Key, "DISTRICT_CAMPUS", "real pin not in the snapshot")
      SDP_Overlay.Set(plot.X, plot.Y, false)
      T.eq(GetMapPinSubject(pid, plot.X, plot.Y), nil, "hidden pin still visible")
      SDP_Overlay.Set(plot.X, plot.Y, nil)
      T.eq(GetMapPinSubject(pid, plot.X, plot.Y).Key, "DISTRICT_CAMPUS", "pin not back after clearing the layer")
    end)
  end)
end)

test("fixed subjects include the city center and locked pins", function()
  local scan = Scan()
  local plot = scan.Candidates[1]
  local ids = { AddRealPin("DISTRICT_THEATER", plot.X, plot.Y) }
  WithPins(ids, function()
    local fixed = SDP_Overlay.With(pid, SDP_Overlay.FixedSubjects, SDP_City.Scan(pid, scan.CityID))
    local keys = {}
    for _, s in ipairs(fixed) do keys[s.X .. "," .. s.Y] = s.Key end
    T.eq(keys[scan.X .. "," .. scan.Y], "DISTRICT_CITY_CENTER", "city center")
    T.eq(keys[plot.X .. "," .. plot.Y], "DISTRICT_THEATER", "locked pin")
  end)
end)

test("a DMT error marks the placement instead of aborting", function()
  -- DMT reads no terrain on unrevealed plots; for some districts (e.g. ones
  -- that need coast) CanPlacePin then raises. Scans exclude such plots, but
  -- the overlay must survive them anyway.
  local scan = Scan()
  local hidden
  for index, reason in pairs(scan.Excluded) do
    if reason == SDP_City.EXCLUDED.UNREVEALED and (hidden == nil or index < hidden) then hidden = index end
  end
  if hidden == nil then T.skip("every plot in range is revealed") end
  local plot = Map.GetPlotByIndex(hidden)
  local errors = 0
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    local result = SDP_Overlay.With(pid, SDP_Overlay.Evaluate,
      { SDP_Overlay.Subject(d.Type, plot:GetX(), plot:GetY()) }, {}, WEIGHTS)
    local item = result.Placements[1]
    if item.Error ~= nil then
      errors = errors + 1
      T.eq(item.CanPlace, false, d.Type .. " placeable despite an error")
      T.eq(result.Legal, false, d.Type .. " legal despite an error")
    end
  end
  print("DMT errors on an unrevealed plot: " .. errors)
end)

test("evaluation is deterministic", function()
  local scan = Scan()
  local districts = DistrictsToCompare(3)
  local layout = {}
  for i, d in ipairs(districts) do
    local plot = scan.Candidates[i * 2]
    if plot then layout[#layout + 1] = SDP_Overlay.Subject(d, plot.X, plot.Y) end
  end
  local first, second = SDP_Overlay.With(pid, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    return SDP_Overlay.Evaluate(layout, fixed, WEIGHTS), SDP_Overlay.Evaluate(layout, fixed, WEIGHTS)
  end)
  T.same(second, first)
end)
