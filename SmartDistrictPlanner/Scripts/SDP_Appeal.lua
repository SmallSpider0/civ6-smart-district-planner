-- SDP_Appeal: the appeal part of the objective (2026-10-21 feedback). A
-- neighborhood's housing depends on the appeal of its plot; a preserve's on
-- its own plot's appeal, and its grove and sanctuary add yields to the
-- unimproved plots around it by their appeal. DMT computes neither.
--
-- Appeal changes with the plan. Building on a plot clears its removable
-- feature and its improvement, and the district or wonder there adds its own
-- appeal to the plots around (Districts.Appeal: holy site +1, industrial
-- zone -1, a wonder as DISTRICT_WONDER). A cleared feature counts only for
-- the plots around, not for the plot itself (issue 58): neighborhoods
-- ordered and built the normal way on two late-game saves left their own
-- plot's appeal unchanged on 9 of 10 woods, 5 of 6 rainforest and 1 marsh
-- plots (tests/bench/probe_ownplot.py, 2026-10-24). Two exceptions, both
-- measured in the game (2026-10-25):
--   - old-growth woods: with the civic in Features.AddCivic (Conservation)
--     the owner's woods that were never removed (not
--     Plot:HasFeatureBeenAdded) give their own plot their Appeal too, so
--     clearing them takes 1 off the plot (all 28 such plots on the islands
--     save, none of the 103 without the civic; granting the civic to a
--     player added it to that player's woods);
--   - a pillaged improvement takes 1 off its own plot and the plots around
--     (Civilopedia; the two improved plots where clearing raised the plot's
--     own appeal by 1 were pillaged, and repairing one raised it and its
--     land neighbours by 1).
-- A feature whose Features.RemoveTech the player lacks is not cleared, but
-- the game does not let a district go there either.
-- Water plots keep their appeal. So
--   appeal(plot) = the game's appeal now (Plot:GetAppeal)
--                + over the neighbours with a planned or pinned (not built)
--                  district or wonder: its Appeal - the Appeal of the feature
--                  and improvement it clears there (and +1 for a pillaged one)
--                on a plot that gets one itself: - the old-growth bonus it
--                  clears (+1 if its improvement was pillaged)
--   housing part = HOUSING weight x over every district with
--                  AppealHousingChanges rows (placed, pinned or built):
--                  Districts.Housing + the change for its plot's appeal;
--                  with the cities given (issue 55), summed per city and
--                  valued by SDP_Land.HousingValue: the city's housing
--                  without these districts plus theirs, against the
--                  population its districts need
--   tile part    = for each placed district with Adjacent_AppealYieldChanges
--                  rows (the preserve; its buildings counted as built), each
--                  unimproved workable neighbour gets the rows' yields for its
--                  appeal. With the land part on they raise that plot's value
--                  in the land model (worked only if among the city's best
--                  plots), else they count in full, weighted.
-- The part of a layout is its value minus the value of the empty layout, so
-- that a plan is also charged for lowering a pinned or built neighborhood.
-- Everything comes from GameInfo and the plots at run time, except the
-- pillage penalty (the engine's; no table holds it).

SDP_Appeal = {}

local m_rules, m_rulesFor = nil, nil

-- {
--   Appeal       { [district type] = Districts.Appeal }; wonders use DISTRICT_WONDER's
--   Housing      { [district type] = { Base = Districts.Housing, Rows = { { Min, Change } } highest Min first } }
--   Tiles        { [district type] = { { Min, Max, Yield, Change, Unimproved } } }
--   Feature      { [feature index] = Appeal } of the features a district clears
--                (Removable; with RemoveTech: { [feature index] = technology index })
--   RemoveTech   { [feature index] = technology index } for those that need one
--   OldGrowth    { [feature index] = civic index } of those with Features.AddCivic:
--                the civic that lets builders plant it also gives the
--                plot itself the feature's Appeal while it was never removed
--   Improvement  { [improvement index] = Appeal }
--   Share        { [improvement index] = Housing / TilesRequired } of the
--                improvements that give housing (farms, pastures ...)
-- }
function SDP_Appeal.Rules()
  if m_rules ~= nil and m_rulesFor == GameInfo then return m_rules end
  local rules = { Appeal = {}, Housing = {}, Tiles = {}, Feature = {}, RemoveTech = {}, OldGrowth = {}, Improvement = {},
    Share = {} }
  for row in GameInfo.Districts() do
    if (row.Appeal or 0) ~= 0 then rules.Appeal[row.DistrictType] = row.Appeal end
  end
  if GameInfo.AppealHousingChanges ~= nil then
    for row in GameInfo.AppealHousingChanges() do
      local entry = rules.Housing[row.DistrictType]
      if entry == nil then
        local district = GameInfo.Districts[row.DistrictType]
        entry = { Base = district and district.Housing or 0, Rows = {} }
        rules.Housing[row.DistrictType] = entry
      end
      entry.Rows[#entry.Rows + 1] = { Min = row.MinimumValue, Change = row.AppealChange }
    end
    for _, entry in pairs(rules.Housing) do
      table.sort(entry.Rows, function(a, b) return a.Min > b.Min end)
    end
  end
  if GameInfo.Adjacent_AppealYieldChanges ~= nil then
    for row in GameInfo.Adjacent_AppealYieldChanges() do
      local list = rules.Tiles[row.DistrictType] or {}
      list[#list + 1] = { Min = row.MinimumValue, Max = row.MaximumValue, Yield = row.YieldType, Change = row.YieldChange,
        Unimproved = row.Unimproved == true }
      rules.Tiles[row.DistrictType] = list
    end
  end
  for row in GameInfo.Features() do
    if row.Removable and (row.Appeal or 0) ~= 0 then
      rules.Feature[row.Index] = row.Appeal
      local tech = row.RemoveTech and GameInfo.Technologies[row.RemoveTech]
      if tech ~= nil then rules.RemoveTech[row.Index] = tech.Index end
      local civic = row.AddCivic and GameInfo.Civics[row.AddCivic]
      if civic ~= nil then rules.OldGrowth[row.Index] = civic.Index end
    end
  end
  for row in GameInfo.Improvements() do
    if (row.Appeal or 0) ~= 0 then rules.Improvement[row.Index] = row.Appeal end
    if (row.Housing or 0) > 0 then rules.Share[row.Index] = row.Housing / math.max(1, row.TilesRequired or 1) end
  end
  m_rules, m_rulesFor = rules, GameInfo
  return rules
end

-- Sum of Housing / TilesRequired over the improved plots a city owns (its
-- housing from improvements is this rounded down). Cities own plots up to 5
-- rings out. A pillaged improvement gives none (measured 2026-10-25: two
-- cities with one pillaged plot each read 3 and 2, the sums without it).
function SDP_Appeal.CityShare(rules, city)
  local total = 0
  for dx = -5, 5 do
    for dy = -5, 5 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 5)
      if plot ~= nil and plot:GetImprovementType() ~= -1 and rules.Share[plot:GetImprovementType()] ~= nil
          and not plot:IsImprovementPillaged() then
        local owner = Cities.GetPlotPurchaseCity(plot)
        if owner ~= nil and owner:GetID() == city:GetID() and plot:GetOwner() == city:GetOwner() then
          total = total + rules.Share[plot:GetImprovementType()]
        end
      end
    end
  end
  return total
end

-- Housing of a district type on a plot of appeal `appeal` (nil: no rows).
function SDP_Appeal.Housing(rules, districtType, appeal)
  local entry = rules.Housing[districtType]
  if entry == nil then return nil end
  for _, row in ipairs(entry.Rows) do
    if appeal >= row.Min then return entry.Base + row.Change end
  end
  return entry.Base
end

-- Yields a tile of appeal `appeal` gets from one district of this type next
-- to it, added into `into` ({ [yield] = n }); `improved`: the tile has an
-- improvement.
local function TileYields(rows, appeal, improved, into)
  for _, row in ipairs(rows) do
    if appeal >= row.Min and appeal <= row.Max and not (row.Unimproved and improved) then
      into[row.Yield] = (into[row.Yield] or 0) + row.Change
    end
  end
end

-- Whether a slot type counts here (it has housing or tile rows).
function SDP_Appeal.Counts(districtType)
  local rules = SDP_Appeal.Rules()
  return rules.Housing[districtType] ~= nil or rules.Tiles[districtType] ~= nil
end

local function Neighbours(cache, index)
  local list = cache[index]
  if list ~= nil then return list end
  list = {}
  local plot = Map.GetPlotByIndex(index)
  if plot ~= nil then
    for dir = 0, 5 do
      local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
      if n ~= nil then list[#list + 1] = n:GetIndex() end
    end
  end
  cache[index] = list
  return list
end

-- A pillaged improvement takes 1 off its own plot's appeal and off each plot
-- around (Civilopedia, Neighborhoods and Appeal: "-1: Each adjacent pillaged
-- tile"; issue 58: repairing one in the game raised its plot and the land
-- plots around by 1). The engine's rule; no GameInfo row holds it.
local PILLAGED_APPEAL = -1

-- Whether the plot's feature is old-growth with the bonus on: the plot's
-- owner has the feature's AddCivic and the feature was never removed
-- (Plot:HasFeatureBeenAdded, as the game's plot tooltip tells old-growth
-- from second-growth woods).
local function OldGrowth(rules, plot, feature)
  local civic = rules.OldGrowth[feature]
  if civic == nil or plot:GetOwner() < 0 then return false end
  if plot.HasFeatureBeenAdded ~= nil and plot:HasFeatureBeenAdded() then return false end
  local owner = Players[plot:GetOwner()]
  local culture = owner ~= nil and owner.GetCulture ~= nil and owner:GetCulture() or nil
  return culture ~= nil and culture:HasCivic(civic)
end

-- What building on plot `index` takes away from appeal: around, from each
-- neighbour (the Appeal of its removable feature and of its improvement, and
-- the pillage penalty); own, from the plot itself (an old-growth feature's
-- bonus, the pillage penalty; a feature's Appeal otherwise counts only
-- around, issue 58).
local function Cleared(rules, index, techs)
  local plot = Map.GetPlotByIndex(index)
  local around, own = 0, 0
  local feature = plot:GetFeatureType()
  local tech = feature ~= -1 and rules.RemoveTech[feature] or nil
  if feature ~= -1 and (tech == nil or techs == nil or techs:HasTech(tech)) then
    around = around + (rules.Feature[feature] or 0)
    if OldGrowth(rules, plot, feature) then own = own + (rules.Feature[feature] or 0) end
  end
  local improvement = plot:GetImprovementType()
  if improvement ~= -1 then
    around = around + (rules.Improvement[improvement] or 0)
    if plot.IsImprovementPillaged ~= nil and plot:IsImprovementPillaged() then
      around = around + PILLAGED_APPEAL
      own = own + PILLAGED_APPEAL
    end
  end
  return around, own
end

local function OwnAppeal(rules, kind, key)
  if kind == "WONDER" then return rules.Appeal.DISTRICT_WONDER or 0 end
  return rules.Appeal[key] or 0
end

-- spec = {
--   PlayerID       whose technologies decide which features building clears
--   Types, Kinds   the search's slots (SDP_Search after Singles)
--   Candidates     { Index, X, Y } by position
--   Fixed          SDP_Overlay.FixedSubjects of every city (built and pinned)
--   Weights        the request's weights: HOUSING (default 1) and the six
--                  tile yields (SDP_Land.Weights)
--   Lands          the search's land models (nil or empty: land part off)
--   Workable       { [plot index] = true } plots a city can work (the tile
--                  part's plots when the land part is off)
--   Optional       { [slot] = true } slots picked from the pool: a preserve
--                  there gets its housing counted, but its grove and
--                  sanctuary yields only reported (they need two buildings;
--                  counted, a preserve near charming plots won nearly every
--                  pick in late-game saves; the user's call, 2026-10-22)
--   Groups         { [slot] = city } (the search's groups), with
--   Cities         { [city] = { Housing, Target } } (optional): the city's
--                  housing now, built neighborhoods included, and its
--                  target population; nil: each housing counts 1
--   FixedGroup     function(plot index) -> city, for fixed districts
-- }
-- Returns a model, or nil when nothing in the problem has appeal rules.
function SDP_Appeal.New(spec)
  local rules = SDP_Appeal.Rules()
  local self = { Rules = rules, K = #spec.Types, Types = spec.Types, Kinds = spec.Kinds, Candidates = spec.Candidates,
    Optional = spec.Optional or {} }
  local any = false
  self.Value = {}
  for m = 1, self.K do
    if spec.Kinds[m] == "DISTRICT" and (rules.Housing[spec.Types[m]] or rules.Tiles[spec.Types[m]]) then
      self.Value[m] = true
      any = true
    end
  end
  -- Fixed districts with housing rows: their housing counts too (a plan that
  -- lowers a pinned neighborhood's appeal pays for it).
  self.FixedValue, self.FixedAt = {}, {}
  local pinned = {}
  for _, subject in ipairs(spec.Fixed or {}) do
    local index = Map.GetPlotIndex(subject.X, subject.Y)
    if subject.Type == "DISTRICT" or subject.Type == "WONDER" then
      self.FixedAt[index] = true
      local plot = Map.GetPlotByIndex(index)
      local built = plot:GetDistrictType() ~= -1 or (plot.GetWonderType ~= nil and plot:GetWonderType() ~= -1)
      if not built then pinned[#pinned + 1] = { Index = index, Kind = subject.Type, Key = subject.Key } end
      if subject.Type == "DISTRICT" and rules.Housing[subject.Key] ~= nil then
        self.FixedValue[#self.FixedValue + 1] = { Index = index, Type = subject.Key }
        any = true
      end
    end
  end
  if not any then return nil end
  setmetatable(self, { __index = SDP_Appeal })
  self.Groups = spec.Groups or {}
  self.Cache = {}
  local player = spec.PlayerID ~= nil and Players[spec.PlayerID] or nil
  local techs = player ~= nil and player:GetTechs() or nil
  local weights = spec.Weights or {}
  self.HousingWeight = weights.HOUSING == nil and 1 or weights.HOUSING
  self.TileWeights = SDP_Land.Weights(weights)
  self.Lands = spec.Lands or {}
  self.Workable = spec.Workable or {}
  -- Appeal before the plan: the game's, plus what the pinned districts and
  -- wonders will do to their neighbours once built.
  self.Base0 = {}
  local function Base(index)
    local value = self.Base0[index]
    if value == nil then
      value = Map.GetPlotByIndex(index):GetAppeal()
      self.Base0[index] = value
    end
    return value
  end
  self.BaseAppeal = Base
  for _, p in ipairs(pinned) do
    local cleared, own = Cleared(rules, p.Index, techs)
    local effect = OwnAppeal(rules, p.Kind, p.Key) - cleared
    if effect ~= 0 then
      for _, q in ipairs(Neighbours(self.Cache, p.Index)) do self.Base0[q] = Base(q) + effect end
    end
    if own ~= 0 then self.Base0[p.Index] = Base(p.Index) - own end
  end
  -- Per candidate: what building there takes off its neighbours' appeal
  -- (Cleared) and off its own (OwnCleared).
  self.Cleared, self.OwnCleared = {}, {}
  for i, c in ipairs(spec.Candidates) do self.Cleared[i], self.OwnCleared[i] = Cleared(rules, c.Index, techs) end
  self.Water = {}
  self.Own = {}
  for m = 1, self.K do self.Own[m] = OwnAppeal(rules, spec.Kinds[m], spec.Types[m]) end
  self.Improved = {}
  self.At, self.OwnAt, self.Boosts, self.Sums = {}, {}, {}, {} -- scratch
  -- Per-city housing (issue 55): the city's housing without the districts
  -- counted here (a built one's housing is in the game's figure already).
  if spec.Cities ~= nil then
    self.Cities, self.CityOrder = {}, {}
    for g, c in pairs(spec.Cities) do
      self.Cities[g] = { Housing = c.Housing, Target = c.Target }
      self.CityOrder[#self.CityOrder + 1] = g
    end
    table.sort(self.CityOrder)
    for _, f in ipairs(self.FixedValue) do
      f.Group = spec.FixedGroup ~= nil and spec.FixedGroup(f.Index) or nil
      local city = f.Group ~= nil and self.Cities[f.Group] or nil
      local plot = Map.GetPlotByIndex(f.Index)
      if city ~= nil and plot:GetDistrictType() ~= -1 then
        city.Housing = city.Housing - (SDP_Appeal.Housing(rules, f.Type, plot:GetAppeal()) or 0)
      end
    end
  end
  self.Base = self:Score(nil)
  return self
end

function SDP_Appeal:IsImproved(index)
  local improved = self.Improved[index]
  if improved == nil then
    improved = Map.GetPlotByIndex(index):GetImprovementType() ~= -1
    self.Improved[index] = improved
  end
  return improved
end

-- Appeal of plot `index` under the layout marked in self.At ([plot index] =
-- slot effect).
function SDP_Appeal:AppealAt(index)
  local water = self.Water[index]
  if water == nil then
    water = Map.GetPlotByIndex(index):IsWater()
    self.Water[index] = water
  end
  if water then return self.BaseAppeal(index) end
  local appeal = self.BaseAppeal(index) - (self.OwnAt[index] or 0)
  local at = self.At
  for _, q in ipairs(Neighbours(self.Cache, index)) do
    local effect = at[q]
    if effect ~= nil then appeal = appeal + effect end
  end
  return appeal
end

-- Value of a layout (nil: the empty one): housing part plus, land part off,
-- the tile part; and, land part on, the tile yields per land model as
-- boosts { [land] = { [plot index] = weighted extra } } (nil when none).
-- `detail` (optional, reports): filled with { [slot] = { Appeal, Housing,
-- Tiles = { [yield] = n } } }.
function SDP_Appeal:Score(layout, detail)
  local rules, candidates, at = self.Rules, self.Candidates, self.At
  local placedAt = {}
  if layout ~= nil then
    for m = 1, self.K do
      local i = layout[m]
      if i ~= 0 then
        local index = candidates[i].Index
        at[index] = self.Own[m] - self.Cleared[i]
        self.OwnAt[index] = self.OwnCleared[i]
        placedAt[#placedAt + 1] = index
      end
    end
  end
  local value = 0
  local housingWeight = self.HousingWeight
  local cities, sums = self.Cities, self.Sums
  for _, f in ipairs(self.FixedValue) do
    if at[f.Index] == nil then
      local housing = SDP_Appeal.Housing(rules, f.Type, self:AppealAt(f.Index))
      local g = f.Group
      if cities ~= nil and g ~= nil and cities[g] ~= nil then
        sums[g] = (sums[g] or 0) + housing
      else
        value = value + housingWeight * housing
      end
    end
  end
  local boosts = nil
  if layout ~= nil then
    for m = 1, self.K do
      local i = layout[m]
      if i ~= 0 and self.Value[m] then
        local index = candidates[i].Index
        local appeal = self:AppealAt(index)
        local housing = SDP_Appeal.Housing(rules, self.Types[m], appeal)
        if housing ~= nil then
          local g = self.Groups[m]
          if cities ~= nil and g ~= nil and cities[g] ~= nil then
            sums[g] = (sums[g] or 0) + housing
          else
            value = value + housingWeight * housing
          end
        end
        local rows = rules.Tiles[self.Types[m]]
        local tiles = nil
        local counted = not self.Optional[m]
        if rows ~= nil and (counted or detail ~= nil) then
          tiles = detail and {} or nil
          for _, q in ipairs(Neighbours(self.Cache, index)) do
            if at[q] == nil and not self.FixedAt[q] then
              local yields = {}
              TileYields(rows, self:AppealAt(q), self:IsImproved(q), yields)
              local extra = 0
              for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
                local amount = yields[yieldType]
                if amount ~= nil then
                  extra = extra + (self.TileWeights[yieldType] or 0) * amount
                  if tiles ~= nil and self.Workable[q] then tiles[yieldType] = (tiles[yieldType] or 0) + amount end
                end
              end
              if extra ~= 0 and counted then
                local owner = nil
                for l, land in ipairs(self.Lands) do
                  if owner == nil and land.ByIndex[q] ~= nil then owner = l end
                end
                if owner ~= nil then
                  boosts = boosts or self.Boosts
                  local b = boosts[owner] or {}
                  boosts[owner] = b
                  b[q] = (b[q] or 0) + extra
                elseif #self.Lands == 0 and self.Workable[q] then
                  value = value + extra
                end
              end
            end
          end
        end
        if detail ~= nil then
          detail[m] = { Appeal = appeal, Housing = housing, Tiles = tiles }
          if rows ~= nil then detail[m].TilesCounted = counted end
        end
      end
    end
  end
  if cities ~= nil then
    for _, g in ipairs(self.CityOrder) do
      local city = cities[g]
      value = value + housingWeight * SDP_Land.HousingValue(city.Housing + (sums[g] or 0), city.Target)
      sums[g] = nil
    end
  end
  for _, index in ipairs(placedAt) do
    at[index] = nil
    self.OwnAt[index] = nil
  end
  return value, boosts
end

-- Housing the player's cities lose when districts go on the plots `indices`
-- over improvements that give housing (farms, pastures ...): 0 or negative.
-- The game adds Housing / TilesRequired over a city's improved plots and
-- rounds the sum down (three farms and a pasture: 1.5 + 0.5 = 2; one farm
-- alone gives nothing; measured in the game 2026-10-21), so a district on a
-- farm costs a whole housing or nothing. Reported with the plan, not part of
-- the objective: counting it there lowered both the adjacency and the
-- city output the judge measures on the panel's default setting (dev set,
-- 2026-10-21; multicity-design.md 22.6).
function SDP_Appeal.ImprovementHousing(playerID, indices)
  local rules = SDP_Appeal.Rules()
  local taken, cities, order = {}, {}, {}
  for _, index in ipairs(indices) do
    local plot = Map.GetPlotByIndex(index)
    local improvement = plot:GetImprovementType()
    local share = improvement ~= -1 and not plot:IsImprovementPillaged() and rules.Share[improvement] or nil
    local city = share ~= nil and plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
    if city ~= nil then
      local id = city:GetID()
      if taken[id] == nil then
        taken[id], cities[id] = 0, city
        order[#order + 1] = id
      end
      taken[id] = taken[id] + share
    end
  end
  local lost = 0
  for _, id in ipairs(order) do
    local total = SDP_Appeal.CityShare(rules, cities[id])
    lost = lost + math.floor(total + 1e-9) - math.floor(total - taken[id] + 1e-9)
  end
  return -lost
end

-- Appeal of each plot in `indices` with `layout` built (calibration, tests):
-- { [plot index] = appeal }.
function SDP_Appeal:AppealsUnder(layout, indices)
  local at, placed = self.At, {}
  for m = 1, self.K do
    local i = layout[m]
    if i ~= 0 then
      local index = self.Candidates[i].Index
      at[index] = self.Own[m] - self.Cleared[i]
      self.OwnAt[index] = self.OwnCleared[i]
      placed[#placed + 1] = index
    end
  end
  local out = {}
  for _, index in ipairs(indices) do out[index] = self:AppealAt(index) end
  for _, index in ipairs(placed) do
    at[index] = nil
    self.OwnAt[index] = nil
  end
  return out
end

-- Empty the boosts Score returned (they live in a scratch table).
function SDP_Appeal:ClearBoosts()
  for l in pairs(self.Boosts) do self.Boosts[l] = nil end
end
