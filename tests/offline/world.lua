-- world.lua: a small fake Civ6 for the offline tests (tools/offline_tests.mjs).
--
-- World.New(spec) builds a hex map and installs the globals the mod's
-- scripts read (Map, GameInfo, Players, PlayerConfigurations, MapTacks, ...)
-- plus a simplified DMT: CanPlacePin, GetBonusYields and the pin subject
-- store. The rules are a reduced copy of the base game's district
-- adjacencies and placement rules, enough to exercise the planner's search
-- and bookkeeping. Exact numbers in the game always come from the real DMT.
--
-- Every DMT call is counted in World.Calls: the benchmarks use the counts as
-- their cost measure (in the game a DMT call costs far more than a search
-- step).
--
-- Map: odd rows are shifted right ("odd-r"); plot index = y * width + x.
-- Map text, one character per plot:
--   .  grassland        h  grassland hills    p  plains     q  plains hills
--   d  desert           M  mountain           ~  coast      o  ocean
--   f  grassland woods  j  plains rainforest  s  grassland marsh
--   O  desert oasis     N  natural wonder (impassable)
--   F  desert floodplains

local World = {}

-- ===========================================================================
-- Game data
-- ===========================================================================
local function Table(rows, key)
  local t = {}
  for i, row in ipairs(rows) do
    row.Index = i - 1
    row.Hash = 100000 + i -- the game's hashes are large numbers; never a valid index here
    t[i - 1] = row
    t[row.Hash] = row
    if key ~= nil then t[row[key]] = row end
  end
  return setmetatable(t, {
    __call = function()
      local i = 0
      return function()
        i = i + 1
        return rows[i]
      end
    end,
  })
end

local YIELDS = { "YIELD_FOOD", "YIELD_PRODUCTION", "YIELD_GOLD", "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH" }

local function Yields(f, p, g, s, c, r)
  return { YIELD_FOOD = f or 0, YIELD_PRODUCTION = p or 0, YIELD_GOLD = g or 0,
    YIELD_SCIENCE = s or 0, YIELD_CULTURE = c or 0, YIELD_FAITH = r or 0 }
end

