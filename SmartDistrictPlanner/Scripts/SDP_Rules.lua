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
