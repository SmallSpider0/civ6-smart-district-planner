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
  SITE_RING = "SITE_RING",           -- unowned, next to a planned city: founding it takes the plot
  FEATURE = "FEATURE",               -- clearing its feature is switched off
  RESOURCE = "RESOURCE",             -- a resource a district cannot remove (luxury, strategic)
  UNREACHABLE = "UNREACHABLE",       -- unowned, and not connected to the city's territory (issue 35)
  FLOODED = "FLOODED",               -- coastal lowland the sea has flooded (Gathering Storm, issue 44)
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

-- Coastal lowland the rising sea has flooded or submerged (Gathering
-- Storm): the game refuses every district there without giving a reason,
-- and DMT does not check it (pitfall 41). The sea level changes over the
-- game, so only the current state counts. No TerrainManager (other rule
-- sets): nothing is flooded.
local function Flooded(plot)
  if TerrainManager == nil or TerrainManager.GetCoastalLowlandType == nil then return false end
  if TerrainManager.GetCoastalLowlandType(plot) == -1 then return false end
  return (TerrainManager.IsFlooded ~= nil and TerrainManager.IsFlooded(plot) == true)
    or (TerrainManager.IsSubmerged ~= nil and TerrainManager.IsSubmerged(plot) == true)
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

-- The player's city-center map pins that are not cities yet (planned
-- cities), sorted by plot index: { X, Y, Index, Name, PinID }. A pin is a
-- city center when DMT reads it as one (CreateMapPinSubject: the city center
-- icon, or DMT's own convention for goody hut / barbarian icons named "City...").
function SDP_City.Sites(playerID)
  local list = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    local subject = CreateMapPinSubject(pin)
    if subject ~= nil and subject.Type == "DISTRICT" and subject.Key == "DISTRICT_CITY_CENTER" then
      local x, y = pin:GetHexX(), pin:GetHexY()
      local plot = Map.GetPlot(x, y)
      if plot ~= nil and not plot:IsCity() then
        list[#list + 1] = { X = x, Y = y, Index = plot:GetIndex(), Name = pin:GetName() or "", PinID = pin:GetID() }
      end
    end
  end
  table.sort(list, ByIndex)
  return list
end

-- The plots next to the player's planned cities, except the one at plot
-- `except` and pins being replaced (`ignore`): { [plot index] = true }. A
-- city founded on the pin takes the unowned ones, so another city cannot
-- build there (issue 26).
local function SiteRings(playerID, except, ignore)
  local rings = {}
  for _, site in ipairs(SDP_City.Sites(playerID)) do
    if site.Index ~= except and not (ignore and ignore[site.PinID]) then
      for _, entry in ipairs(SDP_City.PlotsInRange(site.X, site.Y, 1)) do rings[entry.Index] = true end
    end
  end
  return rings
end

-- The plots a city can come to own (issue 35): the game lets a city grow
-- into or buy a plot only next to one it owns, so an unowned plot counts
-- only when a chain of unowned plots within RADIUS joins it to the city's
-- territory. A planned city starts with its center and first ring (what
-- founding it takes). Plots of other players and cities, and the first
-- rings of other planned cities (`siteRings`), are never part of a chain.
-- Returns { Start, Through, Reached }, sets of plot indices: what the city
-- owns now (or gets on founding), what a chain may run over (Start
-- included), and what a chain reaches from Start (SDP_Multi checks a
-- layout's chains again, with the other cities' planned districts in the
-- way, through SDP_Search's Reach).
local function ReachSets(playerID, cityID, cx, cy, siteRings, allowSwap)
  local start, through = {}, {}
  local center = Map.GetPlotIndex(cx, cy)
  start[center], through[center] = true, true
  for _, entry in ipairs(SDP_City.PlotsInRange(cx, cy, SDP_City.RADIUS)) do
    local plot = Map.GetPlotByIndex(entry.Index)
    local owner = plot:GetOwner()
    local own = false
    if cityID ~= nil then
      local owningCity = owner == playerID and Cities.GetPlotPurchaseCity(plot) or nil
      own = owningCity ~= nil and owningCity:GetID() == cityID
    else
      own = owner == -1 and entry.Ring <= 1
    end
    if own then
      start[entry.Index], through[entry.Index] = true, true
    elseif owner == -1 and not siteRings[entry.Index] then
      through[entry.Index] = true
    end
  end
  -- Plots another of the player's cities owns that this city can take by
  -- swapping tiles (issue 54; CityCommandTypes.SWAP_TILE_OWNER, measured
  -- 2026-10-23 on every city of a late save): next to this city's
  -- territory, no district on it, not next to the other city's center.
  -- { [plot index] = the owning city's ID }.
  local swap = {}
  if cityID ~= nil and allowSwap then
    for _, entry in ipairs(SDP_City.PlotsInRange(cx, cy, SDP_City.RADIUS)) do
      local plot = Map.GetPlotByIndex(entry.Index)
      local owningCity = plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
      if owningCity ~= nil and owningCity:GetID() ~= cityID and not plot:IsCity() and plot:GetDistrictType() == -1
          and Map.GetPlotDistance(plot:GetX(), plot:GetY(), owningCity:GetX(), owningCity:GetY()) > 1 then
        local touches = false
        for _, n in ipairs(SDP_City.PlotsInRange(plot:GetX(), plot:GetY(), 1)) do
          if start[n.Index] then touches = true end
        end
        if touches then
          swap[entry.Index] = owningCity:GetID()
          through[entry.Index] = true
        end
      end
    end
  end
  return { Start = start, Through = through, Reached = SDP_City.Reach(start, through), Swap = swap }
end

-- The plots a chain from `start` reaches over `through` (sets of plot
-- indices; `blocked`, optional: plots the chain may not use). Walks plots
-- in index order so the result never depends on pairs() order (it is a
-- set, so the order only matters for the work done).
function SDP_City.Reach(start, through, blocked)
  local reached, queue, list = {}, {}, {}
  for index in pairs(start) do list[#list + 1] = index end
  table.sort(list)
  for _, index in ipairs(list) do
    if not (blocked and blocked[index]) then
      reached[index] = true
      queue[#queue + 1] = index
    end
  end
  local head = 1
  while head <= #queue do
    local index = queue[head]
    head = head + 1
    local plot = Map.GetPlotByIndex(index)
    for _, n in ipairs(SDP_City.PlotsInRange(plot:GetX(), plot:GetY(), 1)) do
      if through[n.Index] and not reached[n.Index] and not (blocked and blocked[n.Index]) then
        reached[n.Index] = true
        queue[#queue + 1] = n.Index
      end
    end
  end
  return reached
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

-- The technology the player still needs before a district can clear the
-- plot's feature (Features.RemoveTech) or harvest its bonus resource
-- (Resource_Harvests.PrereqTech; issue 52); the game refuses the district
-- until then. Nil when none.
local function MissingRemoveTech(plot, playerID)
  local player = Players[playerID]
  local techs = player ~= nil and player.GetTechs ~= nil and player:GetTechs() or nil
  local function Missing(name)
    local tech = name and GameInfo.Technologies[name] or nil
    if tech == nil or (techs ~= nil and techs:HasTech(tech.Index)) then return nil end
    return tech.TechnologyType
  end
  local feature = plot:GetFeatureType()
  if feature ~= -1 then
    local row = GameInfo.Features[feature]
    local missing = row ~= nil and row.Removable and Missing(row.RemoveTech) or nil
    if missing ~= nil then return missing end
  end
  local resource = plot:GetResourceType()
  local row = resource ~= -1 and GameInfo.Resources[resource] or nil
  if row ~= nil and player ~= nil and player:GetResources():IsResourceVisible(row.Hash) then
    for harvest in GameInfo.Resource_Harvests() do
      if harvest.ResourceType == row.ResourceType then
        local missing = Missing(harvest.PrereqTech)
        if missing ~= nil then return missing end
      end
    end
  end
  return nil
end

-- Whether building on `plot` removes a feature or a bonus resource the
-- player should clear or harvest first for its one-time yields (issue 52).
local function ClearsFirst(plot, playerID)
  local feature = plot:GetFeatureType()
  if feature ~= -1 and GameInfo.Features[feature].Removable then return true end
  local resource = plot:GetResourceType()
  local row = resource ~= -1 and GameInfo.Resources[resource] or nil
  return row ~= nil and Harvestable(row.ResourceType) and Players[playerID]:GetResources():IsResourceVisible(row.Hash)
end

-- Why `plot` cannot take a new district for this city, or nil.
local function ExclusionReason(plot, playerID, cityID, pinned, siteRings, allowFeatureRemoval, reach)
  local E = SDP_City.EXCLUDED
  -- DMT reads no terrain for unrevealed plots and CanPlacePin then fails.
  if not PlayersVisibility[playerID]:IsRevealed(plot:GetIndex()) then return E.UNREVEALED end
  if plot:IsCity() then return E.CITY_CENTER end
  if plot:GetDistrictType() ~= -1 then return E.DISTRICT end
  if plot:GetWonderType() ~= -1 then return E.WONDER end
  if plot:IsNaturalWonder() then return E.NATURAL_WONDER end
  if Flooded(plot) then return E.FLOODED end
  if pinned[plot:GetIndex()] then return E.PIN end
  local owner = plot:GetOwner()
  if owner ~= -1 and owner ~= playerID then return E.FOREIGN end
  if owner == playerID then
    local owningCity = Cities.GetPlotPurchaseCity(plot)
    if owningCity ~= nil and owningCity:GetID() ~= cityID and not reach.Swap[plot:GetIndex()] then return E.OTHER_CITY end
  end
  if owner == -1 and siteRings[plot:GetIndex()] then return E.SITE_RING end
  if owner == -1 and not reach.Reached[plot:GetIndex()] then return E.UNREACHABLE end
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
  return { allowFeatureRemoval = request.AllowFeatureRemoval, ignorePins = ignore, allowSwap = request.Swap == true }
end

-- Scan one city. options.allowSwap (default false): plots another of the
-- player's cities owns that this city can swap over are candidates too
-- (issue 54; the player's switch). options.allowFeatureRemoval (default true): when false,
-- plots with a feature a district would clear (GameInfo.Features.Removable:
-- woods, rainforest, marsh) are excluded (requirement constraint 5).
-- options.ignorePins: { [pin ID] = true } pins treated as absent.
-- Returns nil when the city does not exist, else:
--   PlayerID, CityID, Name, X, Y, Population, SpecialtyCapacity, SpecialtyBuilt
--   Candidates  plots a new district may go on: { Index, X, Y, Ring, Unowned
--               (true when the city does not own the plot yet), Swap (the
--               ID of the player's city it is swapped from), ClearFirst
--               (a removable feature or a bonus resource to clear or harvest
--               before building, issue 52), RemoveTech
--               (the technology still needed to clear its feature, or nil) }
--   Excluded    { [plot index] = SDP_City.EXCLUDED reason } for the other plots in range
--   Reach       { Start, Through, Reached, Swap } (see ReachSets)
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
    Population = city:GetPopulation(), AllowFeatureRemoval = allowFeatureRemoval,
    Candidates = {}, Excluded = {}, Built = {},
    Pins = SDP_City.PinsInRange(playerID, cx, cy, SDP_City.RADIUS + 1, options and options.ignorePins),
    Ignored = options and options.ignorePins,
  }
  scan.SpecialtyCapacity = SDP_City.SpecialtyCapacity(scan.Population)

  local pinned = {}
  for _, pin in ipairs(scan.Pins) do pinned[pin.Index] = true end
  local siteRings = SiteRings(playerID, nil, options and options.ignorePins)
  scan.Reach = ReachSets(playerID, cityID, cx, cy, siteRings, options and options.allowSwap)
  for _, entry in ipairs(SDP_City.PlotsInRange(cx, cy, SDP_City.RADIUS)) do
    local plot = Map.GetPlotByIndex(entry.Index)
    local reason = ExclusionReason(plot, playerID, cityID, pinned, siteRings, allowFeatureRemoval, scan.Reach)
    if reason then
      scan.Excluded[entry.Index] = reason
    else
      -- Unowned: the city has to grow into or buy the plot first. Swap: the
      -- ID of the city it has to swap the plot from. RemoveTech: the
      -- technology still needed to clear its feature. All are shown with the
      -- plan, none changes what is legal.
      entry.Swap = scan.Reach.Swap[entry.Index]
      entry.Unowned = (entry.Swap == nil and not scan.Reach.Start[entry.Index]) or nil
      entry.RemoveTech = MissingRemoveTech(plot, playerID)
      entry.ClearFirst = ClearsFirst(plot, playerID) or nil
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
-- cities (ExclusionReason with no city: OTHER_CITY), nor the unowned plots
-- next to another planned city (SITE_RING). options:
--   allowFeatureRemoval  as for Scan
--   population           the population to plan for (default 1)
--   name                 shown in results (default "")
function SDP_City.ScanSite(playerID, x, y, options)
  options = options or {}
  local allowFeatureRemoval = options.allowFeatureRemoval ~= false
  local scan = {
    PlayerID = playerID, CityID = nil, Site = true, Name = options.name or "", X = x, Y = y,
    Population = options.population or 1, SpecialtyBuilt = 0, AllowFeatureRemoval = allowFeatureRemoval,
    Candidates = {}, Excluded = {}, Built = {},
    Pins = SDP_City.PinsInRange(playerID, x, y, SDP_City.RADIUS + 1, options.ignorePins),
    Ignored = options.ignorePins,
  }
  scan.SpecialtyCapacity = SDP_City.SpecialtyCapacity(scan.Population)
  local pinned = {}
  for _, pin in ipairs(scan.Pins) do pinned[pin.Index] = true end
  local siteRings = SiteRings(playerID, Map.GetPlotIndex(x, y), options.ignorePins)
  scan.Reach = ReachSets(playerID, nil, x, y, siteRings)
  for _, entry in ipairs(SDP_City.PlotsInRange(x, y, SDP_City.RADIUS)) do
    local plot = Map.GetPlotByIndex(entry.Index)
    local reason = ExclusionReason(plot, playerID, nil, pinned, siteRings, allowFeatureRemoval, scan.Reach)
    if reason then
      scan.Excluded[entry.Index] = reason
    else
      entry.Unowned = not scan.Reach.Start[entry.Index] or nil
      entry.RemoveTech = MissingRemoveTech(plot, playerID)
      entry.ClearFirst = ClearsFirst(plot, playerID) or nil
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

-- Fresh water, coast or neither at a city center plot (housing, design
-- 3.3): "FRESH" (river, lake, a feature adding fresh water next to it),
-- "COAST" or "NONE".
function SDP_City.WaterKind(plot)
  if plot:IsRiver() then return "FRESH" end
  local coast = false
  for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
    local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), direction)
    if n ~= nil then
      if n:IsLake() then return "FRESH" end
      local feature = n:GetFeatureType()
      if feature ~= -1 and GameInfo.Features[feature].AddsFreshWater then return "FRESH" end
      if n:IsWater() then coast = true end
    end
  end
  return coast and "COAST" or "NONE"
end

-- Whether the city of a scan lacks fresh water: an existing city by the
-- game's own housing from water (below what a river or lake gives), a
-- planned city by its center plot.
function SDP_City.LacksFreshWater(scan)
  local fresh = (GlobalParameters and GlobalParameters.CITY_POPULATION_RIVER_LAKE) or 5
  if scan.CityID ~= nil then
    local city = CityManager.GetCity(scan.PlayerID, scan.CityID)
    local growth = city and city.GetGrowth and city:GetGrowth()
    if growth ~= nil and growth.GetHousingFromWater ~= nil then return growth:GetHousingFromWater() < fresh end
  end
  return SDP_City.WaterKind(Map.GetPlot(scan.X, scan.Y)) ~= "FRESH"
end

-- Whether a city needs a district of an automatic kind (SDP_Rules.AutoKind)
-- that it has not got: no fresh water for "WATER", enough floodplain
-- candidate plots for "FLOOD".
function SDP_City.NeedsAuto(scan, districtType)
  local kind = SDP_Rules.AutoKind(districtType)
  if kind == "WATER" then return SDP_City.LacksFreshWater(scan) end
  if kind == "FLOOD" then
    local features, count = SDP_Rules.RequiredFeatures(districtType), 0
    for _, c in ipairs(scan.Candidates) do
      local feature = Map.GetPlotByIndex(c.Index):GetFeatureType()
      if feature ~= -1 and features[GameInfo.Features[feature].FeatureType] then count = count + 1 end
    end
    return count >= SDP_Rules.AUTO_FLOOD_PLOTS
  end
  return false
end

-- Distance cost per candidate (feedback item 9): weight x (plots to the
-- nearest center - 1), the centers being the player's cities and `extra`
-- ({ { X, Y } }, planned cities). Returns a list parallel to `candidates`,
-- or nil when the weight is 0 (off).
function SDP_City.DistanceCosts(playerID, candidates, weight, extra)
  if weight == nil or weight <= 0 then return nil end
  local centers = {}
  for _, city in Players[playerID]:GetCities():Members() do centers[#centers + 1] = { X = city:GetX(), Y = city:GetY() } end
  for _, c in ipairs(extra or {}) do centers[#centers + 1] = c end
  local costs = {}
  for i, c in ipairs(candidates) do
    local nearest = math.huge
    for _, center in ipairs(centers) do
      nearest = math.min(nearest, Map.GetPlotDistance(c.X, c.Y, center.X, center.Y))
    end
    if nearest == math.huge then nearest = 1 end
    costs[i] = weight * math.max(0, nearest - 1)
  end
  return costs
end

-- District types built in this city (complete or not). A set.
function SDP_City.BuiltTypes(scan)
  local built = {}
  for _, b in ipairs(scan.Built) do built[b.Type] = true end
  return built
end

-- The pins of a scan that are the city's own (issue 64). A pin within RADIUS
-- is the city's when
--   1. it is named with the number of a city or planned city within RADIUS
--      of it (this mod names its tacks so, SDP_Pins.Own), and that is this
--      city; else
--   2. its plot is owned: this city owns it; else
--   3. its plot is unowned and no other of the player's cities or planned
--      cities (city-center pins) is nearer to it, as the land part gives out
--      unowned plots (SDP_Solver, issue 54).
-- A planned city owns no plot yet: for it 2 never holds. Any other pin is a
-- neighbour's plan: a fixed neighbour, not a district this city has. Pins
-- being replaced are not in scan.Pins. A sublist of scan.Pins, same order.
function SDP_City.OwnPins(scan)
  local playerID = scan.PlayerID
  local here = Map.GetPlotIndex(scan.X, scan.Y)
  local centers, byNumber = {}, {}
  local cityNumbers = SDP_City.CityNumbers(playerID)
  for _, city in Players[playerID]:GetCities():Members() do
    local c = { X = city:GetX(), Y = city:GetY(), Self = city:GetID() == scan.CityID }
    centers[#centers + 1] = c
    byNumber[cityNumbers[city:GetID()]] = c
  end
  local sites, names = SDP_City.Sites(playerID), {}
  for s, site in ipairs(sites) do names[s] = site.Name end
  local siteNumbers = SDP_City.SiteNumbers(playerID, names)
  for s, site in ipairs(sites) do
    if not (scan.Ignored and scan.Ignored[site.PinID]) then
      local c = { X = site.X, Y = site.Y, Self = scan.CityID == nil and site.Index == here }
      centers[#centers + 1] = c
      byNumber[siteNumbers[s]] = c
    end
  end
  local own = {}
  for _, pin in ipairs(scan.Pins) do
    local d = Map.GetPlotDistance(scan.X, scan.Y, pin.X, pin.Y)
    local plot = Map.GetPlot(pin.X, pin.Y)
    local mine = false
    if plot ~= nil and d <= SDP_City.RADIUS then
      local n = tonumber(pin.Name or "")
      local named = n ~= nil and byNumber[n] or nil
      if named ~= nil and Map.GetPlotDistance(named.X, named.Y, pin.X, pin.Y) <= SDP_City.RADIUS then
        mine = named.Self
      elseif plot:GetOwner() == playerID then
        local owningCity = Cities.GetPlotPurchaseCity(plot)
        mine = scan.CityID ~= nil and owningCity ~= nil and owningCity:GetID() == scan.CityID
      elseif plot:GetOwner() == -1 then
        mine = true
        for _, c in ipairs(centers) do
          if not c.Self and Map.GetPlotDistance(c.X, c.Y, pin.X, pin.Y) < d then mine = false end
        end
      end
    end
    if mine then own[#own + 1] = pin end
  end
  return own
end

-- District types the city has a pin of (SDP_City.OwnPins). A set.
function SDP_City.TackedDistricts(scan)
  local tacked = {}
  for _, pin in ipairs(SDP_City.OwnPins(scan)) do
    local key = (pin.Icon or ""):gsub("^ICON_", "")
    local row = GameInfo.Districts[key]
    if row ~= nil and not row.CityCenter then tacked[key] = true end
  end
  return tacked
end

-- District types a city has already: built (complete or not), or pinned for
-- it (SDP_City.OwnPins). A set; for SDP_Rules.Apart.
function SDP_City.PresentDistricts(scan)
  local present = SDP_City.TackedDistricts(scan)
  for _, built in ipairs(scan.Built) do present[built.Type] = true end
  return present
end

-- Why each plannable district cannot be planned for this city, or nil when
-- it can: { [DistrictType] = "BUILT" | "EXCLUSIVE" | "MAX_PER_PLAYER" }.
-- BUILT: already in this city (shown greyed out). EXCLUSIVE: the city has
-- built one it cannot share a city with (SDP_Rules.Exclusive: a water park
-- next to a built entertainment complex). MAX_PER_PLAYER: the player has reached the
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
    elseif SDP_Rules.ExcludedBy(district.Type, builtHere) ~= nil then
      status[district.Type] = "EXCLUSIVE"
    elseif district.MaxPerPlayer and district.MaxPerPlayer > 0
        and (builtByPlayer[district.Type] or 0) >= district.MaxPerPlayer then
      status[district.Type] = "MAX_PER_PLAYER"
    end
  end
  return status
end
