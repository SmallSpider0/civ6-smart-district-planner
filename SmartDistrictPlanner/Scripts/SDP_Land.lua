-- SDP_Land: the "land part" of the objective (docs/multicity-design.md 4.2):
-- what the plots districts and wonders take would otherwise give the city.
--
-- A city works its best P plots. A plot taken by a district or wonder cannot
-- be worked, and building on it clears its removable feature (woods,
-- rainforest, marsh) and its bonus resource, so their one-time yields
-- (Feature_Removes, Resource_Harvests) are lost too.
--   land score = weighted yields of the best P free plots
--              + sum over free plots of their one-time yields
--                / HARVEST_TURNS * feature weight
-- Taking a plot among the best P therefore costs its value minus that of the
-- (P+1)-th best plot, not its whole value; taking a plot the city would not
-- work costs only its one-time yields.
-- Everything is read from GameInfo and the plots at run time.

SDP_Land = {}

SDP_Land.TILE_YIELDS = { "YIELD_FOOD", "YIELD_PRODUCTION", "YIELD_GOLD", "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH" }
SDP_Land.HARVEST_TURNS = 20 -- one-time yields count as this many turns of yield

-- Plots of a city scan (SDP_City.EXCLUDED reasons) that can still be worked.
local WORKABLE_EXCLUSIONS = { FEATURE = true, NATURAL_WONDER = true, PIN = true, RESOURCE = true }

-- Weights for the land part: the six tile yields (missing ones weigh 1) and
-- FEATURE, the weight of one-time yields (default 1).
function SDP_Land.Weights(weights)
  local out = {}
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    local w = weights and weights[yieldType]
    out[yieldType] = (w == nil) and 1 or w
  end
  local feature = weights and weights.FEATURE
  out.FEATURE = (feature == nil) and 1 or feature
  return out
end

-- Population that unlocks `specialty` specialty districts: the inverse of
-- SDP_City.SpecialtyCapacity (1 + floor((pop - 1) / 3)).
function SDP_Land.RequiredPopulation(specialty)
  return math.max(1, 3 * specialty - 2)
end

-- One-time yields of clearing each removable feature and harvesting each
-- resource: { Features = { [FeatureType] = { [yield] = n } }, Resources = ... }.
function SDP_Land.OneTimeYields()
  local out = { Features = {}, Resources = {} }
  for row in GameInfo.Feature_Removes() do
    local t = out.Features[row.FeatureType] or {}
    t[row.YieldType] = (t[row.YieldType] or 0) + row.Yield
    out.Features[row.FeatureType] = t
  end
  for row in GameInfo.Resource_Harvests() do
    local t = out.Resources[row.ResourceType] or {}
    t[row.YieldType] = (t[row.YieldType] or 0) + row.Amount
    out.Resources[row.ResourceType] = t
  end
  return out
end

local function Weighted(yields, w)
  local total = 0
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do total = total + (w[yieldType] or 0) * (yields[yieldType] or 0) end
  return total
end

-- A plot's tile value (weighted yields) and one-time value. `oneTime` from
-- OneTimeYields, `w` from Weights.
function SDP_Land.PlotValues(plot, w, oneTime)
  local tile = 0
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    local weight = w[yieldType]
    if weight ~= 0 then tile = tile + weight * plot:GetYield(GameInfo.Yields[yieldType].Index) end
  end
  local once = 0
  if w.FEATURE ~= 0 then
    local feature = plot:GetFeatureType()
    if feature ~= -1 then
      local row = GameInfo.Features[feature]
      if row.Removable and oneTime.Features[row.FeatureType] then once = once + Weighted(oneTime.Features[row.FeatureType], w) end
    end
    local resource = plot:GetResourceType()
    if resource ~= -1 then
      local row = GameInfo.Resources[resource]
      if oneTime.Resources[row.ResourceType] then once = once + Weighted(oneTime.Resources[row.ResourceType], w) end
    end
    once = once * w.FEATURE / SDP_Land.HARVEST_TURNS
  end
  return tile, once
end

