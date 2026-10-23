-- cmp_game.lua: an emulated Civilization VI for the offline planner comparison.
--
-- Unlike tests/offline/world.lua (a toy rule set), this world runs on the
-- game's real rules: GameInfo is built from the exported gameplay database
-- (tests/compare/export_gameinfo.py), and the planners use the real Detailed
-- Map Tacks code for legality and adjacency. What is emulated is the engine:
-- the map, players, cities, pins, visibility, rivers and the modifier system
-- (GameEffects) that DMT reads trait adjacencies from.
--
-- CmpGame.New(spec) installs the globals every planner reads. spec comes from
-- cmp_mapgen.lua; each planner state builds its own copy from the same
-- scenario, so they all see the same game.
--
-- Unknown methods on game objects return nil and are recorded in
-- CmpGame.Missing, so gaps in the emulation show up in the run log.

CmpGame = {}
CmpGame.Missing = {}

local function Missing(kind, name)
  local key = kind .. ":" .. tostring(name)
  if not CmpGame.Missing[key] then
    CmpGame.Missing[key] = true
    print("cmp_game: missing " .. key)
  end
end

-- Objects whose unknown methods are recorded rather than fatal.
local function Class(kind)
  local class = {}
  class.__index = function(_, name)
    local v = rawget(class, name)
    if v == false then return nil end
    if v ~= nil then return v end
    -- Game methods are capitalized; lowercase names are this file's fields.
    if type(name) ~= "string" or not name:sub(1, 1):match("%u") then return nil end
    Missing(kind, name)
    return function() return nil end
  end
  return class
end

-- A stand-in for UI objects (Controls, ContextPtr, instances): any field is
-- another stub and any call returns a stub, so UI code runs and does nothing.
local Stub
Stub = setmetatable({}, {
  __index = function() return Stub end,
  __call = function() return Stub end,
  __newindex = function() end,
  __tostring = function() return "Stub" end,
  __len = function() return 0 end,
  __concat = function(a, b) return tostring(a) .. tostring(b) end,
})
CmpGame.Stub = Stub

-- ===========================================================================
-- GameInfo
-- ===========================================================================
local COLLECTIONS = {
  Districts = { ReplacesCollection = { "DistrictReplaces", "CivUniqueDistrictType", "DistrictType" } },
  Leaders = {
    TraitCollection = { "LeaderTraits", "LeaderType", "LeaderType" },
    CivilizationCollection = { "CivilizationLeaders", "LeaderType", "LeaderType", "Civilizations", "CivilizationType" },
  },
  Civilizations = { TraitCollection = { "CivilizationTraits", "CivilizationType", "CivilizationType" } },
  Resources = { Harvests = { "Resource_Harvests", "ResourceType", "ResourceType" } },
  Routes = { ValidBuildUnits = { "Route_ValidBuildUnits", "RouteType", "RouteType" } },
  Improvements = { ValidBuildUnits = { "Improvement_ValidBuildUnits", "ImprovementType", "ImprovementType" } },
}

local function TypeHash(s)
  local h = 5381.0
  for i = 1, #s do h = (h * 33.0 + s:byte(i)) % 1073741789.0 end
  return math.floor(h) + 1073741824
end
CmpGame.TypeHash = TypeHash

local g_GameInfo = nil

