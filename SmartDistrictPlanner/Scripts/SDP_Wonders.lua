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

-- The player's wonder list as the map tack popup builds it
-- (MapTacks.PlayerWonders) without the generic wonder icon, sorted by type:
-- { Type, Name, Icon, Status = nil | "BUILT" | "PINNED", AdjacentDistrict }.
-- Tech and era are not checked: this is planning ahead.
function SDP_Wonders.List(playerID)
  local built, pinned = SDP_Wonders.Built(playerID), SDP_Wonders.Pinned(playerID)
  local list = {}
  for _, row in ipairs(MapTacks.PlayerWonders(MapTacks.PlayerTraits(playerID))) do
    if row.BuildingType ~= nil and row.IsWonder then
      local status = nil
      if built[row.BuildingType] then status = "BUILT" elseif pinned[row.BuildingType] then status = "PINNED" end
      list[#list + 1] = {
        Type = row.BuildingType, Name = row.Name, Icon = "ICON_" .. row.BuildingType, Status = status,
        AdjacentDistrict = row.AdjacentDistrict,
      }
    end
  end
  table.sort(list, function(a, b) return a.Type < b.Type end)
  return list
end
