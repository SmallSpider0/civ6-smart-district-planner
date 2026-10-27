-- SDP_Sites: candidate city sites and their scores
-- (docs/multicity-design.md 3.2-3.4).
--
--   Candidates  revealed land plots a city could be founded on: not water,
--               mountain, impassable or a feature that forbids cities; not
--               foreign; farther than CITY_MIN_RANGE from every city and
--               city-center pin; at most half of the three rings unrevealed;
--               within K * D of one of the player's cities.
--   Coarse      every candidate, no DMT: worked plots, fresh water, luxury
--               and strategic resources, one-time yields, appeal, a penalty
--               when too few plots can take districts.
-- Each part is first worked out per turn (issue 88, decided 2026-10-26):
-- yields weigh SDP_Land.PLOT_WEIGHTS (adjacency: 1 a yield) times the tab's
-- yield weights. Then it is turned into points by a fixed rule (decided
-- 2026-10-27, so that every part weighs about the same and a site always
-- gets the same score): ITEM_POINTS for what a good site has in that part
-- (REFERENCE, measured on many generated maps), times the part's own weight
-- (DISTRICT, LAND, FEATURE, HOUSING, AMENITY, STRATEGIC, APPEAL).
--   Fine        the best M candidates: the planned districts placed by the
--               single-city search (SDP_Search) around a hypothetical city
--               center; the district gain and the plots they take enter the
--               score.
-- Every number comes from GameInfo, the plots and DMT at run time.
-- Risk notes (loyalty, unrevealed plots, disasters, distance, possibly
-- unknown strategic resources) are shown, never scored.

SDP_Sites = {}

SDP_Sites.DUPLICATE_VALUE = 1  -- a luxury copy that is not a new kind: traded, while a met civilization lacks it (issue 86)
-- Strategic resources (issue 86, decided 2026-10-26): each plot is worth
-- era x kind. Era: ERA_RECENT when the resource is revealed in the player's
-- era or the one before, else 1. Kind: KIND_NEW for the first plot of a kind
-- the player does not have, KIND_SHORT for a kind it has but runs short of
-- (Gathering Storm: stockpile under SHORT_SHARE of the cap or no income),
-- else 1.
SDP_Sites.ERA_RECENT = 2
SDP_Sites.KIND_NEW = 2
SDP_Sites.KIND_SHORT = 1.5
SDP_Sites.SHORT_SHARE = 0.25
SDP_Sites.MISSING_PLOT = 5     -- penalty (points) per planned district without a usable plot
-- One-time yields of clearing and harvesting are spread over this many turns
-- (issue 88, decided 2026-10-26: 50 at standard speed, other speeds in
-- proportion). The game scales those yields by the speed in the same
-- proportion, so the two cancel and 50 holds at every speed.
SDP_Sites.HARVEST_TURNS = 50
SDP_Sites.LOYALTY_RANGE = 9    -- cities this close press on a city's loyalty (R&F, GS)

-- Points of a part (issue 88): ITEM_POINTS x (its per-turn value / what a
-- good site has). What a good site has, about the 90th percentile of the
-- refined sites of 48 generated maps at three points of the game
-- (docs/notes/issue-88-sites-score.md):
--   District   adjacency per planned district
--   Farm       yield per worked plot, from Farm at the start of the game
--              to FarmLate with every technology and civic (improvements
--              yield more), in proportion to the player's progress
--   Feature    one-time yields per turn per unit of their growth
--              (SDP_Land.Growth): 0.4 a woods plot (20 production over 50
--              turns), so a woods plot is worth 0.8 points at any time
--   Housing    housing over a dry site's (fresh water: 3)
--   Luxury     one new kind for four cities
--   Strategic  the first plot of a new kind revealed in the player's era
SDP_Sites.ITEM_POINTS = 10
SDP_Sites.REFERENCE = { District = 4, Farm = 4.3, FarmLate = 7.2, Feature = 5, Housing = 3, Luxury = 4, Strategic = 4 }

