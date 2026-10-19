-- SDP_Overlay: evaluates hypothetical district placements with DMT's own
-- legality and adjacency code (requirement: reuse DMT, never reimplement it).
--
-- DMT reads map pins only through the globals GetMapPinSubject and
-- UpdateMapPinSubject. While installed, the overlay replaces both in this Lua
-- state: reads see a layer of planned subjects over a snapshot of the real
-- pins; writes go to the layer as `subject or false` (false reads as nil), so
-- nothing ever reaches the player's real pin data.
--
-- DMT caches plot features by coordinates and ignores which pin subject they
-- were computed for, so the cache is cleared after every change to the layer
-- (UpdatePinYields(pid, {}) only resets that cache). Without that, legality
-- and yields would depend on the order of earlier calls.
-- Include order: MapTacks, SDP_Rules, SDP_City, SDP_Overlay.

include("dmt_yieldcalculator") -- includes dmt_mappinsubjectmanager; ends by running DMT_Initialize()

-- DMT_Initialize() subscribed this state's copies of DMT's handlers. DMT's own
-- context already runs them; a second copy would redo the work on every map
-- change (requirements pitfall 7). Remove exactly what dmt_yieldcalculator.lua
-- subscribes (3 LuaEvents and 11 Events in the 2024-01-17 DMT).
LuaEvents.DMT_UpdatePinYields.Remove(UpdatePinYields)
LuaEvents.DMT_MapPinAdded.Remove(OnMapPinAdded)
LuaEvents.DMT_MapPinRemoved.Remove(OnMapPinRemoved)
Events.BuildingAddedToMap.Remove(OnBuildingAdded)
Events.DistrictAddedToMap.Remove(OnDistrictAdded)
Events.DistrictPillaged.Remove(OnDistrictChanged)
Events.DistrictRemovedFromMap.Remove(OnDistrictChanged)
Events.FeatureRemovedFromMap.Remove(OnFeatureRemovedFromMap)
Events.ImprovementChanged.Remove(OnImprovementChanged)
Events.ImprovementAddedToMap.Remove(OnImprovementAdded)
Events.ImprovementRemovedFromMap.Remove(OnImprovementRemoved)
Events.PlotVisibilityChanged.Remove(OnPlotVisibilityChanged)
Events.LoadGameViewStateDone.Remove(OnLoadGameViewStateDone)
Events.LocalPlayerTurnBegin.Remove(OnLocalPlayerTurnBegin)

SDP_Overlay = {}

-- The player configuration value DMT keeps its pin subjects in
-- (MAIN_CACHE_KEY in dmt_mappinsubjectmanager.lua, local there).
local DMT_SUBJECTS_KEY = "DMT_MapPinSubjects"

local m_state = nil -- while installed: { PlayerID, RealGet, RealUpdate, Snapshot, Layer }

local function ClearDMTCache(playerID)
  pcall(UpdatePinYields, playerID, {})
end

local function Key(x, y)
  return GetMapPinSubjectCacheKey(x, y)
end

local function Pack(...)
  return { n = select("#", ...), ... }
end

function SDP_Overlay.Subject(districtType, x, y)
  return { Key = districtType, Type = "DISTRICT", X = x, Y = y }
end

function SDP_Overlay.IsInstalled()
  return m_state ~= nil
end

function SDP_Overlay.Install(playerID)
  if m_state ~= nil then error("SDP_Overlay is already installed", 2) end
  local state = {
    PlayerID = playerID,
    RealGet = GetMapPinSubject,
    RealUpdate = UpdateMapPinSubject,
    Snapshot = LoadMapPinSubjectTable(playerID, DMT_SUBJECTS_KEY) or {},
    Layer = {},
  }
  m_state = state
  GetMapPinSubject = function(pid, x, y) -- lint: allow global-assign
    if pid ~= state.PlayerID then return state.RealGet(pid, x, y) end
    local value = state.Layer[Key(x, y)]
    if value ~= nil then return value or nil end
    return state.Snapshot[Key(x, y)]
  end
  UpdateMapPinSubject = function(pid, x, y, subject) -- lint: allow global-assign
    if pid == state.PlayerID then state.Layer[Key(x, y)] = subject or false end
  end
  ClearDMTCache(playerID)
end

function SDP_Overlay.Uninstall()
  local state = m_state
  if state == nil then return end
  GetMapPinSubject, UpdateMapPinSubject = state.RealGet, state.RealUpdate -- lint: allow global-assign
  m_state = nil
  ClearDMTCache(state.PlayerID)
end

-- Run fn(...) with the overlay installed. The overlay is removed on every
-- path; fn's results are returned, or its error is raised again.
function SDP_Overlay.With(playerID, fn, ...)
  SDP_Overlay.Install(playerID)
  local results = Pack(pcall(fn, ...))
  SDP_Overlay.Uninstall()
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- Put a subject on the layer at (x, y): a table, false to hide a real pin, or
-- nil to fall back to the real pin. Returns the previous layer value.
function SDP_Overlay.Set(x, y, subject)
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  local previous = m_state.Layer[Key(x, y)]
  m_state.Layer[Key(x, y)] = subject
  ClearDMTCache(m_state.PlayerID)
  return previous