function CmpGame.LoadGameInfo()
  if g_GameInfo ~= nil then return g_GameInfo end
  local source = cmp_read_file(CMP_GAMEINFO)
  if source == nil then error("no " .. tostring(CMP_GAMEINFO) .. ": run tests/compare/export_gameinfo.py") end
  local data = assert(load(source, "@gameinfo"))()
  local gi = {}
  local byChild = {} -- [table][column][value] = { rows }
  local function ChildIndex(tableName, column)
    byChild[tableName] = byChild[tableName] or {}
    local idx = byChild[tableName][column]
    if idx == nil then
      idx = {}
      local def = data[tableName]
      for _, row in ipairs(def and def.rows or {}) do
        local v = row[column]
        if v ~= nil then
          idx[v] = idx[v] or {}
          table.insert(idx[v], row)
        end
      end
      byChild[tableName][column] = idx
    end
    return idx
  end
  for name, def in pairs(data) do
    local rows = def.rows
    local t = {}
    local colls = COLLECTIONS[name]
    local rowMeta = nil
    if colls ~= nil then
      rowMeta = {
        __index = function(row, key)
          local c = colls[key]
          if c == nil then return nil end
          local list = {}
          local children = ChildIndex(c[1], c[2])[rawget(row, c[3])] or {}
          for _, child in ipairs(children) do
            if c[4] then
              local target = gi[c[4]][child[c[5]]]
              if target then list[#list + 1] = target end
            else
              list[#list + 1] = child
            end
          end
          rawset(row, key, list)
          return list
        end,
      }
    end
    for i, row in ipairs(rows) do
      row.Index = i - 1
      t[i - 1] = row
      if def.pk ~= nil then
        local key = row[def.pk]
        if type(key) == "string" then
          t[key] = row
          row.Hash = TypeHash(key)
          t[row.Hash] = row
        end
      end
      if rowMeta then setmetatable(row, rowMeta) end
    end
    setmetatable(t, {
      __call = function(_, filter)
        local i = 0
        return function()
          while true do
            i = i + 1
            local row = rows[i]
            if row == nil then return nil end
            local ok = true
            if type(filter) == "table" then
              for k, v in pairs(filter) do
                if row[k] ~= v then ok = false break end
              end
            end
            if ok then return row end
          end
        end
      end,
    })
    gi[name] = t
  end
  -- Tables a planner may ask for that this ruleset lacks: empty, iterable.
  setmetatable(gi, {
    __index = function(_, name)
      return nil
    end,
  })
  g_GameInfo = gi
  return gi
end

-- ===========================================================================
-- Hex geometry: odd rows shifted right ("odd-r"), plot index = y * w + x.
-- ===========================================================================
local function ToCube(x, y) return x - (y - y % 2) / 2, y end
local function FromCube(q, r) return q + (r - r % 2) / 2, r end
local function Distance(x1, y1, x2, y2)
  local q1, r1 = ToCube(x1, y1)
  local q2, r2 = ToCube(x2, y2)
  local dq, dr = q1 - q2, r1 - r2
  return math.floor((math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2)
end
-- Clockwise from north-east; direction d and d + 3 are opposite.
local DIRECTIONS = { { 1, -1 }, { 1, 0 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { 0, -1 } }
CmpGame.Distance = Distance

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
        RemoveAll = function() for i = #handlers, 1, -1 do handlers[i] = nil end end,
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
-- spec (cmp_mapgen.lua):
--   width, height
--   plots[i] (i = plot index + 1) = { t = TerrainType, f = FeatureType,
--       r = ResourceType, rc = count, imp = ImprovementType, lake = true,
--       hidden = true (unrevealed to the local player), low = CoastalLowland
--       index (Gathering Storm), flooded = true, submerged = true }
--   rivers = { { name, edges = { {a, b}, ... }, floodplains = { index } } }
--   players = { { id, civ, leader, minor = bool } }  (id 0 = local player)
--   cities = { { id, owner, x, y, name, population, capital, plots = { index },
--       districts = { { type, x, y } }, buildings = { BuildingType } } }
--   wonders = { { x, y, building, city } }
--   pins = { { x, y, icon, name } }   (local player's)
function CmpGame.New(spec)
  local gi = CmpGame.LoadGameInfo()
  local w = { Spec = spec, Calls = { GetBonusYields = 0, CanPlacePin = 0 } }
  CmpGame.World = w
  local width, height = spec.width, spec.height
  w.Width, w.Height = width, height

  -- Plots -----------------------------------------------------------------
  local Plot = Class("Plot")
  local byIndex = {}
  for i = 0, width * height - 1 do
    local p = spec.plots[i + 1] or { t = "TERRAIN_OCEAN" }
    local terrain = gi.Terrains[p.t] or error("unknown terrain " .. tostring(p.t))
    local plot = setmetatable({
      index = i, x = i % width, y = math.floor(i / width),
      terrain = terrain, feature = p.f and (gi.Features[p.f] or error("unknown feature " .. p.f)) or nil,
      resource = p.r and (gi.Resources[p.r] or error("unknown resource " .. p.r)) or nil,
      resourceCount = p.rc or 1,
      improvement = p.imp and (gi.Improvements[p.imp] or error("unknown improvement " .. p.imp)) or nil,
      lake = p.lake == true, hidden = p.hidden == true,
      lowland = p.low or -1, flooded = p.flooded == true, submerged = p.submerged == true,
      owner = -1, city = nil, district = nil, wonder = nil, riverEdges = {}, appeal = 0,
    }, Plot)
    byIndex[i] = plot
  end
  w.Plots = byIndex

  local function GetPlot(x, y)
    if x == nil or y == nil then return nil end
    if x < 0 or y < 0 or x >= width or y >= height then return nil end
    return byIndex[y * width + x]
  end
  local function Adjacent(x, y, direction)
    local q, r = ToCube(x, y)
    local d = DIRECTIONS[(direction % 6) + 1]
    local nx, ny = FromCube(q + d[1], r + d[2])
    return GetPlot(nx, ny)
  end
  local function Neighbours(plot)
    local list = {}
    for dir = 0, 5 do
      local n = Adjacent(plot.x, plot.y, dir)
      if n ~= nil then list[#list + 1] = n end
    end
    return list
  end
  w.GetPlot, w.Adjacent, w.Neighbours = GetPlot, Adjacent, Neighbours

  -- Rivers: edges between neighbouring plots.
  local rivers = {}
  for r, river in ipairs(spec.rivers or {}) do
    local entry = { TypeID = r - 1, Name = river.name or ("LOC_RIVER_CMP_" .. r), Edges = {}, Floodplains = {} }
    for _, e in ipairs(river.edges) do
      local a, b = byIndex[e[1]], byIndex[e[2]]
      a.riverEdges[e[2]] = entry
      b.riverEdges[e[1]] = entry
      entry.Edges[#entry.Edges + 1] = { e[1], e[2] }
    end
    for _, idx in ipairs(river.floodplains or {}) do
      entry.Floodplains[#entry.Floodplains + 1] = idx
      byIndex[idx].floodRiver = entry
    end
    rivers[#rivers + 1] = entry
  end
  w.Rivers = rivers

  function Plot:GetX() return self.x end
  function Plot:GetY() return self.y end
  function Plot:GetIndex() return self.index end
  function Plot:GetTerrainType() return self.terrain.Index end
  function Plot:GetFeatureType() return self.feature and self.feature.Index or -1 end
  function Plot:GetResourceType() return self.resource and self.resource.Index or -1 end
  function Plot:GetResourceTypeHash() return self.resource and self.resource.Hash or -1 end
  function Plot:GetResourceCount() return self.resource and self.resourceCount or 0 end
  function Plot:GetImprovementType() return self.improvement and self.improvement.Index or -1 end
  function Plot:IsImprovementPillaged() return false end
  function Plot:GetDistrictType() return self.district and self.district.typeRow.Index or -1 end
  function Plot:GetDistrictID() return self.district and self.district.id or -1 end
  function Plot:GetWonderType() return self.wonder and self.wonder.Index or -1 end
  function Plot:IsWonderComplete() return self.wonder ~= nil end
  function Plot:IsCity() return self.isCity == true end
  function Plot:GetOwner() return self.owner end
  function Plot:IsOwned() return self.owner ~= -1 end
  function Plot:GetOwningCity() return self.city end
  function Plot:IsWater() return self.terrain.Water == true end
  function Plot:IsLake() return self.lake end
  function Plot:IsShallowWater() return self.terrain.ShallowWater == true end
  function Plot:IsMountain() return self.terrain.Mountain == true end
  function Plot:IsHills() return self.terrain.Hills == true end
  function Plot:IsFlatlands() return not self.terrain.Hills and not self.terrain.Mountain and not self.terrain.Water end
  function Plot:IsImpassable()
    return self.terrain.Impassable == true or (self.feature ~= nil and self.feature.Impassable == true)
  end
  function Plot:IsNaturalWonder() return self.feature ~= nil and self.feature.NaturalWonder == true end
  function Plot:IsRiver() return next(self.riverEdges) ~= nil end
  function Plot:IsRiverAdjacent() return self:IsRiver() end
  function Plot:GetRiverCrossingCount()
    local n = 0
    for _ in pairs(self.riverEdges) do n = n + 1 end
    return n
  end
  function Plot:IsRiverCrossingToPlot(other)
    return other ~= nil and self.riverEdges[other.index] ~= nil
  end
  -- The game's per-edge flags: river on the east, south-east, south-west edge.
  function Plot:IsWOfRiver() local n = Adjacent(self.x, self.y, 1) return n ~= nil and self.riverEdges[n.index] ~= nil end
  function Plot:IsNWOfRiver() local n = Adjacent(self.x, self.y, 2) return n ~= nil and self.riverEdges[n.index] ~= nil end
  function Plot:IsNEOfRiver() local n = Adjacent(self.x, self.y, 3) return n ~= nil and self.riverEdges[n.index] ~= nil end
  function Plot:IsCoastalLand()
    if self:IsWater() then return false end
    for _, n in ipairs(Neighbours(self)) do
      if n:IsWater() and not n.lake then return true end
    end
    return false
  end
  function Plot:IsAdjacentToShallowWater()
    for _, n in ipairs(Neighbours(self)) do
      if n.terrain.ShallowWater then return true end
    end
    return false
  end
  function Plot:IsAdjacentToLand()
    for _, n in ipairs(Neighbours(self)) do
      if not n:IsWater() then return true end
    end
    return false
  end
  function Plot:IsFreshWater()
    if self:IsWater() then return false end
    if self:IsRiver() then return true end
    for _, n in ipairs(Neighbours(self)) do
      if n.lake or (n.feature and n.feature.FeatureType == "FEATURE_OASIS") then return true end
    end
    return false
  end
  function Plot:GetAppeal() return self.appeal end
  function Plot:GetWorkerCount() return 0 end
  function Plot:GetArea() return Stub end
  function Plot:GetAreaID() return self:IsWater() and 1 or 0 end
  function Plot:IsVisible() return true end
  function Plot:IsRevealed() return not self.hidden end
  function Plot:GetRouteType() return -1 end
  function Plot:IsUnit() return false end
  function Plot:GetUnitCount() return 0 end
  function Plot:GetContinentType() return 0 end
  function Plot:IsNationalPark() return false end
  function Plot:GetPlotIndex() return self.index end

  -- Plot yields as the game reports them: terrain, feature, resource,
  -- improvement. District tiles yield nothing; the city center at least 2/1.
  local yieldIndex = {}
  for row in gi.Yields() do yieldIndex[row.Index] = row.YieldType end
  local terrainYield, featureYield, resourceYield, improvementYield = {}, {}, {}, {}
  local function AddYield(map, key, yieldType, amount)
    map[key] = map[key] or {}
    map[key][yieldType] = (map[key][yieldType] or 0) + amount
  end
  for row in gi.Terrain_YieldChanges() do AddYield(terrainYield, row.TerrainType, row.YieldType, row.YieldChange) end
  for row in gi.Feature_YieldChanges() do AddYield(featureYield, row.FeatureType, row.YieldType, row.YieldChange) end
  for row in gi.Resource_YieldChanges() do AddYield(resourceYield, row.ResourceType, row.YieldType, row.YieldChange) end
  for row in gi.Improvement_YieldChanges() do AddYield(improvementYield, row.ImprovementType, row.YieldType, row.YieldChange) end
  local function BaseYield(plot, yieldType)
    local total = (terrainYield[plot.terrain.TerrainType] or {})[yieldType] or 0
    if plot.feature ~= nil then total = total + ((featureYield[plot.feature.FeatureType] or {})[yieldType] or 0) end
    if plot.resource ~= nil then total = total + ((resourceYield[plot.resource.ResourceType] or {})[yieldType] or 0) end
    if plot.improvement ~= nil then total = total + ((improvementYield[plot.improvement.ImprovementType] or {})[yieldType] or 0) end
    return total
  end
  w.BaseYield = BaseYield
  function Plot:GetYield(index)
    local yieldType = type(index) == "string" and index or yieldIndex[index]
    if yieldType == nil then return 0 end
    if self.isCity then
      local base = BaseYield(self, yieldType)
      if yieldType == "YIELD_FOOD" then return math.max(2, base) end
      if yieldType == "YIELD_PRODUCTION" then return math.max(1, base) end
      return base
    end
    if self.district ~= nil or self.wonder ~= nil then return 0 end
    return BaseYield(self, yieldType)
  end

  -- Players, cities, districts --------------------------------------------
  local playerSpecs = {}
  for _, p in ipairs(spec.players) do playerSpecs[p.id] = p end
  local cities, cityList = {}, {}
  local City = Class("City")
  local District = Class("District")
  local nextDistrictID = 1

  function District:GetType() return self.typeRow.Index end
  function District:GetX() return self.x end
  function District:GetY() return self.y end
  function District:GetID() return self.id end
  function District:IsComplete() return true end
  function District:IsPillaged() return false end
  function District:GetOwner() return self.city.owner end
  function District:GetCity() return self.city end
  function District:GetCityID() return self.city.id end
  function District:GetPlot() return GetPlot(self.x, self.y) end
  function District:GetLocation() return { x = self.x, y = self.y } end
  function District:IsCityCenter() return self.typeRow.CityCenter == true end

  local function AddDistrict(city, districtType, x, y)
    local row = gi.Districts[districtType] or error("unknown district " .. tostring(districtType))
    local plot = GetPlot(x, y)
    local d = setmetatable({ typeRow = row, x = x, y = y, id = nextDistrictID, city = city }, District)
    nextDistrictID = nextDistrictID + 1
    plot.district = d
    if not row.CityCenter and plot.feature ~= nil and plot.feature.Removable then plot.feature = nil end
    if plot.resource ~= nil and not row.CityCenter then
      local harvest = false
      for _ in gi.Resource_Harvests({ ResourceType = plot.resource.ResourceType }) do harvest = true end
      if harvest then plot.resource = nil end
    end
    plot.improvement = nil
    city.districts[#city.districts + 1] = d
    return d
  end

  local function SpecialtyCount(city)
    local n = 0
    for _, d in ipairs(city.districts) do
      if d.typeRow.RequiresPopulation and not d.typeRow.CityCenter then n = n + 1 end
    end
    return n
  end

  function City:GetID() return self.id end
  function City:GetOwner() return self.owner end
  function City:GetX() return self.x end
  function City:GetY() return self.y end
  function City:GetName() return self.name end
  function City:GetPopulation() return self.population end
  function City:IsCapital() return self.capital == true end
  function City:IsOriginalCapital() return self.capital == true end
  function City:GetOriginalOwner() return self.owner end
  function City:GetPlot() return GetPlot(self.x, self.y) end
  function City:GetYield(index) local p = GetPlot(self.x, self.y) return p and p:GetYield(index) or 0 end
  -- Not game methods of cities or districts; planners probe them to tell a
  -- plot from other objects, so they must not exist (the fallback would
  -- answer any capitalized name).
  City.GetResourceType = false
  District.GetResourceType = false
  function City:IsCoastal() return GetPlot(self.x, self.y):IsCoastalLand() end
  function City:GetHousing() return 10 end
  function City:GetBuildings()
    local city = self
    return setmetatable({
      HasBuilding = function(_, index) return city.buildings[index] == true end,
      GetBuildingLocation = function() return -1 end,
      IsPillaged = function() return false end,
    }, { __index = function(_, k) Missing("CityBuildings", k) return function() return nil end end })
  end
  function City:GetDistricts()
    local city = self
    local list = city.districts
    return setmetatable({
      Members = function() return ipairs(list) end,
      GetCount = function() return #list end,
      FindID = function(_, id)
        for _, d in ipairs(list) do
          if d.id == id then return d end
        end
        return nil
      end,
      HasDistrict = function(_, index)
        for _, d in ipairs(list) do
          if d.typeRow.Index == index then return true end
        end
        return false
      end,
      GetDistrict = function(_, index)
        for _, d in ipairs(list) do
          if d.typeRow.Index == index then return d end
        end
        return nil
      end,
      GetDistrictByType = function(_, index)
        for _, d in ipairs(list) do
          if d.typeRow.Index == index then return d end
        end
        return nil
      end,
      GetDistrictLocationByID = function(_, id)
        for _, d in ipairs(list) do
          if d.id == id then return d.x, d.y end
        end
        return nil
      end,
      GetNumZonedDistrictsRequiringPopulation = function() return SpecialtyCount(city) end,
      GetNumAllowedDistrictsRequiringPopulation = function()
        return 1 + math.floor((city.population - 1) / 3)
      end,
      IsComplete = function() return true end,
    }, { __index = function(_, k) Missing("CityDistricts", k) return function() return nil end end })
  end
  function City:GetReligion()
    return setmetatable({ GetMajorityReligion = function() return -1 end, GetReligionsInCity = function() return {} end },
      { __index = function(_, k) Missing("CityReligion", k) return function() return nil end end })
  end
  function City:GetOwnedPlots()
    local list = {}
    for _, idx in ipairs(self.plots) do list[#list + 1] = byIndex[idx] end
    return list
  end

  local function AddCity(c)
    local city = setmetatable({
      id = c.id, owner = c.owner or 0, x = c.x, y = c.y, name = c.name or ("CITY_" .. c.id),
      population = c.population or 1, capital = c.capital == true, districts = {}, buildings = {}, plots = {},
    }, City)
    cities[city.owner .. ":" .. city.id] = city
    cityList[#cityList + 1] = city
    local plot = GetPlot(c.x, c.y)
    plot.isCity = true
    plot.owner, plot.city = city.owner, city
    city.plots[#city.plots + 1] = plot.index
    AddDistrict(city, "DISTRICT_CITY_CENTER", c.x, c.y)
    for _, idx in ipairs(c.plots or {}) do
      local p = byIndex[idx]
      if p.owner == -1 then
        p.owner, p.city = city.owner, city
        city.plots[#city.plots + 1] = idx
      end
    end
    for _, b in ipairs(c.buildings or {}) do city.buildings[gi.Buildings[b].Index] = true end
    return city
  end
  for _, c in ipairs(spec.cities or {}) do AddCity(c) end
  for _, c in ipairs(spec.cities or {}) do
    local city = cities[(c.owner or 0) .. ":" .. c.id]
    for _, d in ipairs(c.districts or {}) do AddDistrict(city, d.type, d.x, d.y) end
  end
  for _, b in ipairs(spec.wonders or {}) do
    local plot = GetPlot(b.x, b.y)
    plot.wonder = gi.Buildings[b.building]
    local city = cities[(b.owner or 0) .. ":" .. b.city]
    if city then
      local d = AddDistrict(city, "DISTRICT_WONDER", b.x, b.y)
      plot.district = d
      city.buildings[plot.wonder.Index] = true
    end
  end
  w.Cities = cityList
  function w:City(id, owner) return cities[(owner or 0) .. ":" .. id] end

  -- Appeal: the adjacent plots' features, terrain, districts, improvements
  -- and wonders (the game's appeal sources that are static on a planning map).
  local function ComputeAppeal(plot)
    if plot:IsWater() then return 0 end
    local appeal, water = 0, false
    for _, n in ipairs(Neighbours(plot)) do
      if n.feature then appeal = appeal + (n.feature.Appeal or 0) end
      if n.terrain.Mountain then appeal = appeal + 1 end
      if n:IsWater() then water = true end
      if n.terrain.Appeal then appeal = appeal + n.terrain.Appeal end
      if n.district then appeal = appeal + (n.district.typeRow.Appeal or 0) end
      if n.improvement then appeal = appeal + (n.improvement.Appeal or 0) end
      if n.wonder then appeal = appeal + 1 end
    end
    if water then appeal = appeal + 1 end
    if plot:IsRiver() then appeal = appeal + 1 end
    return appeal
  end
  for i = 0, width * height - 1 do byIndex[i].appeal = ComputeAppeal(byIndex[i]) end

  -- Map pins (per player) and the player configuration store ---------------
  local Pin = Class("MapPin")
  function Pin:GetID() return self.id end
  function Pin:GetHexX() return self.x end
  function Pin:GetHexY() return self.y end
  function Pin:GetIconName() return self.icon end
  function Pin:SetIconName(icon) self.icon = icon end
  function Pin:GetName() return self.name end
  function Pin:SetName(name) self.name = name end
  function Pin:GetPlayerID() return self.pid end
  function Pin:GetVisibility() return self.visibility end
  function Pin:SetVisibility(v) self.visibility = v end
  function Pin:IsVisible() return true end
  function Pin:GetColor() return 0 end
  function Pin:SetColor() end

  local Config = Class("PlayerConfiguration")
  local configs = {}
  local nextPinID = 0
  for _, p in ipairs(spec.players) do
    local civ = gi.Civilizations[p.civ]
    local leader = gi.Leaders[p.leader]
    configs[p.id] = setmetatable({ pid = p.id, pins = {}, values = {}, civ = civ, leader = leader }, Config)
  end
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
    local pin = setmetatable({ id = nextPinID, x = x, y = y, icon = "ICON_MAP_PIN_SQUARE", name = "", pid = self.pid,
      visibility = 0 }, Pin)
    nextPinID = nextPinID + 1
    self.pins[#self.pins + 1] = pin
    return pin
  end
  function Config:DeleteMapPin(id)
    for i, pin in ipairs(self.pins) do
      if pin.id == id then
        table.remove(self.pins, i)
        return
      end
    end
  end
  function Config:GetValue(key) return self.values[key] end
  function Config:SetValue(key, value) self.values[key] = value end
  function Config:GetLeaderTypeName() return self.leader and self.leader.LeaderType or "LEADER_MINOR_CIV_DEFAULT" end
  function Config:GetLeaderTypeID() return self.leader and self.leader.Index or -1 end
  function Config:GetLeaderTypeHash() return self.leader and self.leader.Hash or -1 end
  function Config:GetCivilizationTypeName() return self.civ and self.civ.CivilizationType or "CIVILIZATION_MINOR" end
  function Config:GetCivilizationTypeID() return self.civ and self.civ.Index or -1 end
  function Config:GetCivilizationTypeHash() return self.civ and self.civ.Hash or -1 end
  function Config:GetPlayerName() return "Player " .. self.pid end
  function Config:GetCivilizationShortDescription() return self.civ and self.civ.Name or "" end
  function Config:GetCivilizationLevelTypeID() return 0 end
  function Config:IsHuman() return self.pid == 0 end
  function Config:IsAI() return self.pid ~= 0 end
  function Config:IsAlive() return true end
  function Config:GetSlotStatus() return 0 end

  for _, p in ipairs(spec.pins or {}) do
    local pin = configs[p.owner or 0]:GetMapPin(p.x, p.y)
    pin.icon = p.icon
    pin.name = p.name or ""
  end
  w.Configs = configs

  -- Players ----------------------------------------------------------------
  local players = {}
  local allTechs, allCivics = {}, {}
  for row in gi.Technologies() do allTechs[row.Index] = true end
  for row in gi.Civics() do allCivics[row.Index] = true end
  local PlayerClass = Class("Player")
  for _, p in ipairs(spec.players) do
    local pid = p.id
    local techs = p.techs == "all" and allTechs or {}
    if type(p.techs) == "table" then for _, t in ipairs(p.techs) do techs[gi.Technologies[t].Index] = true end end
    local civics = p.civics == "all" and allCivics or {}
    if type(p.civics) == "table" then for _, c in ipairs(p.civics) do civics[gi.Civics[c].Index] = true end end
    local myCities = {}
    for _, c in ipairs(cityList) do
      if c.owner == pid then myCities[#myCities + 1] = c end
    end
    local pantheon = p.pantheon and gi.Beliefs[p.pantheon].Index or -1
    players[pid] = setmetatable({
      id = pid, minor = p.minor == true,
      GetID = function() return pid end,
      IsMajor = function() return not p.minor end,
      IsAlive = function() return true end,
      IsHuman = function() return pid == 0 end,
      IsAI = function() return pid ~= 0 end,
      IsBarbarian = function() return false end,
      IsFreeCities = function() return false end,
      GetTeam = function() return pid end,
      GetCities = function()
        return setmetatable({
          Members = function() return ipairs(myCities) end,
          GetCapitalCity = function()
            for _, c in ipairs(myCities) do
              if c.capital then return c end
            end
            return myCities[1]
          end,
          GetCount = function() return #myCities end,
          FindID = function(_, id)
            for _, c in ipairs(myCities) do
              if c.id == id then return c end
            end
            return nil
          end,
        }, { __index = function(_, k) Missing("PlayerCities", k) return function() return nil end end })
      end,
      GetDistricts = function()
        local all = {}
        for _, c in ipairs(myCities) do
          for _, d in ipairs(c.districts) do all[#all + 1] = d end
        end
        return setmetatable({
          Members = function() return ipairs(all) end,
          GetCount = function() return #all end,
          FindID = function(_, id)
            for _, d in ipairs(all) do
              if d.id == id then return d end
            end
            return nil
          end,
        }, { __index = function(_, k) Missing("PlayerDistricts", k) return function() return nil end end })
      end,
      GetTechs = function()
        return setmetatable({
          HasTech = function(_, i) return techs[i] == true end,
          GetResearchProgress = function() return 0 end,
        }, { __index = function(_, k) Missing("PlayerTechs", k) return function() return nil end end })
      end,
      GetCulture = function()
        return setmetatable({
          HasCivic = function(_, i) return civics[i] == true end,
          GetNumPolicySlots = function() return 0 end,
          GetSlotType = function() return -1 end,
          GetSlotPolicy = function() return -1 end,
          GetCurrentGovernment = function() return -1 end,
          IsPolicyActive = function() return false end,
        }, { __index = function(_, k) Missing("PlayerCulture", k) return function() return nil end end })
      end,
      GetReligion = function()
        return setmetatable({
          GetPantheon = function() return pantheon end,
          GetReligionTypeCreated = function() return -1 end,
          GetReligionInMajorityOfCities = function() return -1 end,
        }, { __index = function(_, k) Missing("PlayerReligion", k) return function() return nil end end })
      end,
      GetResources = function()
        return setmetatable({
          IsResourceVisible = function(_, hashOrIndex)
            local row = gi.Resources[hashOrIndex]
            return row == nil or row.PrereqTech == nil or techs[gi.Technologies[row.PrereqTech].Index] == true
          end,
          GetResourceAmount = function() return 0 end,
          HasResource = function() return false end,
          GetExportedResourceAmount = function() return 0 end,
          GetImportedResourceAmount = function() return 0 end,
          GetResourceStockpileAmount = function() return 0 end,
          GetResourceStockpileCap = function() return 0 end,
          GetResourceAccumulationPerTurn = function() return 0 end,
        }, { __index = function(_, k) Missing("PlayerResources", k) return function() return nil end end })
      end,
      GetUnits = function()
        return setmetatable({ Members = function() return ipairs({}) end, GetCount = function() return 0 end },
          { __index = function(_, k) Missing("PlayerUnits", k) return function() return nil end end })
      end,
      GetProperty = function() return nil end,
      GetEra = function() return 3 end,
      GetDiplomacy = function() return Stub end,
    }, PlayerClass)
  end
  w.Players = players

  -- Modifier system (GameEffects) -----------------------------------------
  -- The game instantiates a modifier object per trait modifier of the
  -- player's civilization and leader (and attaches nested ones). DMT reads
  -- these objects to find trait adjacencies and placement rules.
  local objects, modifiers = {}, {}
  local function NewObject(kind, name, pid, str)
    local id = #objects + 1
    objects[id] = { kind = kind, name = name, pid = pid, str = str }
    return id
  end
  local function ArgsOf(modifierId)
    local args = {}
    for row in gi.ModifierArguments({ ModifierId = modifierId }) do args[row.Name] = row.Value end
    return args
  end
  local function Instantiate(modifierId, ownerId, depth)
    local row = gi.Modifiers[modifierId]
    if row == nil or depth > 4 then return end
    local id = NewObject("modifier", modifierId, objects[ownerId].pid, "Modifier: " .. modifierId)
    modifiers[#modifiers + 1] = { id = id, modifierId = modifierId, owner = ownerId, args = ArgsOf(modifierId),
      ownerReq = row.OwnerRequirementSetId }
    local dyn = gi.DynamicModifiers[row.ModifierType]
    if dyn and dyn.EffectType == "EFFECT_ATTACH_MODIFIER" then
      local attached = ArgsOf(modifierId).ModifierId
      if attached then Instantiate(attached, ownerId, depth + 1) end
    end
  end
  for _, p in ipairs(spec.players) do
    if not p.minor then
      local owner = NewObject("player", gi.Leaders[p.leader] and gi.Leaders[p.leader].Name or "", p.id, "Player: " .. p.id)
      local traits = {}
      for row in gi.CivilizationTraits({ CivilizationType = p.civ }) do traits[#traits + 1] = row.TraitType end
      for row in gi.LeaderTraits({ LeaderType = p.leader }) do traits[#traits + 1] = row.TraitType end
      for _, trait in ipairs(traits) do
        for row in gi.TraitModifiers({ TraitType = trait }) do Instantiate(row.ModifierId, owner, 0) end
      end
      if p.pantheon then
        local belief = NewObject("belief", gi.Beliefs[p.pantheon].Name, p.id, "Belief: " .. p.pantheon)
        for row in gi.BeliefModifiers({ BeliefType = p.pantheon }) do Instantiate(row.ModifierID or row.ModifierId, belief, 0) end
      end
    end
  end
  local OBJECT_TYPES = { player = "LOC_MODIFIER_OBJECT_PLAYER", modifier = "LOC_MODIFIER_OBJECT_MODIFIER",
    belief = "LOC_MODIFIER_OBJECT_BELIEF", city = "LOC_MODIFIER_OBJECT_CITY", district = "LOC_MODIFIER_OBJECT_DISTRICT" }
  local byModifierObject = {}
  for _, m in ipairs(modifiers) do byModifierObject[m.id] = m end
  local GameEffects = {
    GetModifiers = function()
      local list = {}
      for _, m in ipairs(modifiers) do list[#list + 1] = m.id end
      return list
    end,
    GetModifierActive = function() return true end,
    GetModifierOwner = function(id) return byModifierObject[id] and byModifierObject[id].owner end,
    GetModifierOwnerRequirementSet = function(id) return byModifierObject[id] and byModifierObject[id].ownerReq end,
    GetRequirementSetState = function() return "Met" end,
    GetModifierDefinition = function(id)
      local m = byModifierObject[id]
      return m and { Id = m.modifierId, Arguments = m.args } or nil
    end,
    GetModifierSubjects = function() return {} end,
    GetObjectsPlayerId = function(id) return objects[id] and objects[id].pid or -1 end,
    GetObjectName = function(id) return objects[id] and objects[id].name or nil end,
    GetObjectType = function(id) return objects[id] and OBJECT_TYPES[objects[id].kind] or nil end,
    GetObjectString = function(id) return objects[id] and objects[id].str or "" end,
    GetModifierTracking = function() return {} end,
  }
  w.Modifiers = modifiers

  -- Rivers for DMT's dam check.
  local RiverManager = {
    GetRiverForFloodplain = function(x, y)
      local plot = GetPlot(x, y)
      return plot and plot.floodRiver and plot.floodRiver.TypeID or -1
    end,
    GetNumRivers = function() return #rivers end,
    GetRiverByIndex = function(i) return rivers[i + 1] end,
    GetRiverNameByType = function(t) return rivers[t + 1] and rivers[t + 1].Name or "" end,
    GetRiverName = function(plot)
      if plot == nil then return "" end
      if plot.floodRiver then return plot.floodRiver.Name end
      for _, r in pairs(plot.riverEdges) do return r.Name end
      return ""
    end,
    GetFloodplainPlots = function(t) return rivers[t + 1] and rivers[t + 1].Floodplains or {} end,
    CanBeFlooded = function(plot) return plot ~= nil and plot.floodRiver ~= nil end,
    GetRiverType = function(plot)
      for _, r in pairs(plot.riverEdges) do return r.TypeID end
      return -1
    end,
  }

  -- Globals -----------------------------------------------------------------
  local Map = {
    GetPlot = GetPlot,
    GetPlotByIndex = function(i) return byIndex[i] end,
    GetPlotIndex = function(x, y) return y * width + x end,
    GetPlotDistance = Distance,
    GetGridSize = function() return width, height end,
    GetPlotCount = function() return width * height end,
    GetMapSize = function() return 0 end,
    IsWrapX = function() return false end,
    IsWrapY = function() return false end,
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
    GetNeighborPlots = function(x, y, range)
      local list = {}
      for _, p in pairs(byIndex) do
        if Distance(x, y, p.x, p.y) <= range then list[#list + 1] = p end
      end
      return list
    end,
    GetCityPlots = function()
      return {
        GetPurchasedPlots = function(_, city)
          local list = {}
          for _, idx in ipairs(city.plots) do list[#list + 1] = idx end
          return list
        end,
      }
    end,
    FindSecondContinent = function() return nil end,
  }

  local visibility = {}
  for _, p in ipairs(spec.players) do
    local pid = p.id
    visibility[pid] = setmetatable({
      IsRevealed = function(_, a, b)
        local plot = b ~= nil and GetPlot(a, b) or byIndex[a]
        if plot == nil then return false end
        return pid ~= 0 or not plot.hidden
      end,
      IsVisible = function(_, a, b)
        local plot = b ~= nil and GetPlot(a, b) or byIndex[a]
        return plot ~= nil and (pid ~= 0 or not plot.hidden)
      end,
      GetState = function() return 2 end,
    }, { __index = function(_, k) Missing("PlayerVisibility", k) return function() return nil end end })
  end

  local Events, LuaEvents = EventTable(), EventTable()
  w.Events, w.LuaEvents = Events, LuaEvents
  local globalParameters = {}
  for row in gi.GlobalParameters() do globalParameters[row.Name] = tonumber(row.Value) or row.Value end

  local function GetCityAt(a, b)
    local plot = b ~= nil and GetPlot(a, b) or (type(a) == "table" and a or byIndex[a])
    if plot == nil or not plot.isCity then return nil end
    return plot.city
  end

  local playerList = {}
  for _, p in ipairs(spec.players) do playerList[#playerList + 1] = players[p.id] end

  local globals = {
    GameInfo = gi,
    GlobalParameters = globalParameters,
    Map = Map,
    Players = players,
    PlayerConfigurations = configs,
    PlayersVisibility = visibility,
    PlayerManager = {
      GetAliveMajors = function()
        local list = {}
        for _, p in ipairs(playerList) do if not p.minor then list[#list + 1] = p end end
        return list
      end,
      GetAliveMinors = function()
        local list = {}
        for _, p in ipairs(playerList) do if p.minor then list[#list + 1] = p end end
        return list
      end,
      GetAliveMajorIDs = function()
        local list = {}
        for _, p in ipairs(playerList) do if not p.minor then list[#list + 1] = p.id end end
        return list
      end,
      IsValid = function(id) return players[id] ~= nil end,
    },
    Game = {
      GetLocalPlayer = function() return 0 end,
      GetLocalObserver = function() return 0 end,
      GetCurrentGameTurn = function() return spec.turn or 120 end,
      GetPlayers = function() return playerList end,
      GetReligion = function() return { GetReligions = function() return {} end } end,
      GetEras = function() return Stub end,
      GetProperty = function() return nil end,
      IsVictoryEnabled = function() return true end,
    },
    GameConfiguration = {
      GetRuleSet = function() return spec.ruleset or "RULESET_EXPANSION_2" end,
      IsAnyMultiplayer = function() return false end,
      IsNetworkMultiplayer = function() return false end,
      IsHotseat = function() return false end,
      IsPlayByCloud = function() return false end,
      GetValue = function() return nil end,
      GetStartEra = function() return 0 end,
    },
    Modding = {
      IsModActive = function(id)
        id = tostring(id):lower()
        return id == "1b28771a-c749-434b-9053-d1380c553de9" or id == "4873eb62-8ccc-4574-b784-dda455e74e68"
      end,
      IsModEnabled = function(id)
        id = tostring(id):lower()
        return id == "1b28771a-c749-434b-9053-d1380c553de9" or id == "4873eb62-8ccc-4574-b784-dda455e74e68"
      end,
      GetActiveMods = function() return {} end,
    },
    CityManager = {
      GetCity = function(pid, id) return cities[pid .. ":" .. id] end,
      GetDistrictAt = function(plot) return plot and plot.district or nil end,
      GetOperationTargets = function() return {} end,
      CanStartOperation = function() return false end,
      GetCityAt = GetCityAt,
    },
    Cities = {
      GetPlotPurchaseCity = function(a, b)
        local plot = b ~= nil and GetPlot(a, b) or (type(a) == "table" and a or byIndex[a])
        return plot and plot.city or nil
      end,
      GetCityInPlot = GetCityAt,
    },
    GameEffects = GameEffects,
    RiverManager = RiverManager,
    -- Coastal lowland and the sea level (scenes from Gathering Storm games).
    TerrainManager = {
      GetCoastalLowlandType = function(plot) return plot.lowland end,
      IsFlooded = function(plot) return plot.flooded end,
      IsSubmerged = function(plot) return plot.submerged end,
    },
    AdjacencyBonusTypes = {
      NO_ADJACENCY = -1, ADJACENCY_DISTRICT = 0, ADJACENCY_FEATURE = 1, ADJACENCY_IMPROVEMENT = 2,
      ADJACENCY_NATURAL_WONDER = 3, ADJACENCY_RESOURCE = 4, ADJACENCY_RESOURCE_CLASS = 5, ADJACENCY_RIVER = 6,
      ADJACENCY_SEA_RESOURCE = 7, ADJACENCY_TERRAIN = 8, ADJACENCY_WONDER = 9,
    },
    DirectionTypes = {
      NUM_DIRECTION_TYPES = 6, DIRECTION_NORTHEAST = 0, DIRECTION_EAST = 1, DIRECTION_SOUTHEAST = 2,
      DIRECTION_SOUTHWEST = 3, DIRECTION_WEST = 4, DIRECTION_NORTHWEST = 5, NO_DIRECTION = -1,
    },
    CityOperationTypes = setmetatable({}, { __index = function(_, k) return k end }),
    CityOperationResults = setmetatable({}, { __index = function(_, k) return k end }),
    CityCommandTypes = setmetatable({}, { __index = function(_, k) return k end }),
    UnitOperationTypes = setmetatable({}, { __index = function(_, k) return k end }),
    Locale = {
      Lookup = function(key, ...)
        local args = { ... }
        if #args == 0 then return tostring(key) end
        for i, a in ipairs(args) do args[i] = tostring(a) end
        return tostring(key) .. "(" .. table.concat(args, ",") .. ")"
      end,
      Compare = function(a, b)
        if a == b then return 0 end
        return tostring(a) < tostring(b) and -1 or 1
      end,
      ToUpper = function(s) return tostring(s):upper() end,
      ToLower = function(s) return tostring(s):lower() end,
      ToNumber = function(n) return tostring(n) end,
      HasTextKey = function() return false end,
      GetCurrentLanguage = function() return { Type = "en_US" } end,
    },
    UI = setmetatable({
      GetElapsedTime = function() return 0 end,
      PlaySound = function() end,
      GridToWorld = function() return 0, 0, 0 end,
      IsInGame = function() return true end,
      GetHeadSelectedCity = function() return nil end,
      LinearToSRGB = function(c) return c end,
      SRGBToLinear = function(c) return c end,
      GetColorValue = function() return 0 end,
      DataError = function(m) print("UI.DataError " .. tostring(m)) end,
    }, { __index = function() return Stub end }),
    UIManager = Stub, ContextPtr = Stub, Controls = Stub, InstanceManager = Stub, PullDownManager = Stub,
    Network = setmetatable({ BroadcastPlayerInfo = function() end }, { __index = function() return function() end end }),
    Events = Events,
    LuaEvents = LuaEvents,
    ExposedMembers = {},
    Keys = setmetatable({}, { __index = function() return 0 end }),
    KeyEvents = setmetatable({}, { __index = function() return 0 end }),
    MouseEvents = setmetatable({}, { __index = function() return 0 end }),
    UIState = nil,
    Automation = { GetTime = function() return 0 end },
  }
  for k, v in pairs(globals) do _G[k] = v end
  -- Adapters may add game methods a planner needs (record them in their
  -- notes): w.Classes.Plot.GetFoo = function(self) ... end
  w.Classes = { Plot = Plot, City = City, District = District, Pin = Pin, Config = Config, Player = PlayerClass }
  w.Globals = globals
  return w
end

return CmpGame