-- [weight key] = the part's weight times its points per unit (above), for
-- the request's plan and the player's progress. request.Raw: per-turn
-- values, no points (measurements).
function SDP_Sites.ItemWeights(ctx, request, districts)
  local w, ref = ctx.Weights, SDP_Sites.REFERENCE
  local out = { DISTRICT = w.DISTRICT, LAND = w.LAND, FEATURE = w.FEATURE, HOUSING = w.HOUSING, AMENITY = w.AMENITY,
    STRATEGIC = w.STRATEGIC, APPEAL = w.APPEAL }
  ctx.Points = { DISTRICT = 1, LAND = 1, FEATURE = 1, HOUSING = 1, AMENITY = 1, STRATEGIC = 1, APPEAL = 1 }
  if not request.Raw then
    local n, growth = SDP_Sites.ITEM_POINTS, SDP_Land.Growth(ctx.PlayerID)
    local progress = (growth - 1) / SDP_Land.ONE_TIME_GROWTH
    local farm = ref.Farm + (ref.FarmLate - ref.Farm) * progress
    ctx.Points = { DISTRICT = n / (math.max(1, districts) * ref.District), LAND = n / (math.max(1, ctx.Population) * farm),
      FEATURE = n / (growth * ref.Feature), HOUSING = n / ref.Housing, AMENITY = n / ref.Luxury,
      STRATEGIC = n / ref.Strategic, APPEAL = 1 }
  end
  for key, value in pairs(ctx.Points) do out[key] = out[key] * value end
  return out
end

-- The weights a site score uses, with their defaults (design 3.3): the six
-- yields, then one per part (issue 88): districts, land (the worked plots),
-- features (one-time yields), housing, luxuries (AMENITY), strategics, appeal.
SDP_Sites.WEIGHT_KEYS = { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION",
  "YIELD_FOOD", "DISTRICT", "LAND", "FEATURE", "HOUSING", "AMENITY", "STRATEGIC", "APPEAL" }
SDP_Sites.PRESETS = {
  BALANCED = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1,
    YIELD_FOOD = 1, DISTRICT = 1, LAND = 1, FEATURE = 1, HOUSING = 1, AMENITY = 1, STRATEGIC = 1, APPEAL = 0 },
  GROWTH = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1,
    YIELD_FOOD = 2, DISTRICT = 1, LAND = 1, FEATURE = 1, HOUSING = 2, AMENITY = 1, STRATEGIC = 1, APPEAL = 0 },
  DISTRICTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1,
    YIELD_FOOD = 1, DISTRICT = 2, LAND = 1, FEATURE = 1, HOUSING = 1, AMENITY = 1, STRATEGIC = 0, APPEAL = 0 },
}
SDP_Sites.PRESET_ORDER = { "BALANCED", "GROWTH", "DISTRICTS" }
-- The distance weight's default for placing districts around a site (issue
-- 91, decided 2026-10-27: 0.5 as on the other tabs). No preset sets it, so a
-- preset puts it back to this; a save keeps it only when it differs.
SDP_Sites.DEFAULT_DISTANCE = 0.5

-- The districts a site is scored with (issue 90, decided 2026-10-26): the
-- states of the single-city tab's grid (MUST, POOL, OFF) and a count. By
-- default every district that takes population is a candidate (POOL),
-- except those that would count once per empire (OFF; the tab shows them
-- as not counted) and those that give a city no adjacency yield and no
-- amenities (SDP_Rules.Functional: Encampment, Aerodrome, Preserve), which
-- players build for what they do; the others are OFF. `functional` is
-- SDP_Rules.Functional(playerID).
SDP_Sites.DEFAULT_COUNT = 3
SDP_Sites.MAX_COUNT = 6

function SDP_Sites.DefaultState(d, functional)
  if not d.Specialty or (d.MaxPerPlayer and d.MaxPerPlayer > 0) or functional[d.Type] then return "OFF" end
  return "POOL"
end

-- The request fields for the default grid: { Districts (required: none),
-- Pool, Pick } with `count` (default DEFAULT_COUNT) districts per site.
function SDP_Sites.DefaultDistricts(playerID, count)
  local functional, pool = SDP_Rules.Functional(playerID), {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(playerID)) do
    if SDP_Sites.DefaultState(d, functional) == "POOL" then pool[#pool + 1] = d.Type end
  end
  return { Districts = {}, Pool = pool, Pick = count or SDP_Sites.DEFAULT_COUNT }
end

function SDP_Sites.Weights(weights)
  local out = {}
  for _, key in ipairs(SDP_Sites.WEIGHT_KEYS) do
    local w = weights and weights[key]
    out[key] = (w == nil) and SDP_Sites.PRESETS.BALANCED[key] or w
  end
  return out
end

-- What a site's plot yields weigh (issue 53, the maintainer's choice of
-- 2026-10-25 for this tab): the fixed numbers of the district planner's
-- land part (SDP_Land.PLOT_WEIGHTS) times the tab's own weight of that
-- yield, which only leans on it (all 1: the fixed numbers; Growth first:
-- food twice). Per-turn plot yields also times the land weight, one-time
-- yields (second table) times FEATURE instead (issue 88).
function SDP_Sites.PlotWeights(w, items)
  items = items or w
  local tile, once = { FEATURE = items.FEATURE }, { FEATURE = items.FEATURE }
  local land = items.LAND or 1
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    once[yieldType] = SDP_Land.PLOT_WEIGHTS[yieldType] * (w[yieldType] or 1)
    tile[yieldType] = once[yieldType] * land
  end
  return tile, once