end

-- Weighted score of a yields table (requirement constraint 3).
function SDP_Overlay.Score(yields, weights)
  local total = 0
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    total = total + (weights[yieldType] or 0) * (yields[yieldType] or 0)
  end
  return total
end

-- One subject's DMT values. A DMT error marks the item (Error) instead of
-- aborting the whole evaluation; such a placement counts as not placeable.
local function Item(playerID, subject, weights, checkPlacement)
  local item = { Subject = subject, Yields = {}, ToolTip = "", Score = 0 }
  local ok, yields, toolTip = pcall(GetBonusYields, playerID, subject)
  if ok then
    item.Yields, item.ToolTip, item.Score = yields, toolTip, SDP_Overlay.Score(yields, weights)
  else
    item.Error = yields
  end
  if checkPlacement then
    local placeOk, canPlace, reason = pcall(CanPlacePin, playerID, subject)
    if placeOk and ok then
      item.CanPlace, item.Reason = canPlace, reason
    else
      item.Error = item.Error or canPlace
      item.CanPlace, item.Reason = false, tostring(item.Error)
    end
  end
  return item
end

-- Evaluate planned districts together with fixed subjects around them.
--   placements  subjects put on the layer for this evaluation only
--   fixed       subjects already on the map (locked pins, built districts)
--               whose yields count towards the total
-- Returns { Legal, Total, Placements = {item}, Fixed = {item} } with
-- item = { Subject, Yields, ToolTip, Score, CanPlace and Reason (placements),
-- Error (DMT raised one) }.
-- Legal: DMT allows every placement. Total sums every item's score.
function SDP_Overlay.Evaluate(placements, fixed, weights)
  local state = m_state
  if state == nil then error("SDP_Overlay is not installed", 2) end
  local saved = {}
  for i, subject in ipairs(placements) do
    saved[i] = state.Layer[Key(subject.X, subject.Y)]
    state.Layer[Key(subject.X, subject.Y)] = subject
  end
  ClearDMTCache(state.PlayerID)

  local ok, result = pcall(function()
    local out = { Legal = true, Total = 0, Placements = {}, Fixed = {} }
    for _, subject in ipairs(placements) do
      local item = Item(state.PlayerID, subject, weights, true)
      out.Placements[#out.Placements + 1] = item
      out.Legal = out.Legal and item.CanPlace
      out.Total = out.Total + item.Score
    end
    for _, subject in ipairs(fixed) do
      local item = Item(state.PlayerID, subject, weights, false)
      out.Fixed[#out.Fixed + 1] = item
      out.Total = out.Total + item.Score
    end
    return out
  end)

  for i = #placements, 1, -1 do
    state.Layer[Key(placements[i].X, placements[i].Y)] = saved[i]
  end
  ClearDMTCache(state.PlayerID)
  if not ok then error(result, 0) end
  return result
end

-- Subjects already on the map near a city whose yields a plan can change:
-- the player's districts within RADIUS + 1 rings (city center included,
-- wonders excluded) and the player's non-plain pins there (from DMT's data,
-- or made from the pin the way DMT does). A pin on a built district is
-- skipped: the district is what DMT sees. Sorted by plot index. Call with the
-- overlay installed so pin subjects come from its snapshot.
function SDP_Overlay.FixedSubjects(scan)
  local byIndex, indices = {}, {}
  local function Add(index, subject)
    if byIndex[index] == nil then
      byIndex[index] = subject
      indices[#indices + 1] = index
    end
  end
  local center = Map.GetPlot(scan.X, scan.Y)
  Add(center:GetIndex(), SDP_Overlay.Subject(GameInfo.Districts[center:GetDistrictType()].DistrictType, scan.X, scan.Y))
  for _, entry in ipairs(SDP_City.PlotsInRange(scan.X, scan.Y, SDP_City.RADIUS + 1)) do
    local plot = Map.GetPlotByIndex(entry.Index)
    local district = plot:GetDistrictType()
    if district ~= -1 and plot:GetOwner() == scan.PlayerID then
      local districtType = GameInfo.Districts[district].DistrictType
      if districtType ~= "DISTRICT_WONDER" then
        Add(entry.Index, SDP_Overlay.Subject(districtType, entry.X, entry.Y))
      end
    end
  end
  for _, pin in ipairs(scan.Pins) do
    local subject = GetMapPinSubject(scan.PlayerID, pin.X, pin.Y)
    if subject == nil then
      subject = CreateMapPinSubject(PlayerConfigurations[scan.PlayerID]:GetMapPinID(pin.ID))
    end
    if subject ~= nil and subject.Type ~= "UNKNOWN" then Add(pin.Index, subject) end
  end
  table.sort(indices)
  local subjects = {}
  for i, index in ipairs(indices) do subjects[i] = byIndex[index] end
  return subjects
end
