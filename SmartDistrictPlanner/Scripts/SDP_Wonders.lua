-- SDP_Wonders: the wonders a player can plan (docs/multicity-design.md 4.4).
-- Legality and every value come from DMT (Type = "WONDER" subjects, Key =
-- the building type); this module only lists them and their status.

SDP_Wonders = {}

-- Wonders already built that the player can know of: in the player's own
-- cities, or seen on a revealed plot. Returns { [BuildingType] = true }.
function SDP_Wonders.Built(playerID)
  local built = {}
  for _, city in Players[playerID]:GetCities():Members() do
    local buildings = city:GetBuildings()
    if buildings ~= nil then
      for row in GameInfo.Buildings() do
        if row.IsWonder and buildings:HasBuilding(row.Index) then built[row.BuildingType] = true end
      end
    end
  end
  local visibility = PlayersVisibility[playerID]
  for index = 0, Map.GetPlotCount() - 1 do
    local plot = Map.GetPlotByIndex(index)
    if plot ~= nil and plot:GetWonderType() ~= -1 and visibility:IsRevealed(index) then
      built[GameInfo.Buildings[plot:GetWonderType()].BuildingType] = true
    end
  end
  return built
end

-- Wonders with a map pin of the player: { [BuildingType] = true }.
function SDP_Wonders.Pinned(playerID)
  local pinned = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    local key = (pin:GetIconName() or ""):gsub("^ICON_", "")
    local row = GameInfo.Buildings[key]
    if row ~= nil and row.IsWonder then pinned[key] = true end
  end
  return pinned
end

-- The era of a wonder: the later era of its prerequisite technology and
-- civic. Returns Eras.ChronologyIndex (0 without either) and the era type.
function SDP_Wonders.Era(row)
  local index, eraType = 0, nil
  local function Take(prereq)
    local era = prereq ~= nil and prereq.EraType ~= nil and GameInfo.Eras[prereq.EraType] or nil
    if era ~= nil and (era.ChronologyIndex or 0) > index then index, eraType = era.ChronologyIndex, era.EraType end
  end
  if row.PrereqTech ~= nil then Take(GameInfo.Technologies[row.PrereqTech]) end
  if row.PrereqCivic ~= nil then Take(GameInfo.Civics[row.PrereqCivic]) end
  return index, eraType
end

-- The player's wonder list as the map tack popup builds it
-- (MapTacks.PlayerWonders) without the generic wonder icon: { Type, Name,
-- Icon, Status = nil | "BUILT" | "PINNED", AdjacentDistrict,
-- AdjacentImprovement, Era, EraType, Cost }. Sorted by era, then production cost, then type (issue 7).
-- Tech and era are not checked: this is planning ahead.
function SDP_Wonders.List(playerID)
  local built, pinned = SDP_Wonders.Built(playerID), SDP_Wonders.Pinned(playerID)
  local list = {}
  for _, row in ipairs(MapTacks.PlayerWonders(MapTacks.PlayerTraits(playerID))) do
    if row.BuildingType ~= nil and row.IsWonder then
      local status = nil
      if built[row.BuildingType] then status = "BUILT" elseif pinned[row.BuildingType] then status = "PINNED" end
      local era, eraType = SDP_Wonders.Era(row)
      list[#list + 1] = {
        Type = row.BuildingType, Name = row.Name, Icon = "ICON_" .. row.BuildingType, Status = status,
        AdjacentDistrict = row.AdjacentDistrict, AdjacentImprovement = row.AdjacentImprovement,
        Era = era, EraType = eraType, Cost = row.Cost or 0,
      }
    end
  end
  table.sort(list, function(a, b)
    if a.Era ~= b.Era then return a.Era < b.Era end
    if a.Cost ~= b.Cost then return a.Cost < b.Cost end
    return a.Type < b.Type
  end)
  return list
end

-- ===========================================================================
-- The improvement a wonder must stand next to (issue 51)
-- ===========================================================================
-- Buildings.AdjacentImprovement (the Temple of Artemis: a Camp, Rise and
-- Fall and Gathering Storm). DMT checks that one is next to the wonder (a
-- built one or a tack) but not where the improvement itself may go
-- (CanPlacePin leaves improvements as a TODO), so that comes from the rules
-- here. The engine (2026-10-24, tests/bench/probe_camp.py) counts a Camp of
-- any of the player's cities, not one on an unowned tile (AGENTS pitfall 43).

local function Rows(name)
  return GameInfo[name] ~= nil and GameInfo[name]() or function() return nil end
end

local function Flag(v) return v == true or (type(v) == "number" and v ~= 0) end

