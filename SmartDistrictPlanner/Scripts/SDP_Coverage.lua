-- SDP_Coverage: how many of the player's cities the planned districts and
-- wonders reach with their regional buildings (docs/multicity-design.md 19).
--
--   Reach     a district's range is the largest Buildings.RegionalRange of
--             the buildings that need its base district (a unique district
--             counts as the one it replaces), generic buildings and the
--             player's own (trait); a wonder's range is its own. Groups: one
--             per base district, one per wonder. A city reached twice by the
--             same group counts once (the game does not stack the effect).
--   Targets   every city of the player, then the new cities being planned.
--   Covered   what the player's built and pinned districts reach already
--             (pins being replaced do not count).
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

-- { [district or wonder type] = { Group, Range } } for every type with a reach.
function SDP_Coverage.Reaches(playerID)
  local traits = MapTacks.PlayerTraits(playerID)
  local byBase, out = {}, {}
  for row in GameInfo.Buildings() do
    local range = row.RegionalRange or 0
    if range > 0 and (row.TraitType == nil or traits[row.TraitType]) then
      if row.PrereqDistrict ~= nil then
        byBase[row.PrereqDistrict] = math.max(byBase[row.PrereqDistrict] or 0, range)
      elseif row.IsWonder then
        out[row.BuildingType] = { Group = row.BuildingType, Range = range }
      end
    end
  end
  for row in GameInfo.Districts() do
    local base = BaseOf(row.DistrictType)
    if byBase[base] ~= nil then out[row.DistrictType] = { Group = base, Range = byBase[base] } end
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
    if Map.GetPlotDistance(x, y, target.X, target.Y) <= reach.Range then out[#out + 1] = (g - 1) * count + t end
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

-- Keys of the targets within reach of `subjectType` at x, y, in target
-- order (whether covered before or not); nil when the type has no reach.
function Model:Reach(subjectType, x, y)
  local ids = self:InReach(subjectType, x, y)
  if ids == nil then return nil end
  local keys = {}
  for _, id in ipairs(ids) do keys[#keys + 1] = self:Pair(id).Key end
  return keys
end
