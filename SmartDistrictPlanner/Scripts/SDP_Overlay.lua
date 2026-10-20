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

-- The two load handlers removed last also built this state's copy of DMT's
-- modifier cache: the player's trait and belief modifiers, which carry the
-- civilization adjacency rules (Japan, Brazil, the Netherlands, Gaul's mines,
-- ...) and placement rules (Gaul: no specialty district next to the city
-- center; Vietnam: specialty districts on woods, rainforest or marsh only).
-- Without it DMT here ignores them. So this state builds the cache itself:
-- DMT's requirement tables once (InitializeModifierCalculator appends, it
-- must not run twice), the player's modifiers on load and at every turn
-- start like DMT does, and once before the first solve if the context was
-- loaded after the game (SDP_Overlay.Install).
local m_modifiersReady = false

function SDP_Overlay.RefreshModifiers()
  if InitializeModifierCalculator == nil or CacheEffectiveModifiers == nil then return end
  if not m_modifiersReady then
    m_modifiersReady = true
    pcall(InitializeModifierCalculator)
  end
  pcall(CacheEffectiveModifiers, Game.GetLocalPlayer())
end

Events.LoadGameViewStateDone.Add(SDP_Overlay.RefreshModifiers)
Events.LocalPlayerTurnBegin.Add(SDP_Overlay.RefreshModifiers)

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

-- Put the overlay's replacements in place for `state`.
local function Activate(state)
  state.RealGet, state.RealUpdate = GetMapPinSubject, UpdateMapPinSubject
  state.RealFeatures = GetRealizedPlotFeatures
  m_state = state
  -- DMT reads what is on the plots around a subject through this global;
  -- HideFeature makes one plot's feature (woods, rainforest) look gone.
  if state.RealFeatures ~= nil then
    GetRealizedPlotFeatures = function(pid, plot, pinSubject) -- lint: allow global-assign
      local features = state.RealFeatures(pid, plot, pinSubject)
      if state.HiddenFeature ~= nil and plot ~= nil and features ~= nil and plot:GetIndex() == state.HiddenFeature then
        local copy = {}
        for key, value in pairs(features) do copy[key] = value end
        copy[AdjacencyBonusTypes.ADJACENCY_FEATURE] = nil
        return copy
      end
      return features
    end
  end
  GetMapPinSubject = function(pid, x, y) -- lint: allow global-assign
    if pid ~= state.PlayerID then return state.RealGet(pid, x, y) end
    local value = state.Layer[Key(x, y)]
    if value ~= nil then return value or nil end
    return state.Snapshot[Key(x, y)]
  end
  UpdateMapPinSubject = function(pid, x, y, subject) -- lint: allow global-assign
    if pid == state.PlayerID then state.Layer[Key(x, y)] = subject or false end
  end
  ClearDMTCache(state.PlayerID)
end

-- Install for the player. `snapshot` (optional) is the real pin data to use
-- instead of loading it again (see Suspend / Resume).
function SDP_Overlay.Install(playerID, snapshot)
  if m_state ~= nil then error("SDP_Overlay is already installed", 2) end
  if not m_modifiersReady then SDP_Overlay.RefreshModifiers() end
  Activate({
    PlayerID = playerID,
    Snapshot = snapshot or LoadMapPinSubjectTable(playerID, DMT_SUBJECTS_KEY) or {},
    Layer = {},
  })
end

function SDP_Overlay.Uninstall()
  local state = m_state
  if state == nil then return end
  GetMapPinSubject, UpdateMapPinSubject = state.RealGet, state.RealUpdate -- lint: allow global-assign
  if state.RealFeatures ~= nil then GetRealizedPlotFeatures = state.RealFeatures end -- lint: allow global-assign
  m_state = nil
  ClearDMTCache(state.PlayerID)
end

-- Take the overlay out between two frames of a sliced computation (SDP_Task)
-- and put it back later with the same snapshot and layer, so the real pin
-- data is loaded once and nothing outside the computation ever sees the
-- layer. Returns the state to pass to Resume.
function SDP_Overlay.Suspend()
  local state = m_state
  if state == nil then error("SDP_Overlay is not installed", 2) end
  SDP_Overlay.Uninstall()
  return state
end

function SDP_Overlay.Resume(state)
  if m_state ~= nil then error("SDP_Overlay is already installed", 2) end
  Activate(state)
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

