-- SDP_Land: the "land part" of the objective (docs/multicity-design.md 4.2):
-- what the plots districts and wonders take would otherwise give the city.
--
-- A city works its best P plots. A plot taken by a district or wonder cannot
-- be worked. A plot's value is what it gives once improved (issue 52): the
-- best improvement the rules allow there (Improvement_Valid*, its
-- Improvement_YieldChanges and the bonuses of technologies and civics the
-- player has), with its removable feature and harvestable bonus resource
-- kept or removed, whichever is worth more. Removing them gives one-time
-- yields (Feature_Removes, Resource_Harvests, divided by HARVEST_TURNS,
-- weighed by FEATURE and grown with the game's progress), and players
-- remove them before building a district there, so building does not lose
-- them: a plot kept as it is forgoes them instead.
--   value(plot) = max over keeping or removing its feature and resource of
--                 its yields then + the best improvement's - what is kept's
--                 one-time yields
--   land score  = weighted values of the best P free plots
-- Taking a plot among the best P therefore costs its value minus that of the
-- (P+1)-th best plot, not its whole value; taking a plot the city would not
-- work costs nothing.
-- Everything is read from GameInfo and the plots at run time.

SDP_Land = {}

SDP_Land.TILE_YIELDS = { "YIELD_FOOD", "YIELD_PRODUCTION", "YIELD_GOLD", "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH" }
SDP_Land.HARVEST_TURNS = 20 -- one-time yields count as this many turns of yield

-- Plots of a city scan (SDP_City.EXCLUDED reasons) that can still be worked.
local WORKABLE_EXCLUSIONS = { FEATURE = true, NATURAL_WONDER = true, PIN = true, RESOURCE = true }

-- What a plot's yields are worth in the district planner's land part (issue
-- 53, the maintainer's choice of 2026-10-25): fixed, apart from the
-- player's yield weights, which weigh the districts' adjacency only. From
-- another planner's weighted-output setting (food 12, production 12, gold 3,
-- science 10, culture 10, faith 6) with food and production as 1; gold and
-- faith match the purchase prices (1 production = 4 gold = 2 faith,
-- GOLD_PURCHASE_MULTIPLIER, GOLD_EQUIVALENT_OTHER_YIELDS). One-time yields of
-- clearing and harvesting are weighed by the same numbers (FEATURE 1).
SDP_Land.PLOT_WEIGHTS = { YIELD_FOOD = 1, YIELD_PRODUCTION = 1, YIELD_GOLD = 1 / 4, YIELD_SCIENCE = 5 / 6,
  YIELD_CULTURE = 5 / 6, YIELD_FAITH = 1 / 2, FEATURE = 1 }

-- The player's one land weight (the request's Weights.LAND, default 1; 0:
-- the land part is off) scales the whole land part (issue 53, decided
-- 2026-10-25): PLOT_WEIGHTS times it, so the one-time yields scale too.
function SDP_Land.Scale(weights)
  local scale = weights and weights.LAND
  if scale == nil then scale = 1 end
  return scale
end

function SDP_Land.PlotWeights(scale)
  local out = {}
  for key, value in pairs(SDP_Land.PLOT_WEIGHTS) do out[key] = value end
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do out[yieldType] = out[yieldType] * (scale or 1) end
  return out
end

-- Weights for valuing plots: the six tile yields (missing ones weigh 1) and
-- FEATURE, the weight of one-time yields (default 1). The district planner
-- passes PLOT_WEIGHTS times its land weight; the site scores PLOT_WEIGHTS
-- times the sites tab's weights (SDP_Sites.PlotWeights).
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

