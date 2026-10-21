-- SDP_Rules: ruleset, plannable districts and the district-to-district
-- adjacency table. Everything comes from GameInfo at runtime (requirement
-- constraint 2: no hardcoded civilization or district rules).
-- Needs MapTacks (game file Base/Assets/UI/MapTacks.lua) to be included first.

SDP_Rules = {}

-- The yields the objective weighs (requirement constraint 3), display order.
SDP_Rules.YIELDS = { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION" }

-- "RULESET_STANDARD", "RULESET_EXPANSION_1" or "RULESET_EXPANSION_2".
function SDP_Rules.Ruleset()
  return GameConfiguration.GetRuleSet()
end

-- Districts the player could plan in a city, sorted by DistrictType. This is
-- the player's district list as the map tack popup builds it (a unique
-- district replaces the one it stands for; other civs' uniques and the wonder
-- pseudo-district are left out) minus the city center.
function SDP_Rules.PlannableDistricts(playerID)
  local list = {}
  for _, row in ipairs(MapTacks.PlayerDistricts(MapTacks.PlayerTraits(playerID))) do
    if not row.CityCenter then
      list[#list + 1] = {
        Type = row.DistrictType,
        Index = row.Index,
        Name = row.Name,
        Icon = "ICON_" .. row.DistrictType,
        Specialty = row.RequiresPopulation == true,
        OnePerCity = row.OnePerCity == true,
        MaxPerPlayer = row.MaxPerPlayer,
      }
    end
  end
  table.sort(list, function(a, b) return a.Type < b.Type end)
  return list
end

-- Whether an Adjacency_YieldChanges row applies to the player now. Mirrors
-- CalculateYieldFromAdjacency in DMT's dmt_yieldcalculator.lua.
local function RowApplies(row, player, traits, excluded)
  local techs, culture = player:GetTechs(), player:GetCulture()
  if row.PrereqTech and not techs:HasTech(GameInfo.Technologies[row.PrereqTech].Index) then return false end
  if row.ObsoleteTech and techs:HasTech(GameInfo.Technologies[row.ObsoleteTech].Index) then return false end
  if row.PrereqCivic and not culture:HasCivic(GameInfo.Civics[row.PrereqCivic].Index) then return false end
  if row.ObsoleteCivic and culture:HasCivic(GameInfo.Civics[row.ObsoleteCivic].Index) then return false end
  for _, trait in ipairs(excluded[row.ID] or {}) do
    if traits[trait] then return false end
  end
  return true
end

local function Add(yields, yieldType, amount)
  yields[yieldType] = (yields[yieldType] or 0) + amount
end

-- Per-neighbour adjacency gains between districts for the linear ranking
-- model. For each district type D:
--   table[D].Any[yield]     gained from each adjacent district of any type
--   table[D].From[X][yield] gained from each adjacent district of type X
--   table[D].Wonder[yield]  gained from each adjacent wonder
--   table[D].Rows           the rows themselves: { Any (bool), District (X or
--                           nil), YieldType, YieldChange, TilesRequired }
-- A row giving YieldChange per TilesRequired neighbours counts as
-- YieldChange / TilesRequired per neighbour. That overestimates a little when
-- the neighbour count is not a multiple of TilesRequired (pitfall 16); it is
-- only used for ranking, exact scores always come from DMT.
function SDP_Rules.AdjacencyTable(playerID)
  local player = Players[playerID]
  local traits = MapTacks.PlayerTraits(playerID)
  local excluded = {}
  for row in GameInfo.ExcludedAdjacencies() do
    excluded[row.YieldChangeId] = excluded[row.YieldChangeId] or {}
    table.insert(excluded[row.YieldChangeId], row.TraitType)
  end

  local result = {}
  for link in GameInfo.District_Adjacencies() do
    local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
    if row ~= nil and (row.OtherDistrictAdjacent or row.AdjacentDistrict or row.AdjacentWonder)
        and RowApplies(row, player, traits, excluded) then
      local entry = result[link.DistrictType]
      if entry == nil then
        entry = { Any = {}, From = {}, Rows = {}, Wonder = {} }
        result[link.DistrictType] = entry
      end
      entry.Rows[#entry.Rows + 1] = {
        Any = row.OtherDistrictAdjacent == true, District = (not row.OtherDistrictAdjacent) and row.AdjacentDistrict or nil,
        YieldType = row.YieldType, YieldChange = row.YieldChange, TilesRequired = row.TilesRequired,
      }
      local perNeighbour = row.YieldChange / row.TilesRequired
      if row.AdjacentWonder then
        Add(entry.Wonder, row.YieldType, perNeighbour)
      elseif row.OtherDistrictAdjacent then
        Add(entry.Any, row.YieldType, perNeighbour)
      else
        entry.From[row.AdjacentDistrict] = entry.From[row.AdjacentDistrict] or {}
        Add(entry.From[row.AdjacentDistrict], row.YieldType, perNeighbour)
      end
    end
  end
  return result
end