-- Take real pins out of the overlay's copy of the pin data, so DMT sees
-- them as gone for this computation (this mod's earlier pins being
-- replaced). `pins` = { { X, Y } }. The real data is not touched; call again
-- after every Install (Resume keeps it).
function SDP_Overlay.HidePins(pins)
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  if pins == nil or #pins == 0 then return end
  for _, pin in ipairs(pins) do m_state.Snapshot[Key(pin.X, pin.Y)] = nil end
  ClearDMTCache(m_state.PlayerID)
end

-- Make the feature on plot `index` invisible to DMT's adjacency (nil: none),
-- as if a builder had cleared it. Only for subjects next to it: the plot's
-- own subject is not affected.
function SDP_Overlay.HideFeature(index)
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  m_state.HiddenFeature = index
  ClearDMTCache(m_state.PlayerID)
end

-- Like Set, but DMT's plot cache is left alone: the caller (SDP_Board)
-- batches changes and calls ClearCache before its next DMT call.
function SDP_Overlay.Put(x, y, subject)
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  m_state.Layer[Key(x, y)] = subject
end

function SDP_Overlay.ClearCache()
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  ClearDMTCache(m_state.PlayerID)
end

-- One subject's weighted DMT score with the layer as it is. Returns the
-- score and true, or 0 and false when DMT raised an error (as in Evaluate,
-- such a placement counts as not placeable).
function SDP_Overlay.ScoreOf(subject, weights)
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  local ok, yields = pcall(GetBonusYields, m_state.PlayerID, subject)
  if not ok then return 0, false end
  return SDP_Overlay.Score(yields, weights), true
end

-- The game's own placement rules on top of DMT's (SDP_City.EngineRefused),
-- asked once per (city, district) and remembered for the turn: what the
-- engine allows changes with techs, civics and population, which change
-- between turns. A plot bought later in the turn is not in the remembered
-- set, so DMT decides it alone.
local m_engine = { Turn = nil, Refused = {} }

function SDP_Overlay.ResetEngine()
  m_engine = { Turn = nil, Refused = {} }
end

-- Whether the game refuses `subject` (a district) where it stands.
function SDP_Overlay.EngineRefuses(playerID, subject)
  if subject.Type ~= "DISTRICT" or subject.Key == "DISTRICT_CITY_CENTER" then return false end
  local plot = Map.GetPlot(subject.X, subject.Y)
  if plot == nil or plot:GetOwner() ~= playerID then return false end
  local city = Cities.GetPlotPurchaseCity(plot)
  if city == nil then return false end
  local turn = Game.GetCurrentGameTurn()
  if m_engine.Turn ~= turn then m_engine = { Turn = turn, Refused = {} } end
  local key = playerID .. ":" .. city:GetID() .. ":" .. subject.Key
  local refused = m_engine.Refused[key]
  if refused == nil then
    refused = SDP_City.EngineRefused(playerID, city:GetID(), subject.Key) or false
    m_engine.Refused[key] = refused
  end
  return refused ~= false and refused[plot:GetIndex()] == true
end

-- DMT's CanPlacePin with the layer as it is, and the game agrees; a DMT
-- error counts as false.
function SDP_Overlay.CanPlace(subject)
  if m_state == nil then error("SDP_Overlay is not installed", 2) end
  local ok, canPlace = pcall(CanPlacePin, m_state.PlayerID, subject)
  return ok and canPlace == true and not SDP_Overlay.EngineRefuses(m_state.PlayerID, subject)
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
      if canPlace and SDP_Overlay.EngineRefuses(playerID, subject) then
        -- DMT allows it, the game does not (e.g. a canal joining no water).
        item.CanPlace, item.Reason, item.EngineRefused = false, Locale.Lookup("LOC_SDP_REASON_ENGINE"), true
      end
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
-- EngineRefused (DMT allows it, the game does not), Error (DMT raised one) }.
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
  -- The city center (a planned city's center is its pin, added below).
  local center = Map.GetPlot(scan.X, scan.Y)
  if center:GetDistrictType() ~= -1 then
    Add(center:GetIndex(), SDP_Overlay.Subject(GameInfo.Districts[center:GetDistrictType()].DistrictType, scan.X, scan.Y))
  end
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