end

-- Closest distance at which two cities may stand (game data, not DMT's 3).
function SDP_Sites.MinRange()
  return (GlobalParameters and GlobalParameters.CITY_MIN_RANGE) or 3
end

-- City centers to keep away from: every revealed city (any player) and the
-- player's city-center pins. { X, Y, Own (bool), Pin (bool) }.
function SDP_Sites.Centers(playerID)
  local list = {}
  local visibility = PlayersVisibility[playerID]
  for index = 0, Map.GetPlotCount() - 1 do
    local plot = Map.GetPlotByIndex(index)
    if plot:IsCity() and visibility:IsRevealed(index) then
      list[#list + 1] = { X = plot:GetX(), Y = plot:GetY(), Index = index, Own = plot:GetOwner() == playerID }
    end
  end
  for _, site in ipairs(SDP_Multi.Sites(playerID)) do
    list[#list + 1] = { X = site.X, Y = site.Y, Index = site.Index, Own = true, Pin = true }
  end
  table.sort(list, function(a, b) return a.Index < b.Index end)
  return list
end

local function Nearest(centers, x, y, own)
  local best = math.huge
  for _, c in ipairs(centers) do
    if own == nil or c.Own == own then best = math.min(best, Map.GetPlotDistance(x, y, c.X, c.Y)) end
  end
  return best
end

-- Why a plot cannot be a candidate site, or nil.
local function SiteExclusion(playerID, plot, centers, minRange, reach)
  if plot:IsWater() then return "WATER" end
  if plot:IsMountain() then return "MOUNTAIN" end
  if plot:IsImpassable() then return "IMPASSABLE" end
  local feature = plot:GetFeatureType()
  if feature ~= -1 and GameInfo.Features[feature].Settlement == false then return "FEATURE" end
  local owner = plot:GetOwner()
  if owner ~= -1 and owner ~= playerID then return "FOREIGN" end
  if Nearest(centers, plot:GetX(), plot:GetY()) <= minRange then return "TOO_CLOSE" end
  if reach ~= nil and Nearest(centers, plot:GetX(), plot:GetY(), true) > reach then return "TOO_FAR" end
  return nil
end

-- Candidate sites: { X, Y, Index, Unrevealed, Rings } sorted by plot index.
-- options.K, options.D: number of new cities and the relay distance; plots
-- beyond K * D of the player's own cities and pins cannot be reached.
function SDP_Sites.Candidates(playerID, options)
  options = options or {}
  local centers = SDP_Sites.Centers(playerID)
  local hasOwn = false
  for _, c in ipairs(centers) do
    if c.Own then hasOwn = true end
  end
  local reach = hasOwn and (options.K or 3) * (options.D or 5) or nil
  local minRange = SDP_Sites.MinRange()
  local visibility = PlayersVisibility[playerID]
  local list = {}
  for index = 0, Map.GetPlotCount() - 1 do
    if SDP_Task ~= nil and index % 256 == 255 then SDP_Task.Tick(1) end
    if visibility:IsRevealed(index) then
      local plot = Map.GetPlotByIndex(index)
      if SiteExclusion(playerID, plot, centers, minRange, reach) == nil then
        local rings = SDP_City.PlotsInRange(plot:GetX(), plot:GetY(), SDP_City.RADIUS)
        local unrevealed = 0
        for _, entry in ipairs(rings) do
          if not visibility:IsRevealed(entry.Index) then unrevealed = unrevealed + 1 end
        end
        if unrevealed * 2 <= #rings then
          list[#list + 1] = { X = plot:GetX(), Y = plot:GetY(), Index = index, Unrevealed = unrevealed, Rings = #rings }
        end
      end
    end
  end
  return list, centers
end

-- ===========================================================================
-- Scores
-- ===========================================================================

-- What is shared by every site of one request.
function SDP_Sites.Context(playerID, request)
  local ctx = { PlayerID = playerID, Weights = SDP_Sites.Weights(request.Weights) }
  local plannable, byType = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do byType[d.Type] = d end
  -- The plan every site is scored with. A district with an empire limit
  -- (government plaza) would count once per site: it is left out here.
  local plan, specialty, seen = {}, 0, {}
  for _, districtType in ipairs(request.Districts or {}) do
    local row = byType[districtType]
    if row ~= nil and not seen[districtType] and not (row.MaxPerPlayer and row.MaxPerPlayer > 0) then
      seen[districtType] = true
      plan[#plan + 1] = districtType
      if row.Specialty then specialty = specialty + 1 end
    end
  end
  -- Issue 90: request.Pool, the candidates that take population, of which
  -- each site picks its best request.Pick (the tab's count less the
  -- required ones, which are in request.Districts). A pick of none leaves
  -- the pool out; a pick that takes the whole pool needs no picking: those
  -- count as required.
  -- Else PlanCount (feedback item 8): with more ticked, each site picks its
  -- best PlanCount of them; without either every ticked district counts.
  local pool, pick = {}, 0
  if request.Pool ~= nil then
    for _, districtType in ipairs(request.Pool) do
      local row = byType[districtType]
      if row ~= nil and row.Specialty and not seen[districtType] and not (row.MaxPerPlayer and row.MaxPerPlayer > 0) then
        seen[districtType] = true
        pool[#pool + 1] = districtType
      end
    end
    pick = math.max(0, math.min(request.Pick or 0, #pool))
    if pick == 0 then
      pool = {}
    elseif pick == #pool then
      for _, districtType in ipairs(pool) do plan[#plan + 1] = districtType end
      pool, pick = {}, 0
    end
    specialty = pick
    for _, districtType in ipairs(plan) do
      if byType[districtType].Specialty then specialty = specialty + 1 end
    end
  elseif request.PlanCount ~= nil and specialty > request.PlanCount then
    local rest = {}
    for _, districtType in ipairs(plan) do
      if byType[districtType].Specialty then pool[#pool + 1] = districtType else rest[#rest + 1] = districtType end
    end
    plan, pick, specialty = rest, request.PlanCount, request.PlanCount
  end
  ctx.Plan, ctx.Pool, ctx.Pick, ctx.Population = plan, pool, pick, SDP_Land.RequiredPopulation(specialty)
  ctx.Items = SDP_Sites.ItemWeights(ctx, request, #plan + pick)
  local tileWeights, onceWeights = SDP_Sites.PlotWeights(ctx.Weights, ctx.Items)
  ctx.Land = SDP_Land.Context(playerID, tileWeights, true, { OnceWeights = onceWeights, Turns = SDP_Sites.HARVEST_TURNS })
  -- The distance cost is in adjacency: in points like it.
  ctx.Distance = request.Distance and request.Distance * ctx.Points.DISTRICT
  -- Resources the player has (amounts) and can see.
  local resources = Players[playerID]:GetResources()
  ctx.Owned, ctx.Visible, ctx.Amount = {}, {}, {}
  for row in GameInfo.Resources() do
    ctx.Amount[row.ResourceType] = resources:GetResourceAmount(row.Index)
    ctx.Owned[row.ResourceType] = ctx.Amount[row.ResourceType] > 0
    ctx.Visible[row.ResourceType] = resources:IsResourceVisible(row.Hash)
  end
  SDP_Sites.ResourceContext(ctx, playerID, request)
  ctx.Loyalty = SDP_Rules.Ruleset() ~= "RULESET_STANDARD"
  ctx.UnknownStrategic = false
  for row in GameInfo.Resources() do
    if row.ResourceClassType == "RESOURCECLASS_STRATEGIC" and not ctx.Visible[row.ResourceType] then ctx.UnknownStrategic = true end
  end
  ctx.Housing = {
    Fresh = (GlobalParameters and GlobalParameters.CITY_POPULATION_RIVER_LAKE) or 5,
    Coast = (GlobalParameters and GlobalParameters.CITY_POPULATION_COAST) or 3,
    None = (GlobalParameters and GlobalParameters.CITY_POPULATION_NO_WATER) or 2,
    Center = SDP_Land.CenterHousing(),
  }
  -- Districts on the coast (the harbor): their buildings' housing counts
  -- for the site (issue 55).
  ctx.CoastDistricts = {}
  for row in GameInfo.Districts() do
    if row.Coast then ctx.CoastDistricts[row.DistrictType] = true end
  end
  return ctx
end

-- What the resource parts need (issue 86):
--   Cities      the player's cities and city-center pins plus the K new ones:
--               a new luxury gives an amenity to at most this many
--   Buyers      [luxury type] = met major civilizations (not city-states,
--               which do not trade) that do not have it: copies beyond the
--               first are worth DUPLICATE_VALUE up to this many
--   EraFactor   [strategic type] = ERA_RECENT or 1
--   Short       [strategic type] = true: had but short (Gathering Storm)
function SDP_Sites.ResourceContext(ctx, playerID, request)
  local player = Players[playerID]
  ctx.Cities = player:GetCities():GetCount() + #SDP_Multi.Sites(playerID) + (request.K or 1)
  ctx.Buyers = SDP_Sites.Buyers(playerID)
  local era = player.GetEra ~= nil and player:GetEra() or 0
  local resources = player:GetResources()
  local stockpiles = SDP_Rules.Ruleset() == "RULESET_EXPANSION_2" and resources.GetResourceStockpileCap ~= nil
  ctx.EraFactor, ctx.Short = {}, {}
  for row in GameInfo.Resources() do
    if row.ResourceClassType == "RESOURCECLASS_STRATEGIC" then
      -- Revealed by its technology's era; without one, from the start.
      local tech = row.PrereqTech and GameInfo.Technologies[row.PrereqTech] or nil
      local techEra = tech and GameInfo.Eras[tech.EraType] or nil
      local revealed = techEra ~= nil and techEra.Index or 0
      ctx.EraFactor[row.ResourceType] = revealed >= era - 1 and SDP_Sites.ERA_RECENT or 1
      if stockpiles and ctx.Owned[row.ResourceType] then
        local cap = resources:GetResourceStockpileCap(row.Index) or 0
        local income = resources.GetResourceAccumulationPerTurn ~= nil and resources:GetResourceAccumulationPerTurn(row.Index) or 1
        ctx.Short[row.ResourceType] = ctx.Amount[row.ResourceType] < SDP_Sites.SHORT_SHARE * cap or income <= 0
      end
    end
  end
end

-- [luxury type] = met major civilizations that lack it, read like the
-- game's World Resources screen (GlobalResourcePopup: what each can trade).
-- Empty when the deal manager is not there (nobody to sell to).
function SDP_Sites.Buyers(playerID)
  local out = {}
  local diplomacy = Players[playerID].GetDiplomacy ~= nil and Players[playerID]:GetDiplomacy() or nil
  if diplomacy == nil or DealManager == nil or DealItemTypes == nil or PlayerManager == nil then return out end
  local luxuries = {}
  for row in GameInfo.Resources() do
    if row.ResourceClassType == "RESOURCECLASS_LUXURY" then luxuries[#luxuries + 1] = row.ResourceType end
  end
  for _, other in ipairs(PlayerManager.GetAliveMajorIDs()) do
    if other ~= playerID and diplomacy:HasMet(other) then
      local has = {}
      local deal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, playerID, other)
      for _, entry in ipairs(DealManager.GetPossibleDealItems(other, other, DealItemTypes.RESOURCES, deal) or {}) do
        local row = GameInfo.Resources[entry.ForType]
        if row ~= nil then has[row.ResourceType] = true end
      end
      for _, kind in ipairs(luxuries) do
        if not has[kind] then out[kind] = (out[kind] or 0) + 1 end
      end
    end
  end
  return out
end

-- Fresh water, coast or neither at a site (housing, design 3.3).
local Water = function(plot) return SDP_City.WaterKind(plot) end

-- Water part of a site (design 3.3, issues 55 and 56): what its housing is
-- worth over a dry site's, weighed by HOUSING. A site's housing is its water
-- housing, the first-era city-center buildings' (granary), and the
-- buildings' of the coast districts (harbor) among `districts`; its worth
-- is SDP_Land.HousingValue with the population the plan needs as target
-- and a new city's population, 1 (issue 91).
function SDP_Sites.WaterPart(ctx, site, districts)
  local plot = Map.GetPlot(site.X, site.Y)
  local kind = site.Info.WaterKind
  local housing = ((kind == "FRESH" and ctx.Housing.Fresh) or (kind == "COAST" and ctx.Housing.Coast) or ctx.Housing.None)
    + ctx.Housing.Center
  for _, districtType in ipairs(districts) do
    if ctx.CoastDistricts[districtType] then housing = housing + SDP_Land.BuildingHousing(districtType, plot:IsCoastalLand()) end
  end
  site.Info.Housing = housing
  local dry = ctx.Housing.None + ctx.Housing.Center
  return ctx.Items.HOUSING * (SDP_Land.HousingValue(housing, ctx.Population, 1) - SDP_Land.HousingValue(dry, ctx.Population, 1))
end

-- The coarse score of a site (no DMT). Returns a site table:
--   X, Y, Index, Scan, Land (SDP_Land model of its workable plots)
--   Parts = { Farm, Water, Luxury, Strategic, Feature, Appeal, Penalty } (weighted)
--   Coarse  sum of the parts; Valid false when too few plots take districts
--   Luxury = { [type] = copies }, Strategic = { [type] = amount }
--   Resources = { { Index, Type, Luxury (bool), Count (copies), Amount } }: the
--     visible luxury and strategic resources on its workable plots
--   Info = { WaterKind, Usable, Unrevealed, Disaster, OwnDistance, Loyalty, Features = { [type] = plots } }
--     OwnDistance: to the nearest of the player's cities and city-center pins
function SDP_Sites.Coarse(ctx, candidate, centers)
  local playerID, w = ctx.PlayerID, ctx.Weights
  local x, y = candidate.X, candidate.Y
  local scan = SDP_City.ScanSite(playerID, x, y, { population = ctx.Population })
  local site = { X = x, Y = y, Index = candidate.Index, Scan = scan, Parts = {}, Info = {}, Luxury = {}, Strategic = {},
    Resources = {} }

  -- Worked plots and one-time yields.
  local plots, featureCount, disaster = {}, {}, false
  for _, index in ipairs(SDP_Land.Workable(scan)) do
    local plot = Map.GetPlotByIndex(index)
    local tile, once, bare, forgone = SDP_Land.PlotValues(plot, ctx.Land)
    plots[#plots + 1] = { Index = index, Tile = tile, Once = once, Forgone = forgone }
    local feature = plot:GetFeatureType()
    if feature ~= -1 then
      local row = GameInfo.Features[feature]
      featureCount[row.FeatureType] = (featureCount[row.FeatureType] or 0) + 1
      if row.FeatureType:find("FLOODPLAINS") or row.FeatureType:find("VOLCANIC") then disaster = true end
    end
    -- Resources the player can see.
    local resource = plot:GetResourceType()
    if resource ~= -1 then
      local row = GameInfo.Resources[resource]
      if ctx.Visible[row.ResourceType] then
        local count = math.max(1, plot:GetResourceCount())
        if row.ResourceClassType == "RESOURCECLASS_LUXURY" then
          site.Luxury[row.ResourceType] = (site.Luxury[row.ResourceType] or 0) + count
          site.Resources[#site.Resources + 1] = { Index = index, Type = row.ResourceType, Luxury = true, Count = count,
            Amount = count }
        elseif row.ResourceClassType == "RESOURCECLASS_STRATEGIC" then
          -- Plots, whatever each yields (issue 86).
          site.Strategic[row.ResourceType] = (site.Strategic[row.ResourceType] or 0) + 1
          site.Resources[#site.Resources + 1] = { Index = index, Type = row.ResourceType, Luxury = false, Count = count,
            Amount = 1 }
        end
      end
    end
  end
  site.Land = SDP_Land.Model(plots, ctx.Population)
  site.Parts.Farm, site.Parts.Feature = SDP_Sites.LandParts(site.Land, {}, site.Land.OnceTotal)

  site.Info.WaterKind = Water(Map.GetPlot(x, y))
  site.Parts.Water = SDP_Sites.WaterPart(ctx, site, ctx.Plan)

  site.Parts.Luxury = ctx.Items.AMENITY * SDP_Sites.LuxuryValue(ctx, site.Luxury, {})
  site.Parts.Strategic = ctx.Items.STRATEGIC * SDP_Sites.StrategicValue(ctx, site.Strategic, {})

  -- Appeal of the plots districts could take.
  local appeal, usable = 0, 0
  for _, c in ipairs(scan.Candidates) do
    local plot = Map.GetPlotByIndex(c.Index)
    if not plot:IsWater() and not plot:IsMountain() and not plot:IsImpassable() then
      usable = usable + 1
      appeal = appeal + plot:GetAppeal()
    end
  end
  site.Parts.Appeal = usable > 0 and w.APPEAL * appeal / usable or 0
  local planned = #ctx.Plan + ctx.Pick
  site.Parts.Penalty = math.max(0, planned - usable) * SDP_Sites.MISSING_PLOT
  site.Valid = usable * 2 >= planned
  site.Info.Usable = usable
  site.Info.Unrevealed = candidate.Unrevealed
  site.Info.Disaster = disaster
  site.Info.Features = featureCount
  site.Info.OwnDistance = Nearest(centers, x, y, true)
  site.Info.Loyalty = ctx.Loyalty and SDP_Sites.LoyaltyRisk(playerID, x, y, centers) or nil
  site.Info.UnknownStrategic = ctx.UnknownStrategic
  site.Coarse = site.Parts.Farm + site.Parts.Feature + site.Parts.Water + site.Parts.Luxury + site.Parts.Strategic
    + site.Parts.Appeal - site.Parts.Penalty
  return site
end

-- The land of a site split into its two parts (issue 88), with the plots
-- `taken` (indices) built on or worked by another site and `once` the
-- one-time values of the plots it keeps:
--   Farm     what its best P plots yield each turn, each kept or cleared,
--            whichever is worth more
--   Feature  the one-time yields of the plots it clears (every plot it does
--            not work, and the worked ones worth more cleared), per turn
-- Farm + Feature = SDP_Land.ScoreTaken + once.
function SDP_Sites.LandParts(model, taken, once)
  local yield, forgone = SDP_Land.WorkedParts(model, taken, #taken)
  return yield, once - forgone
end

-- Amenity value of luxury copies { [type] = copies } (issue 86): the first
-- copy of a kind the player does not have and `taken` has not counted is
-- new, worth one amenity in each city up to its Happiness (4 in the rules);
-- every other copy is worth DUPLICATE_VALUE while a met civilization lacks
-- the kind and has not been sold one (the player's own spare copies sold
-- first). `taken` = { [type] = { New, Sold } } is updated.
function SDP_Sites.LuxuryValue(ctx, copies, taken)
  local kinds = {}
  for kind in pairs(copies) do kinds[#kinds + 1] = kind end
  table.sort(kinds)
  local value = 0
  for _, kind in ipairs(kinds) do
    local count = copies[kind]
    local t = taken[kind]
    if t == nil then
      t = { New = false, Sold = math.max(0, (ctx.Amount[kind] or 0) - 1) }
      taken[kind] = t
    end
    if not ctx.Owned[kind] and not t.New then
      value = value + math.min(GameInfo.Resources[kind].Happiness or 0, ctx.Cities)
      t.New, count = true, count - 1
    end
    local sold = math.max(0, math.min(count, (ctx.Buyers[kind] or 0) - t.Sold))
    value = value + sold * SDP_Sites.DUPLICATE_VALUE
    t.Sold = t.Sold + sold
  end
  return value
end

-- Strategic value { [type] = plots } (issue 86): each plot era x kind (see
-- KIND_NEW); `taken` = { [type] = true } marks the kinds already counted as
-- new and is updated.
function SDP_Sites.StrategicValue(ctx, plots, taken)
  local kinds = {}
  for kind in pairs(plots) do kinds[#kinds + 1] = kind end
  table.sort(kinds)
  local value = 0
  for _, kind in ipairs(kinds) do
    local n, era = plots[kind], ctx.EraFactor[kind] or 1
    if not ctx.Owned[kind] and not taken[kind] then
      value = value + era * (SDP_Sites.KIND_NEW + (n - 1))
      taken[kind] = true
    else
      value = value + era * n * (ctx.Short[kind] and SDP_Sites.KIND_SHORT or 1)
    end
  end
  return value
end

-- Loyalty risk (R&F, GS), a rough hint only: population-weighted pressure
-- of the player's cities against foreign ones within LOYALTY_RANGE.
-- "LOW" when foreign pressure is at most ours, "MEDIUM" up to twice, else "HIGH".
-- `centers` from SDP_Sites.Centers (pins are not cities and are skipped).
function SDP_Sites.LoyaltyRisk(playerID, x, y, centers)
  local own, foreign = 0, 0
  for _, c in ipairs(centers) do
    if not c.Pin then
      local d = Map.GetPlotDistance(x, y, c.X, c.Y)
      if d <= SDP_Sites.LOYALTY_RANGE then
        local city = Cities.GetCityInPlot(c.X, c.Y)
        local pop = city and city:GetPopulation() or 1
        local pressure = pop * (SDP_Sites.LOYALTY_RANGE + 1 - d)
        if c.Own then own = own + pressure else foreign = foreign + pressure end
      end
    end
  end
  if foreign <= own then return "LOW" end
  if foreign <= 2 * own then return "MEDIUM" end
  return "HIGH"
end

-- ===========================================================================
-- Fine scores: districts placed around each site with DMT.
-- ===========================================================================

-- One board for every site of a request: fixed subjects near any of them;
-- each site's hypothetical city center sits in slot CENTER_SLOT while its
-- districts are searched, so district values away from the center are
-- shared between sites (SDP_Board's memo). The overlay must be installed.
SDP_Sites.CENTER_SLOT = 1000

function SDP_Sites.Board(ctx, sites)
  local fixed, seen = {}, {}
  for _, site in ipairs(sites) do
    for _, subject in ipairs(SDP_Overlay.FixedSubjects(site.Scan)) do
      local index = Map.GetPlotIndex(subject.X, subject.Y)
      if not seen[index] then
        seen[index] = true
        fixed[#fixed + 1] = subject
      end
    end
  end
  table.sort(fixed, function(a, b) return Map.GetPlotIndex(a.X, a.Y) < Map.GetPlotIndex(b.X, b.Y) end)
  -- Adjacency: 1 a yield, as on the single-city tab (issue 88), times the
  -- tab's yield weights and the district weight.
  ctx.AdjacencyWeights = {}
  for _, y in ipairs(SDP_Rules.YIELDS) do ctx.AdjacencyWeights[y] = ctx.Weights[y] * ctx.Items.DISTRICT end
  ctx.Board = SDP_Board.New(ctx.PlayerID, fixed, ctx.AdjacencyWeights)
  return ctx.Board
end

-- District score of a site: the best placement of the plan around a city
-- center there (SDP_Search with `params`, typically SDP_Tiers.Sites[tier]).
-- Adds site.Districts = { { Type, Index, X, Y, Value } }, site.Parts.District
-- (DMT gain of the districts and the center around them), updates Farm and
-- Feature for the plots the districts take, and site.Fine (the full score).
function SDP_Sites.Fine(ctx, site, params)
  local board = ctx.Board
  local center = { Key = "DISTRICT_CITY_CENTER", Type = "DISTRICT", X = site.X, Y = site.Y }
  board:Put(SDP_Sites.CENTER_SLOT, center)
  local _, centerLegal = board:Total()
  site.Districts, site.Parts.District = {}, 0
  if centerLegal and #ctx.Plan + ctx.Pick > 0 then
    local slots = {}
    for s, districtType in ipairs(ctx.Plan) do slots[s] = { Key = districtType, Type = "DISTRICT", Group = 1 } end
    for _, districtType in ipairs(ctx.Pool) do
      slots[#slots + 1] = { Key = districtType, Type = "DISTRICT", Group = 1, Optional = true }
    end
    local search = SDP_Search.New({
      PlayerID = ctx.PlayerID, Board = board, Weights = ctx.AdjacencyWeights, Params = params,
      Candidates = site.Scan.Candidates, Slots = slots, Lands = { site.Land },
      Pools = ctx.Pick > 0 and { [1] = ctx.Pick } or nil,
      Costs = SDP_City.DistanceCosts(ctx.PlayerID, site.Scan.Candidates, ctx.Distance, { { X = site.X, Y = site.Y } }),
      Exclusive = SDP_Rules.Exclusive(),
    })
    search:Singles()
    search:Run()
    if search.BestLayout ~= nil then
      local layout = search.BestLayout
      local taken = {}
      for m = 1, search.K do
        if layout[m] ~= 0 then
          local c = search.Candidates[layout[m]]
          site.Districts[#site.Districts + 1] = { Type = search.Types[m], Index = c.Index, X = c.X, Y = c.Y,
            Value = search.Single[m][layout[m]] }
          taken[#taken + 1] = c.Index
        end
      end
      local land = SDP_Land.ScoreTaken(site.Land, taken, #taken, {})
      site.Parts.District = search.BestGain - (land - site.Land.Base)
      site.Parts.Farm, site.Parts.Feature = SDP_Sites.LandParts(site.Land, taken, site.Land.OnceTotal)
      local types = {}
      for _, d in ipairs(site.Districts) do types[#types + 1] = d.Type end
      site.Parts.Water = SDP_Sites.WaterPart(ctx, site, types)
    end
  end
  board:Clear()
  site.CenterLegal = centerLegal
  site.Fine = site.Parts.District + site.Parts.Farm + site.Parts.Feature + site.Parts.Water + site.Parts.Luxury
    + site.Parts.Strategic + site.Parts.Appeal - site.Parts.Penalty
  return site
end