-- Role templates for the multi-city tab ("science city", ...): for each of
-- the five yields, the plannable districts with an adjacency rule giving
-- that yield to this player (District_Adjacencies + Adjacency_YieldChanges,
-- any kind of neighbour). Derived from GameInfo, so unique districts and
-- rule changes come along. Returns { { Yield, Districts = { types in
-- PlannableDistricts order } } } in YIELDS order, yields without districts
-- left out.
function SDP_Rules.Templates(playerID)
  local player = Players[playerID]
  local traits = MapTacks.PlayerTraits(playerID)
  local excluded = {}
  for row in GameInfo.ExcludedAdjacencies() do
    excluded[row.YieldChangeId] = excluded[row.YieldChangeId] or {}
    table.insert(excluded[row.YieldChangeId], row.TraitType)
  end
  local gives = {} -- [district][yield] = true
  for link in GameInfo.District_Adjacencies() do
    local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
    if row ~= nil and row.YieldChange > 0 and RowApplies(row, player, traits, excluded) then
      gives[link.DistrictType] = gives[link.DistrictType] or {}
      gives[link.DistrictType][row.YieldType] = true
    end
  end
  local out = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local districts = {}
    for _, d in ipairs(SDP_Rules.PlannableDistricts(playerID)) do
      if gives[d.Type] and gives[d.Type][yieldType] then districts[#districts + 1] = d.Type end
    end
    if #districts > 0 then out[#out + 1] = { Yield = yieldType, Districts = districts } end
  end
  return out
end

-- Districts a plan may add on its own when the city needs them (feedback
-- item 4), read from GameInfo, never by name:
--   "WATER"  Districts.Aqueduct (the aqueduct and the uniques replacing it):
--            added when the city has no fresh water
--   "FLOOD"  Districts_XP2.PreventsFloods (the dam, Gathering Storm only):
--            added when the city has AUTO_FLOOD_PLOTS or more plots with a
--            feature the district requires (District_RequiredFeatures: the
--            floodplains)
-- Returns the kind for a district type, or nil.
SDP_Rules.AUTO_FLOOD_PLOTS = 3

function SDP_Rules.AutoKind(districtType)
  local row = GameInfo.Districts[districtType]
  if row == nil then return nil end
  if row.Aqueduct then return "WATER" end
  local xp2 = GameInfo.Districts_XP2 and GameInfo.Districts_XP2[districtType]
  if xp2 ~= nil and xp2.PreventsFloods then return "FLOOD" end
  return nil
end

-- Features a district must stand on (District_RequiredFeatures): a set.
function SDP_Rules.RequiredFeatures(districtType)
  local set = {}
  if GameInfo.District_RequiredFeatures ~= nil then
    for row in GameInfo.District_RequiredFeatures() do
      if row.DistrictType == districtType then set[row.FeatureType] = true end
    end
  end
  return set
end

-- ===========================================================================
-- Districts kept apart (2026-10-21 feedback: the harbor and the commercial
-- hub). A building gives the player one more trade route only when its city
-- has no building B: a MODIFIER_PLAYER_ADJUST_TRADE_ROUTE_CAPACITY modifier
-- whose requirement sets hold an inverted REQUIREMENT_CITY_HAS_BUILDING on B
-- (in the game's rules the lighthouse's, B = the market). Both districts in
-- one city then give one trade route, in two cities two.
-- Returns {
--   Pairs     { { A, B, Building, Other } }: base district types; A's
--             Building loses its route when the city has B's Other. Sorted.
--   Partners  { [district type] = { [district type] = true } }: both ways,
--             a unique district standing for the one it replaces
-- }, both empty when the rules have no such modifier.
-- ===========================================================================
local m_apart, m_apartFor = nil, nil

local function BaseDistrict(districtType)
  local replaces = GameInfo.DistrictReplaces[districtType]
  return replaces and replaces.ReplacesDistrictType or districtType
end
SDP_Rules.BaseDistrict = BaseDistrict

function SDP_Rules.Apart()
  if m_apart ~= nil and m_apartFor == GameInfo then return m_apart end
  m_apart, m_apartFor = { Pairs = {}, Partners = {} }, GameInfo
  if GameInfo.BuildingModifiers == nil or GameInfo.RequirementSetRequirements == nil then return m_apart end
  local sets, argument = {}, {}
  for row in GameInfo.RequirementSetRequirements() do
    sets[row.RequirementSetId] = sets[row.RequirementSetId] or {}
    table.insert(sets[row.RequirementSetId], row.RequirementId)
  end
  for row in GameInfo.RequirementArguments() do
    if row.Name == "BuildingType" then argument[row.RequirementId] = row.Value end
  end
  local pairs, seen = {}, {}
  for row in GameInfo.BuildingModifiers() do
    local modifier = GameInfo.Modifiers[row.ModifierId]
    if modifier ~= nil and modifier.ModifierType == "MODIFIER_PLAYER_ADJUST_TRADE_ROUTE_CAPACITY" then
      for _, setId in ipairs({ modifier.SubjectRequirementSetId or "", modifier.OwnerRequirementSetId or "" }) do
        for _, requirementId in ipairs(sets[setId] or {}) do
          local requirement = GameInfo.Requirements[requirementId]
          local other = argument[requirementId]
          if requirement ~= nil and requirement.RequirementType == "REQUIREMENT_CITY_HAS_BUILDING" and requirement.Inverse
              and other ~= nil then
            local a, b = GameInfo.Buildings[row.BuildingType], GameInfo.Buildings[other]
            if a ~= nil and b ~= nil and a.PrereqDistrict ~= nil and b.PrereqDistrict ~= nil then
              local da, db = BaseDistrict(a.PrereqDistrict), BaseDistrict(b.PrereqDistrict)
              local key = da .. "|" .. db
              if da ~= db and not seen[key] then
                seen[key] = true
                pairs[#pairs + 1] = { A = da, B = db, Building = a.BuildingType, Other = b.BuildingType }
              end
            end
          end
        end
      end
    end
  end
  table.sort(pairs, function(x, y)
    if x.A ~= y.A then return x.A < y.A end
    return x.B < y.B
  end)
  local byBase = {}
  for row in GameInfo.Districts() do
    local base = BaseDistrict(row.DistrictType)
    byBase[base] = byBase[base] or {}
    table.insert(byBase[base], row.DistrictType)
  end
  local partners = {}
  local function Link(x, y)
    for _, tx in ipairs(byBase[x] or {}) do
      partners[tx] = partners[tx] or {}
      for _, ty in ipairs(byBase[y] or {}) do partners[tx][ty] = true end
    end
  end
  for _, pair in ipairs(pairs) do
    Link(pair.A, pair.B)
    Link(pair.B, pair.A)
  end
  m_apart, m_apartFor = { Pairs = pairs, Partners = partners }, GameInfo
  return m_apart
end

-- The pairs (SDP_Rules.Apart) a city ends up with both of, given the types
-- a plan places there (a list) and the ones it has already (`present`, a
-- set, may be nil); a pair the city had before the plan is left out:
-- { { A, B, Building, Other } } with the city's own types (a unique one as
-- it is), in Pairs order.
function SDP_Rules.Together(types, present)
  local have, planned = {}, {}
  for _, districtType in ipairs(types) do
    local base = BaseDistrict(districtType)
    if have[base] == nil then have[base] = districtType end
    planned[base] = true
  end
  local before = {}
  for districtType in pairs(present or {}) do before[#before + 1] = districtType end
  table.sort(before)
  for _, districtType in ipairs(before) do
    local base = BaseDistrict(districtType)
    if have[base] == nil then have[base] = districtType end
  end
  local out = {}
  for _, pair in ipairs(SDP_Rules.Apart().Pairs) do
    if have[pair.A] and have[pair.B] and (planned[pair.A] or planned[pair.B]) then
      out[#out + 1] = { A = have[pair.A], B = have[pair.B], Building = pair.Building, Other = pair.Other }
    end
  end
  return out
end

-- Districts one city cannot have together (MutuallyExclusiveDistricts: the
-- entertainment complex and the water park, and the unique districts that
-- replace them). DMT checks this only against built districts, so a plan
-- could hold both (late-game stress test, 2026-10-21); the solvers keep
-- them apart. { [district type] = { [district type] = true } }, both ways,
-- cached per GameInfo; empty when the rules have no such table.
local m_exclusive, m_exclusiveFor = nil, nil

function SDP_Rules.Exclusive()
  if m_exclusive ~= nil and m_exclusiveFor == GameInfo then return m_exclusive end
  m_exclusive, m_exclusiveFor = {}, GameInfo
  if GameInfo.MutuallyExclusiveDistricts == nil then return m_exclusive end
  for row in GameInfo.MutuallyExclusiveDistricts() do
    local a, b = row.District, row.MutuallyExclusiveDistrict
    if a ~= nil and b ~= nil and a ~= b then
      m_exclusive[a] = m_exclusive[a] or {}
      m_exclusive[b] = m_exclusive[b] or {}
      m_exclusive[a][b], m_exclusive[b][a] = true, true
    end
  end
  return m_exclusive
end

-- The first type in `types` (a set) that `districtType` cannot share a city
-- with, by name; nil when none.
function SDP_Rules.ExcludedBy(districtType, types)
  local others = SDP_Rules.Exclusive()[districtType]
  if others == nil then return nil end
  local found = nil
  for other in pairs(types) do
    if others[other] and (found == nil or other < found) then found = other end
  end
  return found
end

-- Yields a district of type `district` gains from one adjacent `neighbour`
-- (a district type, or a wonder: a building type), from an AdjacencyTable.
-- Returns a new table.
function SDP_Rules.NeighbourGain(adjacency, district, neighbour)
  local gain = {}
  local entry = adjacency[district]
  if entry == nil then return gain end
  local isWonder = GameInfo.Buildings[neighbour] ~= nil
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local amount
    if isWonder then
      amount = (entry.Wonder or {})[yieldType] or 0
    else
      amount = (entry.Any[yieldType] or 0) + ((entry.From[neighbour] or {})[yieldType] or 0)
    end
    if amount ~= 0 then gain[yieldType] = amount end
  end
  return gain
end
