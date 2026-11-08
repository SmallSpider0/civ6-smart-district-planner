-- SDP_Coverage: how many of the player's cities the planned districts and
-- wonders reach with their regional buildings (docs/multicity-design.md 19).
--
--   Reach     a district's range is the largest Buildings.RegionalRange of
--             the buildings that need its base district (a unique district
--             counts as the one it replaces), generic buildings and the
--             player's own (trait), plus what the player's modifiers add now
--             (ExtraRanges: a city-state's suzerain bonus, issue 197); a
--             wonder's range is its own. Groups: one
--             per base district, one per wonder. A city reached twice by the
--             same group counts once (the game does not stack the effect).
--   Targets   every city of the player, then the new cities being planned
--             (the single-city tab: every city-center pin, SiteTargets).
--   Covered   what the player's built and pinned districts reach already
--             (pins being replaced do not count).
--   Own city  a planned district or wonder counts the city it is planned
--             for like any other (issue 346, decided 2026-11-08, replacing
--             issue 91's "not its own city"): the count is how many cities
--             first get the group's effect from the plan. Two cities each
--             planning an industrial zone within reach of the other count 2.
-- A layout is worth Weight x the (city, group) pairs it newly covers; the
-- search adds that to the DMT gain and the land part (SDP_Search).
-- Everything is read from GameInfo; lists are sorted (constraint 6).

SDP_Coverage = {}

local Model = {}
Model.__index = Model

local function BaseOf(districtType)
  local row = GameInfo.DistrictReplaces[districtType]
  return row and row.ReplacesDistrictType or districtType
end
SDP_Coverage.BaseOf = BaseOf

local EXTRA_RANGE = "EFFECT_ADJUST_DISTRICT_EXTRA_REGIONAL_RANGE"

local function Rows(name)
  local t = GameInfo[name]
  return t ~= nil and t or function() return function() return nil end end
end

-- The district types a player-wide modifier's subject requirement set
-- picks: { [type] = true }, or nil when the set has a requirement other than
-- "district type matches" (not read; the extra range is then left out). A
-- requirement naming a base district also matches the unique districts that
-- replace it.
local function SubjectDistricts(setId)
  local all = {}
  for row in GameInfo.Districts() do all[#all + 1] = row.DistrictType end
  if setId == nil then
    local out = {}
    for _, t in ipairs(all) do out[t] = true end
    return out
  end
  local set = GameInfo.RequirementSets ~= nil and GameInfo.RequirementSets[setId] or nil
  local any = set ~= nil and set.RequirementSetType == "REQUIREMENTSET_TEST_ANY"
  local named = {}
  for row in Rows("RequirementSetRequirements")() do
    if row.RequirementSetId == setId then
      local requirement = GameInfo.Requirements ~= nil and GameInfo.Requirements[row.RequirementId] or nil
      if requirement == nil or requirement.RequirementType ~= "REQUIREMENT_DISTRICT_TYPE_MATCHES" or requirement.Inverse then
        return nil
      end
      local value
      for arg in Rows("RequirementArguments")() do
        if arg.RequirementId == row.RequirementId and arg.Name == "DistrictType" then value = arg.Value end
      end
      if value == nil then return nil end
      named[#named + 1] = value
    end
  end
  if #named == 0 then return nil end
  local out = {}
  for _, t in ipairs(all) do
    local hits = 0
    for _, n in ipairs(named) do
      if t == n or BaseOf(t) == n then hits = hits + 1 end
    end
    if (any and hits > 0) or (not any and hits == #named) then out[t] = true end
  end
  return out
end

-- Extra regional range the player has now on every district of a type
-- (issue 197): active modifiers owned by the player whose effect adds
-- regional range to the player's districts, such as the suzerain bonus of
-- Toronto. Read from the game's modifiers (GameEffects) and the rules; a
-- modifier on one district (a great engineer's) is not counted.
-- { [district type] = extra }.
function SDP_Coverage.ExtraRanges(playerID)
  local out = {}
  if GameEffects == nil or GameInfo.Modifiers == nil or GameInfo.DynamicModifiers == nil then return out end
  local found = {}
  for _, id in ipairs(GameEffects.GetModifiers() or {}) do
    local owner = GameEffects.GetModifierActive(id) and GameEffects.GetModifierOwner(id) or nil
    if owner ~= nil and GameEffects.GetObjectsPlayerId(owner) == playerID then
      local setId = GameEffects.GetModifierOwnerRequirementSet(id)
      local met = setId == nil or GameEffects.GetRequirementSetState(setId) == "Met"
      local def = met and GameEffects.GetModifierDefinition(id) or nil
      local row = def ~= nil and GameInfo.Modifiers[def.Id] or nil
      local dynamic = row ~= nil and GameInfo.DynamicModifiers[row.ModifierType] or nil
      if dynamic ~= nil and dynamic.EffectType == EXTRA_RANGE and dynamic.CollectionType == "COLLECTION_PLAYER_DISTRICTS" then
        found[#found + 1] = row
      end
    end
  end
  table.sort(found, function(a, b) return a.ModifierId < b.ModifierId end)
  for _, row in ipairs(found) do
    local amount = 0
    for arg in Rows("ModifierArguments")() do
      if arg.ModifierId == row.ModifierId and arg.Name == "Amount" then amount = tonumber(arg.Value) or 0 end
    end
    local types = amount ~= 0 and SubjectDistricts(row.SubjectRequirementSetId) or nil
    for t in pairs(types or {}) do out[t] = (out[t] or 0) + amount end
  end
  return out
end

-- { [district or wonder type] = { Group, Range, Extra } } for every type with
-- a reach; Extra: what ExtraRanges adds to a district's range (0 for none).
function SDP_Coverage.Reaches(playerID)
  local traits = MapTacks.PlayerTraits(playerID)
  local byBase, out = {}, {}
  for row in GameInfo.Buildings() do
    local range = row.RegionalRange or 0
    if range > 0 and (row.TraitType == nil or traits[row.TraitType]) then
      if row.PrereqDistrict ~= nil then
        byBase[row.PrereqDistrict] = math.max(byBase[row.PrereqDistrict] or 0, range)
      elseif row.IsWonder then
        out[row.BuildingType] = { Group = row.BuildingType, Range = range, Extra = 0 }
      end
    end
  end
  local extra = SDP_Coverage.ExtraRanges(playerID)
  for row in GameInfo.Districts() do
    local base = BaseOf(row.DistrictType)
    if byBase[base] ~= nil then
      local more = math.max(0, extra[row.DistrictType] or 0)
      out[row.DistrictType] = { Group = base, Range = byBase[base] + more, Extra = more }
    end
  end
  return out
end

-- The player's cities by ID ({ Key = "C<id>", X, Y, CityID, Name }), then
-- `sites` ({ Key, X, Y, Name }) in the order given.
function SDP_Coverage.Targets(playerID, sites)
  local cities = {}
  for _, city in Players[playerID]:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  local list = {}
  for _, city in ipairs(cities) do
    list[#list + 1] = { Key = "C" .. city:GetID(), X = city:GetX(), Y = city:GetY(), CityID = city:GetID(), Name = city:GetName() }
  end
  for _, site in ipairs(sites or {}) do
    list[#list + 1] = { Key = site.Key, X = site.X, Y = site.Y, Name = site.Name }
  end
  return list
end

-- Every city-center pin of the player as a target ({ Key = "S<plot index>",
-- X, Y, Name }, by plot index): the single-city tab counts all of them.
function SDP_Coverage.SiteTargets(playerID)
  local list = {}
  for _, site in ipairs(SDP_City.Sites(playerID)) do
    list[#list + 1] = { Key = "S" .. site.Index, X = site.X, Y = site.Y, Name = site.Name }
  end
  return list
end

-- The player's built districts and district pins with a reach, sorted by
-- plot index and type: { Type, X, Y }. Pins in `ignorePins` ([pin ID] =
-- true, this mod's earlier pins being replaced) are left out.
function SDP_Coverage.Sources(playerID, reaches, ignorePins)
  local list = {}
  for _, district in Players[playerID]:GetDistricts():Members() do
    local row = GameInfo.Districts[district:GetType()]
    if row ~= nil and reaches[row.DistrictType] ~= nil then
      list[#list + 1] = { Type = row.DistrictType, X = district:GetX(), Y = district:GetY() }
    end
  end
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    if not (ignorePins and ignorePins[pin:GetID()]) then
      local key = (pin:GetIconName() or ""):gsub("^ICON_", "")
      if reaches[key] ~= nil and GameInfo.Districts[key] ~= nil then
        list[#list + 1] = { Type = key, X = pin:GetHexX(), Y = pin:GetHexY() }
      end
    end
  end
  table.sort(list, function(a, b)
    local ia, ib = Map.GetPlotIndex(a.X, a.Y), Map.GetPlotIndex(b.X, b.Y)
    if ia ~= ib then return ia < ib end
    return a.Type < b.Type
  end)
  return list
end

-- spec = { PlayerID, Weight (> 0), Sites (as for Targets), IgnorePins }
function SDP_Coverage.New(spec)
  local self = setmetatable({}, Model)
  local playerID = spec.PlayerID
  self.Weight = spec.Weight
  self.Reaches = SDP_Coverage.Reaches(playerID)
  self.Targets = SDP_Coverage.Targets(playerID, spec.Sites)
  local groups, seen = {}, {}
  for _, reach in pairs(self.Reaches) do
    if not seen[reach.Group] then
      seen[reach.Group] = true
      groups[#groups + 1] = reach.Group
    end
  end
  table.sort(groups)
  self.Groups, self.GroupIndex = groups, {}
  for g, name in ipairs(groups) do self.GroupIndex[name] = g end
  -- A (group, target) pair is the number (g - 1) * #Targets + t.
  self.Covered, self.Lists, self.Seen, self.Stamp = {}, {}, {}, 0
  self.Sources = SDP_Coverage.Sources(playerID, self.Reaches, spec.IgnorePins)
  for _, source in ipairs(self.Sources) do
    for _, id in ipairs(self:InReach(source.Type, source.X, source.Y)) do self.Covered[id] = true end
  end
  return self
end

-- Pair numbers of every target within reach of `subjectType` at x, y (nil:
-- the type has no reach).
function Model:InReach(subjectType, x, y)
  local reach = self.Reaches[subjectType]
  if reach == nil then return nil end
  local g, count, out = self.GroupIndex[reach.Group], #self.Targets, {}
  for t, target in ipairs(self.Targets) do
    if Map.GetPlotDistance(x, y, target.X, target.Y) <= reach.Range then
      out[#out + 1] = (g - 1) * count + t
    end
  end
  return out
end

-- The pairs a placement would newly cover on its own (cached per type and
-- plot); nil when the type has no reach.
function Model:List(subjectType, plotIndex, x, y)
  local byType = self.Lists[subjectType]
  if byType == nil then
    if self.Reaches[subjectType] == nil then return nil end
    byType = {}
    self.Lists[subjectType] = byType
  end
  local list = byType[plotIndex]
  if list == nil then
    list = {}
    for _, id in ipairs(self:InReach(subjectType, x, y)) do
      if not self.Covered[id] then list[#list + 1] = id end
    end
    byType[plotIndex] = list
  end
  return list
end

-- Distinct pairs over lists[1..n].
function Model:Count(lists, n)
  self.Stamp = self.Stamp + 1
  local stamp, seen, count = self.Stamp, self.Seen, 0
  for l = 1, n do
    for _, id in ipairs(lists[l]) do
      if seen[id] ~= stamp then
        seen[id] = stamp
        count = count + 1
      end
    end
  end
  return count
end

-- The target a pair number stands for, and its group.
function Model:Pair(id)
  local count = #self.Targets
  local g = math.floor((id - 1) / count) + 1
  return self.Targets[id - (g - 1) * count], self.Groups[g]
end

-- Keys of the targets `subjectType` at x, y newly covers (within reach and
-- not covered by a built or pinned district of its group), in target order;
-- nil when the type has no reach.
function Model:Reach(subjectType, x, y)
  local ids = self:InReach(subjectType, x, y)
  if ids == nil then return nil end
  local keys = {}
  for _, id in ipairs(ids) do
    if not self.Covered[id] then keys[#keys + 1] = self:Pair(id).Key end
  end
  return keys
end

-- The newly covered pairs `ids` (sorted) by group, for reports: returns the
-- count and { { Group, Keys (target keys), Range, Extra } } in order of first
-- appearance (Range and Extra: the group's own type, as in Reaches).
function Model:Summary(ids)
  local byGroup, list = {}, {}
  for _, id in ipairs(ids) do
    local target, group = self:Pair(id)
    if byGroup[group] == nil then
      local reach = self.Reaches[group] or {}
      byGroup[group] = { Group = group, Keys = {}, Range = reach.Range, Extra = reach.Extra or 0 }
      list[#list + 1] = byGroup[group]
    end
    local keys = byGroup[group].Keys
    keys[#keys + 1] = target.Key
  end
  return #ids, list
end