-- Rules of the improvements a worked plot may get, read once per GameInfo:
-- { Improvements = { { Index, Sea, Terrains, Features, Resources = { [type] = must remove the feature },
--   Yields = { [yield] = n }, Bonus = { { Yield, Change, Tech, Civic } } } },
--   FeatureYields, ResourceYields = { [type] = { [yield] = n } } }.
-- Only improvements every player can build (Buildable, no TraitType, not
-- needing a river or adjacent resources) that give yields.
local m_rules, m_rulesFor = nil, nil
-- Rule columns that are yes/no: some are numbers in the game's database
-- (Improvements.RequiresRiver is 0 or 1, and `not 0` is false in Lua).
local function Flag(v) return v == true or (type(v) == "number" and v ~= 0) end
local function ImprovementRules()
  if m_rules ~= nil and m_rulesFor == GameInfo then return m_rules end
  local rules = { Improvements = {}, FeatureYields = {}, ResourceYields = {} }
  local function Rows(name) return GameInfo[name] ~= nil and GameInfo[name]() or function() return nil end end
  local byType = {}
  for row in Rows("Improvements") do
    if Flag(row.Buildable) and row.TraitType == nil and not Flag(row.RequiresRiver) and not Flag(row.RequiresAdjacentBonusOrLuxury)
        and not Flag(row.RequiresAdjacentLuxury) and (row.ValidAdjacentTerrainAmount or 0) == 0
        and (row.Workable == nil or Flag(row.Workable)) then
      local entry = { Type = row.ImprovementType, Index = row.Index, Sea = row.Domain == "DOMAIN_SEA", Terrains = {}, Features = {}, Resources = {},
        Yields = {}, Bonus = {}, Any = false }
      byType[row.ImprovementType] = entry
    end
  end
  for row in Rows("Improvement_YieldChanges") do
    local entry = byType[row.ImprovementType]
    if entry ~= nil and (row.YieldChange or 0) ~= 0 then
      entry.Yields[row.YieldType] = (entry.Yields[row.YieldType] or 0) + row.YieldChange
      entry.Any = true
    end
  end
  for row in Rows("Improvement_BonusYieldChanges") do
    local entry = byType[row.ImprovementType]
    if entry ~= nil then
      entry.Bonus[#entry.Bonus + 1] = { Yield = row.YieldType, Change = row.BonusYieldChange or 0, Tech = row.PrereqTech,
        Civic = row.PrereqCivic }
    end
  end
  for row in Rows("Improvement_ValidTerrains") do
    local entry = byType[row.ImprovementType]
    if entry ~= nil then entry.Terrains[row.TerrainType] = true end
  end
  for row in Rows("Improvement_ValidFeatures") do
    local entry = byType[row.ImprovementType]
    if entry ~= nil then entry.Features[row.FeatureType] = true end
  end
  for row in Rows("Improvement_ValidResources") do
    local entry = byType[row.ImprovementType]
    if entry ~= nil then entry.Resources[row.ResourceType] = Flag(row.MustRemoveFeature) end
  end
  local names = {}
  for name in pairs(byType) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if byType[name].Any then rules.Improvements[#rules.Improvements + 1] = byType[name] end
  end
  for row in Rows("Feature_YieldChanges") do
    local t = rules.FeatureYields[row.FeatureType] or {}
    t[row.YieldType] = (t[row.YieldType] or 0) + row.YieldChange
    rules.FeatureYields[row.FeatureType] = t
  end
  for row in Rows("Resource_YieldChanges") do
    local t = rules.ResourceYields[row.ResourceType] or {}
    t[row.YieldType] = (t[row.YieldType] or 0) + row.YieldChange
    rules.ResourceYields[row.ResourceType] = t
  end
  m_rules, m_rulesFor = rules, GameInfo
  return rules
end

-- Whether the player's traits forbid harvesting resources (Maori), read from
-- the trait modifiers.
local function HarvestPrevented(playerID)
  if playerID == nil or MapTacks == nil or MapTacks.PlayerTraits == nil or GameInfo.TraitModifiers == nil
      or GameInfo.Modifiers == nil then
    return false
  end
  local traits = MapTacks.PlayerTraits(playerID) or {}
  for row in GameInfo.TraitModifiers() do
    if traits[row.TraitType] then
      local modifier = GameInfo.Modifiers[row.ModifierId]
      if modifier ~= nil and modifier.ModifierType == "MODIFIER_PLAYER_ADJUST_PREVENT_HARVEST_RESOURCE" then return true end
    end
  end
  return false
end

-- How far the player is through the technology and civic trees, 0..1 (the
-- larger): one-time yields of removing a feature or harvesting grow with it.
local function Progress(playerID)
  local player = playerID ~= nil and Players[playerID] or nil
  if player == nil then return 0 end
  local function Share(tableName, has)
    local total, done = 0, 0
    if GameInfo[tableName] == nil or has == nil then return 0 end
    for row in GameInfo[tableName]() do
      total = total + 1
      if has(row.Index) then done = done + 1 end
    end
    return total > 0 and done / total or 0
  end
  local techs = player.GetTechs ~= nil and player:GetTechs() or nil
  local culture = player.GetCulture ~= nil and player:GetCulture() or nil
  return math.max(Share("Technologies", techs and function(i) return techs:HasTech(i) end),
    Share("Civics", culture and function(i) return culture:HasCivic(i) end))
end

-- How much one-time yields have grown for the player: 1 at the start,
-- 1 + ONE_TIME_GROWTH with every technology or civic.
function SDP_Land.Growth(playerID)
  return 1 + SDP_Land.ONE_TIME_GROWTH * Progress(playerID)
end

-- What the land part needs to value plots for one player (issue 52):
--   W              SDP_Land.Weights(weights)
--   OnceW          what one-time yields weigh: options.OnceWeights (the
--                  city sites tab, issue 88: without its land weight), else W
--   Turns          one-time yields count as this many turns of yield:
--                  options.Turns, else HARVEST_TURNS
--   AllowRemoval   whether districts may clear features (constraint 5; when
--                  not, a featured plot keeps its feature)
-- plus the rules, the player's technologies and civics for improvement
-- bonuses, which resources the player sees and whether it may harvest.
-- One-time yields grow with progress: x (1 + ONE_TIME_GROWTH x progress).
SDP_Land.ONE_TIME_GROWTH = 9
function SDP_Land.Context(playerID, weights, allowRemoval, options)
  options = options or {}
  local ctx = { W = SDP_Land.Weights(weights), AllowRemoval = allowRemoval ~= false, OneTime = SDP_Land.OneTimeYields(),
    Rules = ImprovementRules(), PlayerID = playerID, Turns = options.Turns or SDP_Land.HARVEST_TURNS }
  ctx.OnceW = options.OnceWeights ~= nil and SDP_Land.Weights(options.OnceWeights) or ctx.W
  ctx.Growth = SDP_Land.Growth(playerID)
  ctx.Harvest = not HarvestPrevented(playerID)
  local player = playerID ~= nil and Players[playerID] or nil
  local techs = player ~= nil and player.GetTechs ~= nil and player:GetTechs() or nil
  local culture = player ~= nil and player.GetCulture ~= nil and player:GetCulture() or nil
  local resources = player ~= nil and player.GetResources ~= nil and player:GetResources() or nil
  ctx.Visible = function(row)
    if resources == nil or resources.IsResourceVisible == nil then return true end
    return resources:IsResourceVisible(row.Hash)
  end
  -- Weighted gain of each improvement, bonuses of what the player has.
  ctx.Gain = {}
  for _, entry in ipairs(ctx.Rules.Improvements) do
    local gain = Weighted(entry.Yields, ctx.W)
    for _, b in ipairs(entry.Bonus) do
      local tech = b.Tech and GameInfo.Technologies[b.Tech] or nil
      local civic = b.Civic and GameInfo.Civics[b.Civic] or nil
      local has = (b.Tech == nil or (tech ~= nil and techs ~= nil and techs:HasTech(tech.Index)))
        and (b.Civic == nil or (civic ~= nil and culture ~= nil and culture:HasCivic(civic.Index)))
      if has then gain = gain + (ctx.W[b.Yield] or 0) * b.Change end
    end
    ctx.Gain[entry] = gain
  end
  return ctx
end

-- The improvements that can go on a plot of terrain `terrain` (type),
-- feature `feature` and resource `resource` (types or nil) in the sea or on
-- land (entries of the rules). A resource with improvements of its own
-- takes only those (Improvement_ValidResources).
function SDP_Land.ValidImprovements(ctx, sea, terrain, feature, resource)
  local list, own = {}, false
  if resource ~= nil then
    for _, entry in ipairs(ctx.Rules.Improvements) do
      local must = entry.Resources[resource]
      if must ~= nil then
        own = true
        if entry.Sea == sea and not (must and feature ~= nil) then list[#list + 1] = entry end
      end
    end
    if own then return list end
  end
  for _, entry in ipairs(ctx.Rules.Improvements) do
    if entry.Sea == sea then
      local valid
      if feature ~= nil then valid = entry.Features[feature] == true else valid = entry.Terrains[terrain] == true end
      if valid then list[#list + 1] = entry end
    end
  end
  return list
end

-- Plots no improvement can go on whatever is removed (measured against
-- ImprovementBuilder.CanHaveImprovement on a late save, 2026-10-23): coastal
-- lowland the sea has flooded (Gathering Storm) and antiquity sites (a
-- resource of the artifact class, excavated, never improved).
local function Unimprovable(plot, resourceRow)
  if resourceRow ~= nil and resourceRow.ResourceClassType == "RESOURCECLASS_ARTIFACT" then return true end
  if TerrainManager ~= nil and TerrainManager.GetCoastalLowlandType ~= nil and TerrainManager.IsFlooded ~= nil then
    return TerrainManager.GetCoastalLowlandType(plot) ~= -1 and TerrainManager.IsFlooded(plot) == true
  end
  return false
end

-- Best weighted gain of those; 0 when none applies.
local function BestImprovement(ctx, sea, terrain, feature, resource)
  local best = 0
  for _, entry in ipairs(SDP_Land.ValidImprovements(ctx, sea, terrain, feature, resource)) do
    best = math.max(best, ctx.Gain[entry])
  end
  return best
end

-- A plot's value, its one-time value (what removing its feature and
-- harvesting its resource would give, weighted, per turn), its value
-- left unimproved with its feature kept (issue 91: a preserve's grove and
-- sanctuary give yields only to unimproved plots, so a plot next to one is
-- worth the better of its improved value and this plus those yields) and
-- the part of the one-time value its best use forgoes (what it keeps: its
-- value is already lowered by it; issue 88). `ctx` from SDP_Land.Context.
function SDP_Land.PlotValues(plot, ctx)
  local w, rules = ctx.W, ctx.Rules
  local now = 0
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    local weight = w[yieldType]
    if weight ~= 0 then now = now + weight * plot:GetYield(GameInfo.Yields[yieldType].Index) end
  end
  local featureRow = plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()] or nil
  local resourceRow = plot:GetResourceType() ~= -1 and GameInfo.Resources[plot:GetResourceType()] or nil
  -- A resource the player cannot see: its yields are not the player's to plan on.
  if resourceRow ~= nil and not ctx.Visible(resourceRow) then
    now = now - Weighted(rules.ResourceYields[resourceRow.ResourceType] or {}, w)
    resourceRow = nil
  end
  local scale = w.FEATURE * ctx.Growth / ctx.Turns
  local feature, featureOnce, removable = nil, 0, false
  if featureRow ~= nil then
    feature = featureRow.FeatureType
    -- With removal off (constraint 5) the player keeps features.
    if featureRow.Removable and ctx.AllowRemoval then
      removable = true
      featureOnce = Weighted(ctx.OneTime.Features[feature] or {}, ctx.OnceW) * scale
    end
  end
  local resource, resourceOnce, harvestable = nil, 0, false
  if resourceRow ~= nil then
    resource = resourceRow.ResourceType
    if ctx.OneTime.Resources[resource] ~= nil and ctx.Harvest then
      harvestable = true
      resourceOnce = Weighted(ctx.OneTime.Resources[resource], ctx.OnceW) * scale
    end
  end
  local improved = plot:GetImprovementType() ~= -1
  if improved or Unimprovable(plot, resourceRow) then
    -- The game's yields include the improvement (removing or harvesting
    -- would undo it), or none can go there.
    return now, featureOnce + resourceOnce, now, 0
  end
  local sea = plot:IsWater()
  local terrain = GameInfo.Terrains[plot:GetTerrainType()].TerrainType
  local featureYield = feature ~= nil and Weighted(rules.FeatureYields[feature] or {}, w) or 0
  local resourceYield = resource ~= nil and Weighted(rules.ResourceYields[resource] or {}, w) or 0
  local best, bare, forgone = nil, nil, 0
  for _, removeFeature in ipairs(removable and { false, true } or { false }) do
    for _, harvest in ipairs(harvestable and { false, true } or { false }) do
      local value, kept = now, 0
      local f, r = feature, resource
      if removeFeature then value, f = value - featureYield, nil else kept = kept + featureOnce end
      if harvest then value, r = value - resourceYield, nil else kept = kept + resourceOnce end
      value = value - kept
      if not removeFeature and (bare == nil or value > bare) then bare = value end
      value = value + BestImprovement(ctx, sea, terrain, f, r)
      if best == nil or value > best then best, forgone = value, kept end
    end
  end
  return best, featureOnce + resourceOnce, bare, forgone
