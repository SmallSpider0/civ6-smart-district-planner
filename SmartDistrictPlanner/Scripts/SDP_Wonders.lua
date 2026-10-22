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
-- Icon, Status = nil | "BUILT" | "PINNED", AdjacentDistrict, Era, EraType,
-- Cost }. Sorted by era, then production cost, then type (issue 7).
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
        AdjacentDistrict = row.AdjacentDistrict, Era = era, EraType = eraType, Cost = row.Cost or 0,
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
