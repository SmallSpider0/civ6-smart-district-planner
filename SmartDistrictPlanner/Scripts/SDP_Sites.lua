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
--   Fine        the best M candidates: the planned districts placed by the
--               single-city search (SDP_Search) around a hypothetical city
--               center; the district gain and the plots they take enter the
--               score.
-- Every number comes from GameInfo, the plots and DMT at run time.
-- Risk notes (loyalty, unrevealed plots, disasters, distance, possibly
-- unknown strategic resources) are shown, never scored.

SDP_Sites = {}

SDP_Sites.DUPLICATE_VALUE = 1  -- amenities a luxury copy is worth when it is not a new kind (trade)
SDP_Sites.NEW_STRATEGIC = 2    -- bonus per strategic resource kind the player does not have yet
SDP_Sites.MISSING_PLOT = 2     -- penalty per planned district without a usable plot
SDP_Sites.LOYALTY_RANGE = 9    -- cities this close press on a city's loyalty (R&F, GS)

-- The weights a site score uses, with their defaults (design 3.3).
SDP_Sites.WEIGHT_KEYS = { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION",
  "YIELD_FOOD", "HOUSING", "AMENITY", "STRATEGIC", "FEATURE", "APPEAL" }
SDP_Sites.PRESETS = {
  BALANCED = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1,
    YIELD_FOOD = 1, HOUSING = 1, AMENITY = 1, STRATEGIC = 1, FEATURE = 1, APPEAL = 0 },
  GROWTH = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1,
    YIELD_FOOD = 2, HOUSING = 2, AMENITY = 1, STRATEGIC = 1, FEATURE = 1, APPEAL = 0 },
  DISTRICTS = { YIELD_SCIENCE = 2, YIELD_CULTURE = 2, YIELD_FAITH = 2, YIELD_GOLD = 2, YIELD_PRODUCTION = 2,
    YIELD_FOOD = 1, HOUSING = 1, AMENITY = 1, STRATEGIC = 0, FEATURE = 1, APPEAL = 0 },
}
SDP_Sites.PRESET_ORDER = { "BALANCED", "GROWTH", "DISTRICTS" }

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
-- food twice). FEATURE weighs the one-time yields as before.
function SDP_Sites.PlotWeights(w)
  local out = { FEATURE = w.FEATURE }
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    out[yieldType] = SDP_Land.PLOT_WEIGHTS[yieldType] * (w[yieldType] or 1)
  end
  return out
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
  ctx.Land = SDP_Land.Context(playerID, SDP_Sites.PlotWeights(ctx.Weights), true)
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
  ctx.Distance = request.Distance
  -- Resources the player has (amounts) and can see.
  local resources = Players[playerID]:GetResources()
  ctx.Owned, ctx.Visible = {}, {}
  for row in GameInfo.Resources() do
    ctx.Owned[row.ResourceType] = resources:GetResourceAmount(row.Index) > 0
    ctx.Visible[row.ResourceType] = resources:IsResourceVisible(row.Hash)
  end
  -- Strategic amount per plot: Gathering Storm's per-turn extraction rate,
  -- else the resource count on the plot.
  ctx.Extraction = {}
  if GameInfo.Resource_Consumption ~= nil then
    for row in GameInfo.Resource_Consumption() do ctx.Extraction[row.ResourceType] = row.ImprovedExtractionRate end
  end
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

-- Fresh water, coast or neither at a site (housing, design 3.3).
local Water = function(plot) return SDP_City.WaterKind(plot) end

-- Water part of a site (design 3.3, issues 55 and 56): what its housing is
-- worth over a dry site's, weighed by HOUSING. A site's housing is its water
-- housing, the first-era city-center buildings' (granary), and the
-- buildings' of the coast districts (harbor) among `districts`; its worth
-- is SDP_Land.HousingValue with the population the plan needs as target
-- (its knee one past it, issue 91).
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
  return ctx.Weights.HOUSING * (SDP_Land.HousingValue(housing, ctx.Population) - SDP_Land.HousingValue(dry, ctx.Population))
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
    local tile, once = SDP_Land.PlotValues(plot, ctx.Land)
    plots[#plots + 1] = { Index = index, Tile = tile, Once = once }
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
          local amount = ctx.Extraction[row.ResourceType] or count
          site.Strategic[row.ResourceType] = (site.Strategic[row.ResourceType] or 0) + amount
          site.Resources[#site.Resources + 1] = { Index = index, Type = row.ResourceType, Luxury = false, Count = count,
            Amount = amount }
        end
      end
    end
  end
  site.Land = SDP_Land.Model(plots, ctx.Population)
  local once = site.Land.OnceTotal
  site.Parts.Farm = site.Land.Base
  site.Parts.Feature = once

  site.Info.WaterKind = Water(Map.GetPlot(x, y))
  site.Parts.Water = SDP_Sites.WaterPart(ctx, site, ctx.Plan)

  site.Parts.Luxury = w.AMENITY * SDP_Sites.LuxuryValue(ctx, site.Luxury, {})
  site.Parts.Strategic = w.STRATEGIC * SDP_Sites.StrategicValue(ctx, site.Strategic, {})

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

-- Amenity value of luxury copies { [type] = copies }: a kind the player does
-- not have and `taken` (kinds already counted elsewhere) does not hold is
-- new: its first copy is worth its Happiness, every other copy
-- DUPLICATE_VALUE. Marks the new kinds in `taken`.
function SDP_Sites.LuxuryValue(ctx, copies, taken)
  local kinds = {}
  for kind in pairs(copies) do kinds[#kinds + 1] = kind end
  table.sort(kinds)
  local value = 0
  for _, kind in ipairs(kinds) do
    local count = copies[kind]
    if not ctx.Owned[kind] and not taken[kind] then
      value = value + (GameInfo.Resources[kind].Happiness or 0) + (count - 1) * SDP_Sites.DUPLICATE_VALUE
      taken[kind] = true
    else
      value = value + count * SDP_Sites.DUPLICATE_VALUE
    end
  end
  return value
end

-- Strategic value { [type] = amount }: the amounts plus NEW_STRATEGIC per
-- kind the player does not have and `taken` does not hold.
function SDP_Sites.StrategicValue(ctx, amounts, taken)
  local kinds = {}
  for kind in pairs(amounts) do kinds[#kinds + 1] = kind end
  table.sort(kinds)
  local value = 0
  for _, kind in ipairs(kinds) do
    value = value + amounts[kind]
    if not ctx.Owned[kind] and not taken[kind] then
      value = value + SDP_Sites.NEW_STRATEGIC
      taken[kind] = true
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
  ctx.AdjacencyWeights = {}
  for _, y in ipairs(SDP_Rules.YIELDS) do ctx.AdjacencyWeights[y] = ctx.Weights[y] end
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
      site.Parts.Farm = land
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
