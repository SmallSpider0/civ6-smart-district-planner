-- SDP_City: what the planner needs to know about one city: the plots a new
-- district could go on, the districts already built, and the player's
-- existing map pins nearby. Existing pins are locked: never moved, and they
-- act as fixed neighbours (requirement constraint 7).
-- Every list is sorted by plot index so results never depend on pairs() order.

SDP_City = {}

SDP_City.RADIUS = 3  -- districts go within three rings of the city center

-- Why a plot within range cannot take a new district.
SDP_City.EXCLUDED = {
  UNREVEALED = "UNREVEALED",         -- not revealed to the player: DMT knows nothing there
  CITY_CENTER = "CITY_CENTER",       -- any city's center
  DISTRICT = "DISTRICT",             -- a district is already there
  WONDER = "WONDER",                 -- a wonder is built or placed there
  NATURAL_WONDER = "NATURAL_WONDER",
  PIN = "PIN",                       -- an existing map pin: locked
  FOREIGN = "FOREIGN",               -- owned by another player
  OTHER_CITY = "OTHER_CITY",         -- owned by another of the player's cities
  FEATURE = "FEATURE",               -- clearing its feature is switched off
  RESOURCE = "RESOURCE",             -- a resource a district cannot remove (luxury, strategic)
}

-- Resources a district can be built on: the ones the game can harvest
-- (Resource_Harvests). The others (luxuries, strategics) block districts.
-- DMT means to check this in CanPlacePin, but for a district pin it drops
-- the plot's resource before the check, so it never refuses one.
local m_harvestable = nil
local function Harvestable(resourceType)
  if m_harvestable == nil then
    m_harvestable = {}
    for row in GameInfo.Resource_Harvests() do m_harvestable[row.ResourceType] = true end
  end
  return m_harvestable[resourceType] == true
end

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
-- `ignore` (optional): { [pin ID] = true } pins to leave out (this mod's own
-- pins being replaced, see SDP_Pins.Own).
function SDP_City.PinsInRange(playerID, x, y, radius, ignore)
  local list = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    local px, py = pin:GetHexX(), pin:GetHexY()
    if Map.GetPlotDistance(x, y, px, py) <= radius and not (ignore and ignore[pin:GetID()]) then
      list[#list + 1] = {
        ID = pin:GetID(), X = px, Y = py, Index = Map.GetPlotIndex(px, py),
        Icon = pin:GetIconName(), Name = pin:GetName(),
      }
    end
  end
  table.sort(list, ByIndex)
  return list
end

-- City numbers, the names our pins carry. The icon already says which
-- district a pin is, so the name says which city it belongs to: the player's
-- cities are numbered 1, 2, ... in founding order (city ID; the capital is
-- usually 1), planned cities (city-center pins) take the numbers after them.
-- Returns { [cityID] = number } and how many cities there are.
function SDP_City.CityNumbers(playerID)
  local ids = {}
  for _, city in Players[playerID]:GetCities():Members() do ids[#ids + 1] = city:GetID() end
  table.sort(ids)
  local numbers = {}
  for n, id in ipairs(ids) do numbers[id] = n end
  return numbers, #ids
end

-- Numbers for planned cities, given their city-center pins' names in a fixed
-- order: a pin named with a free number above the cities' keeps it (our own
-- site pins), the others get the lowest free numbers in turn. Returns a list
-- parallel to `names`.
function SDP_City.SiteNumbers(playerID, names)
  local _, count = SDP_City.CityNumbers(playerID)
  local taken, out = {}, {}
  for i, name in ipairs(names) do
    local n = tonumber(name)
    if n ~= nil and n == math.floor(n) and n > count and not taken[n] then
      out[i], taken[n] = n, true
    end
  end
  local next = count + 1
  for i = 1, #names do
    if out[i] == nil then
      while taken[next] do next = next + 1 end
      out[i], taken[next] = next, true
    end
  end
  return out
end

-- Specialty district slots for a population (pitfall 18).
function SDP_City.SpecialtyCapacity(population)
  return 1 + math.floor((population - 1) / 3)
end

-- Why `plot` cannot take a new district for this city, or nil.
local function ExclusionReason(plot, playerID, cityID, pinned, allowFeatureRemoval)
  local E = SDP_City.EXCLUDED
  -- DMT reads no terrain for unrevealed plots and CanPlacePin then fails.
  if not PlayersVisibility[playerID]:IsRevealed(plot:GetIndex()) then return E.UNREVEALED end
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
  local resource = plot:GetResourceType()
  if resource ~= -1 then
    local row = GameInfo.Resources[resource]
    if row ~= nil and not Harvestable(row.ResourceType)
        and Players[playerID]:GetResources():IsResourceVisible(row.Hash) then
      return E.RESOURCE
    end
  end
  return nil
end

