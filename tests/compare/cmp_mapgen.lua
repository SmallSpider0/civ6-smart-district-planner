-- cmp_mapgen.lua: deterministic game situations for the planner comparison.
--
-- CmpMapgen.Generate(scenario) turns a scenario (cmp_scenarios.lua) into a
-- world spec for cmp_game.lua: terrain from elevation and moisture noise per
-- biome, rivers along plot edges that run downhill to the sea, floodplains,
-- lakes, woods, rainforest, marsh, reefs, volcanoes, a natural wonder,
-- resources placed by the game's own valid-terrain tables, cities with the
-- tiles they own at the scenario's stage, districts and improvements already
-- built, the player's own map pins, neighbours and unexplored tiles.
--
-- Same scenario, same spec: the only randomness is a seeded Park-Miller
-- generator, and every list is walked in a fixed order.

CmpMapgen = {}

local W, H = 30, 24

local function Rng(seed)
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function(n)
    state = (state * 48271.0) % 2147483647
    state = math.floor(state)
    if n == nil then return state / 2147483647 end
    return state % n + 1
  end
end
CmpMapgen.Rng = Rng

local function ToCube(x, y) return x - (y - y % 2) / 2, y end
local function FromCube(q, r) return q + (r - r % 2) / 2, r end
local DIRS = { { 1, -1 }, { 1, 0 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { 0, -1 } }
local function Idx(x, y) return y * W + x end
local function XY(i) return i % W, math.floor(i / W) end
local function Valid(x, y) return x >= 0 and y >= 0 and x < W and y < H end
local function Neighbour(x, y, d)
  local q, r = ToCube(x, y)
  local nx, ny = FromCube(q + DIRS[d][1], r + DIRS[d][2])
  if not Valid(nx, ny) then return nil end
  return nx, ny
end
local function Neighbours(i)
  local x, y = XY(i)
  local list = {}
  for d = 1, 6 do
    local nx, ny = Neighbour(x, y, d)
    if nx then list[#list + 1] = Idx(nx, ny) end
  end
  return list
end
local function Dist(a, b)
  local x1, y1 = XY(a)
  local x2, y2 = XY(b)
  local q1, r1 = ToCube(x1, y1)
  local q2, r2 = ToCube(x2, y2)
  local dq, dr = q1 - q2, r1 - r2
  return math.floor((math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2)
end
CmpMapgen.Dist, CmpMapgen.Neighbours, CmpMapgen.XY, CmpMapgen.Idx = Dist, Neighbours, XY, Idx
CmpMapgen.W, CmpMapgen.H = W, H

-- Smooth value noise in [0, 1].
local function Noise(rng, cell)
  local gw, gh = math.floor(W / cell) + 2, math.floor(H / cell) + 2
  local grid = {}
  for i = 0, gw * gh - 1 do grid[i] = rng() end
  return function(x, y)
    local fx, fy = x / cell, y / cell
    local x0, y0 = math.floor(fx), math.floor(fy)
    local tx, ty = fx - x0, fy - y0
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    local function G(a, b) return grid[b * gw + a] end
    local top = G(x0, y0) * (1 - tx) + G(x0 + 1, y0) * tx
    local bottom = G(x0, y0 + 1) * (1 - tx) + G(x0 + 1, y0 + 1) * tx
    return top * (1 - ty) + bottom * ty
  end
end

local function Field(rng)
  local a, b, c = Noise(rng, 9), Noise(rng, 4.5), Noise(rng, 2.2)
  return function(x, y) return (a(x, y) * 0.55 + b(x, y) * 0.3 + c(x, y) * 0.15) end
end

-- Biomes: water level, hill and mountain thresholds, base terrain by
-- moisture, feature chances, river count and floodplain chance.
local BIOMES = {
  -- water: share of plots under water; mountains, hills: shares of the land.
  temperate = { water = 0.22, mountains = 0.07, hills = 0.17, base = { "TERRAIN_PLAINS", "TERRAIN_GRASS" }, woods = 0.15,
    jungle = 0.00, marsh = 0.03, rivers = 3, flood = 0.25, edgeSea = 2, reef = 0.06 },
  coastal = { water = 0.40, mountains = 0.05, hills = 0.14, base = { "TERRAIN_PLAINS", "TERRAIN_GRASS" }, woods = 0.12,
    jungle = 0.02, marsh = 0.03, rivers = 2, flood = 0.2, edgeSea = 6, reef = 0.14 },
  highland = { water = 0.14, mountains = 0.15, hills = 0.30, base = { "TERRAIN_PLAINS", "TERRAIN_GRASS" }, woods = 0.15,
    jungle = 0.0, marsh = 0.01, rivers = 2, flood = 0.1, edgeSea = 1, reef = 0.04 },
  jungle = { water = 0.22, mountains = 0.05, hills = 0.14, base = { "TERRAIN_PLAINS", "TERRAIN_GRASS" }, woods = 0.06,
    jungle = 0.30, marsh = 0.06, rivers = 3, flood = 0.2, edgeSea = 2, reef = 0.1 },
  desert = { water = 0.20, mountains = 0.06, hills = 0.15, base = { "TERRAIN_DESERT", "TERRAIN_PLAINS" }, woods = 0.02,
    jungle = 0.0, marsh = 0.0, rivers = 2, flood = 0.9, edgeSea = 2, reef = 0.05, oasis = 0.03 },
  tundra = { water = 0.22, mountains = 0.08, hills = 0.17, base = { "TERRAIN_TUNDRA", "TERRAIN_PLAINS" }, woods = 0.22,
    jungle = 0.0, marsh = 0.02, rivers = 2, flood = 0.1, edgeSea = 2, reef = 0.0, snow = 0.12 },
  island = { water = 0.55, mountains = 0.06, hills = 0.14, base = { "TERRAIN_PLAINS", "TERRAIN_GRASS" }, woods = 0.12,
    jungle = 0.08, marsh = 0.03, rivers = 1, flood = 0.2, island = true, reef = 0.2 },
  volcanic = { water = 0.22, mountains = 0.10, hills = 0.18, base = { "TERRAIN_PLAINS", "TERRAIN_GRASS" }, woods = 0.13,
    jungle = 0.03, marsh = 0.03, rivers = 2, flood = 0.2, edgeSea = 2, reef = 0.06, volcano = 0.35, fissure = 0.02 },
}
CmpMapgen.BIOMES = BIOMES

local HILLS = { TERRAIN_GRASS = "TERRAIN_GRASS_HILLS", TERRAIN_PLAINS = "TERRAIN_PLAINS_HILLS",
  TERRAIN_DESERT = "TERRAIN_DESERT_HILLS", TERRAIN_TUNDRA = "TERRAIN_TUNDRA_HILLS", TERRAIN_SNOW = "TERRAIN_SNOW_HILLS" }
local MOUNTAIN = { TERRAIN_GRASS = "TERRAIN_GRASS_MOUNTAIN", TERRAIN_PLAINS = "TERRAIN_PLAINS_MOUNTAIN",
  TERRAIN_DESERT = "TERRAIN_DESERT_MOUNTAIN", TERRAIN_TUNDRA = "TERRAIN_TUNDRA_MOUNTAIN", TERRAIN_SNOW = "TERRAIN_SNOW_MOUNTAIN" }

local function IsLand(p) return p.t ~= "TERRAIN_COAST" and p.t ~= "TERRAIN_OCEAN" end
local function IsMountain(p) return p.t:find("_MOUNTAIN", 1, true) ~= nil end
local function IsHills(p) return p.t:find("_HILLS", 1, true) ~= nil end
local function IsFlat(p) return IsLand(p) and not IsMountain(p) and not IsHills(p) end
local function BaseOf(t) return (t:gsub("_HILLS$", ""):gsub("_MOUNTAIN$", "")) end

-- ===========================================================================
-- Terrain, water, rivers, features
-- ===========================================================================
local function Quantile(values, share)
  local sorted = {}
  for _, v in ipairs(values) do sorted[#sorted + 1] = v end
  table.sort(sorted)
  if #sorted == 0 then return 0 end
  local k = math.max(1, math.min(#sorted, math.floor(#sorted * share + 0.5)))
  return sorted[k]
end

local function Terrain(spec, scn, rng, biome)
  local elev, moist = Field(rng), Field(rng)
  local plots, elevation = {}, {}
  local cx, cy = W / 2, H / 2
  local center = Idx(math.floor(cx), math.floor(cy))
  local all = {}
  for i = 0, W * H - 1 do
    local x, y = XY(i)
    local e = elev(x, y)
    -- Push the map edges towards the sea so the center is mostly land.
    local edge = math.min(x, y, W - 1 - x, H - 1 - y)
    if biome.island then
      local d = math.sqrt(((x - cx) / (W * 0.42)) ^ 2 + ((y - cy) / (H * 0.42)) ^ 2)
      e = e * 0.5 + (1 - d) * 0.6
    elseif biome.edgeSea then
      if edge < biome.edgeSea then e = e - (biome.edgeSea - edge) * 0.08 end
      if scn.biome == "coastal" and x > W * 0.62 then e = e - (x - W * 0.62) * 0.045 end
    end
    elevation[i] = e
    all[#all + 1] = e
  end
  local seaLevel = Quantile(all, biome.water)
  for _, i in ipairs({ center }) do
    for j = 0, W * H - 1 do
      if Dist(i, j) <= 2 then elevation[j] = math.max(elevation[j], seaLevel + 0.02) end
    end
  end
  local land = {}
  for i = 0, W * H - 1 do
    if elevation[i] > seaLevel then land[#land + 1] = elevation[i] end
  end
  local mountainLevel = Quantile(land, 1 - biome.mountains)
  local hillLevel = Quantile(land, 1 - biome.mountains - biome.hills)
  for i = 0, W * H - 1 do
    local x, y = XY(i)
    local e = elevation[i]
    local m = moist(x, y)
    local base = m > 0.5 and biome.base[2] or biome.base[1]
    if biome.snow and m < 0.3 and rng() < biome.snow * 3 then base = "TERRAIN_SNOW" end
    if scn.biome == "desert" and m > 0.68 then base = "TERRAIN_PLAINS" end
    local t
    if e <= seaLevel then t = "TERRAIN_COAST"
    elseif e > mountainLevel and Dist(i, center) > 1 then t = MOUNTAIN[base]
    elseif e > hillLevel then t = HILLS[base]
    else t = base end
    plots[i + 1] = { t = t, moist = m }
  end
  -- Ocean next to land is coast; coast far from land is ocean.
  for i = 0, W * H - 1 do
    local p = plots[i + 1]
    if not IsLand(p) then
      local nearLand = false
      for _, n in ipairs(Neighbours(i)) do
        if IsLand(plots[n + 1]) then nearLand = true end
      end
      p.t = nearLand and "TERRAIN_COAST" or "TERRAIN_OCEAN"
    end
  end
  -- Lakes: small inland basins.
  local lakes = (scn.biome == "temperate" or scn.biome == "tundra" or scn.biome == "highland") and 2 or 1
  for _ = 1, lakes do
    local best, bestE = nil, 9
    for _ = 1, 40 do
      local i = rng(W * H) - 1
      local p = plots[i + 1]
      local inland = IsFlat(p)
      for _, n in ipairs(Neighbours(i)) do
        if not IsLand(plots[n + 1]) then inland = false end
      end
      if inland and Dist(i, Idx(math.floor(cx), math.floor(cy))) >= 3 and elevation[i] < bestE then best, bestE = i, elevation[i] end
    end
    if best then
      plots[best + 1].t, plots[best + 1].lake = "TERRAIN_COAST", true
      if rng() < 0.5 then
        local n = Neighbours(best)[rng(#Neighbours(best))]
        local q = plots[n + 1]
        if IsFlat(q) and Dist(n, Idx(math.floor(cx), math.floor(cy))) >= 3 then q.t, q.lake = "TERRAIN_COAST", true end
      end
    end
  end
  spec.plots = plots
  spec.elevation = elevation
end

-- Rivers run along plot edges. An edge (a, b) continues to (a, c) or (b, c),
-- c being one of the two plots next to both; the walk prefers low ground and
-- ends at water, a mountain or after a few dozen edges.
local function Rivers(spec, scn, rng, biome)
  local plots, elevation = spec.plots, spec.elevation
  local rivers = {}
  local used = {}
  local function EdgeKey(a, b) if a > b then a, b = b, a end return a .. "_" .. b end
  local function Common(a, b)
    local set, list = {}, {}
    for _, n in ipairs(Neighbours(a)) do set[n] = true end
    for _, n in ipairs(Neighbours(b)) do
      if set[n] then list[#list + 1] = n end
    end
    return list
  end
  local center = Idx(math.floor(W / 2), math.floor(H / 2))
  for r = 1, biome.rivers do
    -- Source: a land plot on high ground (hills, near mountains); the first
    -- river starts near the middle, where the capital will be.
    local source, sourceE = nil, -1
    for _ = 1, 80 do
      local i = rng(W * H) - 1
      local p = plots[i + 1]
      local near = r > 1 or (Dist(i, center) >= 2 and Dist(i, center) <= 5)
      if near and IsLand(p) and not IsMountain(p) and elevation[i] > sourceE then
        local x, y = XY(i)
        if x > 1 and y > 1 and x < W - 2 and y < H - 2 then source, sourceE = i, elevation[i] end
      end
    end
    if source then
      local ns = Neighbours(source)
      local a, b = source, ns[rng(#ns)]
      local edges, prev = {}, nil
      local length = 0
      while length < 30 do
        if not IsLand(plots[a + 1]) or not IsLand(plots[b + 1]) then break end
        local key = EdgeKey(a, b)
        if used[key] then break end
        used[key] = true
        edges[#edges + 1] = { a, b }
        length = length + 1
        local options = {}
        for _, c in ipairs(Common(a, b)) do
          if c ~= prev then
            options[#options + 1] = { a, c, b }
            options[#options + 1] = { b, c, a }
          end
        end
        if #options == 0 then break end
        local best, bestScore = nil, 99
        for _, o in ipairs(options) do
          if not used[EdgeKey(o[1], o[2])] then
            local p1, p2 = plots[o[1] + 1], plots[o[2] + 1]
            local score = math.min(elevation[o[1]], elevation[o[2]]) + rng() * 0.08
            if IsMountain(p1) or IsMountain(p2) then score = score + 0.3 end
            if score < bestScore then best, bestScore = o, score end
          end
        end
        if best == nil then break end
        a, b, prev = best[1], best[2], best[3]
        if not IsLand(plots[a + 1]) or not IsLand(plots[b + 1]) then break end
      end
      if #edges >= 4 then rivers[#rivers + 1] = { name = "LOC_RIVER_CMP_" .. r, edges = edges, floodplains = {} } end
    end
  end
  -- Floodplains on flat, featureless river banks.
  local FLOOD = { TERRAIN_DESERT = "FEATURE_FLOODPLAINS", TERRAIN_GRASS = "FEATURE_FLOODPLAINS_GRASSLAND",
    TERRAIN_PLAINS = "FEATURE_FLOODPLAINS_PLAINS" }
  for _, river in ipairs(rivers) do
    local seen = {}
    for _, e in ipairs(river.edges) do
      for _, i in ipairs(e) do
        local p = plots[i + 1]
        if not seen[i] and IsFlat(p) and p.f == nil and FLOOD[p.t] and not p.flood and rng() < biome.flood then
          p.f, p.flood = FLOOD[p.t], true
          river.floodplains[#river.floodplains + 1] = i
        end
        seen[i] = true
      end
    end
  end
  spec.rivers = rivers
end

local function ValidFeatureTerrain(gi, feature, terrain)
  for row in gi.Feature_ValidTerrains({ FeatureType = feature }) do
    if row.TerrainType == terrain then return true end
  end
  return false
end

local function Features(spec, scn, rng, biome, gi)
  local plots = spec.plots
  local center = Idx(math.floor(W / 2), math.floor(H / 2))
  for i = 0, W * H - 1 do
    local p = plots[i + 1]
    if p.f == nil and IsLand(p) and not IsMountain(p) then
      local roll = rng()
      local woods = biome.woods * (0.6 + p.moist)
      if roll < biome.jungle and ValidFeatureTerrain(gi, "FEATURE_JUNGLE", p.t) then p.f = "FEATURE_JUNGLE"
      elseif roll < biome.jungle + woods and ValidFeatureTerrain(gi, "FEATURE_FOREST", p.t) then p.f = "FEATURE_FOREST"
      elseif roll < biome.jungle + woods + biome.marsh and ValidFeatureTerrain(gi, "FEATURE_MARSH", p.t) then p.f = "FEATURE_MARSH"
      elseif biome.oasis and roll > 1 - biome.oasis and p.t == "TERRAIN_DESERT" then p.f = "FEATURE_OASIS"
      elseif biome.fissure and roll > 1 - biome.fissure and IsFlat(p) then p.f = "FEATURE_GEOTHERMAL_FISSURE"
      end
    elseif p.t == "TERRAIN_COAST" and not p.lake and p.f == nil and rng() < (biome.reef or 0) then
      p.f = "FEATURE_REEF"
    end
  end
  -- Volcanoes on some mountains, volcanic soil around them.
  if biome.volcano then
    for i = 0, W * H - 1 do
      local p = plots[i + 1]
      if IsMountain(p) and p.f == nil and rng() < biome.volcano then
        p.f = "FEATURE_VOLCANO"
        for _, n in ipairs(Neighbours(i)) do
          local q = plots[n + 1]
          if IsFlat(q) and (q.f == nil or q.f == "FEATURE_FOREST") and rng() < 0.6 and q.t ~= "TERRAIN_DESERT" then
            q.f = "FEATURE_VOLCANIC_SOIL"
          end
        end
      end
    end
  end
  -- A natural wonder two or three tiles from the center.
  if scn.naturalWonder then
    local nw = scn.naturalWonder
    local best = nil
    for _, d in ipairs({ 2, 3 }) do
      for i = 0, W * H - 1 do
        if best == nil and Dist(i, center) == d and IsLand(plots[i + 1]) and not plots[i + 1].flood and rng() < 0.25 then best = i end
      end
    end
    if best then
      local p = plots[best + 1]
      if nw == "FEATURE_KILIMANJARO" or nw == "FEATURE_MATTERHORN" or nw == "FEATURE_EVEREST" then
        p.t = MOUNTAIN[BaseOf(p.t)] or "TERRAIN_GRASS_MOUNTAIN"
      else
        p.t = BaseOf(p.t)
      end
      p.f = nw
    end
  end
end

-- ===========================================================================
-- Resources and improvements
-- ===========================================================================
local function Resources(spec, scn, rng, gi)
  local plots = spec.plots
  local byTerrain, byFeature = {}, {}
  local classes = {}
  for row in gi.Resources() do classes[row.ResourceType] = row end
  for row in gi.Resource_ValidTerrains() do
    byTerrain[row.TerrainType] = byTerrain[row.TerrainType] or {}
    table.insert(byTerrain[row.TerrainType], row.ResourceType)
  end
  for row in gi.Resource_ValidFeatures() do
    byFeature[row.FeatureType] = byFeature[row.FeatureType] or {}
    table.insert(byFeature[row.FeatureType], row.ResourceType)
  end
  -- A few luxury types for this region, as the map script clumps them.
  local luxuries = {}
  for row in gi.Resources() do
    if row.ResourceClassType == "RESOURCECLASS_LUXURY" and (row.Frequency or 0) > 0 then luxuries[#luxuries + 1] = row.ResourceType end
  end
  local regional = {}
  for _ = 1, 4 do regional[luxuries[rng(#luxuries)]] = true end
  for i = 0, W * H - 1 do
    local p = plots[i + 1]
    if p.f == nil or not (gi.Features[p.f] and gi.Features[p.f].NaturalWonder) then
      local options = {}
      local source = {}
      for _, r in ipairs(p.f and byFeature[p.f] or {}) do source[#source + 1] = r end
      if p.f == nil or byFeature[p.f] == nil then
        for _, r in ipairs(byTerrain[p.t] or {}) do source[#source + 1] = r end
      end
      for _, r in ipairs(source) do
        local row = classes[r]
        local ok = row ~= nil and (row.Frequency or 0) + (row.SeaFrequency or 0) > 0
        if ok and row.ResourceClassType == "RESOURCECLASS_LUXURY" and not regional[r] then ok = false end
        if ok and row.ResourceClassType == "RESOURCECLASS_ARTIFACT" then ok = false end
        if ok and p.lake and not row.LakeEligible then ok = false end
        if ok then options[#options + 1] = r end
      end
      table.sort(options)
      if #options > 0 then
        local r = options[rng(#options)]
        local class = classes[r].ResourceClassType
        local chance = class == "RESOURCECLASS_BONUS" and 0.11 or class == "RESOURCECLASS_LUXURY" and 0.07 or 0.05
        if not IsLand(p) then chance = chance * 0.6 end
        if rng() < chance then
          p.r = r
          p.rc = class == "RESOURCECLASS_STRATEGIC" and 2 or 1
        end
      end
    end
  end
end

local function ImprovementFor(gi, p)
  if p.r then
    local list = {}
    for row in gi.Improvement_ValidResources({ ResourceType = p.r }) do
      local imp = gi.Improvements[row.ImprovementType]
      if imp and imp.TraitType == nil then list[#list + 1] = row.ImprovementType end
    end
    table.sort(list)
    for _, imp in ipairs(list) do
      if imp ~= "IMPROVEMENT_OFFSHORE_OIL_RIG" and imp ~= "IMPROVEMENT_OIL_WELL" then return imp end
    end
    return nil
  end
  return nil
end

-- ===========================================================================
-- Cities, ownership, districts, pins
-- ===========================================================================
local function SiteScore(spec, i, taken)
  local p = spec.plots[i + 1]
  if not IsLand(p) or IsMountain(p) then return -1 end
  if p.f and p.f ~= "FEATURE_FOREST" and p.f ~= "FEATURE_JUNGLE" and p.f ~= "FEATURE_MARSH"
      and p.f ~= "FEATURE_FLOODPLAINS" and p.f ~= "FEATURE_FLOODPLAINS_GRASSLAND" and p.f ~= "FEATURE_FLOODPLAINS_PLAINS" then
    return -1
  end
  for _, t in ipairs(taken) do
    if Dist(i, t) < 4 then return -1 end
  end
  local score = 1
  local land = 0
  for _, n in ipairs(Neighbours(i)) do
    local q = spec.plots[n + 1]
    if IsLand(q) then land = land + 1 end
    if q.lake then score = score + 2 end
  end
  if land < 3 then return -1 end
  if spec.riverPlots[i] then score = score + 3 end
  if IsHills(p) then score = score + 1 end
  return score + land * 0.2
end

local function Coastal(spec, i)
  for _, n in ipairs(Neighbours(i)) do
    local q = spec.plots[n + 1]
    if not IsLand(q) and not q.lake then return true end
  end
  return false
end

local function NearestSite(spec, from, minD, maxD, taken, rng, coastal)
  local best, bestScore = nil, -1
  for i = 0, W * H - 1 do
    local d = Dist(i, from)
    if d >= minD and d <= maxD and (not coastal or Coastal(spec, i)) then
      local x, y = XY(i)
      if x >= 2 and y >= 2 and x <= W - 3 and y <= H - 3 then
        local s = SiteScore(spec, i, taken)
        if s >= 0 then
          s = s + rng() * 1.5
          if s > bestScore then best, bestScore = i, s end
        end
      end
    end
  end
  return best
end

-- Districts a player of this civ builds instead of the base ones.
function CmpMapgen.UniqueFor(gi, civ, leader)
  local traits = {}
  for row in gi.CivilizationTraits({ CivilizationType = civ }) do traits[row.TraitType] = true end
  for row in gi.LeaderTraits({ LeaderType = leader }) do traits[row.TraitType] = true end
  local map = {}
  for row in gi.Districts() do
    if row.TraitType and traits[row.TraitType] then
      for rep in gi.DistrictReplaces({ CivUniqueDistrictType = row.DistrictType }) do
        map[rep.ReplacesDistrictType] = row.DistrictType
      end
    end
  end
  return map
end

local STAGES = {
  early = { population = 5, rings = 1, extra = 5, built = 0, improve = 0.3 },
  mid = { population = 11, rings = 2, extra = 7, built = 2, improve = 0.55 },
  late = { population = 19, rings = 3, extra = 0, built = 3, improve = 0.7 },
}
CmpMapgen.STAGES = STAGES

-- A plausible, not optimal, spot for a district a player built earlier.
local function BuiltSpot(spec, gi, city, districtType, rng, occupied)
  local row = gi.Districts[districtType]
  local list = {}
  for _, i in ipairs(city.plots) do
    local p = spec.plots[i + 1]
    local d = Dist(i, Idx(city.x, city.y))
    local ok = d >= 1 and d <= 3 and IsLand(p) and not IsMountain(p) and not occupied[i] and not p.lake
    if ok and p.f and gi.Features[p.f] and not gi.Features[p.f].Removable then ok = false end
    if ok and p.r and gi.Resources[p.r].ResourceClassType ~= "RESOURCECLASS_BONUS" then ok = false end
    if ok and row.NoAdjacentCity and d == 1 then ok = false end
    if ok and row.Aqueduct then ok = false end
    if ok then list[#list + 1] = i end
  end
  if #list == 0 then return nil end
  return list[rng(#list)]
end

function CmpMapgen.Generate(scn)
  local gi = CmpGame.LoadGameInfo()
  local rng = Rng(scn.seed)
  local biome = BIOMES[scn.biome] or error("unknown biome " .. tostring(scn.biome))
  local spec = { width = W, height = H, turn = scn.turn or 120 }
  Terrain(spec, scn, rng, biome)
  Rivers(spec, scn, rng, biome)
  spec.riverPlots = {}
  for _, r in ipairs(spec.rivers) do
    for _, e in ipairs(r.edges) do
      spec.riverPlots[e[1]], spec.riverPlots[e[2]] = true, true
    end
  end
  Features(spec, scn, rng, biome, gi)
  Resources(spec, scn, rng, gi)

  local stage = STAGES[scn.stage or "mid"]
  spec.players = {
    { id = 0, civ = scn.civ, leader = scn.leader, techs = "all", civics = "all", pantheon = scn.pantheon, era = scn.era },
  }
  local cities = {}
  local center = Idx(math.floor(W / 2), math.floor(H / 2))
  local taken = {}
  -- Coastal and island games: the capital is on the coast (Harbor, Indonesia).
  local seaside = scn.biome == "coastal" or scn.biome == "island"
  local capital = (seaside and NearestSite(spec, center, 0, 8, taken, rng, true))
    or NearestSite(spec, center, 0, 3, taken, rng) or center
  taken[#taken + 1] = capital
  local own = { capital }
  for c = 2, scn.cities or 1 do
    local site = NearestSite(spec, own[1], 4, 6, taken, rng) or NearestSite(spec, own[#own], 4, 7, taken, rng)
    if site then
      taken[#taken + 1] = site
      own[#own + 1] = site
    end
  end
  for n, site in ipairs(own) do
    local x, y = XY(site)
    local population = scn.population or stage.population
    if n > 1 and not scn.samePopulation then population = math.max(4, population - 3 * (n - 1)) end
    cities[#cities + 1] = { id = 65536 + n - 1, owner = 0, x = x, y = y, name = "CITY_" .. n, population = population,
      capital = n == 1, plots = {}, districts = {}, buildings = {} }
  end
  if scn.foreign then
    spec.players[#spec.players + 1] = { id = 1, civ = "CIVILIZATION_PERSIA", leader = "LEADER_CYRUS", techs = "all", civics = "all" }
    local site = NearestSite(spec, own[1], 6, 7, taken, rng)
    if site then
      taken[#taken + 1] = site
      local x, y = XY(site)
      cities[#cities + 1] = { id = 131072, owner = 1, x = x, y = y, name = "FOREIGN", population = 9, capital = true,
        plots = {}, districts = {}, buildings = {} }
    end
  end
  if scn.cityState then
    spec.players[#spec.players + 1] = { id = 62, civ = "CIVILIZATION_KABUL", leader = "LEADER_MINOR_CIV_KABUL", minor = true }
    local site = NearestSite(spec, own[1], 5, 7, taken, rng)
    if site then
      taken[#taken + 1] = site
      local x, y = XY(site)
      cities[#cities + 1] = { id = 196608, owner = 62, x = x, y = y, name = "CITY_STATE", population = 4, capital = true,
        plots = {}, districts = {}, buildings = {} }
    end
  end

  -- Tiles each city owns at this stage; a tile goes to the nearest city.
  local claimed = {}
  for _, c in ipairs(cities) do claimed[Idx(c.x, c.y)] = c end
  local order = {}
  for _, c in ipairs(cities) do
    local cIdx = Idx(c.x, c.y)
    local rings = c.owner == 0 and stage.rings or 2
    local candidates = {}
    for i = 0, W * H - 1 do
      local d = Dist(i, cIdx)
      if d >= 1 and d <= 3 then candidates[#candidates + 1] = { i = i, d = d, roll = rng() } end
    end
    table.sort(candidates, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      return a.roll < b.roll
    end)
    local extra = c.owner == 0 and stage.extra or 4
    for _, cand in ipairs(candidates) do
      local nearest = true
      for _, o in ipairs(cities) do
        if o ~= c and Dist(cand.i, Idx(o.x, o.y)) < cand.d then nearest = false end
      end
      if nearest and claimed[cand.i] == nil then
        if cand.d <= rings then
          claimed[cand.i] = c
        elseif extra > 0 then
          claimed[cand.i] = c
          extra = extra - 1
        end
      end
    end
    order[#order + 1] = c
  end
  for i = 0, W * H - 1 do
    local c = claimed[i]
    if c and Idx(c.x, c.y) ~= i then c.plots[#c.plots + 1] = i end
  end

  -- Districts built earlier (a player's, not an optimizer's choices).
  local unique = CmpMapgen.UniqueFor(gi, scn.civ, scn.leader)
  local occupied = {}
  for _, c in ipairs(cities) do occupied[Idx(c.x, c.y)] = true end
  local builtLists = scn.built or {}
  for n, c in ipairs(cities) do
    local list = builtLists[n]
    if list == nil and c.owner == 0 then
      list = {}
      local pool = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }
      for k = 1, math.max(0, stage.built - (n - 1)) do list[#list + 1] = pool[((scn.seed + n + k) % #pool) + 1] end
    elseif list == nil then
      list = { "DISTRICT_CAMPUS" }
    end
    for _, base in ipairs(list) do
      local dt = c.owner == 0 and (unique[base] or base) or base
      local skip = false
      for _, d in ipairs(c.districts) do
        if d.type == dt then skip = true end
      end
      for _, req in ipairs(scn.districts or {}) do
        if c.owner == 0 and n == 1 and (unique[req] or req) == dt then skip = true end
      end
      if not skip then
        local spot = BuiltSpot(spec, gi, c, dt, rng, occupied)
        if spot then
          local x, y = XY(spot)
          c.districts[#c.districts + 1] = { type = dt, x = x, y = y }
          occupied[spot] = true
        end
      end
    end
  end

  -- Improvements on owned tiles.
  for _, c in ipairs(cities) do
    for _, i in ipairs(c.plots) do
      local p = spec.plots[i + 1]
      if not occupied[i] and IsLand(p) and not IsMountain(p) and rng() < stage.improve then
        local imp = ImprovementFor(gi, p)
        if imp == nil and p.f == nil and IsHills(p) and rng() < 0.45 then imp = "IMPROVEMENT_MINE" end
        if imp == nil and (p.f == nil or p.flood) and IsFlat(p) and p.t ~= "TERRAIN_SNOW" and rng() < 0.6 then
          imp = "IMPROVEMENT_FARM"
          if p.t == "TERRAIN_DESERT" and not p.flood then imp = nil end
        end
        if imp == nil and p.f == "FEATURE_FOREST" and scn.stage == "late" and rng() < 0.3 then imp = "IMPROVEMENT_LUMBER_MILL" end
        if imp then p.imp = imp end
      end
    end
  end

  -- The player's own pins (plans made by hand earlier).
  spec.pins = {}
  for _, pin in ipairs(scn.pins or {}) do
    local c = cities[pin.city or 1]
    local cIdx = Idx(c.x, c.y)
    local best = nil
    for _, i in ipairs(c.plots) do
      local p = spec.plots[i + 1]
      local d = Dist(i, cIdx)
      if best == nil and d == (pin.ring or 2) and IsLand(p) and not IsMountain(p) and not occupied[i] and p.r == nil
          and (p.f == nil or p.f == "FEATURE_FOREST" or p.f == "FEATURE_JUNGLE") then
        best = i
      end
    end
    if best then
      local x, y = XY(best)
      local icon = pin.icon
      if icon:find("^ICON_DISTRICT_") then
        local dt = icon:gsub("^ICON_", "")
        icon = "ICON_" .. (unique[dt] or dt)
      end
      spec.pins[#spec.pins + 1] = { x = x, y = y, icon = icon, name = pin.name or "" }
      occupied[best] = true
    end
  end

  -- Wonders built earlier.
  spec.wonders = {}
  for _, b in ipairs(scn.wonders or {}) do
    local c = cities[1]
    for _, i in ipairs(c.plots) do
      local p = spec.plots[i + 1]
      if not occupied[i] and IsFlat(p) and p.r == nil and p.f == nil and Dist(i, Idx(c.x, c.y)) == 2 and #spec.wonders == 0 then
        local x, y = XY(i)
        spec.wonders[#spec.wonders + 1] = { x = x, y = y, building = b, city = c.id }
        occupied[i] = true
        p.imp = nil
      end
    end
  end

  -- Camp resources near the first city, no camp built near it (issue 51:
  -- the Temple of Artemis scenes, scn.campResources tiles two or three
  -- rings out). Only these scenes draw from the generator here.
  if scn.campResources then
    local camp = {}
    for row in gi.Improvement_ValidResources() do
      if row.ImprovementType == "IMPROVEMENT_CAMP" then camp[#camp + 1] = row.ResourceType end
    end
    table.sort(camp)
    local function Fits(r, p)
      if p.f ~= nil then
        for row in gi.Resource_ValidFeatures({ ResourceType = r }) do
          if row.FeatureType == p.f then return true end
        end
        return false
      end
      for row in gi.Resource_ValidTerrains({ ResourceType = r }) do
        if row.TerrainType == p.t then return true end
      end
      return false
    end
    local c = cities[1]
    local cIdx = Idx(c.x, c.y)
    for i = 0, W * H - 1 do
      local p = spec.plots[i + 1]
      if p.imp == "IMPROVEMENT_CAMP" and Dist(i, cIdx) <= 5 then p.imp = nil end
    end
    local placed = 0
    for i = 0, W * H - 1 do
      local p = spec.plots[i + 1]
      local d = Dist(i, cIdx)
      if placed < scn.campResources and (d == 2 or d == 3) and IsLand(p) and not IsMountain(p) and not occupied[i]
          and p.r == nil and p.imp == nil and not (p.f and gi.Features[p.f] and gi.Features[p.f].NaturalWonder) then
        local options = {}
        for _, r in ipairs(camp) do
          if Fits(r, p) then options[#options + 1] = r end
        end
        if #options > 0 and rng() < 0.3 then
          p.r = options[rng(#options)]
          p.rc = 1
          placed = placed + 1
        end
      end
    end
  end

  -- Unexplored tiles: far tiles the player has not seen yet.
  if scn.hidden then
    for i = 0, W * H - 1 do
      local d = Dist(i, Idx(cities[1].x, cities[1].y))
      if d >= 3 and rng() < scn.hidden * (d - 2) / 3 then spec.plots[i + 1].hidden = true end
    end
  end

  for _, c in ipairs(cities) do
    for _, d in ipairs(c.districts) do spec.plots[Idx(d.x, d.y) + 1].imp = nil end
  end
  spec.cities = cities
  spec.elevation = nil
  spec.riverPlots = nil
  for _, p in ipairs(spec.plots) do p.moist, p.flood = nil, nil end
  return spec
end

return CmpMapgen
