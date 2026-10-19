-- SDP_City: what the planner needs to know about one city: the plots a new
-- district could go on, the districts already built, and the player's
-- existing map pins nearby. Existing pins are locked: never moved, and they
-- act as fixed neighbours (requirement constraint 7).
-- Every list is sorted by plot index so results never depend on pairs() order.

SDP_City = {}

SDP_City.RADIUS = 3  -- districts go within three rings of the city center

-- Why a plot within range cannot take a new district.
SDP_City.EXCLUDED = {
  CITY_CENTER = "CITY_CENTER",       -- any city's center
  DISTRICT = "DISTRICT",             -- a district is already there
  WONDER = "WONDER",                 -- a wonder is built or placed there
  NATURAL_WONDER = "NATURAL_WONDER",
  PIN = "PIN",                       -- an existing map pin: locked
  FOREIGN = "FOREIGN",               -- owned by another player
  OTHER_CITY = "OTHER_CITY",         -- owned by another of the player's cities
  FEATURE = "FEATURE",               -- clearing its feature is switched off
}

local function ByIndex(a, b)
  if a.Index ~= b.Index then return a.Index < b.Index end
  return (a.ID or 0) < (b.ID or 0)
end

-- Plots within `radius` rings of (x, y), the center excluded, sorted by plot
-- index. Each entry: { Index, X, Y, Ring }.
function SDP_City.PlotsInRange(x, y, radius)
  local list = {}
  for dx = -radius, radius do
    for dy = -radius, radius do
      local plot = Map.GetPlotXYWithRangeCheck(x, y, dx, dy, radius)
      if plot ~= nil then
        local ring = Map.GetPlotDistance(x, y, plot:GetX(), plot:GetY())
        if ring >= 1 then
          list[#list + 1] = { Index = plot:GetIndex(), X = plot:GetX(), Y = plot:GetY(), Ring = ring }
        end
      end
    end
  end
  table.sort(list, ByIndex)
  return list
end

-- The player's map pins within `radius` rings of (x, y), sorted by plot index.
-- Reads GetMapPins() only: PlayerConfiguration:GetMapPin(x, y) would create a
-- pin where there is none.
function SDP_City.PinsInRange(playerID, x, y, radius)
  local list = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    local px, py = pin:GetHexX(), pin:GetHexY()
    if Map.GetPlotDistance(x, y, px, py) <= radius then
      list[#list + 1] = {
        ID = pin:GetID(), X = px, Y = py, Index = Map.GetPlotIndex(px, py),
        Icon = pin:GetIconName(), Name = pin:GetName(),
      }
    end
  end
  table.sort(list, ByIndex)
  return list
end

-- Specialty district slots for a population (pitfall 18).
function SDP_City.SpecialtyCapacity(population)
  return 1 + math.floor((population - 1) / 3)
end

-- Why `plot` cannot take a new district for this city, or nil.
local function ExclusionReason(plot, playerID, cityID, pinned, allowFeatureRemoval)
  local E = SDP_City.EXCLUDED
  if plot:IsCity() then return E.CITY_CENTER end
  if plot:GetDistrictType() ~= -1 then return E.DISTRICT end
  if plot:GetWonderType() ~= -1 then return E.WONDER end
  if plot:IsNaturalWonder() then return E.NATURAL_WONDER end
  if pinned[plot:GetIndex()] then return E.PIN end
  local owner = plot:GetOwner()
  if owner ~= -1 and owner ~= playerID then return E.FOREIGN end
  if owner == playerID then
    local owningCity = Cities.GetPlotPurchaseCity(plot)
    if owningCity ~= nil and owningCity:GetID() ~= cityID then return E.OTHER_CITY end
  end
  local feature = plot:GetFeatureType()
  if not allowFeatureRemoval and feature ~= -1 and GameInfo.Features[feature].Removable then
    return E.FEATURE
  end
  return nil
end

-- Scan one city. options.allowFeatureRemoval (default true): when false,
-- plots with a feature a district would clear (GameInfo.Features.Removable:
-- woods, rainforest, marsh) are excluded (requirement constraint 5).
-- Returns nil when the city does not exist, else:
--   PlayerID, CityID, Name, X, Y, Population, SpecialtyCapacity, SpecialtyBuilt
--   Candidates  plots a new district may go on: { Index, X, Y, Ring }
--   Excluded    { [plot index] = SDP_City.EXCLUDED reason } for the other plots in range
--   Built       districts placed in this city (complete or not): { Type, X, Y, Index, Complete }
--   Pins        the player's pins within RADIUS + 1 rings (neighbours of every
--               candidate): { ID, X, Y, Index, Icon, Name }
function SDP_City.Scan(playerID, cityID, options)
  local city = CityManager.GetCity(playerID, cityID)
  if city == nil then return nil end
  local allowFeatureRemoval = not (options and options.allowFeatureRemoval == false)
  local cx, cy = city:GetX(), city:GetY()

  local scan = {
    PlayerID = playerID, CityID = cityID, Name = city:GetName(), X = cx, Y = cy,
    Population = city:GetPopulation(),
    Candidates = {}, Excluded = {}, Built = {},
    Pins = SDP_City.PinsInRange(playerID, cx, cy, SDP_City.RADIUS + 1),
  }
  scan.SpecialtyCapacity = SDP_City.SpecialtyCapacity(scan.Population)

  local pinned = {}
  for _, pin in ipairs(scan.Pins) do pinned[pin.Index] = true end
  for _, entry in ipairs(SDP_City.PlotsInRange(cx, cy, SDP_City.RADIUS)) do
    local reason = ExclusionReason(Map.GetPlotByIndex(entry.Index), playerID, cityID, pinned, allowFeatureRemoval)
    if reason then
      scan.Excluded[entry.Index] = reason
    else
      scan.Candidates[#scan.Candidates + 1] = entry
    end
  end

  scan.SpecialtyBuilt = 0
  for _, district in city:GetDistricts():Members() do
    local row = GameInfo.Districts[district:GetType()]
    if not row.CityCenter then
      scan.Built[#scan.Built + 1] = {
        Type = row.DistrictType, X = district:GetX(), Y = district:GetY(),
        Index = Map.GetPlotIndex(district:GetX(), district:GetY()), Complete = district:IsComplete(),
      }
      if row.RequiresPopulation then scan.SpecialtyBuilt = scan.SpecialtyBuilt + 1 end
    end
  end
  table.sort(scan.Built, ByIndex)
  return scan
end

-- Why each plannable district cannot be planned for this city, or nil when
-- it can: { [DistrictType] = "BUILT" | "MAX_PER_PLAYER" }. BUILT: already in
-- this city (shown greyed out). MAX_PER_PLAYER: the player has reached the
-- district's MaxPerPlayer elsewhere (e.g. one Government Plaza per empire).
function SDP_City.DistrictStatus(scan, districts)
  local builtHere, builtByPlayer = {}, {}
  for _, built in ipairs(scan.Built) do builtHere[built.Type] = true end
  for _, district in Players[scan.PlayerID]:GetDistricts():Members() do
    local districtType = GameInfo.Districts[district:GetType()].DistrictType
    builtByPlayer[districtType] = (builtByPlayer[districtType] or 0) + 1
  end
  local status = {}
  for _, district in ipairs(districts) do
    if builtHere[district.Type] and district.OnePerCity then
      status[district.Type] = "BUILT"
    elseif district.MaxPerPlayer and district.MaxPerPlayer > 0
        and (builtByPlayer[district.Type] or 0) >= district.MaxPerPlayer then
      status[district.Type] = "MAX_PER_PLAYER"
    end
  end
  return status
end