-- Scan options for a solver request: AllowFeatureRemoval, and IgnorePins
-- (this mod's earlier pins being replaced: { { ID, X, Y } }).
function SDP_City.ScanOptions(request)
  local ignore = nil
  for _, pin in ipairs(request.IgnorePins or {}) do
    ignore = ignore or {}
    ignore[pin.ID] = true
  end
  return { allowFeatureRemoval = request.AllowFeatureRemoval, ignorePins = ignore }
end

-- Scan one city. options.allowFeatureRemoval (default true): when false,
-- plots with a feature a district would clear (GameInfo.Features.Removable:
-- woods, rainforest, marsh) are excluded (requirement constraint 5).
-- options.ignorePins: { [pin ID] = true } pins treated as absent.
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
    Pins = SDP_City.PinsInRange(playerID, cx, cy, SDP_City.RADIUS + 1, options and options.ignorePins),
    Ignored = options and options.ignorePins,
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

-- Scan a planned city: a city-center map pin at (x, y) that is not a city
-- yet (docs/multicity-design.md 4.1). Same shape as Scan, without CityID.
-- A new city cannot use plots that already belong to one of the player's
-- cities (ExclusionReason with no city: OTHER_CITY). options:
--   allowFeatureRemoval  as for Scan
--   population           the population to plan for (default 1)
--   name                 shown in results (default "")
function SDP_City.ScanSite(playerID, x, y, options)
  options = options or {}
  local allowFeatureRemoval = options.allowFeatureRemoval ~= false
  local scan = {
    PlayerID = playerID, CityID = nil, Site = true, Name = options.name or "", X = x, Y = y,
    Population = options.population or 1, SpecialtyBuilt = 0,
    Candidates = {}, Excluded = {}, Built = {},
    Pins = SDP_City.PinsInRange(playerID, x, y, SDP_City.RADIUS + 1, options.ignorePins),
    Ignored = options.ignorePins,
  }
  scan.SpecialtyCapacity = SDP_City.SpecialtyCapacity(scan.Population)
  local pinned = {}
  for _, pin in ipairs(scan.Pins) do pinned[pin.Index] = true end
  for _, entry in ipairs(SDP_City.PlotsInRange(x, y, SDP_City.RADIUS)) do
    local reason = ExclusionReason(Map.GetPlotByIndex(entry.Index), playerID, nil, pinned, allowFeatureRemoval)
    if reason then
      scan.Excluded[entry.Index] = reason
    else
      scan.Candidates[#scan.Candidates + 1] = entry
    end
  end
  return scan
end

-- Plots the game itself refuses for a district in a city, on top of DMT's
-- rules (docs/multicity-design.md section 18, item 3; AGENTS pitfall 27:
-- DMT does not check that a canal connects water): the city's own plots
-- within RADIUS left out of the engine's build targets for the district
-- (CityManager.GetOperationTargets, what the game's placement lens shows).
-- Returns a set of plot indices, or nil when the engine gives no list (API
-- missing, district locked, no free slot, ...): then DMT decides alone.
-- Plots the city does not own yet are never in it (the engine only offers
-- owned plots).
function SDP_City.EngineRefused(playerID, cityID, districtType)
  if CityManager == nil or CityManager.GetOperationTargets == nil or CityOperationTypes == nil
      or CityOperationResults == nil then
    return nil
  end
  local city = CityManager.GetCity(playerID, cityID)
  local row = GameInfo.Districts[districtType]
  if city == nil or row == nil then return nil end
  local params = {}
  params[CityOperationTypes.PARAM_DISTRICT_TYPE] = row.Hash
  local ok, results = pcall(CityManager.GetOperationTargets, city, CityOperationTypes.BUILD, params)
  local plots = ok and type(results) == "table" and results[CityOperationResults.PLOTS] or nil
  if type(plots) ~= "table" then return nil end
  local allowed, any = {}, false
  for _, index in ipairs(plots) do
    allowed[index], any = true, true
  end
  if not any then return nil end
  local refused = {}
  for _, p in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), SDP_City.RADIUS)) do
    if not allowed[p.Index] then
      local plot = Map.GetPlotByIndex(p.Index)
      local owner = plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
      if owner ~= nil and owner:GetID() == cityID then refused[p.Index] = true end
    end
  end
  return refused
end

-- Why each plannable district cannot be planned for this city, or nil when
-- it can: { [DistrictType] = "BUILT" | "MAX_PER_PLAYER" }. BUILT: already in
-- this city (shown greyed out). MAX_PER_PLAYER: the player has reached the
-- district's MaxPerPlayer elsewhere (e.g. one Government Plaza per empire),
-- counting the player's pins of it too: a pinned Government Plaza in another
-- city is where the plan already has it (SDP_Multi counts them the same way).
function SDP_City.DistrictStatus(scan, districts)
  local builtHere, builtByPlayer = {}, {}
  for _, built in ipairs(scan.Built) do builtHere[built.Type] = true end
  for _, district in Players[scan.PlayerID]:GetDistricts():Members() do
    local districtType = GameInfo.Districts[district:GetType()].DistrictType
    builtByPlayer[districtType] = (builtByPlayer[districtType] or 0) + 1
  end
  for _, pin in ipairs(PlayerConfigurations[scan.PlayerID]:GetMapPins()) do
    local key = (pin:GetIconName() or ""):gsub("^ICON_", "")
    local plot = Map.GetPlot(pin:GetHexX(), pin:GetHexY())
    local row = GameInfo.Districts[key]
    -- A pin on the district it planned (built since) is counted once; a pin
    -- being replaced (scan.Ignored) not at all.
    if row ~= nil and not (plot ~= nil and plot:GetDistrictType() == row.Index)
        and not (scan.Ignored and scan.Ignored[pin:GetID()]) then
      builtByPlayer[key] = (builtByPlayer[key] or 0) + 1
    end
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