-- Land model of one city. plots: { Index, Tile, Once } for every plot it
-- can work. Returns { Plots (best tile first, ties by plot index), P, Base,
-- Loss = { [plot index] = what taking that plot alone costs } }.
function SDP_Land.Model(plots, population)
  local sorted = {}
  for i, p in ipairs(plots) do sorted[i] = { Index = p.Index, Tile = p.Tile, Once = p.Once } end
  table.sort(sorted, function(a, b)
    if a.Tile ~= b.Tile then return a.Tile > b.Tile end
    return a.Index < b.Index
  end)
  local model = { Plots = sorted, P = math.max(0, math.min(population, #sorted)), Loss = {}, ByIndex = {} }
  local next = sorted[model.P + 1]
  local cut = next and next.Tile or 0
  for rank, p in ipairs(sorted) do
    model.ByIndex[p.Index] = p
    model.Loss[p.Index] = (rank <= model.P and (p.Tile - cut) or 0) + p.Once
  end
  local once = 0
  for _, p in ipairs(sorted) do once = once + p.Once end
  model.OnceTotal = once
  model.Base = SDP_Land.ScoreTaken(model, {}, 0, {})
  return model
end

-- Land score with the plots taken[1..count] (plot indices, any plots) built
-- on. `mark` is a scratch table, left empty. The solvers call this for every
-- layout they try, so it only walks the best plots until P are found.
-- `boost` (optional): { [plot index] = extra tile value } (a preserve's
-- yields on the plots around it, SDP_Appeal); a boosted plot is worked when
-- its raised value is among the best P.
function SDP_Land.ScoreTaken(model, taken, count, mark, boost)
  for t = 1, count do mark[taken[t]] = true end
  local worked, used = 0, 0
  if boost == nil then
    for _, p in ipairs(model.Plots) do
      if used >= model.P then break end
      if not mark[p.Index] then
        worked = worked + p.Tile
        used = used + 1
      end
    end
  else
    -- The boosted plots (few) best first, merged into the walk over the rest.
    local raised = {}
    for index, extra in pairs(boost) do
      local p = model.ByIndex[index]
      if p ~= nil and not mark[index] then raised[#raised + 1] = { Index = index, Tile = p.Tile + extra } end
    end
    table.sort(raised, function(a, b)
      if a.Tile ~= b.Tile then return a.Tile > b.Tile end
      return a.Index < b.Index
    end)
    local r = 1
    for _, p in ipairs(model.Plots) do
      if used >= model.P then break end
      if not mark[p.Index] and boost[p.Index] == nil then
        while used < model.P and raised[r] ~= nil
            and (raised[r].Tile > p.Tile or (raised[r].Tile == p.Tile and raised[r].Index < p.Index)) do
          worked, used, r = worked + raised[r].Tile, used + 1, r + 1
        end
        if used < model.P then
          worked = worked + p.Tile
          used = used + 1
        end
      end
    end
    while used < model.P and raised[r] ~= nil do
      worked, used, r = worked + raised[r].Tile, used + 1, r + 1
    end
  end
  local once = model.OnceTotal
  for t = 1, count do
    local p = model.ByIndex[taken[t]]
    if p ~= nil and mark[taken[t]] then once = once - p.Once end
    mark[taken[t]] = nil
  end
  return worked + once
end

-- Land score with the plots in `taken` ({ [plot index] = true }) built on.
function SDP_Land.Score(model, taken)
  local worked, count, once = 0, 0, 0
  for _, p in ipairs(model.Plots) do
    if not taken[p.Index] then
      if count < model.P then
        worked = worked + p.Tile
        count = count + 1
      end
      once = once + p.Once
    end
  end
  return worked + once
end

-- Plot indices a city scan can work (see ForScan), sorted.
function SDP_Land.Workable(scan)
  local list = {}
  for _, c in ipairs(scan.Candidates) do list[#list + 1] = c.Index end
  for index, reason in pairs(scan.Excluded) do
    if WORKABLE_EXCLUSIONS[reason] then list[#list + 1] = index end
  end
  table.sort(list)
  return list
end

-- Land model for a single-city scan. Workable: free candidates plus plots
-- excluded only for reasons that do not stop working them (a feature the
-- player keeps, a natural wonder, a pin that is not a district or wonder).
-- `fixed` are SDP_Overlay.FixedSubjects (their plots are taken). `keep`
-- (optional) says which plots this city works when several cities could:
-- keep(plot index) -> bool.
function SDP_Land.ForScan(scan, fixed, weights, population, keep)
  local w = SDP_Land.Weights(weights)
  local oneTime = SDP_Land.OneTimeYields()
  local taken = {}
  for _, subject in ipairs(fixed) do
    if subject.Type == "DISTRICT" or subject.Type == "WONDER" then taken[Map.GetPlotIndex(subject.X, subject.Y)] = true end
  end
  local plots = {}
  local function Add(index)
    if not taken[index] and (keep == nil or keep(index)) then
      local tile, once = SDP_Land.PlotValues(Map.GetPlotByIndex(index), w, oneTime)
      plots[#plots + 1] = { Index = index, Tile = tile, Once = once }
    end
  end
  for _, c in ipairs(scan.Candidates) do Add(c.Index) end
  local excluded = {}
  for index, reason in pairs(scan.Excluded) do
    if WORKABLE_EXCLUSIONS[reason] then excluded[#excluded + 1] = index end
  end
  table.sort(excluded)
  for _, index in ipairs(excluded) do Add(index) end
  return SDP_Land.Model(plots, population)
end
