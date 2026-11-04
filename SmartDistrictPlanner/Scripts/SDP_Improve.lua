-- SDP_Improve: improvements planned with the districts (issue 227,
-- docs/notes/issue-227-improvement-tacks.md).
--
-- Two kinds of improvement tacks:
--   1. For the districts (Model:Assign): next to a planned district, an
--      improvement that gives it adjacency (Adjacency_YieldChanges rows with
--      AdjacentImprovement in its District_Adjacencies, and
--      EFFECT_IMPROVEMENT_ADJACENCY modifiers of the player's traits), or one
--      the district gives yields (Improvement_Adjacencies rows next to a
--      district or wonder, and EFFECT_ADJUST_PLOT_YIELD modifiers whose only
--      requirements are "this plot has improvement X" and "next to district
--      Y"). The search (SDP_Search) asks Assign for every layout which plots
--      get which improvement; DMT scores the districts with them on the map
--      (silent board slots, like the Camp of issue 51) and the land part
--      counts each such plot with its improvement plus what the districts
--      give it (as a preserve's yields, issue 91).
--   2. For the worked plots (Model:Worked): once the plan is chosen, the
--      plots the city works that have no improvement get the one the land
--      part assumes there. Never one that would change a district's
--      adjacency, so these leave the plan's value as it is.
-- Rules come from GameInfo and the player's traits; Assign is a model
-- (whole steps of TilesRequired, the request's weights), it never calls
-- DMT. Loops run over sorted arrays: the same input gives the same choice
-- (requirement constraint 6).

SDP_Improve = {}

local function Rows(name)
  return GameInfo[name] ~= nil and GameInfo[name]() or function() return nil end
end

local function Flag(v) return v == true or (type(v) == "number" and v ~= 0) end

local function Split(text)
  local list = {}
  for part in tostring(text or ""):gmatch("[^,]+") do list[#list + 1] = part end
  return list
end

-- Modifier arguments, requirement sets and requirement arguments, indexed
-- once per GameInfo.
local m_index, m_indexFor = nil, nil
local function Index()
  if m_index ~= nil and m_indexFor == GameInfo then return m_index end
  local index = { Args = {}, SetRequirements = {}, RequirementArgs = {} }
  for row in Rows("ModifierArguments") do
    index.Args[row.ModifierId] = index.Args[row.ModifierId] or {}
    index.Args[row.ModifierId][row.Name] = row.Value
  end
  for row in Rows("RequirementSetRequirements") do
    local list = index.SetRequirements[row.RequirementSetId] or {}
    list[#list + 1] = row.RequirementId
    index.SetRequirements[row.RequirementSetId] = list
  end
  for row in Rows("RequirementArguments") do
    index.RequirementArgs[row.RequirementId] = index.RequirementArgs[row.RequirementId] or {}
    index.RequirementArgs[row.RequirementId][row.Name] = row.Value
  end
  m_index, m_indexFor = index, GameInfo
  return index
end

local function EffectOf(modifierId)
  local modifier = GameInfo.Modifiers ~= nil and GameInfo.Modifiers[modifierId] or nil
  if modifier == nil or GameInfo.DynamicModifiers == nil then return nil, modifier end
  local dynamic = GameInfo.DynamicModifiers[modifier.ModifierType]
  return dynamic and dynamic.EffectType or nil, modifier
end

-- The requirements of a plot-yield modifier when they are only "the plot
-- has improvement X" and "the plot is next to district Y" (all of them,
-- none inverted): { Improvement, District }; nil for anything else (the
-- modifier is then not counted).
local function PlotRequirements(index, setId)
  if setId == nil or GameInfo.RequirementSets == nil or GameInfo.Requirements == nil then return nil end
  local set = GameInfo.RequirementSets[setId]
  if set == nil or (set.RequirementSetType ~= nil and set.RequirementSetType ~= "REQUIREMENTSET_TEST_ALL") then return nil end
  local out = {}
  for _, id in ipairs(index.SetRequirements[setId] or {}) do
    local req = GameInfo.Requirements[id]
    if req == nil or Flag(req.Inverse) then return nil end
    local args = index.RequirementArgs[id] or {}
    for name in pairs(args) do
      if name ~= "ImprovementType" and name ~= "DistrictType" then return nil end
    end
    if req.RequirementType == "REQUIREMENT_PLOT_IMPROVEMENT_TYPE_MATCHES" and args.ImprovementType ~= nil
        and out.Improvement == nil then
      out.Improvement = args.ImprovementType
    elseif req.RequirementType == "REQUIREMENT_PLOT_ADJACENT_DISTRICT_TYPE_MATCHES" and args.DistrictType ~= nil
        and out.District == nil then
      out.District = args.DistrictType
    else
      return nil
    end
  end
  if out.District == nil then return nil end
  return out
end

-- The rules for one player:
--   Gives[district] = { { Improvement, Yield, Amount, Tiles } }: the district
--     gets Amount per Tiles adjacent improvements of that type
--   Takes[improvement] = { { District (type) | Any (any district) | Wonder,
--     Yields = { { Yield, Amount } }, Tiles, Once } }: the improvement gets
--     Amount per Tiles adjacent districts (Once: once when next to one)
--   Features[district] = { [feature] = true }: features adjacent to the
--     district that give it adjacency (any modifier counts): improvements
--     never clear them next to it
-- Rows of Adjacency_YieldChanges apply as DMT applies them (technologies,
-- civics, ExcludedAdjacencies: SDP_Rules.RowApplies).
function SDP_Improve.Rules(playerID)
  local player = Players[playerID]
  local traits = MapTacks.PlayerTraits(playerID) or {}
  local excluded = {}
  for row in Rows("ExcludedAdjacencies") do
    excluded[row.YieldChangeId] = excluded[row.YieldChangeId] or {}
    table.insert(excluded[row.YieldChangeId], row.TraitType)
  end
  local index = Index()
  local rules = { Gives = {}, Takes = {}, Features = {} }
  local function Give(district, improvement, yieldType, amount, tiles)
    if district == nil or improvement == nil or yieldType == nil or (amount or 0) == 0 then return end
    local list = rules.Gives[district] or {}
    list[#list + 1] = { Improvement = improvement, Yield = yieldType, Amount = amount, Tiles = math.max(1, tiles or 1) }
    rules.Gives[district] = list
  end
  local function Take(improvement, row)
    if improvement == nil or #row.Yields == 0 then return end
    local list = rules.Takes[improvement] or {}
    list[#list + 1] = row
    rules.Takes[improvement] = list
  end
  local function Feature(district, feature)
    if district == nil or feature == nil then return end
    rules.Features[district] = rules.Features[district] or {}
    rules.Features[district][feature] = true
  end
  local function PlotYields(args)
    local yields, types, amounts = {}, Split(args.YieldType), Split(args.Amount)
    for k, yieldType in ipairs(types) do
      local amount = tonumber(amounts[k] or amounts[1])
      if amount ~= nil and amount ~= 0 then yields[#yields + 1] = { Yield = yieldType, Amount = amount } end
    end
    return yields
  end
  for link in Rows("District_Adjacencies") do
    local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
    if row ~= nil then
      if row.AdjacentImprovement ~= nil and SDP_Rules.RowApplies(row, player, traits, excluded) then
        Give(link.DistrictType, row.AdjacentImprovement, row.YieldType, row.YieldChange, row.TilesRequired)
      end
      if row.AdjacentFeature ~= nil then Feature(link.DistrictType, row.AdjacentFeature) end
    end
  end
  for link in Rows("Improvement_Adjacencies") do
    local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
    if row ~= nil and (row.AdjacentDistrict ~= nil or Flag(row.OtherDistrictAdjacent) or Flag(row.AdjacentWonder))
        and SDP_Rules.RowApplies(row, player, traits, excluded) then
      Take(link.ImprovementType, {
        District = (not Flag(row.OtherDistrictAdjacent) and not Flag(row.AdjacentWonder)) and row.AdjacentDistrict or nil,
        Any = Flag(row.OtherDistrictAdjacent), Wonder = Flag(row.AdjacentWonder),
        Yields = { { Yield = row.YieldType, Amount = row.YieldChange } }, Tiles = math.max(1, row.TilesRequired or 1) })
    end
  end
  for row in Rows("TraitModifiers") do
    if traits[row.TraitType] then
      local effect, modifier = EffectOf(row.ModifierId)
      local args = index.Args[row.ModifierId] or {}
      if effect == "EFFECT_IMPROVEMENT_ADJACENCY" then
        Give(args.DistrictType, args.ImprovementType, args.YieldType, tonumber(args.Amount), tonumber(args.TilesRequired))
      elseif effect == "EFFECT_ADJUST_PLOT_YIELD" then
        local req = PlotRequirements(index, modifier.SubjectRequirementSetId)
        if req ~= nil and req.Improvement ~= nil then
          Take(req.Improvement, { District = req.District, Yields = PlotYields(args), Tiles = 1, Once = true })
        end
      end
    end
  end
  for row in Rows("ImprovementModifiers") do
    local effect, modifier = EffectOf(row.ModifierId)
    if effect == "EFFECT_ADJUST_PLOT_YIELD" then
      local req = PlotRequirements(index, modifier.SubjectRequirementSetId)
      if req ~= nil and (req.Improvement == nil or req.Improvement == row.ImprovementType) then
        Take(row.ImprovementType, { District = req.District, Yields = PlotYields(index.Args[row.ModifierId] or {}), Tiles = 1,
          Once = true })
      end
    end
  end
  for row in Rows("Modifiers") do
    local effect = EffectOf(row.ModifierId)
    if effect == "EFFECT_FEATURE_ADJACENCY" then
      local args = index.Args[row.ModifierId] or {}
      Feature(args.DistrictType, args.FeatureType)
    end
  end
  return rules
end

-- What the districts and wonders `around` give an improvement of type
-- `improvementType` (Takes), weighted by `w` (missing yields weigh 0).
-- around = { Districts = { types }, Wonders = n }. `onceOnly`: the modifier
-- rows alone (Once), the ones DMT does not count.
function SDP_Improve.TakeValue(rules, improvementType, around, w, onceOnly)
  local total = 0
  for _, row in ipairs(rules.Takes[improvementType] or {}) do
    if row.Once or not onceOnly then
      local count = 0
      if row.Wonder then
        count = around.Wonders or 0
      else
        for _, d in ipairs(around.Districts) do
          if row.Any or d == row.District then count = count + 1 end
        end
      end
      local steps = row.Once and (count > 0 and 1 or 0) or math.floor(count / row.Tiles)
      if steps > 0 then
        for _, y in ipairs(row.Yields) do total = total + steps * y.Amount * (w[y.Yield] or 0) end
      end
    end
  end
  return total
end

-- The same unweighted: { [yield] = amount } (for the result's tooltips).
function SDP_Improve.TakeYields(rules, improvementType, around)
  local out = {}
  for _, row in ipairs(rules.Takes[improvementType] or {}) do
    local count = 0
    if row.Wonder then
      count = around.Wonders or 0
    else
      for _, d in ipairs(around.Districts) do
        if row.Any or d == row.District then count = count + 1 end
      end
    end
    local steps = row.Once and (count > 0 and 1 or 0) or math.floor(count / row.Tiles)
    for _, y in ipairs(row.Yields) do
      if steps > 0 then out[y.Yield] = (out[y.Yield] or 0) + steps * y.Amount end
    end
  end
  return out
end

-- ===========================================================================
-- The model a search uses
-- ===========================================================================
local Model = {}
Model.__index = Model

-- spec = {
--   PlayerID
--   Weights      the request's adjacency weights by yield (SDP_Rules.YieldWeights)
--   PlotWeights  the land part's plot weights (SDP_Land.PlotWeights), nil
--                when the land part is off
--   Lands        the search's land models (their plots and ranks)
--   AllowRemoval whether features may be cleared (requirement constraint 5)
--   Ownable      { [plot index] = true }: unowned plots a participating city
--                can come to own
--   Taken        { [plot index] = true }: fixed subjects and every pin
--   Fixed        the fixed subjects (SDP_Overlay.FixedSubjects): districts
--                and improvement tacks next to the plan count
-- }
function SDP_Improve.New(spec)
  local self = setmetatable({}, Model)
  self.PlayerID, self.Weights = spec.PlayerID, spec.Weights or {}
  self.Rules = SDP_Improve.Rules(spec.PlayerID)
  self.LandOn = spec.PlotWeights ~= nil and #(spec.Lands or {}) > 0
  self.Lands = spec.Lands or {}
  self.Ctx = SDP_Land.Context(spec.PlayerID, spec.PlotWeights, spec.AllowRemoval ~= false)
  self.Ownable, self.Taken = spec.Ownable or {}, spec.Taken or {}
  -- What is on the map already: fixed districts and improvement tacks.
  self.FixedDistrict, self.FixedImprovement = {}, {}
  for _, subject in ipairs(spec.Fixed or {}) do
    local index = Map.GetPlotIndex(subject.X, subject.Y)
    if subject.Type == "DISTRICT" then self.FixedDistrict[index] = subject.Key
    elseif subject.Type == "IMPROVEMENT" then self.FixedImprovement[index] = subject.Key end
  end
  -- District types an improvement can matter to.
  self.Target = {}
  for district in pairs(self.Rules.Gives) do self.Target[district] = true end
  -- What districts give improvements counts only in the land part.
  self.AnyTake = false
  if self.LandOn then
    for _, rows in pairs(self.Rules.Takes) do
      for _, row in ipairs(rows) do
        if row.District ~= nil then self.Target[row.District] = true end
        if row.Any then self.AnyTake = true end
      end
    end
  end
  self.options, self.neighbours, self.subjects, self.rings = {}, {}, {}, {}
  self.assigned, self.assignedCount = {}, 0 -- Assign's groups by their surroundings
  return self
end

-- Whether improvements can matter at all here.
function Model:Active()
  return next(self.Rules.Gives) ~= nil or (self.LandOn and next(self.Rules.Takes) ~= nil)
end

-- Whether a district of `districtType` can get an improvement next to it.
function Model:IsTarget(districtType)
  return self.Target[districtType] == true or self.AnyTake
end

function Model:Neighbours(index)
  local list = self.neighbours[index]
  if list == nil then
    list = {}
    local plot = Map.GetPlotByIndex(index)
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
      local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), direction)
      if n ~= nil then list[#list + 1] = n:GetIndex() end
    end
    self.neighbours[index] = list
  end
  return list
end

-- The improvements a free plot can take, one per type (the better of
-- keeping or clearing its feature; resources are kept): { Type, Entry,
-- Clear, Value } in type order. Empty for a plot no improvement may go on.
function Model:Options(index)
  local list = self.options[index]
  if list ~= nil then return list end
  list = {}
  local plot = Map.GetPlotByIndex(index)
  if SDP_Wonders.FreeForImprovement(self.PlayerID, plot, self.Ownable, self.Taken) then
    local byType, types = {}, {}
    for _, o in ipairs(SDP_Land.ImprovementOptions(plot, self.Ctx)) do
      if not o.Harvest then
        local t = o.Entry.Type
        local best = byType[t]
        if best == nil then types[#types + 1] = t end
        if best == nil or o.Value > best.Value + 1e-9 then
          byType[t] = { Type = t, Entry = o.Entry, Clear = o.Clear, Value = o.Value }
        end
      end
    end
    table.sort(types)
    for _, t in ipairs(types) do list[#list + 1] = byType[t] end
  end
  self.options[index] = list
  return list
end

-- The land model entry of a plot (its Tile and Rank) and the model, or nil.
function Model:LandEntry(index)
  for _, land in ipairs(self.Lands) do
    local p = land.ByIndex[index]
    if p ~= nil then return p, land end
  end
  return nil
end

-- The districts and wonders next to plot `index`: the planned ones
-- (`placedAt`: { [plot index] = { Type, Kind } }), the fixed ones and the
-- ones built. Returns { Districts = { types in direction order }, Wonders }.
function Model:Around(index, placedAt)
  local districts, wonders = {}, 0
  for _, n in ipairs(self:Neighbours(index)) do
    local placed = placedAt and placedAt[n] or nil
    if placed ~= nil then
      if placed.Kind == "WONDER" then wonders = wonders + 1 else districts[#districts + 1] = placed.Type end
    elseif self.FixedDistrict[n] ~= nil then
      districts[#districts + 1] = self.FixedDistrict[n]
    else
      local plot = Map.GetPlotByIndex(n)
      if plot:GetWonderType() ~= -1 then
        wonders = wonders + 1
      elseif plot:IsCity() or plot:GetDistrictType() ~= -1 then
        local d = plot:GetDistrictType()
        if d ~= -1 and GameInfo.Districts[d] ~= nil then districts[#districts + 1] = GameInfo.Districts[d].DistrictType end
      end
    end
  end
  return { Districts = districts, Wonders = wonders }
end

-- Whether clearing the feature of plot `index` would cost a district next
-- to it adjacency (Rules.Features).
function Model:FeatureMatters(index, around)
  local plot = Map.GetPlotByIndex(index)
  local feature = plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()] or nil
  if feature == nil then return false end
  for _, d in ipairs(around.Districts) do
    local set = self.Rules.Features[d]
    if set ~= nil and set[feature.FeatureType] then return true end
  end
  return false
end

-- Improvements of type `t` already next to plot `index` (built, or a fixed
-- improvement tack).
function Model:ExistingNext(index, t)
  local count = 0
  for _, n in ipairs(self:Neighbours(index)) do
    if self.FixedImprovement[n] == t then
      count = count + 1
    else
      local improvement = Map.GetPlotByIndex(n):GetImprovementType()
      if improvement ~= -1 and GameInfo.Improvements[improvement] ~= nil
          and GameInfo.Improvements[improvement].ImprovementType == t then
        count = count + 1
      end
    end
  end
  return count
end

-- The improvements for the districts of one layout.
--   placed   { { Type, Kind, Index } }: the layout's slots, in slot order
--   blocked  { [plot index] = true }: plots the layout uses otherwise (the
--            improvements wonders need)
-- Returns the plan, { { Index, Type, Clear } } sorted by plot index, and
-- the land values of the plots it changes, { [plot index] = tile value }
-- (nil when none): a planned improvement's plot with that improvement and
-- what the districts give it; a built improvement next to a planned
-- district plus what that district gives it.
--
-- Districts more than two plots apart share no plot and no neighbour of
-- one, so their improvements are chosen apart: the targets fall into groups
-- (within two plots of each other, transitively), and each group's choice
-- depends only on what is placed or blocked within two plots of its
-- districts. The search tries many layouts that differ in one group, so
-- each group's choice is kept by that key (the choice is the same whatever
-- else is placed: same input, same output).
function Model:Assign(placed, blocked)
  local placedAt, targets, at = {}, {}, {}
  for _, p in ipairs(placed) do
    placedAt[p.Index] = p
    if p.Kind ~= "WONDER" and self:IsTarget(p.Type) then
      targets[#targets + 1] = p
      at[p.Index] = #targets
    end
  end
  if #targets == 0 then return {}, nil end
  -- Groups: union of targets within two plots.
  local parent = {}
  for t = 1, #targets do parent[t] = t end
  local function Root(t)
    while parent[t] ~= t do t = parent[t] end
    return t
  end
  for t, p in ipairs(targets) do
    for _, n in ipairs(self:Ring2(p.Index)) do
      local u = at[n]
      if u ~= nil then
        local a, b = Root(t), Root(u)
        if a ~= b then
          if a < b then parent[b] = a else parent[a] = b end
        end
      end
    end
  end
  local groups, order = {}, {}
  for t = 1, #targets do
    local r = Root(t)
    if groups[r] == nil then
      groups[r] = {}
      order[#order + 1] = r
    end
    table.insert(groups[r], targets[t])
  end
  local cache = self.assigned
  local plan, forced = {}, nil
  for _, r in ipairs(order) do
    local group = groups[r]
    -- The key: the group's surroundings, plots in index order.
    -- (In slot order: the same surroundings in another order only miss the
    -- cache; AssignGroup does not depend on the order.)
    local parts, mark = {}, {}
    for _, p in ipairs(group) do
      mark[p.Index] = true
      parts[#parts + 1] = p.Index .. p.Type
    end
    for _, p in ipairs(group) do
      for _, n in ipairs(self:Ring2(p.Index)) do
        if not mark[n] then
          mark[n] = true
          local q = placedAt[n]
          if q ~= nil then
            parts[#parts + 1] = n .. (q.Kind == "WONDER" and "w" or q.Type)
          elseif blocked and blocked[n] then
            parts[#parts + 1] = n .. "b"
          end
        end
      end
    end
    local key = table.concat(parts, ",")
    local hit = cache[key]
    if hit == nil then
      local groupPlan, groupForced = self:AssignGroup(group, placedAt, blocked)
      hit = { Plan = groupPlan, Forced = groupForced }
      if self.assignedCount >= 20000 then
        cache = {}
        self.assigned, self.assignedCount = cache, 0
      end
      cache[key] = hit
      self.assignedCount = self.assignedCount + 1
    end
    for _, item in ipairs(hit.Plan) do plan[#plan + 1] = item end
    if hit.Forced ~= nil then
      forced = forced or {}
      for index, value in pairs(hit.Forced) do forced[index] = value end
    end
  end
  if #order > 1 then table.sort(plan, function(a, b) return a.Index < b.Index end) end
  return plan, forced
end

-- Plots within two of plot `index` (itself left out).
function Model:Ring2(index)
  local list = self.rings[index]
  if list == nil then
    list = {}
    local mark = { [index] = true }
    for _, n in ipairs(self:Neighbours(index)) do
      if not mark[n] then
        mark[n] = true
        list[#list + 1] = n
      end
      for _, m in ipairs(self:Neighbours(n)) do
        if not mark[m] then
          mark[m] = true
          list[#list + 1] = m
        end
      end
    end
    self.rings[index] = list
  end
  return list
end

-- Assign for one group of target districts (`targets`), with everything
-- placed (`placedAt`) and blocked around them.
function Model:AssignGroup(targets, placedAt, blocked)
  local forced = nil
  local w = self.Weights
  -- Candidate plots next to the target districts, and built improvements a
  -- planned district gives more (issue 227 question 5).
  local seen, candidates = {}, {}
  for _, p in ipairs(targets) do
    for _, n in ipairs(self:Neighbours(p.Index)) do
      if not seen[n] then
        seen[n] = true
        if not placedAt[n] and not (blocked and blocked[n]) then
          if #self:Options(n) > 0 then
            candidates[#candidates + 1] = n
          elseif self.LandOn then
            local entry = self:LandEntry(n)
            local plot = Map.GetPlotByIndex(n)
            local built = plot:GetImprovementType() ~= -1 and plot:GetOwner() == self.PlayerID
              and GameInfo.Improvements[plot:GetImprovementType()] or nil
            local t = built and built.ImprovementType or self.FixedImprovement[n]
            if entry ~= nil and t ~= nil and self.Rules.Takes[t] ~= nil then
              local cw = self.Ctx.W
              local extra = SDP_Improve.TakeValue(self.Rules, t, self:Around(n, placedAt), cw, built == nil)
                - SDP_Improve.TakeValue(self.Rules, t, self:Around(n, nil), cw, built == nil)
              if extra ~= 0 then
                forced = forced or {}
                forced[n] = entry.Tile + extra
              end
            end
          end
        end
      end
    end
  end
  if #candidates == 0 then return {}, forced end
  table.sort(candidates)
  -- Each candidate's best improvement by a linear value: the adjacency it
  -- gives the districts around (Amount / Tiles each) and what the plot's
  -- land value gains (only while the city works it).
  local choice = {}
  local chosen = {}
  for _, q in ipairs(candidates) do
    local around = self:Around(q, placedAt)
    local entry = self.LandOn and self:LandEntry(q) or nil
    local worked = entry ~= nil and entry.Rank ~= nil and self:IsWorked(entry)
    local best = nil
    for _, o in ipairs(self:Options(q)) do
      if not (o.Clear and self:FeatureMatters(q, around)) then
        local adjacency = 0
        for _, d in ipairs(around.Districts) do
          for _, g in ipairs(self.Rules.Gives[d] or {}) do
            if g.Improvement == o.Type then adjacency = adjacency + (w[g.Yield] or 0) * g.Amount / g.Tiles end
          end
        end
        local take = self.LandOn and SDP_Improve.TakeValue(self.Rules, o.Type, around, self.Ctx.W) or 0
        if adjacency > 0 or take > 0 then
          local land = 0
          if worked then land = o.Value + take - entry.Tile end
          local value = adjacency + land
          if (adjacency > 0 or value > 0) and (best == nil or value > best.Linear + 1e-9) then
            best = { Index = q, Type = o.Type, Clear = o.Clear, Linear = value, Land = land, Tile = o.Value + take,
              Around = around }
          end
        end
      end
    end
    if best ~= nil then
      choice[q] = best
      chosen[#chosen + 1] = q
    end
  end
  -- Exact value of a set (whole steps of Tiles, the improvements already
  -- there counted): drop, in plot order, every improvement the value does
  -- not need, until none can go.
  local districts, districtSeen = {}, {}
  for _, q in ipairs(chosen) do
    for _, n in ipairs(self:Neighbours(q)) do
      if not districtSeen[n] then
        districtSeen[n] = true
        local d = placedAt[n] and placedAt[n].Kind ~= "WONDER" and placedAt[n].Type or self.FixedDistrict[n]
        if d == nil then
          local plot = Map.GetPlotByIndex(n)
          if plot:GetDistrictType() ~= -1 and GameInfo.Districts[plot:GetDistrictType()] ~= nil then
            d = GameInfo.Districts[plot:GetDistrictType()].DistrictType
          end
        end
        if d ~= nil and self.Rules.Gives[d] ~= nil then districts[#districts + 1] = { Index = n, Type = d } end
      end
    end
  end
  table.sort(districts, function(a, b) return a.Index < b.Index end)
  -- Each district's counts: the improvements there already (ExistingNext)
  -- and the chosen plots next to it of each type it takes, so a set's value
  -- is a sum over these (the pruning below tries many sets).
  local terms = {}
  for _, d in ipairs(districts) do
    for _, g in ipairs(self.Rules.Gives[d.Type]) do
      local weight = (w[g.Yield] or 0) * g.Amount
      if weight ~= 0 then
        local plots = {}
        for _, n in ipairs(self:Neighbours(d.Index)) do
          if choice[n] ~= nil and choice[n].Type == g.Improvement then plots[#plots + 1] = n end
        end
        if #plots > 0 then
          terms[#terms + 1] = { Base = self:ExistingNext(d.Index, g.Improvement), Plots = plots, Tiles = g.Tiles,
            Weight = weight }
        end
      end
    end
  end
  local active = {}
  for _, q in ipairs(chosen) do active[q] = true end
  local function Value()
    local total = 0
    for _, t in ipairs(terms) do
      local count = t.Base
      for _, n in ipairs(t.Plots) do
        if active[n] then count = count + 1 end
      end
      total = total + t.Weight * math.floor(count / t.Tiles)
    end
    for _, q in ipairs(chosen) do
      if active[q] then total = total + choice[q].Land end
    end
    return total
  end
  local current = Value()
  local changed = true
  while changed do
    changed = false
    for _, q in ipairs(chosen) do
      if active[q] then
        active[q] = false
        local without = Value()
        if without >= current - 1e-9 then
          current, changed = without, true
        else
          active[q] = true
        end
      end
    end
  end
  local plan = {}
  for _, q in ipairs(chosen) do
    if active[q] then
      local c = choice[q]
      plan[#plan + 1] = { Index = q, Type = c.Type, Clear = c.Clear }
      if self.LandOn and self:LandEntry(q) ~= nil then
        forced = forced or {}
        forced[q] = c.Tile
      end
    end
  end
  return plan, forced
end

-- Whether a land model entry is among the plots its city works (its rank,
-- with nothing taken).
function Model:IsWorked(entry)
  for _, land in ipairs(self.Lands) do
    if land.ByIndex[entry.Index] == entry then return entry.Rank <= land.P end
  end
  return false
end

-- The subject of improvement `t` on plot `index` (made once, so the board
-- sees the same table every time).
function Model:Subject(t, index)
  local byType = self.subjects[t]
  if byType == nil then
    byType = {}
    self.subjects[t] = byType
  end
  local subject = byType[index]
  if subject == nil then
    local plot = Map.GetPlotByIndex(index)
    subject = { Key = t, Type = "IMPROVEMENT", X = plot:GetX(), Y = plot:GetY() }
    byType[index] = subject
  end
  return subject
end

-- A plan entry of Assign for a result: { Type, X, Y, Index, Clear, Harvest,
-- Unowned, Yields (the tile's once built: what it gives now, less its
-- feature when cleared and its resource when harvested, plus the
-- improvement's own with the bonuses the player has and what the districts
-- around give it) }. `placedAt` as for Around.
function Model:Entry(item, placedAt)
  local plot = Map.GetPlotByIndex(item.Index)
  local yields = {}
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    yields[yieldType] = plot:GetYield(GameInfo.Yields[yieldType].Index)
  end
  local function Less(list)
    for yieldType, n in pairs(list or {}) do yields[yieldType] = (yields[yieldType] or 0) - n end
  end
  local feature = plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()] or nil
  if item.Clear and feature ~= nil then Less(self.Ctx.Rules.FeatureYields[feature.FeatureType]) end
  local resource = plot:GetResourceType() ~= -1 and GameInfo.Resources[plot:GetResourceType()] or nil
  if resource ~= nil and (item.Harvest or not self.Ctx.Visible(resource)) then
    Less(self.Ctx.Rules.ResourceYields[resource.ResourceType])
  end
  for _, entry in ipairs(self.Ctx.Rules.Improvements) do
    if entry.Type == item.Type then
      for yieldType, n in pairs(self.Ctx.Yields[entry] or {}) do yields[yieldType] = (yields[yieldType] or 0) + n end
    end
  end
  for yieldType, n in pairs(SDP_Improve.TakeYields(self.Rules, item.Type, self:Around(item.Index, placedAt))) do
    yields[yieldType] = (yields[yieldType] or 0) + n
  end
  for yieldType, n in pairs(yields) do
    if n == 0 then yields[yieldType] = nil end
  end
  return { Type = item.Type, X = plot:GetX(), Y = plot:GetY(), Index = item.Index, Clear = item.Clear or nil,
    Harvest = item.Harvest or nil, Unowned = plot:GetOwner() ~= self.PlayerID or nil, Yields = yields }
end

-- The improvement tacks for the worked plots (issue 227 question 3), once
-- the plan is chosen.
--   land       one city's land model
--   taken      { plot indices } the plan builds on (districts, wonders)
--   boost      the preserve's extra on the unimproved plots (SDP_Appeal) or nil
--   forced     Assign's land values or nil
--   assigned   { [plot index] = true }: Assign's plots (planned already)
--   placedAt   as for Around
-- Returns entries (as Model:Entry) sorted by plot index: each worked plot
-- with no improvement gets the one the land part assumes, unless
-- leaving it unimproved is worth more (next to a preserve), or the
-- improvement would change a district's adjacency next to it (it gives that
-- district adjacency, or clears a feature that does).
function Model:Worked(land, taken, boost, forced, assigned, placedAt)
  local worked = SDP_Land.WorkedPlots(land, taken, #taken, boost, forced)
  local indices = {}
  for index in pairs(worked) do indices[#indices + 1] = index end
  table.sort(indices)
  local out = {}
  for _, q in ipairs(indices) do
    local plot = Map.GetPlotByIndex(q)
    local p = land.ByIndex[q]
    local bare = boost ~= nil and boost[q] ~= nil and p ~= nil and p.Bare + boost[q] >= p.Tile
    if not assigned[q] and not bare and SDP_Wonders.FreeForImprovement(self.PlayerID, plot, self.Ownable, self.Taken) then
      local o = SDP_Land.AssumedImprovement(plot, self.Ctx, true)
      if o ~= nil then
        local around = self:Around(q, placedAt)
        local changes = o.Clear and self:FeatureMatters(q, around)
        for _, d in ipairs(around.Districts) do
          for _, g in ipairs(self.Rules.Gives[d] or {}) do
            if g.Improvement == o.Entry.Type then changes = true end
          end
        end
        if not changes then
          out[#out + 1] = self:Entry({ Index = q, Type = o.Entry.Type, Clear = o.Clear, Harvest = o.Harvest }, placedAt)
        end
      end
    end
  end
  return out
end