local function BuildGameInfo()
  local gi = {}
  local yields = {}
  for _, y in ipairs(YIELDS) do yields[#yields + 1] = { YieldType = y, Name = "LOC_" .. y .. "_NAME" } end
  gi.Yields = Table(yields, "YieldType")

  gi.Terrains = Table({
    { TerrainType = "TERRAIN_GRASS", Name = "LOC_TERRAIN_GRASS", Yields = Yields(2) },
    { TerrainType = "TERRAIN_GRASS_HILLS", Name = "LOC_TERRAIN_GRASS_HILLS", Hills = true, Yields = Yields(2, 1) },
    { TerrainType = "TERRAIN_GRASS_MOUNTAIN", Name = "LOC_TERRAIN_GRASS_MOUNTAIN", Mountain = true, Impassable = true, Yields = Yields() },
    { TerrainType = "TERRAIN_PLAINS", Name = "LOC_TERRAIN_PLAINS", Yields = Yields(1, 1) },
    { TerrainType = "TERRAIN_PLAINS_HILLS", Name = "LOC_TERRAIN_PLAINS_HILLS", Hills = true, Yields = Yields(1, 2) },
    { TerrainType = "TERRAIN_DESERT", Name = "LOC_TERRAIN_DESERT", Yields = Yields() },
    { TerrainType = "TERRAIN_COAST", Name = "LOC_TERRAIN_COAST", Water = true, Yields = Yields(1, 0, 1) },
    { TerrainType = "TERRAIN_OCEAN", Name = "LOC_TERRAIN_OCEAN", Water = true, Yields = Yields(1) },
  }, "TerrainType")

  gi.Features = Table({
    { FeatureType = "FEATURE_FOREST", Name = "LOC_FEATURE_FOREST", Removable = true, Settlement = true, Yields = Yields(0, 1) },
    { FeatureType = "FEATURE_JUNGLE", Name = "LOC_FEATURE_JUNGLE", Removable = true, Settlement = true, Yields = Yields(1) },
    { FeatureType = "FEATURE_MARSH", Name = "LOC_FEATURE_MARSH", Removable = true, Settlement = true, Yields = Yields(1) },
    { FeatureType = "FEATURE_OASIS", Name = "LOC_FEATURE_OASIS", AddsFreshWater = true, Settlement = false, Yields = Yields(3, 0, 1) },
    { FeatureType = "FEATURE_NW_TEST", Name = "LOC_FEATURE_NW_TEST", NaturalWonder = true, Impassable = true, Settlement = false,
      Yields = Yields(0, 0, 0, 2) },
    { FeatureType = "FEATURE_FLOODPLAINS", Name = "LOC_FEATURE_FLOODPLAINS", Settlement = true, Yields = Yields(1) },
  }, "FeatureType")
  gi.Feature_Removes = Table({
    { FeatureType = "FEATURE_FOREST", YieldType = "YIELD_PRODUCTION", Yield = 20 },
    { FeatureType = "FEATURE_JUNGLE", YieldType = "YIELD_PRODUCTION", Yield = 10 },
    { FeatureType = "FEATURE_JUNGLE", YieldType = "YIELD_FOOD", Yield = 10 },
    { FeatureType = "FEATURE_MARSH", YieldType = "YIELD_FOOD", Yield = 20 },
  })

  gi.Resources = Table({
    { ResourceType = "RESOURCE_WHEAT", Name = "LOC_RESOURCE_WHEAT", ResourceClassType = "RESOURCECLASS_BONUS", Happiness = 0, Yields = Yields(1) },
    { ResourceType = "RESOURCE_COPPER", Name = "LOC_RESOURCE_COPPER", ResourceClassType = "RESOURCECLASS_BONUS", Happiness = 0, Yields = Yields(0, 0, 2) },
    { ResourceType = "RESOURCE_STONE", Name = "LOC_RESOURCE_STONE", ResourceClassType = "RESOURCECLASS_BONUS", Happiness = 0, Yields = Yields(0, 1) },
    { ResourceType = "RESOURCE_WINE", Name = "LOC_RESOURCE_WINE", ResourceClassType = "RESOURCECLASS_LUXURY", Happiness = 4, Yields = Yields(1, 0, 1) },
    { ResourceType = "RESOURCE_SILK", Name = "LOC_RESOURCE_SILK", ResourceClassType = "RESOURCECLASS_LUXURY", Happiness = 4, Yields = Yields(0, 0, 0, 0, 1) },
    { ResourceType = "RESOURCE_IRON", Name = "LOC_RESOURCE_IRON", ResourceClassType = "RESOURCECLASS_STRATEGIC", Happiness = 0,
      PrereqTech = "TECH_BRONZE_WORKING", Yields = Yields(0, 0, 0, 1) },
    { ResourceType = "RESOURCE_HORSES", Name = "LOC_RESOURCE_HORSES", ResourceClassType = "RESOURCECLASS_STRATEGIC", Happiness = 0,
      Yields = Yields(1, 1) },
  }, "ResourceType")
  gi.Resource_Harvests = Table({
    { ResourceType = "RESOURCE_WHEAT", YieldType = "YIELD_FOOD", Amount = 20 },
    { ResourceType = "RESOURCE_COPPER", YieldType = "YIELD_GOLD", Amount = 40 },
    { ResourceType = "RESOURCE_STONE", YieldType = "YIELD_PRODUCTION", Amount = 20 },
  })
  gi.Resource_Consumption = Table({
    { ResourceType = "RESOURCE_IRON", ImprovedExtractionRate = 2 },
    { ResourceType = "RESOURCE_HORSES", ImprovedExtractionRate = 2 },
  }, "ResourceType")

  gi.Technologies = Table({ { TechnologyType = "TECH_BRONZE_WORKING", Name = "LOC_TECH_BRONZE_WORKING" } }, "TechnologyType")
  gi.Improvements = Table({ { ImprovementType = "IMPROVEMENT_FARM", Name = "LOC_IMPROVEMENT_FARM_NAME" } }, "ImprovementType")
  gi.Civics = Table({}, "CivicType")

  local function District(t, extra)
    local row = { DistrictType = t, Name = "LOC_" .. t .. "_NAME", OnePerCity = true, ReplacesCollection = {} }
    for k, v in pairs(extra or {}) do row[k] = v end
    return row
  end
  gi.Districts = Table({
    District("DISTRICT_CITY_CENTER", { CityCenter = true }),
    District("DISTRICT_CAMPUS", { RequiresPopulation = true }),
    District("DISTRICT_HOLY_SITE", { RequiresPopulation = true }),
    District("DISTRICT_THEATER", { RequiresPopulation = true }),
    District("DISTRICT_COMMERCIAL_HUB", { RequiresPopulation = true }),
    District("DISTRICT_INDUSTRIAL_ZONE", { RequiresPopulation = true }),
    District("DISTRICT_ENTERTAINMENT_COMPLEX", { RequiresPopulation = true }),
    District("DISTRICT_ENCAMPMENT", { RequiresPopulation = true, NoAdjacentCity = true }),
    District("DISTRICT_GOVERNMENT", { RequiresPopulation = true, MaxPerPlayer = 1 }),
    District("DISTRICT_AQUEDUCT", { Aqueduct = true }),
    District("DISTRICT_DAM", { OnePerCity = false }),
    District("DISTRICT_NEIGHBORHOOD", { OnePerCity = false }),
    District("DISTRICT_WONDER", { OnePerCity = false }),
    District("DISTRICT_ACROPOLIS", { RequiresPopulation = true, TraitType = "TRAIT_CIVILIZATION_DISTRICT_ACROPOLIS" }),
  }, "DistrictType")
  -- Gathering Storm's extra district columns and required features (the dam).
  gi.Districts_XP2 = Table({ { DistrictType = "DISTRICT_DAM", PreventsFloods = true, OnePerRiver = true } }, "DistrictType")
  gi.District_RequiredFeatures = Table({ { DistrictType = "DISTRICT_DAM", FeatureType = "FEATURE_FLOODPLAINS" } })
  gi.DistrictReplaces = Table({
    { CivUniqueDistrictType = "DISTRICT_ACROPOLIS", ReplacesDistrictType = "DISTRICT_THEATER" },
  }, "CivUniqueDistrictType")
  gi.Districts.DISTRICT_ACROPOLIS.ReplacesCollection = { gi.DistrictReplaces[0] }

  -- Adjacency rows, after the base game's (Adjacency_YieldChanges.xml).
  local adj, links = {}, {}
  local function Adj(district, id, yieldType, change, extra)
    local row = { ID = id, YieldType = yieldType, YieldChange = change, TilesRequired = 1, Description = "LOC_" .. id }
    for k, v in pairs(extra or {}) do row[k] = v end
    if adj[id] == nil then adj[id] = row end
    links[#links + 1] = { DistrictType = district, YieldChangeId = id }
  end
  local MOUNTAIN = { AdjacentTerrain = "TERRAIN_GRASS_MOUNTAIN" }
  local TWO_DISTRICTS = { OtherDistrictAdjacent = true, TilesRequired = 2 }
  Adj("DISTRICT_CAMPUS", "Mountains_Science1", "YIELD_SCIENCE", 1, MOUNTAIN)
  Adj("DISTRICT_CAMPUS", "Jungle_Science", "YIELD_SCIENCE", 1, { AdjacentFeature = "FEATURE_JUNGLE", TilesRequired = 2 })
  Adj("DISTRICT_CAMPUS", "District_Science", "YIELD_SCIENCE", 1, TWO_DISTRICTS)
  Adj("DISTRICT_CAMPUS", "Government_Science", "YIELD_SCIENCE", 1, { AdjacentDistrict = "DISTRICT_GOVERNMENT" })
  Adj("DISTRICT_HOLY_SITE", "Mountains_Faith1", "YIELD_FAITH", 1, MOUNTAIN)
  Adj("DISTRICT_HOLY_SITE", "Forest_Faith", "YIELD_FAITH", 1, { AdjacentFeature = "FEATURE_FOREST", TilesRequired = 2 })
  Adj("DISTRICT_HOLY_SITE", "NaturalWonder_Faith", "YIELD_FAITH", 2, { AdjacentNaturalWonder = true })
  Adj("DISTRICT_HOLY_SITE", "District_Faith", "YIELD_FAITH", 1, TWO_DISTRICTS)
  Adj("DISTRICT_HOLY_SITE", "Government_Faith", "YIELD_FAITH", 1, { AdjacentDistrict = "DISTRICT_GOVERNMENT" })
  for _, theater in ipairs({ "DISTRICT_THEATER", "DISTRICT_ACROPOLIS" }) do
    Adj(theater, "Wonder_Culture", "YIELD_CULTURE", 2, { AdjacentWonder = true })
    Adj(theater, "Entertainment_Culture", "YIELD_CULTURE", 2, { AdjacentDistrict = "DISTRICT_ENTERTAINMENT_COMPLEX" })
    Adj(theater, "Government_Culture", "YIELD_CULTURE", 1, { AdjacentDistrict = "DISTRICT_GOVERNMENT" })
  end
  Adj("DISTRICT_THEATER", "District_Culture", "YIELD_CULTURE", 1, TWO_DISTRICTS)
  Adj("DISTRICT_ACROPOLIS", "District_Culture_Acropolis", "YIELD_CULTURE", 1, { OtherDistrictAdjacent = true })
  Adj("DISTRICT_COMMERCIAL_HUB", "River_Gold", "YIELD_GOLD", 2, { AdjacentRiver = true })
  Adj("DISTRICT_COMMERCIAL_HUB", "District_Gold", "YIELD_GOLD", 1, TWO_DISTRICTS)
  Adj("DISTRICT_COMMERCIAL_HUB", "Government_Gold", "YIELD_GOLD", 1, { AdjacentDistrict = "DISTRICT_GOVERNMENT" })
  Adj("DISTRICT_INDUSTRIAL_ZONE", "Aqueduct_Production", "YIELD_PRODUCTION", 2, { AdjacentDistrict = "DISTRICT_AQUEDUCT" })
  Adj("DISTRICT_INDUSTRIAL_ZONE", "Dam_Production", "YIELD_PRODUCTION", 2, { AdjacentDistrict = "DISTRICT_DAM" })
  Adj("DISTRICT_INDUSTRIAL_ZONE", "District_Production", "YIELD_PRODUCTION", 1, TWO_DISTRICTS)
  Adj("DISTRICT_INDUSTRIAL_ZONE", "Government_Production", "YIELD_PRODUCTION", 1, { AdjacentDistrict = "DISTRICT_GOVERNMENT" })
  local adjRows = {}
  for _, link in ipairs(links) do
    if adj[link.YieldChangeId] ~= nil then
      adjRows[#adjRows + 1] = adj[link.YieldChangeId]
      adj[link.YieldChangeId] = nil
    end
  end
  gi.Adjacency_YieldChanges = Table(adjRows, "ID")
  gi.District_Adjacencies = Table(links)
  gi.ExcludedAdjacencies = Table({})

  gi.Buildings = Table({
    { BuildingType = "BUILDING_PYRAMIDS", Name = "LOC_BUILDING_PYRAMIDS_NAME", IsWonder = true, Cost = 220, ValidTerrain = "TERRAIN_DESERT" },
    { BuildingType = "BUILDING_HANGING_GARDENS", Name = "LOC_BUILDING_HANGING_GARDENS_NAME", IsWonder = true, Cost = 180, RequiresRiver = true },
    { BuildingType = "BUILDING_GREAT_LIBRARY", Name = "LOC_BUILDING_GREAT_LIBRARY_NAME", IsWonder = true, Cost = 400,
      AdjacentDistrict = "DISTRICT_CAMPUS" },
    { BuildingType = "BUILDING_COLOSSEUM", Name = "LOC_BUILDING_COLOSSEUM_NAME", IsWonder = true, Cost = 400,
      AdjacentDistrict = "DISTRICT_ENTERTAINMENT_COMPLEX", RegionalRange = 6 },
    { BuildingType = "BUILDING_STONEHENGE", Name = "LOC_BUILDING_STONEHENGE_NAME", IsWonder = true, Cost = 180, FlatOnly = true },
    { BuildingType = "BUILDING_LIBRARY", Name = "LOC_BUILDING_LIBRARY_NAME", Cost = 90, PrereqDistrict = "DISTRICT_CAMPUS" },
    -- Regional buildings (Buildings.RegionalRange), as in the base game; the
    -- last one is a made-up civilization building with a longer reach.
    { BuildingType = "BUILDING_FACTORY", Name = "LOC_BUILDING_FACTORY_NAME", Cost = 330,
      PrereqDistrict = "DISTRICT_INDUSTRIAL_ZONE", RegionalRange = 6 },
    { BuildingType = "BUILDING_ZOO", Name = "LOC_BUILDING_ZOO_NAME", Cost = 445,
      PrereqDistrict = "DISTRICT_ENTERTAINMENT_COMPLEX", RegionalRange = 6 },
    { BuildingType = "BUILDING_TEST_LONG_REACH", Name = "LOC_BUILDING_TEST_LONG_REACH_NAME", Cost = 330,
      PrereqDistrict = "DISTRICT_INDUSTRIAL_ZONE", RegionalRange = 9, TraitType = "TRAIT_CIVILIZATION_DISTRICT_ACROPOLIS" },
  }, "BuildingType")
  return gi
end

-- ===========================================================================
-- Hex geometry (odd-r offset coordinates)
-- ===========================================================================
local function ToCube(x, y)
  return x - (y - y % 2) / 2, y
end

local function FromCube(q, r)
  return q + (r - r % 2) / 2, r
end

local function Distance(x1, y1, x2, y2)
  local q1, r1 = ToCube(x1, y1)
  local q2, r2 = ToCube(x2, y2)
  local dq, dr = q1 - q2, r1 - r2
  return (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
end

-- Directions in cube steps, clockwise from north-east.
local DIRECTIONS = { { 1, -1 }, { 1, 0 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { 0, -1 } }

-- ===========================================================================
-- Event objects (Events.X / LuaEvents.X)
-- ===========================================================================
local function EventTable()
  return setmetatable({}, {
    __index = function(t, name)
      local handlers = {}
      local event = setmetatable({
        Add = function(fn) handlers[#handlers + 1] = fn end,
        Remove = function(fn)
          for i = #handlers, 1, -1 do
            if handlers[i] == fn then table.remove(handlers, i) end
          end
        end,
        Count = function() return #handlers end,
      }, {
        __call = function(_, ...)
          for _, fn in ipairs(handlers) do fn(...) end
        end,
      })
      rawset(t, name, event)
      return event
    end,
  })
end

-- ===========================================================================
-- World
-- ===========================================================================
local TERRAIN_CHARS = {
  ["."] = { "TERRAIN_GRASS" }, h = { "TERRAIN_GRASS_HILLS" }, p = { "TERRAIN_PLAINS" }, q = { "TERRAIN_PLAINS_HILLS" },
  d = { "TERRAIN_DESERT" }, M = { "TERRAIN_GRASS_MOUNTAIN" }, ["~"] = { "TERRAIN_COAST" }, o = { "TERRAIN_OCEAN" },
  f = { "TERRAIN_GRASS", "FEATURE_FOREST" }, j = { "TERRAIN_PLAINS", "FEATURE_JUNGLE" }, s = { "TERRAIN_GRASS", "FEATURE_MARSH" },
  O = { "TERRAIN_DESERT", "FEATURE_OASIS" }, N = { "TERRAIN_GRASS", "FEATURE_NW_TEST" },
  F = { "TERRAIN_DESERT", "FEATURE_FLOODPLAINS" },
}

local function XY(spec)
  if type(spec) == "string" then
    local x, y = spec:match("^(%-?%d+),(%-?%d+)$")
    return tonumber(x), tonumber(y)
  end
  return spec[1] or spec.x, spec[2] or spec.y
end

function World.New(spec)
  local w = { Calls = { GetBonusYields = 0, CanPlacePin = 0, ClearCache = 0 }, Turn = spec.turn or 1, Time = 0 }
  local gi = BuildGameInfo()
  w.GameInfo = gi
  local rows = spec.rows
  local height, width = #rows, #rows[1]
  w.Width, w.Height = width, height

  -- Plots ------------------------------------------------------------------
  local plots, byIndex = {}, {}
  local Plot = {}
  Plot.__index = Plot
  for y = 0, height - 1 do
    local row = rows[y + 1]
    for x = 0, width - 1 do
      local def = TERRAIN_CHARS[row:sub(x + 1, x + 1)]
      if def == nil then error("world: unknown map character at " .. x .. "," .. y) end
      local plot = setmetatable({
        x = x, y = y, index = y * width + x,
        terrain = gi.Terrains[def[1]], feature = def[2] and gi.Features[def[2]] or nil,
        owner = -1, city = nil, district = -1, wonder = -1, river = false, lake = false,
        resource = nil, resourceCount = 0, revealed = true, appeal = 0,
      }, Plot)
      plots[x .. "," .. y] = plot
      byIndex[plot.index] = plot
    end
  end
  w.Plots = byIndex

  local function GetPlot(x, y)
    if x == nil or y == nil or x < 0 or y < 0 or x >= width or y >= height then return nil end
    return byIndex[y * width + x]
  end
  function w:Plot(x, y) return GetPlot(x, y) end

  local function Adjacent(x, y, direction)
    local q, r = ToCube(x, y)
    local d = DIRECTIONS[direction + 1]
    local nx, ny = FromCube(q + d[1], r + d[2])
    return GetPlot(nx, ny)
  end

  function Plot:GetX() return self.x end
  function Plot:GetY() return self.y end
  function Plot:GetIndex() return self.index end
  function Plot:IsCity() return self.isCity == true end
  function Plot:GetDistrictType() return self.district end
  function Plot:GetWonderType() return self.wonder end
  function Plot:IsNaturalWonder() return self.feature ~= nil and self.feature.NaturalWonder == true end
  function Plot:GetOwner() return self.owner end
  function Plot:IsOwned() return self.owner ~= -1 end
  function Plot:GetFeatureType() return self.feature and self.feature.Index or -1 end
  function Plot:GetTerrainType() return self.terrain.Index end
  function Plot:GetResourceType() return self.resource and self.resource.Index or -1 end
  function Plot:GetResourceCount() return self.resource and self.resourceCount or 0 end
  function Plot:IsRiver() return self.river end
  function Plot:IsLake() return self.lake end
  function Plot:IsWater() return self.terrain.Water == true end
  function Plot:IsMountain() return self.terrain.Mountain == true end
  function Plot:IsHills() return self.terrain.Hills == true end
  function Plot:IsImpassable() return self.terrain.Impassable == true or (self.feature ~= nil and self.feature.Impassable == true) end
  function Plot:GetAppeal() return self.appeal end
  function Plot:IsCoastalLand()
    if self:IsWater() then return false end
    for dir = 0, 5 do
      local n = Adjacent(self.x, self.y, dir)
      if n ~= nil and n.terrain.TerrainType == "TERRAIN_COAST" then return true end
    end
    return false
  end
  function Plot:IsFreshWater()
    if self.river then return true end
    for dir = 0, 5 do
      local n = Adjacent(self.x, self.y, dir)
      if n ~= nil and (n.lake or n.river or (n.feature ~= nil and n.feature.AddsFreshWater)) then return true end
    end
    return false
  end
  function Plot:IsRiverCrossingToPlot(other) return self.river and other.river end
  function Plot:GetYield(yieldIndex)
    local yieldType = gi.Yields[yieldIndex].YieldType
    if self.isCity or self.district ~= -1 then return 0 end
    local total = self.terrain.Yields[yieldType]
    if self.feature ~= nil then total = total + self.feature.Yields[yieldType] end
    if self.resource ~= nil then total = total + self.resource.Yields[yieldType] end
    return total
  end

  for _, s in ipairs(spec.rivers or {}) do GetPlot(XY(s)).river = true end
  for _, s in ipairs(spec.lakes or {}) do GetPlot(XY(s)).lake = true end
  for _, r in ipairs(spec.resources or {}) do
    local plot = GetPlot(r[1], r[2])
    plot.resource = gi.Resources[r[3]]
    plot.resourceCount = r[4] or 1
  end
  for _, s in ipairs(spec.unrevealed or {}) do GetPlot(XY(s)).revealed = false end
  for _, a in ipairs(spec.appeal or {}) do GetPlot(a[1], a[2]).appeal = a[3] end

  -- Players, cities, districts --------------------------------------------
  local players, cities, cityList = {}, {}, {}
  local function NewPlayer(id)
    local p = { id = id, cities = {}, techs = {}, resources = {} }
    players[id] = p
    return p
  end
  NewPlayer(0)
  NewPlayer(1)
  NewPlayer(62) -- a city-state
  for _, t in ipairs(spec.techs or {}) do players[0].techs[gi.Technologies[t].Index] = true end
  for r, amount in pairs(spec.playerResources or {}) do players[0].resources[gi.Resources[r].Index] = amount end

  local City = {}
  City.__index = City
  function City:GetID() return self.id end
  function City:GetOwner() return self.owner end
  function City:GetX() return self.x end
  function City:GetY() return self.y end
  function City:GetName() return self.name end
  function City:GetPopulation() return self.population end
  function City:IsCapital() return self.capital == true end
  function City:GetBuildings()
    local built = self.buildings
    return { HasBuilding = function(_, index) return built[index] == true end }
  end
  function City:GetDistricts()
    local list = self.districts
    return { Members = function() return ipairs(list) end }
  end
  -- Housing from water as the game counts it: river, lake or oasis next to
  -- the center 5, coast 3, else 2.
  function City:GetGrowth()
    local center = GetPlot(self.x, self.y)
    return {
      GetHousingFromWater = function()
        if center.river then return 5 end
        local coast = false
        for dir = 0, 5 do
          local n = Adjacent(self.x, self.y, dir)
          if n ~= nil then
            if n.lake or (n.feature ~= nil and n.feature.AddsFreshWater) then return 5 end
            if n.terrain.Water then coast = true end
          end
        end
        return coast and 3 or 2
      end,
    }
  end

  local District = {}
  District.__index = District
  function District:GetType() return self.type end
  function District:GetX() return self.x end
  function District:GetY() return self.y end
  function District:IsComplete() return self.complete end

  local function AddDistrict(city, districtType, x, y, complete)
    local plot = GetPlot(x, y)
    local d = setmetatable({ type = gi.Districts[districtType].Index, x = x, y = y, complete = complete ~= false }, District)
    plot.district = d.type
    city.districts[#city.districts + 1] = d
    return d
  end

  function w:Own(x, y, owner, city)
    local plot = GetPlot(x, y)
    plot.owner, plot.city = owner, city
  end

  function w:AddCity(c)
    local owner = c.owner or 0
    local city = setmetatable({
      id = c.id, owner = owner, x = c.x, y = c.y, name = c.name or ("CITY_" .. c.id),
      population = c.population or 1, capital = c.capital, districts = {}, buildings = {},
    }, City)
    cities[owner .. ":" .. c.id] = city
    cityList[#cityList + 1] = city
    local list = players[owner].cities
    list[#list + 1] = city
    local plot = GetPlot(c.x, c.y)
    plot.isCity = true
    AddDistrict(city, "DISTRICT_CITY_CENTER", c.x, c.y, true)
    for _, p in pairs(byIndex) do
      if Distance(c.x, c.y, p.x, p.y) <= (c.radius or 1) and p.owner == -1 then w:Own(p.x, p.y, owner, city) end
    end
    return city
  end
  for _, c in ipairs(spec.cities or {}) do w:AddCity(c) end
  for _, o in ipairs(spec.owned or {}) do
    w:Own(o[1], o[2], o[3], o[4] and cities[o[3] .. ":" .. o[4]] or nil)
  end
  for _, d in ipairs(spec.districts or {}) do
    AddDistrict(cities[(d.owner or 0) .. ":" .. d.city], d.type, d.x, d.y, d.complete)
  end
  for _, b in ipairs(spec.wonders or {}) do
    GetPlot(b[1], b[2]).wonder = gi.Buildings[b[3]].Index
  end
  function w:City(id, owner) return cities[(owner or 0) .. ":" .. id] end
  function w:AddBuilding(cityID, buildingType, owner)
    cities[(owner or 0) .. ":" .. cityID].buildings[gi.Buildings[buildingType].Index] = true
  end
  function w:AddDistrict(cityID, districtType, x, y, complete, owner)
    return AddDistrict(cities[(owner or 0) .. ":" .. cityID], districtType, x, y, complete)
  end

  -- Map pins and DMT's pin subject store ----------------------------------
  local pinLists, nextPinID, subjects = { [0] = {}, [1] = {} }, 1, { [0] = {}, [1] = {} }
  local Pin = {}
  Pin.__index = Pin
  function Pin:GetID() return self.id end
  function Pin:GetHexX() return self.x end
  function Pin:GetHexY() return self.y end
  function Pin:GetIconName() return self.icon end
  function Pin:GetName() return self.name end
  function Pin:SetName(name) self.name = name end
  function Pin:SetIconName(icon) self.icon = icon end

  local function Key(x, y) return x .. "_" .. y end

  local function CreateSubject(pin)
    local iconType = pin:GetIconName():gsub("ICON_", "")
    local subject = { Id = pin:GetID(), X = pin:GetHexX(), Y = pin:GetHexY(), Key = iconType, Type = "UNKNOWN" }
    if iconType:match("^IMPROVEMENT_") then
      subject.Type = "IMPROVEMENT"
    elseif iconType:match("^DISTRICT_") then
      subject.Type = iconType == "DISTRICT_WONDER" and "WONDER" or "DISTRICT"
    elseif iconType:match("^BUILDING_") then
      subject.Type = "WONDER"
    elseif iconType == "MAP_PIN_DISTRICT" then
      subject.Type = "DISTRICT"
    end
    return subject
  end

  local Config = {}
  Config.__index = Config
  function Config:GetMapPins() return self.pins end
  function Config:GetMapPinID(id)
    for _, pin in ipairs(self.pins) do
      if pin.id == id then return pin end
    end
    return nil
  end
  function Config:GetMapPin(x, y)
    for _, pin in ipairs(self.pins) do
      if pin.x == x and pin.y == y then return pin end
    end
    local pin = setmetatable({ id = nextPinID, x = x, y = y, icon = "ICON_MAP_PIN_SQUARE", name = "" }, Pin)
    nextPinID = nextPinID + 1
    self.pins[#self.pins + 1] = pin
    return pin
  end
  -- Values saved with the game (SDP_Pins keeps its record here).
  function Config:GetValue(key) return self.values and self.values[key] end
  function Config:SetValue(key, value)
    self.values = self.values or {}
    self.values[key] = value
  end
  function Config:DeleteMapPin(id)
    for i, pin in ipairs(self.pins) do
      if pin.id == id then
        table.remove(self.pins, i)
        return
      end
    end
  end
  local configs = {}
  for pid, list in pairs(pinLists) do configs[pid] = setmetatable({ pins = list, pid = pid }, Config) end

  -- Adds a pin as the DMT popup does: the pin plus its subject.
  function w:AddPin(x, y, icon, name, pid)
    pid = pid or 0
    local pin = configs[pid]:GetMapPin(x, y)
    pin:SetIconName(icon)
    pin:SetName(name or "")
    subjects[pid][Key(x, y)] = CreateSubject(pin)
    return pin
  end
  function w:Pins(pid) return pinLists[pid or 0] end
  for _, p in ipairs(spec.pins or {}) do w:AddPin(p[1], p[2], p[3], p[4]) end

  -- The simplified DMT -----------------------------------------------------
  -- What DMT sees on a plot: the planned subject there, else the real map.
  local function Realized(pid, plot)
    local subject = GetMapPinSubject(pid, plot.x, plot.y) -- the global: SDP_Overlay replaces it
    local f = { terrain = plot.terrain.TerrainType, plot = plot }
    if plot.isCity then f.district = "DISTRICT_CITY_CENTER"
    elseif plot.district ~= -1 then f.district = gi.Districts[plot.district].DistrictType
    elseif plot.wonder ~= -1 then f.wonder = gi.Buildings[plot.wonder].BuildingType
    elseif subject ~= nil and subject.Type == "DISTRICT" then f.district = subject.Key
    elseif subject ~= nil and subject.Type == "WONDER" then f.wonder = subject.Key
    end
    if plot.feature ~= nil and plot.feature.NaturalWonder then f.naturalWonder = plot.feature.FeatureType
    elseif plot.feature ~= nil and f.district == nil and f.wonder == nil then f.feature = plot.feature.FeatureType
    end
    if plot.resource ~= nil and f.district == nil and f.wonder == nil then f.resource = plot.resource end
    return f
  end

  local function Neighbours(x, y)
    local list = {}
    for dir = 0, 5 do
      local n = Adjacent(x, y, dir)
      if n ~= nil then list[#list + 1] = n end
    end
    return list
  end

  local function AdjacentTo(pid, x, y, districtType)
    for _, n in ipairs(Neighbours(x, y)) do
      local d = Realized(pid, n).district
      if d ~= nil and gi.DistrictReplaces[d] then d = gi.DistrictReplaces[d].ReplacesDistrictType end
      if d == districtType and not (n.owner ~= -1 and n.owner ~= pid) then return true end
    end
    return false
  end

  local function CanPlace(pid, subject)
    w.Calls.CanPlacePin = w.Calls.CanPlacePin + 1
    if subject.Type ~= "DISTRICT" and subject.Type ~= "WONDER" then return true, "" end
    local plot = GetPlot(subject.X, subject.Y)
    if plot == nil then return false, "off map" end
    local f = Realized(pid, plot)
    if f.naturalWonder then return false, "natural wonder" end
    if plot.terrain.Water or plot.terrain.Mountain then return false, "terrain" end
    if plot.feature ~= nil and not plot.feature.Removable and not plot.feature.NaturalWonder
        and plot.feature.FeatureType ~= "FEATURE_FLOODPLAINS" then return false, "feature" end
    if f.resource ~= nil and f.resource.ResourceClassType ~= "RESOURCECLASS_BONUS"
        and gi.Districts[subject.Key] ~= nil and not gi.Districts[subject.Key].CityCenter then
      return false, "resource"
    end
    if subject.Type == "DISTRICT" then
      if f.wonder ~= nil then return false, "wonder" end
      if f.district ~= nil and f.district ~= subject.Key then return false, "district" end
      local row = gi.Districts[subject.Key]
      if row.CityCenter then
        for _, p in pairs(byIndex) do
          if Distance(p.x, p.y, plot.x, plot.y) <= 3 and p ~= plot and Realized(pid, p).district == "DISTRICT_CITY_CENTER" then
            return false, "too close to a city"
          end
        end
      end
      if row.NoAdjacentCity and AdjacentTo(pid, plot.x, plot.y, "DISTRICT_CITY_CENTER") then return false, "next to a city" end
      if subject.Key == "DISTRICT_DAM" and not (plot.river and plot.feature ~= nil
          and plot.feature.FeatureType == "FEATURE_FLOODPLAINS") then
        return false, "dam"
      end
      if row.Aqueduct then
        local ok = false
        if AdjacentTo(pid, plot.x, plot.y, "DISTRICT_CITY_CENTER") then
          for _, n in ipairs(Neighbours(plot.x, plot.y)) do
            if n.terrain.Mountain or n.lake or (n.river and plot.river) or (n.feature ~= nil and n.feature.FeatureType == "FEATURE_OASIS") then ok = true end
          end
        end
        if not ok then return false, "aqueduct" end
      end
    else
      if f.district ~= nil then return false, "district" end
      if f.wonder ~= nil and f.wonder ~= subject.Key then return false, "wonder" end
      local row = gi.Buildings[subject.Key]
      if row.ValidTerrain and plot.terrain.TerrainType ~= row.ValidTerrain then return false, "terrain" end
      if row.FlatOnly and plot.terrain.Hills then return false, "hills" end
      if row.RequiresRiver and not plot.river then return false, "river" end
      if row.AdjacentDistrict and not AdjacentTo(pid, plot.x, plot.y, row.AdjacentDistrict) then return false, "adjacent district" end
    end
    return true, ""
  end

  local function BonusYields(pid, subject)
    w.Calls.GetBonusYields = w.Calls.GetBonusYields + 1
    local yields, tips = {}, {}
    if subject.Type ~= "DISTRICT" then return yields, "" end
    local plot = GetPlot(subject.X, subject.Y)
    local around = {}
    for _, n in ipairs(Neighbours(subject.X, subject.Y)) do
      around[#around + 1] = GetRealizedPlotFeatures(pid, n, GetMapPinSubject(pid, n.x, n.y)) -- the global, as DMT
    end
    for link in gi.District_Adjacencies() do
      if link.DistrictType == subject.Key then
        local row = gi.Adjacency_YieldChanges[link.YieldChangeId]
        local count = 0
        if row.AdjacentRiver then
          count = plot.river and 1 or 0
        else
          for _, f in ipairs(around) do
            if (row.AdjacentTerrain and f.terrain == row.AdjacentTerrain)
                or (row.AdjacentFeature and f.feature == row.AdjacentFeature)
                or (row.OtherDistrictAdjacent and f.district ~= nil)
                or (row.AdjacentDistrict and f.district == row.AdjacentDistrict)
                or (row.AdjacentWonder and f.wonder ~= nil)
                or (row.AdjacentNaturalWonder and f.naturalWonder ~= nil) then
              count = count + 1
            end
          end
        end
        local amount = math.floor(count / row.TilesRequired) * row.YieldChange
        if amount ~= 0 then
          yields[row.YieldType] = (yields[row.YieldType] or 0) + amount
          tips[#tips + 1] = row.ID .. " " .. amount
        end
      end
    end
    return yields, table.concat(tips, "[NEWLINE]")
  end

  -- Globals ---------------------------------------------------------------
  local Map = {
    GetPlot = GetPlot,
    GetPlotByIndex = function(i) return byIndex[i] end,
    GetPlotIndex = function(x, y) return y * width + x end,
    GetPlotDistance = Distance,
    GetGridSize = function() return width, height end,
    GetPlotCount = function() return width * height end,
    GetAdjacentPlot = function(x, y, direction) return Adjacent(x, y, direction) end,
    GetAdjacentPlots = function(x, y)
      local list = {}
      for dir = 0, 5 do list[dir + 1] = Adjacent(x, y, dir) end
      return list
    end,
    GetPlotXYWithRangeCheck = function(x, y, dx, dy, range)
      local q, r = ToCube(x, y)
      local nx, ny = FromCube(q + dx, r + dy)
      if Distance(x, y, nx, ny) > range then return nil end
      return GetPlot(nx, ny)
    end,
  }

  local Player = {}
  Player.__index = Player
  local playerObjects = {}
  for id, p in pairs(players) do
    playerObjects[id] = setmetatable({
      GetID = function() return id end,
      IsMajor = function() return id < 62 end,
      GetCities = function()
        return {
          Members = function() return ipairs(p.cities) end,
          GetCapitalCity = function()
            for _, c in ipairs(p.cities) do
              if c.capital then return c end
            end
            return nil
          end,
          GetCount = function() return #p.cities end,
        }
      end,
      GetDistricts = function()
        local all = {}
        for _, c in ipairs(p.cities) do
          for _, d in ipairs(c.districts) do all[#all + 1] = d end
        end
        return { Members = function() return ipairs(all) end }
      end,
      GetTechs = function() return { HasTech = function(_, i) return p.techs[i] == true end } end,
      GetCulture = function() return { HasCivic = function() return false end } end,
      GetResources = function()
        return {
          GetResourceAmount = function(_, i) return p.resources[i] or 0 end,
          IsResourceVisible = function(_, hashOrIndex)
            local row = gi.Resources[hashOrIndex]
            return row == nil or row.PrereqTech == nil or p.techs[gi.Technologies[row.PrereqTech].Index] == true
          end,
        }
      end,
    }, Player)
  end

  local traits = {}
  for _, t in ipairs(spec.traits or {}) do traits[t] = true end

  local Events, LuaEvents = EventTable(), EventTable()
  LuaEvents.DMT_MapPinAdded.Add(function(pin) subjects[0][Key(pin:GetHexX(), pin:GetHexY())] = CreateSubject(pin) end)
  LuaEvents.DMT_MapPinRemoved.Add(function(pin) subjects[0][Key(pin:GetHexX(), pin:GetHexY())] = nil end)
  w.Events, w.LuaEvents = Events, LuaEvents

  local sounds = {}
  w.Sounds = sounds
  local function Noop() end

  sdp_install_globals({
    Map = Map,
    GameInfo = gi,
    GlobalParameters = { CITY_MIN_RANGE = spec.cityMinRange or 3, CITY_POPULATION_RIVER_LAKE = 5,
      CITY_POPULATION_COAST = 3, CITY_POPULATION_NO_WATER = 2 },
    DirectionTypes = { NUM_DIRECTION_TYPES = 6 },
    Players = playerObjects,
    PlayerConfigurations = configs,
    PlayersVisibility = {
      [0] = { IsRevealed = function(_, i) return byIndex[i] ~= nil and byIndex[i].revealed end },
      [1] = { IsRevealed = function() return true end },
    },
    CityManager = {
      GetCity = function(pid, id) return cities[pid .. ":" .. id] end,
      -- The game's build targets: spec.engine = { [DistrictType] = { "x,y", ... } }
      -- (plots the engine allows); other districts give an empty result, as
      -- a locked district does in the game.
      GetOperationTargets = function(city, _, params)
        local row = gi.Districts[params[CityOperationTypes.PARAM_DISTRICT_TYPE]]
        local allowed = row and spec.engine and spec.engine[row.DistrictType]
        if allowed == nil then return {} end
        local plots = {}
        for _, key in ipairs(allowed) do
          local x, y = key:match("^(%d+),(%d+)$")
          plots[#plots + 1] = Map.GetPlotIndex(tonumber(x), tonumber(y))
        end
        return { [CityOperationResults.PLOTS] = plots }
      end,
    },
    CityOperationTypes = { BUILD = "BUILD", PARAM_DISTRICT_TYPE = "PARAM_DISTRICT_TYPE" },
    CityOperationResults = { PLOTS = "PLOTS" },
    Cities = {
      GetPlotPurchaseCity = function(plot) return plot.city end,
      GetCityInPlot = function(x, y)
        for _, c in ipairs(cityList) do
          if c.x == x and c.y == y then return c end
        end
        return nil
      end,
    },
    Game = {
      GetLocalPlayer = function() return 0 end,
      GetCurrentGameTurn = function() return w.Turn end,
    },
    GameConfiguration = { GetRuleSet = function() return spec.ruleset or "RULESET_EXPANSION_2" end },
    Locale = {
      Lookup = function(key, ...)
        local args = { ... }
        if #args == 0 then return tostring(key) end
        for i, a in ipairs(args) do args[i] = tostring(a) end
        return tostring(key) .. "(" .. table.concat(args, ",") .. ")"
      end,
      Compare = function(a, b)
        if a == b then return 0 end
        return a < b and -1 or 1
      end,
    },
    UI = {
      GetElapsedTime = function() return w.Time end,
      PlaySound = function(name) sounds[#sounds + 1] = name end,
    },
    Network = { BroadcastPlayerInfo = Noop },
    Events = Events,
    LuaEvents = LuaEvents,
    MapTacks = {
      PlayerTraits = function() local copy = {} for k, v in pairs(traits) do copy[k] = v end return copy end,
      PlayerDistricts = function(t)
        local skip = {}
        for row in gi.Districts() do
          if row.DistrictType == "DISTRICT_WONDER" then skip[row.DistrictType] = true
          elseif row.TraitType and t[row.TraitType] then
            for _, swap in ipairs(row.ReplacesCollection) do skip[swap.ReplacesDistrictType] = true end
          elseif row.TraitType then skip[row.DistrictType] = true
          end
        end
        local list = {}
        for row in gi.Districts() do
          if not skip[row.DistrictType] then list[#list + 1] = row end
        end
        return list
      end,
      PlayerWonders = function()
        local list = {}
        for row in gi.Buildings() do
          if row.IsWonder then list[#list + 1] = row end
        end
        list[#list + 1] = gi.Districts.DISTRICT_WONDER
        return list
      end,
    },
    -- DMT
    GetMapPinSubjectCacheKey = Key,
    GetMapPinSubject = function(pid, x, y) return (subjects[pid] or {})[Key(x, y)] end,
    UpdateMapPinSubject = function(pid, x, y, subject) subjects[pid][Key(x, y)] = subject end,
    LoadMapPinSubjectTable = function(pid)
      local copy = {}
      for k, v in pairs(subjects[pid] or {}) do copy[k] = v end
      return copy
    end,
    CreateMapPinSubject = CreateSubject,
    -- DMT reads a plot's features for its neighbours' adjacency here; the
    -- feature sits under AdjacencyBonusTypes.ADJACENCY_FEATURE ("feature").
    GetRealizedPlotFeatures = function(pid, plot) return Realized(pid, plot) end,
    AdjacencyBonusTypes = { ADJACENCY_FEATURE = "feature", ADJACENCY_DISTRICT = "district", ADJACENCY_TERRAIN = "terrain" },
    UpdatePinYields = function() w.Calls.ClearCache = w.Calls.ClearCache + 1 end,
    CanPlacePin = CanPlace,
    GetBonusYields = BonusYields,
    OnMapPinAdded = Noop, OnMapPinRemoved = Noop, OnBuildingAdded = Noop, OnDistrictAdded = Noop,
    OnDistrictChanged = Noop, OnFeatureRemovedFromMap = Noop, OnImprovementChanged = Noop,
    OnImprovementAdded = Noop, OnImprovementRemoved = Noop, OnPlotVisibilityChanged = Noop,
    OnLoadGameViewStateDone = Noop, OnLocalPlayerTurnBegin = Noop,
  })

  function w:ResetCalls()
    self.Calls.GetBonusYields, self.Calls.CanPlacePin, self.Calls.ClearCache = 0, 0, 0
  end
  -- DMT calls so far, weighted as the cost measure of the benchmarks.
  function w:Cost()
    return self.Calls.GetBonusYields + self.Calls.CanPlacePin
  end
  return w
end

-- ===========================================================================
-- Deterministic random maps for benchmarks (no math.random: constraint 6)
-- ===========================================================================
function World.Rng(seed)
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function(n)
    state = (state * 48271) % 2147483647
    if n == nil then return state / 2147483647 end
    return state % n + 1
  end
end

-- A width x height land map with mountains, woods, rainforest, marsh,
-- hills, some coast at the edges, rivers and resources. Returns a spec for
-- World.New (without cities).
function World.RandomSpec(seed, width, height)
  local rng = World.Rng(seed)
  local rows = {}
  for y = 0, height - 1 do
    local chars = {}
    for x = 0, width - 1 do
      local c
      if x == 0 or y == 0 or x == width - 1 or y == height - 1 then
        c = rng() < 0.6 and "~" or "."
      else
        local roll = rng()
        if roll < 0.08 then c = "M"
        elseif roll < 0.22 then c = "f"
        elseif roll < 0.29 then c = "j"
        elseif roll < 0.32 then c = "s"
        elseif roll < 0.44 then c = "h"
        elseif roll < 0.50 then c = "q"
        elseif roll < 0.55 then c = "d"
        elseif roll < 0.70 then c = "p"
        else c = "." end
      end
      chars[#chars + 1] = c
    end
    rows[#rows + 1] = table.concat(chars)
  end
  local spec = { rows = rows, rivers = {}, resources = {} }
  -- A few rivers: random walks.
  for _ = 1, math.max(1, math.floor(width * height / 120)) do
    local x, y = rng(width - 2), rng(height - 2)
    for _ = 1, 8 do
      spec.rivers[#spec.rivers + 1] = x .. "," .. y
      local step = rng(4)
      if step == 1 then x = x + 1 elseif step == 2 then x = x - 1 elseif step == 3 then y = y + 1 else y = y - 1 end
      x = math.max(1, math.min(width - 2, x))
      y = math.max(1, math.min(height - 2, y))
    end
  end
  local kinds = { "RESOURCE_WHEAT", "RESOURCE_COPPER", "RESOURCE_STONE", "RESOURCE_WINE", "RESOURCE_SILK", "RESOURCE_IRON", "RESOURCE_HORSES" }
  for y = 1, height - 2 do
    for x = 1, width - 2 do
      local c = rows[y + 1]:sub(x + 1, x + 1)
      if c ~= "M" and c ~= "~" and rng() < 0.08 then
        spec.resources[#spec.resources + 1] = { x, y, kinds[rng(#kinds)], 1 }
      end
    end
  end
  return spec
end

return World