end

-- Land model of one city. plots: { Index, Tile, Once, Bare, Forgone } for
-- every plot it can work (Bare: its value left unimproved, PlotValues; nil:
-- the same as Tile; Forgone optional, see PlotValues). Returns { Plots (best
-- tile first, ties by plot index), P, Base, Loss = { [plot index] = what
-- taking that plot alone costs }, OnceTotal (the plots' one-time values: the
-- city gets them whatever is built) }.
function SDP_Land.Model(plots, population)
  local sorted = {}
  for i, p in ipairs(plots) do
    sorted[i] = { Index = p.Index, Tile = p.Tile, Once = p.Once, Bare = p.Bare or p.Tile, Forgone = p.Forgone or 0 }
  end
  table.sort(sorted, function(a, b)
    if a.Tile ~= b.Tile then return a.Tile > b.Tile end
    return a.Index < b.Index
  end)
  local model = { Plots = sorted, P = math.max(0, math.min(population, #sorted)), Loss = {}, ByIndex = {} }
  local next = sorted[model.P + 1]
  local cut = next and next.Tile or 0
  for rank, p in ipairs(sorted) do
    model.ByIndex[p.Index] = p
    model.Loss[p.Index] = rank <= model.P and (p.Tile - cut) or 0
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
-- yields on the unimproved plots around it, SDP_Appeal): such a plot is
-- worth the better of its value and its unimproved value plus the extra
-- (issue 91), and is worked when that is among the best P.
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
      if p ~= nil and not mark[index] then raised[#raised + 1] = { Index = index, Tile = math.max(p.Tile, p.Bare + extra) } end
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
  for t = 1, count do mark[taken[t]] = nil end
  return worked
end

-- The worked plots of ScoreTaken (no boost) split for display (issue 88):
-- what they yield each turn as kept or cleared, and the one-time value they
-- forgo by being kept. ScoreTaken = yield - forgone.
function SDP_Land.WorkedParts(model, taken, count)
  local mark = {}
  for t = 1, count do mark[taken[t]] = true end
  local yield, forgone, used = 0, 0, 0
  for _, p in ipairs(model.Plots) do
    if used >= model.P then break end
    if not mark[p.Index] then
      yield = yield + p.Tile + p.Forgone
      forgone = forgone + p.Forgone
      used = used + 1
    end
  end
  return yield, forgone
end

-- Land score with the plots in `taken` ({ [plot index] = true }) built on.
function SDP_Land.Score(model, taken)
  local worked, count = 0, 0
  for _, p in ipairs(model.Plots) do
    if not taken[p.Index] and count < model.P then
      worked = worked + p.Tile
      count = count + 1
    end
  end
  return worked
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
  local ctx = SDP_Land.Context(scan.PlayerID, weights, scan.AllowFeatureRemoval)
  local taken = {}
  for _, subject in ipairs(fixed) do
    if subject.Type == "DISTRICT" or subject.Type == "WONDER" then taken[Map.GetPlotIndex(subject.X, subject.Y)] = true end
  end
  local plots = {}
  local function Add(index)
    if not taken[index] and (keep == nil or keep(index)) then
      local tile, once, bare = SDP_Land.PlotValues(Map.GetPlotByIndex(index), ctx)
      plots[#plots + 1] = { Index = index, Tile = tile, Once = once, Bare = bare }
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

-- ===========================================================================
-- Housing (issues 55, 56)
-- ===========================================================================
-- A city grows at full speed while its housing is 2 or more above its
-- population, at half and a quarter speed at 1 and 0, and stops a few past
-- it (GlobalParameters CITY_HOUSING_LEFT_*). Housing is worth most while
-- the city still has to grow, and less in a big city, which needs more
-- food for each citizen (issue 91, plan B of docs/notes/
-- issue-91-housing-value.md, decided 2026-10-26):
--   - each Housing counts 1 up to the knee K, each one past it half the one
--     before (0.5, 0.25, ...);
--   - K = max(T + HOUSING_TARGET_SPARE, population + HOUSING_GROWTH_SPARE):
--     to reach the target population T at full speed the last step, T - 1
--     to T, needs housing T + 1; a city already past T needs its
--     population + 2 to keep growing at full speed (housing left 2 or more,
--     CITY_HOUSING_LEFT_50PCT_GROWTH = 1);
--   - the whole value times min(1, GrowthThreshold(5) /
--     GrowthThreshold(population)).
-- Summed, continuous between whole numbers:
--   HousingValue(n, T, pop) = S(pop) x n                        n <= K
--                           = S(pop) x (K + 1 - 0.5^(n - K))     n > K
-- `population` nil: T (a planned city's plan decides it); a city-center
-- pin or a site is population 1.
SDP_Land.HOUSING_TARGET_SPARE = 1
SDP_Land.HOUSING_GROWTH_SPARE = 2
SDP_Land.HOUSING_SCALE_POPULATION = 5 -- cities up to this size: no discount

-- Food a city of `population` needs for its next citizen, from the game's
-- GlobalParameters (CITY_GROWTH_THRESHOLD + MULTIPLIER x (p - 1) +
-- (p - 1)^EXPONENT; the game speed scales every size alike, so the ratio
-- below does not depend on it).
function SDP_Land.GrowthThreshold(population)
  local g = GlobalParameters or {}
  local base, mult, exp = g.CITY_GROWTH_THRESHOLD or 15, g.CITY_GROWTH_MULTIPLIER or 8, g.CITY_GROWTH_EXPONENT or 1.5
  local p = math.max(1, population) - 1
  return base + mult * p + p ^ exp
end

function SDP_Land.HousingScale(population)
  if population == nil then return 1 end
  return math.min(1, SDP_Land.GrowthThreshold(SDP_Land.HOUSING_SCALE_POPULATION) / SDP_Land.GrowthThreshold(population))
end

function SDP_Land.HousingKnee(target, population)
  return math.max(target + SDP_Land.HOUSING_TARGET_SPARE, (population or target) + SDP_Land.HOUSING_GROWTH_SPARE)
end

function SDP_Land.HousingValue(n, target, population)
  local knee = SDP_Land.HousingKnee(target, population)
  local value = n
  if n > knee then value = knee + 1 - 0.5 ^ (n - knee) end
  return SDP_Land.HousingScale(population) * value
end

-- The era a technology or civic belongs to (nil when unknown).
local function EraOf(tech, civic)
  local row = (tech and GameInfo.Technologies[tech]) or (civic and GameInfo.Civics[civic]) or nil
  return row and row.EraType or nil
end

local function FirstEra()
  local first, index = nil, math.huge
  if GameInfo.Eras == nil then return nil end
  for row in GameInfo.Eras() do
    if (row.ChronologyIndex or math.huge) < index then first, index = row.EraType, row.ChronologyIndex end
  end
  return first
end

-- Housing every new city soon has from city-center buildings: those of the
-- first era that are not wonders, the palace (Capital) or a civilization's
-- own (the granary in the game's rules). Sites add it to their water housing.
function SDP_Land.CenterHousing()
  local first, total = FirstEra(), 0
  if first == nil or GameInfo.Buildings == nil then return 0 end
  for row in GameInfo.Buildings() do
    if row.PrereqDistrict == "DISTRICT_CITY_CENTER" and (row.Housing or 0) > 0 and not row.IsWonder
        and not row.Capital and row.TraitType == nil and (row.PrereqTech or row.PrereqCivic)
        and EraOf(row.PrereqTech, row.PrereqCivic) == first then
      total = total + row.Housing
    end
  end
  return total
end

-- Whether every requirement of requirement set `id` is of type `kind`.
local function SetIsOnly(id, kind)
  if GameInfo.RequirementSetRequirements == nil or GameInfo.Requirements == nil then return false end
  local any = false
  for row in GameInfo.RequirementSetRequirements() do
    if row.RequirementSetId == id then
      local requirement = GameInfo.Requirements[row.RequirementId]
      if requirement == nil or requirement.RequirementType ~= kind or requirement.Inverse then return false end
      any = true
    end
  end
  return any
end

-- Housing the buildings of a district type give a city (issue 55: the
-- harbor's lighthouse and seaport): their Housing, plus building modifiers
-- that adjust the owner city's housing with no requirement or only "plot is
-- next to the coast" (counted when `coastal`, the city center is; Gathering
-- Storm's lighthouse). Not wonders, not a civilization's own buildings.
-- The base type's buildings count for a replacement (Cothon for Harbor).
local m_buildingHousing, m_buildingHousingFor = {}, nil
function SDP_Land.BuildingHousing(districtType, coastal)
  if m_buildingHousingFor ~= GameInfo then m_buildingHousing, m_buildingHousingFor = {}, GameInfo end
  local key = districtType .. (coastal and "+" or "-")
  if m_buildingHousing[key] ~= nil then return m_buildingHousing[key] end
  local base = districtType
  if GameInfo.DistrictReplaces ~= nil then
    for row in GameInfo.DistrictReplaces() do
      if row.CivUniqueDistrictType == districtType then base = row.ReplacesDistrictType end
    end
  end
  local total, buildings = 0, {}
  if GameInfo.Buildings == nil then return 0 end
  for row in GameInfo.Buildings() do
    if (row.PrereqDistrict == districtType or row.PrereqDistrict == base) and not row.IsWonder and row.TraitType == nil then
      total = total + (row.Housing or 0)
      buildings[row.BuildingType] = true
    end
  end
  if GameInfo.BuildingModifiers ~= nil and GameInfo.Modifiers ~= nil and GameInfo.ModifierArguments ~= nil then
    for link in GameInfo.BuildingModifiers() do
      local modifier = buildings[link.BuildingType] and GameInfo.Modifiers[link.ModifierId] or nil
      if modifier ~= nil and modifier.ModifierType == "MODIFIER_CITY_OWNER_ADJUST_BUILDING_HOUSING" then
        local set = modifier.SubjectRequirementSetId
        local applies = set == nil or (coastal and SetIsOnly(set, "REQUIREMENT_PLOT_ADJACENT_TO_COAST"))
        if applies then
          for argument in GameInfo.ModifierArguments() do
            if argument.ModifierId == link.ModifierId and argument.Name == "Amount" then
              total = total + (tonumber(argument.Value) or 0)
            end
          end
        end
      end
    end
  end
  m_buildingHousing[key] = total
  return total
end

-- A city's housing now (issue 55): the game's figure for a city, water
-- housing plus CenterHousing for a planned one (a city-center pin or site).
function SDP_Land.ScanHousing(scan)
  if scan.CityID ~= nil then
    local city = CityManager.GetCity(scan.PlayerID, scan.CityID)
    local growth = city ~= nil and city.GetGrowth ~= nil and city:GetGrowth() or nil
    if growth ~= nil and growth.GetHousing ~= nil then return growth:GetHousing() end
  end
  local p = GlobalParameters or {}
  local kind = SDP_City.WaterKind(Map.GetPlot(scan.X, scan.Y))
  local water = (kind == "FRESH" and (p.CITY_POPULATION_RIVER_LAKE or 5)) or (kind == "COAST" and (p.CITY_POPULATION_COAST or 3))
    or (p.CITY_POPULATION_NO_WATER or 2)
  return water + SDP_Land.CenterHousing()
end