-- Whether the rules let improvement `row` go on `plot` as the player sees
-- it: a visible resource with improvements of its own takes only those
-- (Improvement_ValidResources), else the feature decides
-- (Improvement_ValidFeatures), else the terrain (Improvement_ValidTerrains).
-- Not checked: technology (planning ahead, as for districts and wonders).
-- The game's ImprovementBuilder.CanHaveImprovement agreed on every tile of
-- a map for the Camp (2026-10-24); it is not there in the UI state, so it
-- is asked only where it exists.
function SDP_Wonders.ImprovementFits(playerID, row, plot)
  if plot:IsWater() ~= (row.Domain == "DOMAIN_SEA") then return false end
  local feature = plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()] or nil
  local resource = plot:GetResourceType() ~= -1 and GameInfo.Resources[plot:GetResourceType()] or nil
  if resource ~= nil and not Players[playerID]:GetResources():IsResourceVisible(resource.Hash) then resource = nil end
  local fits = nil
  if resource ~= nil then
    for r in Rows("Improvement_ValidResources") do
      if r.ResourceType == resource.ResourceType then
        if fits == nil then fits = false end
        if r.ImprovementType == row.ImprovementType then
          fits = not (Flag(r.MustRemoveFeature) and feature ~= nil and not feature.Removable)
        end
      end
    end
  end
  if fits == nil then
    fits = false
    if feature ~= nil then
      for r in Rows("Improvement_ValidFeatures") do
        if r.ImprovementType == row.ImprovementType and r.FeatureType == feature.FeatureType then fits = true end
      end
    else
      local terrain = GameInfo.Terrains[plot:GetTerrainType()]
      for r in Rows("Improvement_ValidTerrains") do
        if r.ImprovementType == row.ImprovementType and terrain ~= nil and r.TerrainType == terrain.TerrainType then fits = true end
      end
    end
  end
  if fits and ImprovementBuilder ~= nil and ImprovementBuilder.CanHaveImprovement ~= nil then
    local ok, can = pcall(ImprovementBuilder.CanHaveImprovement, plot, row.Index, -1)
    if ok and can == false then fits = false end
  end
  return fits
end

-- Coastal lowland the sea has flooded (Gathering Storm): no improvement.
local function Flooded(plot)
  if TerrainManager == nil or TerrainManager.GetCoastalLowlandType == nil or TerrainManager.IsFlooded == nil then return false end
  return TerrainManager.GetCoastalLowlandType(plot) ~= -1 and TerrainManager.IsFlooded(plot) == true
end

-- Where the improvement a wonder needs can go for each candidate plot.
--   improvementType  Buildings.AdjacentImprovement
--   candidates       the search's candidates { Index, X, Y }, sorted
--   allowed          { [position] = true }: where the wonder may go
--   ownable          { [plot index] = true }: unowned plots a participating
--                    city can come to own (SDP_City scan Reach.Reached)
--   taken            { [plot index] = true }: plots with a fixed subject or
--                    a tack (never used, constraint 7)
--   fixed            the fixed subjects (a tack of the improvement counts)
-- Returns nil when the rules lack the improvement, else
-- { Type, Needed = { [position] = true } (no such improvement of the player
-- next to it yet), Plots = { [position] = { plot indices, sorted } } (where
-- one could go next to it), Any (some allowed position has one or could) }.
function SDP_Wonders.Support(playerID, improvementType, candidates, allowed, ownable, taken, fixed)
  local row = GameInfo.Improvements[improvementType]
  if row == nil then return nil end
  local pinned = {}
  for _, subject in ipairs(fixed or {}) do
    if subject.Type == "IMPROVEMENT" and subject.Key == improvementType then
      pinned[Map.GetPlotIndex(subject.X, subject.Y)] = true
    end
  end
  local visibility = PlayersVisibility[playerID]
  local fitsAt = {}
  local function Free(plot)
    local index = plot:GetIndex()
    local cached = fitsAt[index]
    if cached ~= nil then return cached end
    local owner = plot:GetOwner()
    local ok = visibility:IsRevealed(index) and not taken[index] and not plot:IsCity() and plot:GetDistrictType() == -1
      and plot:GetWonderType() == -1 and not plot:IsNaturalWonder() and plot:GetImprovementType() == -1
      and (owner == playerID or (owner == -1 and ownable[index] == true)) and not Flooded(plot)
      and SDP_Wonders.ImprovementFits(playerID, row, plot)
    fitsAt[index] = ok
    return ok
  end
  local out = { Type = improvementType, Needed = {}, Plots = {}, Any = false }
  for i, c in ipairs(candidates) do
    if allowed[i] then
      local has, list = false, {}
      for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(c.X, c.Y, direction)
        if plot ~= nil then
          local index = plot:GetIndex()
          if pinned[index] or (plot:GetImprovementType() == row.Index and plot:GetOwner() == playerID) then
            has = true
          elseif Free(plot) then
            list[#list + 1] = index
          end
        end
      end
      if has then
        out.Any = true
      else
        table.sort(list)
        out.Needed[i], out.Plots[i] = true, list
        if #list > 0 then out.Any = true end
      end
    end
  end
  return out
end
