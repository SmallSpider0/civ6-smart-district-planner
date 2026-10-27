-- SDP_Search: the placement search shared by the single-city solver
-- (SDP_Solver) and the multi-city solver (SDP_Multi).
--
-- A problem is a set of slots (a district or wonder to place, belonging to a
-- group: a city) over one sorted list of candidate plots. A layout gives each
-- slot a candidate position (0: not placed). Its value is SDP_Board's exact
-- DMT gain plus the land part of every land model (SDP_Land) plus, when
-- given, the coverage part (SDP_Coverage: weight x newly covered cities) plus,
-- when a district depends on appeal, the appeal part (SDP_Appeal: housing,
-- a preserve's yields on the plots around it).
--
--   Singles     every slot alone on every allowed plot: legality and value.
--   Exhaustive  every legal layout of the active slots (small problems).
--   Shortlist   a model (singles, pair gains from SDP_Rules.AdjacencyTable,
--               land losses) ranks layouts with a depth-first search, best
--               plots first under an optimistic bound; the best are then
--               evaluated exactly.
--   Local search from a layout: move one slot, swap two, shift a group of
--               touching slots one plot over, move an adjacent pair (tier).
--   Kicks       ruin and recreate: take a slot and its planned neighbours off,
--               put them back one by one on their best plots, local search.
--   Pools       a group may hold optional slots (candidate districts) of
--               which exactly a given number is placed: the search ranks
--               the combinations by an optimistic model value, solves the
--               best few exactly (Combos), tries swapping one candidate for
--               another (TypeSwaps) and refines the best combinations.
--               With Apart, a group never picks two partner districts, nor
--               one whose partner it has or requires, nor one its Avoid set
--               names while a partner candidate can be placed, unless every
--               combination would (then it may: ApartRelaxed). Two
--               districts one city cannot have (spec.Exclusive) are never
--               picked together, nor with a required one.
--   Costs       an optional cost per candidate plot (the distance cost)
--               taken off for every placed slot.
-- Budgets are counts (SDP_Tiers); loops run over sorted arrays; ties go to
-- the smaller candidate positions (= plot indices). Same input, same result
-- (requirement constraint 6). The overlay must be installed while it runs.

SDP_Search = {}

local Search = {}
Search.__index = Search

local function Copy(list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  return out
end
SDP_Search.Copy = Copy

local function Tick(units)
  if SDP_Task ~= nil then SDP_Task.Tick(units) end
end

-- a before b: higher score first, then smaller positions (lexicographic).
-- Candidates are sorted by plot index, so this compares plot indices.
local function Better(scoreA, layoutA, scoreB, layoutB)
  if scoreA ~= scoreB then return scoreA > scoreB end
  for i = 1, #layoutA do
    if layoutA[i] ~= layoutB[i] then return layoutA[i] < layoutB[i] end
  end
  return false
end
SDP_Search.Better = Better

-- spec = {
--   PlayerID, Board (SDP_Board with the fixed subjects), Weights, Params
--   Candidates  { Index, X, Y } sorted by plot index
--   Slots       { Key, Type ("DISTRICT" | "WONDER"), Group, Allowed = { [position] = true } or nil (all),
--                 Requires = district type a wonder must be next to (GameInfo.Buildings.AdjacentDistrict),
--                 Support = SDP_Wonders.Support: the improvement a wonder must be next to
--                   (Buildings.AdjacentImprovement, issue 51) }
--   Lands       SDP_Land models whose part counts (each only sees its own plots)
--   Coverage    SDP_Coverage model or nil (off)
--   CoverOwner  function(search, m, i) -> the coverage target key of the city
--               slot m on candidate i is planned for (not counted as covered
--               by it, issue 91); nil: every city counts
--   Pools       { [group] = count }: of the group's slots marked Optional,
--               exactly `count` are placed (fewer when they do not fit)
--   Costs       { [position] = cost } or nil: taken off per placed slot
--   Appeal      { Fixed (SDP_Overlay.FixedSubjects), Weights (the request's),
--                 Workable = { [plot index] = true } } or nil: the appeal part
--               (SDP_Appeal; nothing when no district depends on appeal)
--   Exclusive   { [type] = { [type] = true } } (SDP_Rules.Exclusive) or nil:
--               no combination of a group holds two of them (the solvers
--               leave out the required and candidate ones the city cannot
--               take with what it has)
--   Apart       { Partners = { [type] = { [type] = true } } (SDP_Rules.Apart),
--                 Present = { [group] = { [type] = true } } (built or pinned),
--                 Avoid = { [group] = { [type] = true } } or nil
--                 (SDP_Rules.ApartAvoid) }
--               or nil (off): partner districts are not picked into one
--               group; of two partner candidates a group takes the one its
--               Avoid set leaves in (issue 106: by the city, not the score)
--   Alternatives  keep this many distinct good layouts (SDP_Solver's
--               solutions; 0 or nil: none)
--   Reach       { [group] = { Start, Through } } plot index sets
--               (SDP_City scan.Reach) or nil: a layout is legal only when
--               every placed slot of such a group joins the group's Start
--               through Through plots that no other group's slot occupies
--               (issue 35: a city can only grow into plots next to its own)
--   Owners      { Wonder = { [position] = { [group] = true } } (the groups whose
--                 city could own the candidate), Fixed = { [plot index] =
--                 { Type, Groups = { [group] = true } } } (fixed districts and
--                 the groups they belong to) } or nil (off): a wonder slot's
--               Requires counts only a district of a city that could own the
--               wonder's plot, placed (a slot of such a group) or fixed
--               (issue 45: the game takes only the wonder's own city's)
-- }
function SDP_Search.New(spec)
  local self = setmetatable({}, Search)
  self.PlayerID, self.Board, self.Weights, self.Params = spec.PlayerID, spec.Board, spec.Weights, spec.Params
  self.Candidates, self.N = spec.Candidates, #spec.Candidates
  self.Lands = spec.Lands or {}
  self.Coverage = spec.Coverage
  self.CoverOwner = spec.CoverOwner
  self.PoolSpec, self.Costs = spec.Pools, spec.Costs
  self.Apart, self.ApartRelaxed = spec.Apart, {}
  self.Exclusive = spec.Exclusive or {}
  self.AppealSpec = spec.Appeal
  self.AltCount = spec.Alternatives or 0
  self.Alt = {}
  self.ReachSpec = spec.Reach
  self.Owners = spec.Owners
  self.CoverLists = {} -- scratch for CoverageCount
  self.SlotSpecs = spec.Slots
  self.Moving, self.Taken, self.Mark = {}, {}, {} -- scratch tables for Evaluate
  self.Stats = {
    Tier = spec.Params.Tier, Method = "none", Layouts = 0, Nodes = 0, Calls = 0, Evaluations = 0,
    Tries = 0, Truncated = false, Starts = 0, Continues = 0,
  }
  self.CallCap, self.TryCap = math.huge, math.huge
  return self
end

-- The subject for slot m on candidate i (made once, so the board sees the
-- same table every time).
function Search:Subject(m, i)
  local row = self.Subjects[m]
  local subject = row[i]
  if subject == nil then
    local c = self.Candidates[i]
    subject = { Key = self.Types[m], Type = self.Kinds[m], X = c.X, Y = c.Y }
    row[i] = subject
  end
  return subject
end

local function Serves(slotType, required)
  if slotType == required then return true end
  local row = GameInfo.DistrictReplaces[slotType]
  return row ~= nil and row.ReplacesDistrictType == required
end

-- Whether a district of type `required` next to candidate i belongs to a
-- city that could own i (spec.Owners): a fixed one, or (with `layout`) a
-- placed slot of such a city's group. Without Owners any city's counts.
function Search:OwnDistrictNext(required, i, layout)
  local owners = self.Owners
  if owners == nil then return true end
  local cities = owners.Wonder[i]
  if cities == nil then return false end
  for _, index in ipairs(self.Board:Neighbours(self.Candidates[i].Index)) do
    local f = index and owners.Fixed[index]
    if f ~= nil and Serves(f.Type, required) then
      for g in pairs(f.Groups) do
        if cities[g] then return true end
      end
    end
  end
  if layout ~= nil then
    local _, is = self:Touching()
    for m = 1, self.K do
      local j = layout[m]
      if j ~= 0 and is[i][j] and self.Kinds[m] == "DISTRICT" and cities[self.Groups[m]]
          and Serves(self.Types[m], required) then
        return true
      end
    end
  end
  return false
end

-- Whether every placed wonder that must be next to a district has one of
-- its own city's (OwnDistrictNext).
function Search:WondersServed(layout)
  for m = 1, self.K do
    local i, required = layout[m], self.SlotSpecs[self.SlotIndex[m]].Requires
    if i ~= 0 and required ~= nil and not self:OwnDistrictNext(required, i, layout) then return false end
  end
  return true
end

-- The board slot of the improvement next to wonder slot m (issue 51), and
-- the one Singles uses: negative, apart from the slots' own numbers.
local SUPPORT_SINGLE = -1
local function SupportSlot(m) return -1 - m end

-- The subject of improvement `improvementType` on plot `index` (made once
-- per plot, so the board sees the same table every time).
function Search:SupportSubject(improvementType, index)
  self.SupportSubjects = self.SupportSubjects or {}
  local byType = self.SupportSubjects[improvementType]
  if byType == nil then
    byType = {}
    self.SupportSubjects[improvementType] = byType
  end
  local subject = byType[index]
  if subject == nil then
    local plot = Map.GetPlotByIndex(index)
    subject = { Key = improvementType, Type = "IMPROVEMENT", X = plot:GetX(), Y = plot:GetY() }
    byType[index] = subject
  end
  return subject
end

-- Where the improvements the placed wonders need go in `layout`: for each
-- such wonder, in slot order, the first tile of its list (SDP_Wonders.Support,
-- sorted by plot index) that no placed slot and no earlier improvement
-- takes. Returns { [m] = plot index or nil } (scratch: read it before the
-- next call) and false when a wonder that needs one finds no tile.
function Search:SupportPlots(layout)
  local out, ok = self.SupportOut, true
  local list = self.SupportList
  if list == nil then return out, true end
  self.SupportStamp = self.SupportStamp + 1
  local stamp, used, candidates = self.SupportStamp, self.SupportUsed, self.Candidates
  for m = 1, self.K do
    if layout[m] ~= 0 then used[candidates[layout[m]].Index] = stamp end
  end
  for _, m in ipairs(list) do
    out[m] = nil
    local i, support = layout[m], self.SupportOf[m]
    if i ~= 0 and support.Needed[i] then
      for _, index in ipairs(support.Plots[i] or {}) do
        if used[index] ~= stamp then
          out[m] = index
          used[index] = stamp
          break
        end
      end
      if out[m] == nil then ok = false end
    end
  end
  return out, ok
end

-- Every slot alone on every allowed candidate. Slots without any legal plot
-- are dropped; returns the list of their indices into spec.Slots. Afterwards
-- K, Types, Kinds, Groups, Single, Legal and SlotIndex (into spec.Slots)
-- describe the placeable slots.
-- A wonder that must be next to a district is never legal alone: it counts
-- as possible on a plot when the district on some adjacent candidate makes
-- it legal; the search then only accepts layouts where DMT allows it.
function Search:Singles()
  local board, n = self.Board, self.N
  local adjacent = self:Touching()
  local types, kinds, groups, single, legal, subjects, index, dropped = {}, {}, {}, {}, {}, {}, {}, {}
  for s, slot in ipairs(self.SlotSpecs) do
    local gains, ok, row, any = {}, {}, {}, false
    for i = 1, n do
      if slot.Allowed == nil or slot.Allowed[i] then
        local c = self.Candidates[i]
        row[i] = { Key = slot.Key, Type = slot.Type or "DISTRICT", X = c.X, Y = c.Y }
        board:Put(1, row[i])
        -- A wonder that needs an improvement next to it: the first tile
        -- that can take one (none: not here).
        local support, supported = slot.Support, true
        if support ~= nil and support.Needed[i] then
          local first = support.Plots[i] and support.Plots[i][1]
          if first ~= nil then
            board:Put(SUPPORT_SINGLE, self:SupportSubject(support.Type, first), true)
          else
            supported = false
          end
        end
        local gain, isLegal = board:Total()
        if not supported then isLegal = false end
        -- Next to another city's district only: not legal alone (issue 45).
        if isLegal and slot.Requires ~= nil and not self:OwnDistrictNext(slot.Requires, i) then isLegal = false end
        if not isLegal and slot.Requires ~= nil then
          local mine = self.Owners and self.Owners.Wonder[i] or nil
          for _, j in ipairs(adjacent[i]) do
            local shared = mine == nil
            for g in pairs(mine or {}) do
              if self.Owners.Wonder[j] and self.Owners.Wonder[j][g] then shared = true end
            end
            if shared and supported and not board:IsTaken(self.Candidates[j].Index) then
              local cj = self.Candidates[j]
              board:Put(2, { Key = slot.Requires, Type = "DISTRICT", X = cj.X, Y = cj.Y })
              board:Total()
              local wonderLegal = board.slots[1].Legal
              board:Put(2, nil)
              board:Total()
              if wonderLegal then
                isLegal = true
                break
              end
            end
          end
        end
        board:Put(SUPPORT_SINGLE, nil)
        gains[i], ok[i] = gain, isLegal
        any = any or isLegal
      else
        gains[i], ok[i] = 0, false
      end
    end
    board:Put(1, nil)
    board:Total()
    if any then
      local m = #types + 1
      types[m], kinds[m], groups[m], single[m], legal[m], subjects[m], index[m] =
        slot.Key, slot.Type or "DISTRICT", slot.Group, gains, ok, row, s
    else
      dropped[#dropped + 1] = s
    end
  end
  self.Types, self.Kinds, self.Groups, self.Single, self.Legal, self.Subjects, self.SlotIndex =
    types, kinds, groups, single, legal, subjects, index
  self.K = #types
  -- Wonders with an improvement to place next to them (issue 51).
  self.SupportList, self.SupportOf = nil, {}
  for m = 1, self.K do
    local support = self.SlotSpecs[index[m]].Support
    if support ~= nil then
      self.SupportList = self.SupportList or {}
      self.SupportList[#self.SupportList + 1] = m
      self.SupportOf[m] = support
    end
  end
  self.SupportOut, self.SupportUsed, self.SupportStamp = {}, {}, 0
  self:MeasurePairs()
  if self.AppealSpec ~= nil then
    local optional = {}
    for m = 1, self.K do optional[m] = self.SlotSpecs[index[m]].Optional == true end
    self.AppealModel = SDP_Appeal.New({ PlayerID = self.PlayerID, Types = types, Kinds = kinds, Candidates = self.Candidates,
      Fixed = self.AppealSpec.Fixed, Weights = self.AppealSpec.Weights, Lands = self.Lands,
      Workable = self.AppealSpec.Workable, Optional = optional, Groups = groups, Cities = self.AppealSpec.Cities,
      FixedGroup = self.AppealSpec.FixedGroup })
  end
  -- Pools: each group's optional and required slots and how many optional
  -- ones to place.
  self.Optional, self.PoolSlots, self.RequiredSlots, self.PoolCount, self.PoolGroups = {}, {}, {}, {}, {}
  for m = 1, self.K do
    local g = groups[m]
    if self.SlotSpecs[index[m]].Optional then
      self.Optional[m] = true
      self.PoolSlots[g] = self.PoolSlots[g] or {}
      table.insert(self.PoolSlots[g], m)
    else
      self.RequiredSlots[g] = self.RequiredSlots[g] or {}
      table.insert(self.RequiredSlots[g], m)
    end
  end
  local selected = 0
  for m = 1, self.K do
    if not self.Optional[m] then selected = selected + 1 end
  end
  for g, list in pairs(self.PoolSlots) do
    local count = math.min((self.PoolSpec and self.PoolSpec[g]) or 0, #list)
    self.PoolCount[g] = count
    selected = selected + count
    if count > 0 then self.PoolGroups[#self.PoolGroups + 1] = g end
  end
  table.sort(self.PoolGroups)
  self.Selected = selected
  self.AltNeed = math.max(2, math.ceil(0.2 * selected))
  self:PrepareReach()
  return dropped
end

-- Reach (spec.Reach): for each group, its Start plots in order, which
-- candidate positions lie on its Through plots, and the neighbours of
-- every Through plot, worked out once.
function Search:PrepareReach()
  local spec = self.ReachSpec
  if spec == nil then return end
  local groups = {}
  for g in pairs(spec) do groups[#groups + 1] = g end
  table.sort(groups)
  local neighbours, inside, starts = {}, {}, {}
  for _, g in ipairs(groups) do
    local list = {}
    for index in pairs(spec[g].Through) do list[#list + 1] = index end
    table.sort(list)
    for _, index in ipairs(list) do
      if neighbours[index] == nil then
        local plot = Map.GetPlotByIndex(index)
        local around = {}
        for _, n in ipairs(SDP_City.PlotsInRange(plot:GetX(), plot:GetY(), 1)) do around[#around + 1] = n.Index end
        neighbours[index] = around
      end
    end
    local first = {}
    for index in pairs(spec[g].Start) do first[#first + 1] = index end
    table.sort(first)
    starts[g] = first
    local positions = {}
    for i = 1, self.N do
      if spec[g].Through[self.Candidates[i].Index] then positions[i] = true end
    end
    inside[g] = positions
  end
  self.Reach = { Spec = spec, Groups = groups, Neighbours = neighbours, Inside = inside, Starts = starts,
    Mark = {}, Stamp = 0, Queue = {}, Blocked = {} }
end

-- Whether every placed slot of each group with a Reach joins the group's
-- Start plots through its Through plots, the other groups' placed slots
-- (of groups with a Reach: wonders do not block) being in the way. A group
-- none of the others' slots touch needs no walk: its candidates are
-- reachable by the scan already.
function Search:Reachable(layout)
  local reach = self.Reach
  if reach == nil then return true end
  local candidates, groups, k = self.Candidates, self.Groups, self.K
  local blocked, mark, queue = reach.Blocked, reach.Mark, reach.Queue
  for _, g in ipairs(reach.Groups) do
    local inside, any, placed = reach.Inside[g], false, false
    for m = 1, k do
      local i = layout[m]
      if i ~= 0 and inside[i] then
        if groups[m] == g then
          placed = true
        elseif reach.Spec[groups[m]] ~= nil then
          blocked[candidates[i].Index], any = true, true
        end
      end
    end
    local ok = true
    if any and placed then
      reach.Stamp = reach.Stamp + 1
      local stamp, through, n = reach.Stamp, reach.Spec[g].Through, 0
      for _, index in ipairs(reach.Starts[g]) do
        mark[index], n = stamp, n + 1
        queue[n] = index
      end
      local head = 1
      while head <= n do
        local index = queue[head]
        head = head + 1
        for _, next in ipairs(reach.Neighbours[index]) do
          if through[next] and mark[next] ~= stamp and not blocked[next] then
            mark[next], n = stamp, n + 1
            queue[n] = next
          end
        end
      end
      for m = 1, k do
        local i = layout[m]
        if i ~= 0 and groups[m] == g and mark[candidates[i].Index] ~= stamp then
          ok = false
          break
        end
      end
    end
    if any then
      for m = 1, k do
        local i = layout[m]
        if i ~= 0 then blocked[candidates[i].Index] = nil end
      end
    end
    if not ok then return false end
  end
  return true
end

-- Whether the search has candidate districts to choose from.
function Search:HasPools()
  return #self.PoolGroups > 0
end

-- Move the board to `layout` and return its value (DMT gain + land parts +
-- coverage part) and whether DMT allows every placed slot. Position 0
-- leaves a slot off.
function Search:Evaluate(layout)
  local board, candidates, k = self.Board, self.Candidates, self.K
  -- The improvements wonders need (issue 51) leave the tiles they no longer
  -- use first: a slot may move onto one.
  local supports, supported = nil, true
  if self.SupportList ~= nil then
    supports, supported = self:SupportPlots(layout)
    for _, m in ipairs(self.SupportList) do
      local slot = SupportSlot(m)
      if board:PlotOf(slot) ~= supports[m] then board:Put(slot, nil) end
    end
  end
  local moving, count = self.Moving, 0
  for m = 1, k do
    local i = layout[m]
    if board:PlotOf(m) ~= (i ~= 0 and candidates[i].Index or nil) then
      count = count + 1
      moving[count] = m
      board:Put(m, nil)
    end
  end
  for c = 1, count do
    local m = moving[c]
    if layout[m] ~= 0 then board:Put(m, self:Subject(m, layout[m])) end
  end
  if supports ~= nil then
    for _, m in ipairs(self.SupportList) do
      local slot, index = SupportSlot(m), supports[m]
      if index ~= nil and board:PlotOf(slot) == nil then
        board:Put(slot, self:SupportSubject(self.SupportOf[m].Type, index), true)
      end
    end
  end
  local gain, legal = board:Total()
  if not supported then legal = false end
  self.Stats.Evaluations = self.Stats.Evaluations + 1
  if legal and self.Reach ~= nil and not self:Reachable(layout) then legal = false end
  if legal and self.Owners ~= nil and not self:WondersServed(layout) then legal = false end
  local appeal, boosts = self.AppealModel, nil
  if appeal ~= nil then
    local value
    value, boosts = appeal:Score(layout)
    gain = gain + value - appeal.Base
  end
  if #self.Lands > 0 then
    local taken, placed = self.Taken, 0
    for m = 1, k do
      if layout[m] ~= 0 then
        placed = placed + 1
        taken[placed] = candidates[layout[m]].Index
      end
    end
    for l, land in ipairs(self.Lands) do
      gain = gain + SDP_Land.ScoreTaken(land, taken, placed, self.Mark, boosts and boosts[l]) - land.Base
    end
  end
  if boosts ~= nil then appeal:ClearBoosts() end
  if self.Coverage ~= nil then gain = gain + self.Coverage.Weight * self:CoverageCount(layout) end
  local costs = self.Costs
  if costs ~= nil then
    for m = 1, k do
      local i = layout[m]
      if i ~= 0 then gain = gain - costs[i] end
    end
  end
  return gain, legal
end

-- The distance cost of a layout alone (for reports; 0 when off), negative.
function Search:CostDelta(layout)
  local costs, total = self.Costs, 0
  if costs == nil then return 0 end
  for m = 1, self.K do
    if layout[m] ~= 0 then total = total - costs[layout[m]] end
  end
  return total
end

-- The pairs a placement of slot m on candidate i newly covers on its own
-- (nil: the slot has no reach).
function Search:CoverList(m, i)
  local c = self.Candidates[i]
  return self.Coverage:List(self.Types[m], c.Index, c.X, c.Y, self.CoverOwner and self.CoverOwner(self, m, i) or nil)
end

-- How many (city, group) pairs a layout newly covers.
function Search:CoverageCount(layout)
  local lists, n = self.CoverLists, 0
  for m = 1, self.K do
    if layout[m] ~= 0 then
      local list = self:CoverList(m, layout[m])
      if list ~= nil then
        n = n + 1
        lists[n] = list
      end
    end
  end
  return self.Coverage:Count(lists, n)
end

-- The (city, group) pairs a layout newly covers, sorted (for reports).
function Search:CoveragePairs(layout)
  local seen, ids = {}, {}
  for m = 1, self.K do
    if layout[m] ~= 0 then
      for _, id in ipairs(self:CoverList(m, layout[m]) or {}) do
        if not seen[id] then
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

-- The coverage part of a layout alone (for reports; 0 when off).
function Search:CoverageDelta(layout)
  if self.Coverage == nil then return 0 end
  return self.Coverage.Weight * self:CoverageCount(layout)
end

-- The appeal part of a layout alone and what a preserve's yields on the
-- plots around it add to the land part (for reports and the model; 0 when
-- there is none): housing, tiles. `detail` as SDP_Appeal:Score.
function Search:AppealParts(layout, detail)
  local appeal = self.AppealModel
  if appeal == nil then return 0, 0 end
  local value, boosts = appeal:Score(layout, detail)
  local tiles = 0
  if boosts ~= nil then
    local taken = {}
    for m = 1, self.K do
      if layout[m] ~= 0 then taken[#taken + 1] = self.Candidates[layout[m]].Index end
    end
    for l, land in ipairs(self.Lands) do
      if boosts[l] ~= nil then
        tiles = tiles + SDP_Land.ScoreTaken(land, taken, #taken, {}, boosts[l]) - SDP_Land.ScoreTaken(land, taken, #taken, {})
      end
    end
    appeal:ClearBoosts()
  end
  return value - appeal.Base, tiles
end

-- The appeal part of a layout alone (for reports; 0 when there is none): the
-- housing of neighborhoods and preserves. A preserve's yields on the plots
-- around it are in the land part (issue 91).
function Search:AppealDelta(layout, detail)
  local housing = self:AppealParts(layout, detail)
  return housing
end

-- Both parts of AppealParts together (the model's single values).
function Search:AppealSingle(layout)
  local housing, tiles = self:AppealParts(layout)
  return housing + tiles
end

-- The land part of a layout alone (for reports), with a preserve's yields
-- on the plots around it.
function Search:LandDelta(layout)
  local taken = {}
  for m = 1, self.K do
    if layout[m] ~= 0 then taken[#taken + 1] = self.Candidates[layout[m]].Index end
  end
  local delta = 0
  for _, land in ipairs(self.Lands) do delta = delta + SDP_Land.ScoreTaken(land, taken, #taken, {}) - land.Base end
  if self.AppealModel ~= nil and #self.Lands > 0 then
    local _, tiles = self:AppealParts(layout)
    delta = delta + tiles
  end
  return delta
end

function Search:SetBudgets()
  self.CallCap = self.Board.Calls + self.Params.CallLimit
  self.TryCap = self.Stats.Tries + self.Params.TryLimit
end

function Search:OverBudget()
  if self.Board.Calls >= self.CallCap or self.Stats.Tries >= self.TryCap then
    self.Stats.Truncated = true
    return true
  end
  return false
end

local function Placed(layout)
  local count = 0
  for m = 1, #layout do
    if layout[m] ~= 0 then count = count + 1 end
  end
  return count
end
SDP_Search.Placed = Placed

-- Keep the best legal layout seen. More placed slots always win (a slot
-- may find no free plot while other cities' slots are placed first), then
-- the higher value, then the smaller positions.
function Search:Consider(gain, legal, layout)
  if not legal then return false end
  local placed = Placed(layout)
  if self.AltCount > 0 then self:KeepAlternative(gain, layout, placed) end
  local best = self.BestLayout
  if best == nil or placed > self.BestPlaced or (placed == self.BestPlaced and Better(gain, layout, self.BestGain, best)) then
    self.BestLayout, self.BestGain, self.BestPlaced = Copy(layout), gain, placed
    return true
  end
  return false
end

-- Whether layouts a and b differ in at least `count` slots.
local function Differ(a, b, count)
  local diff = 0
  for m = 1, #a do
    if a[m] ~= b[m] then
      diff = diff + 1
      if diff >= count then return true end
    end
  end
  return diff >= count
end

-- Two layouts are different solutions when they place other candidate
-- districts (pools) or put at least AltNeed slots elsewhere.
function Search:IsDistinct(a, b)
  for m in pairs(self.Optional) do
    if (a[m] ~= 0) ~= (b[m] ~= 0) then return true end
  end
  return Differ(a, b, self.AltNeed)
end

-- Placed slots first, then the higher value, then the smaller positions.
local function Ahead(placedA, gainA, layoutA, placedB, gainB, layoutB)
  if placedA ~= placedB then return placedA > placedB end
  return Better(gainA, layoutA, gainB, layoutB)
end

-- Keep the AltCount best layouts seen that differ from each other in at
-- least AltNeed slots (design 4.5's rule): alternative solutions.
function Search:KeepAlternative(gain, layout, placed)
  for _, e in ipairs(self.Alt) do
    if not self:IsDistinct(layout, e.Layout) and not Ahead(placed, gain, layout, e.Placed, e.Gain, e.Layout) then return end
  end
  local kept = {}
  for _, e in ipairs(self.Alt) do
    if self:IsDistinct(layout, e.Layout) then kept[#kept + 1] = e end
  end
  local entry = { Gain = gain, Layout = Copy(layout), Placed = placed }
  local pos = #kept + 1
  while pos > 1 and Ahead(placed, gain, layout, kept[pos - 1].Placed, kept[pos - 1].Gain, kept[pos - 1].Layout) do
    kept[pos] = kept[pos - 1]
    pos = pos - 1
  end
  kept[pos] = entry
  while #kept > self.AltCount do kept[#kept] = nil end
  self.Alt = kept
end

-- Candidate positions adjacent to each candidate (ascending), adjacency as a
-- matrix, and the candidate position of each plot index.
function Search:Touching()
  if self.Adjacent ~= nil then return self.Adjacent, self.IsAdjacent end
  local candidates, n = self.Candidates, self.N
  local adjacent, is, at = {}, {}, {}
  for i = 1, n do at[candidates[i].Index] = i end
  for i = 1, n do
    adjacent[i], is[i] = {}, {}
    for _, q in ipairs(self.Board:Neighbours(candidates[i].Index)) do
      local j = q and at[q]
      if j then is[i][j] = true end
    end
    for j = 1, n do
      if is[i][j] then adjacent[i][#adjacent[i] + 1] = j end
    end
  end
  self.Adjacent, self.IsAdjacent, self.CandidateAt = adjacent, is, at
  return adjacent, is
end

-- Plots taken by the slots not in `active` (set of slots), in `layout`.
local function UsedBy(layout, active)
  local used = {}
  for m = 1, #layout do
    if not active[m] and layout[m] ~= 0 then used[layout[m]] = true end
  end
  return used
end

-- Number of ways to put the active slots on distinct free legal plots,
-- counting stops just above `limit`.
function Search:CountLayouts(order, used, limit)
  local legal, n, count = self.Legal, self.N, 0
  local function Walk(d)
    if count > limit then return end
    if d > #order then
      count = count + 1
      return
    end
    local m = order[d]
    for i = 1, n do
      if legal[m][i] and not used[i] then
        used[i] = true
        Walk(d + 1)
        used[i] = nil
      end
    end
  end
  Walk(1)
  return count
end

-- Every legal layout of the active slots (`order`), the others staying as
-- in `base`. Returns whether it went through all of them, and the best one
-- (layout, value) or nil.
function Search:Exhaustive(order, base)
  local active = {}
  for _, m in ipairs(order) do active[m] = true end
  local used = UsedBy(base, active)
  local layout = Copy(base)
  local legal, n, stopped = self.Legal, self.N, false
  local bestLayout, bestGain = nil, nil
  local function Walk(d)
    if d > #order then
      local gain, isLegal = self:Evaluate(layout)
      self:Consider(gain, isLegal, layout)
      if isLegal and (bestLayout == nil or Better(gain, layout, bestGain, bestLayout)) then
        bestLayout, bestGain = Copy(layout), gain
      end
      Tick(SDP_Tiers.UNITS_PER_TRY)
      if self:OverBudget() then stopped = true end
      return
    end
    local m = order[d]
    for i = 1, n do
      if legal[m][i] and not used[i] then
        used[i], layout[m] = true, i
        Walk(d + 1)
        used[i], layout[m] = nil, 0
        if stopped then return end
      end
    end
  end
  Walk(1)
  return not stopped, bestLayout, bestGain
end

-- What two districts next to each other add beyond their values alone,
-- measured with DMT for each pair of district types (Measured[ta][tb]): the
-- smallest over a few neighbouring candidate pairs, so a rounding step at
-- one spot does not count everywhere. Plots with a feature are measured only
-- when there are no others: clearing it can cost the neighbour a bonus,
-- which belongs to the spot, not to the pair. Catches what the adjacency
-- table does not hold, such as a civilization's trait (Japan: +1 per
-- neighbouring district instead of +1 per two) that DMT applies as a
-- modifier (issue 36). The board must be empty; run once, after the singles.
SDP_Search.PAIR_SAMPLES = 3
SDP_Search.FIXED_CREDIT = true
function Search:MeasurePairs()
  local board, k = self.Board, self.K
  local adjacent = self:Touching()
  local measured, slotOf, bare = {}, {}, {}
  for i = 1, self.N do
    local plot = Map.GetPlotByIndex(self.Candidates[i].Index)
    bare[i] = plot ~= nil and plot:GetFeatureType() == -1
  end
  for m = 1, k do
    if self.Kinds[m] == "DISTRICT" and slotOf[self.Types[m]] == nil then slotOf[self.Types[m]] = m end
  end
  local types = {}
  for t in pairs(slotOf) do types[#types + 1] = t end
  table.sort(types)
  for x, ta in ipairs(types) do
    measured[ta] = measured[ta] or {}
    for y = x, #types do
      local tb = types[y]
      measured[tb] = measured[tb] or {}
      local a, b = slotOf[ta], slotOf[tb]
      local best, samples = nil, 0
      for pass = 1, 2 do
        for i = 1, self.N do
          if samples >= SDP_Search.PAIR_SAMPLES then break end
          if self.Legal[a][i] and (pass == 2 or bare[i]) then
            for _, j in ipairs(adjacent[i]) do
              if samples >= SDP_Search.PAIR_SAMPLES then break end
              if self.Legal[b][j] and (pass == 2) ~= (bare[i] and bare[j]) then
                local ci, cj = self.Candidates[i], self.Candidates[j]
                board:Put(1, { Key = ta, Type = "DISTRICT", X = ci.X, Y = ci.Y })
                board:Put(2, { Key = tb, Type = "DISTRICT", X = cj.X, Y = cj.Y })
                local both, legal = board:Total()
                board:Put(1, nil)
                board:Put(2, nil)
                if legal then
                  local value = both - self.Single[a][i] - self.Single[b][j]
                  if best == nil or value < best then best = value end
                  samples = samples + 1
                end
              end
            end
          end
        end
        if samples > 0 then break end
      end
      board:Total()
      measured[ta][tb], measured[tb][ta] = best, best
    end
  end
  self.Measured = measured
end

-- Model scores (see the header): ModelSingle[m][i] and Pair[a][b].
-- The model is "unrounded": a row worth YieldChange per TilesRequired
-- districts counts YieldChange / TilesRequired per neighbour, and for the
-- fixed districts already next to a plot (a city center above all) the part
-- the singles rounded away is added back. Otherwise a district next to a city
-- center looks no better than one in the open until a second neighbour comes.
function Search:Model()
  if self.ModelSingle ~= nil then return end
  local k, n, candidates, board, weights = self.K, self.N, self.Candidates, self.Board, self.Weights
  local adjacency = SDP_Rules.AdjacencyTable(self.PlayerID)
  local fixedNear = {}
  for i = 1, n do
    local list = {}
    for _, q in ipairs(board:Neighbours(candidates[i].Index)) do
      local f = q and board.fixedAt[q]
      if f and f.Subject.Type == "DISTRICT" then list[#list + 1] = f.Subject.Key end
    end
    fixedNear[i] = list
  end
  local loss = {}
  for i = 1, n do
    local total = 0
    for _, land in ipairs(self.Lands) do total = total + (land.Loss[candidates[i].Index] or 0) end
    loss[i] = total
  end
  -- The appeal part of a neighborhood or preserve slot alone on each plot
  -- (its housing, a preserve's yields). What other slots do to the appeal of
  -- a pinned or built neighborhood is left to the exact evaluation: adding
  -- it here steered the standard tier away from better layouts (dev set,
  -- 2026-10-21: 7 situations, objective 993 with it, 997 without).
  local appealSingle = nil
  if self.AppealModel ~= nil then
    appealSingle = {}
    local layout = self:EmptyLayout()
    for m = 1, k do
      appealSingle[m] = {}
      for i = 1, n do
        if self.Legal[m][i] and self.AppealModel.Value[m] then
          layout[m] = i
          appealSingle[m][i] = self:AppealSingle(layout)
          layout[m] = 0
        end
      end
    end
  end
  -- A fixed district with a row that needs TilesRequired neighbours (+1 for
  -- every two districts, ...) reaches its next step with two new neighbours,
  -- which no single value shows. Each new neighbour that counts for such a
  -- row gets the share up to that step, (r + 1) / TilesRequired of the row
  -- (r: what the fixed district has towards it now), unless one alone
  -- completes it; the model stays an upper bound (issue 36).
  local function DistrictAt(q)
    local f = board.fixedAt[q]
    if f ~= nil then return f.Subject.Type == "DISTRICT" and f.Subject.Key or nil end
    local plot = Map.GetPlotByIndex(q)
    local d = plot and plot:GetDistrictType() or -1
    local row = d ~= -1 and GameInfo.Districts[d] or nil
    return row and row.DistrictType ~= "DISTRICT_WONDER" and row.DistrictType or nil
  end
  local credit = {}
  for i = 1, n do
    local list = {}
    for _, q in ipairs(board:Neighbours(candidates[i].Index)) do
      local f = q and board.fixedAt[q]
      local key = f and f.Subject.Type == "DISTRICT" and f.Subject.Key or nil
      for _, row in ipairs(key and (adjacency[key] or {}).Rows or {}) do
        if row.TilesRequired > 1 and (row.Any or row.District) then
          local count = 0
          for _, nq in ipairs(board:Neighbours(q)) do
            local other = nq and DistrictAt(nq)
            if other ~= nil and (row.Any or Serves(other, row.District)) then count = count + 1 end
          end
          local r = count % row.TilesRequired
          if r + 1 < row.TilesRequired then
            list[#list + 1] = { Row = row, Value = (weights[row.YieldType] or 0) * row.YieldChange * (r + 1) / row.TilesRequired }
          end
        end
      end
    end
    credit[i] = list
  end
  local single = {}
  for m = 1, k do
    single[m] = {}
    local rows = (adjacency[self.Types[m]] or {}).Rows or {}
    for i = 1, n do
      local value = self.Single[m][i] - loss[i] - (self.Costs and self.Costs[i] or 0)
      if appealSingle ~= nil then value = value + (appealSingle[m][i] or 0) end
      -- Coverage alone; two slots of one group over the same city both
      -- count it here, so the model stays optimistic.
      if self.Coverage ~= nil and self.Legal[m][i] then
        local list = self:CoverList(m, i)
        if list ~= nil then value = value + self.Coverage.Weight * #list end
      end
      for _, row in ipairs(rows) do
        if row.TilesRequired > 1 then
          local count = 0
          for _, key in ipairs(fixedNear[i]) do
            if row.Any or key == row.District then count = count + 1 end
          end
          value = value + (weights[row.YieldType] or 0) * row.YieldChange * (count % row.TilesRequired) / row.TilesRequired
        end
      end
      if self.Kinds[m] == "DISTRICT" and SDP_Search.FIXED_CREDIT then
        for _, c in ipairs(credit[i]) do
          if c.Row.Any or Serves(self.Types[m], c.Row.District) then value = value + c.Value end
        end
      end
      single[m][i] = value
    end
  end
  local pair = {}
  local appeal = self.AppealModel
  for a = 1, k do
    pair[a] = {}
    for b = 1, k do
      pair[a][b] = SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, self.Types[a], self.Types[b]), weights)
        + SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, self.Types[b], self.Types[a]), weights)
      local m = self.Measured and self.Measured[self.Types[a]] and self.Measured[self.Types[a]][self.Types[b]]
      if m ~= nil and m > pair[a][b] then pair[a][b] = m end
      -- A neighbour that raises appeal can lift a housing district one step
      -- (optimistic: the model stays a bound).
      if appeal ~= nil and a ~= b then
        if appeal.Value[a] and appeal.Own[b] > 0 then pair[a][b] = pair[a][b] + appeal.HousingWeight end
        if appeal.Value[b] and appeal.Own[a] > 0 then pair[a][b] = pair[a][b] + appeal.HousingWeight end
      end
    end
  end
  self.ModelSingle, self.Pair = single, pair
end

-- Model search over the active slots (`order`), the others staying as in
-- `base`; keeps the best Shortlist layouts and evaluates them exactly.
-- Returns them, legal ones only, best first ({ Gain, Layout }), and the
-- model's optimistic bound for the active slots.
function Search:Shortlist(order, base)
  self:Model()
  local _, touching = self:Touching()
  local n, legal, params, stats = self.N, self.Legal, self.Params, self.Stats
  local single, pair = self.ModelSingle, self.Pair
  local active = {}
  for _, m in ipairs(order) do active[m] = true end
  local fixedSlots = {}
  for m = 1, self.K do
    if not active[m] and base[m] ~= 0 then fixedSlots[#fixedSlots + 1] = m end
  end

  -- Plots best first, so that a search cut short by its budget has looked at
  -- the most promising ones.
  local plots = {}
  for _, m in ipairs(order) do
    local list = {}
    for i = 1, n do
      if legal[m][i] then list[#list + 1] = i end
    end
    table.sort(list, function(a, b)
      if single[m][a] ~= single[m][b] then return single[m][a] > single[m][b] end
      return a < b
    end)
    plots[m] = list
  end

  -- Optimistic remaining score from the d-th active slot on: each remaining
  -- slot's best single plus its positive pair gains with the slots placed
  -- before it and the fixed ones (added when it is placed), at most six.
  local optimistic = {}
  for d = #order, 1, -1 do
    local m = order[d]
    local gains = {}
    for e = 1, d - 1 do
      local g = pair[m][order[e]]
      if g > 0 then gains[#gains + 1] = g end
    end
    for _, f in ipairs(fixedSlots) do
      if pair[m][f] > 0 then gains[#gains + 1] = pair[m][f] end
    end
    table.sort(gains, function(a, b) return a > b end)
    local pairs = 0
    for g = 1, math.min(6, #gains) do pairs = pairs + gains[g] end
    local bestSingle = plots[m][1] and single[m][plots[m][1]] or 0
    optimistic[d] = bestSingle + pairs + (optimistic[d + 1] or 0)
  end

  local shortlist = {} -- { Score, Layout } best first
  local limit = params.Shortlist
  local function Keep(score, layout)
    local size = #shortlist
    if size >= limit and not Better(score, layout, shortlist[size].Score, shortlist[size].Layout) then return end
    local pos = size + 1
    while pos > 1 and Better(score, layout, shortlist[pos - 1].Score, shortlist[pos - 1].Layout) do
      shortlist[pos] = shortlist[pos - 1]
      pos = pos - 1
    end
    shortlist[pos] = { Score = score, Layout = Copy(layout) }
    if #shortlist > limit then shortlist[#shortlist] = nil end
  end

  if (params.Beam or 0) > 0 then
    return self:Beam(self:BeamOrder(order, plots), base, plots, fixedSlots)
  end

  local used = UsedBy(base, active)
  local layout = Copy(base)
  local nodeCap = stats.Nodes + params.NodeLimit
  local stopped = false
  local function Walk(d, partial)
    if d > #order then
      Keep(partial, layout)
      return
    end
    stats.Nodes = stats.Nodes + 1
    if stats.Nodes % SDP_Tiers.NODES_PER_UNIT == 0 then Tick(1) end
    if stats.Nodes > nodeCap then
      stats.Truncated, stopped = true, true
      return
    end
    if #shortlist >= limit and partial + optimistic[d] <= shortlist[#shortlist].Score then return end
    local m = order[d]
    for _, i in ipairs(plots[m]) do
      if not used[i] then
        local score = partial + single[m][i]
        for e = 1, d - 1 do
          local prev = order[e]
          if touching[i][layout[prev]] then score = score + pair[m][prev] end
        end
        for _, f in ipairs(fixedSlots) do
          if touching[i][layout[f]] then score = score + pair[m][f] end
        end
        used[i], layout[m] = true, i
        Walk(d + 1, score)
        used[i], layout[m] = nil, base[m]
        if stopped then return end
      end
    end
  end
  Walk(1, 0)
  stats.Shortlist = (stats.Shortlist or 0) + #shortlist

  local ranked = {}
  for _, entry in ipairs(shortlist) do
    if self:OverBudget() then break end
    local gain, isLegal = self:Evaluate(entry.Layout)
    if isLegal then ranked[#ranked + 1] = { Gain = gain, Layout = entry.Layout } end
    self:Consider(gain, isLegal, entry.Layout)
  end
  table.sort(ranked, function(a, b) return Better(a.Gain, a.Layout, b.Gain, b.Layout) end)
  return ranked, optimistic[1]
end

-- Keep the `width` best of a stream of entries ({ Score, Seq, ... }): a
-- binary min-heap on (Score, then later Seq first out), so ties keep the
-- earlier entry and the result does not depend on anything but the order of
-- generation.
local function Worse(a, b)
  if a.Score ~= b.Score then return a.Score < b.Score end
  return a.Seq > b.Seq
end

local function HeapPush(heap, width, entry)
  local size = #heap
  if size >= width then
    if not Worse(heap[1], entry) then return end
    -- Replace the worst and sift down.
    heap[1] = entry
    local i = 1
    while true do
      local l, r, smallest = 2 * i, 2 * i + 1, i
      if l <= size and Worse(heap[l], heap[smallest]) then smallest = l end
      if r <= size and Worse(heap[r], heap[smallest]) then smallest = r end
      if smallest == i then break end
      heap[i], heap[smallest] = heap[smallest], heap[i]
      i = smallest
    end
    return
  end
  heap[size + 1] = entry
  local i = size + 1
  while i > 1 do
    local parent = math.floor(i / 2)
    if not Worse(heap[i], heap[parent]) then break end
    heap[i], heap[parent] = heap[parent], heap[i]
    i = parent
  end
end

-- Beam search on the model (Params.Beam partial layouts kept per step,
-- ranked by their model score plus the optimistic rest). Unlike a
-- depth-first search cut short by its budget, every step looks at the whole
-- map. Returns the best complete layouts exactly evaluated, like Shortlist.
function Search:Beam(order, base, plots, fixedSlots)
  local _, touching = self:Touching()
  local single, pair, params, stats = self.ModelSingle, self.Pair, self.Params, self.Stats
  -- Optimistic rest in this order (as in Shortlist).
  local optimistic = {}
  for d = #order, 1, -1 do
    local m = order[d]
    local gains = {}
    for e = 1, d - 1 do
      local g = pair[m][order[e]]
      if g > 0 then gains[#gains + 1] = g end
    end
    for _, f in ipairs(fixedSlots) do
      if pair[m][f] > 0 then gains[#gains + 1] = pair[m][f] end
    end
    table.sort(gains, function(a, b) return a > b end)
    local sum = 0
    for g = 1, math.min(6, #gains) do sum = sum + gains[g] end
    optimistic[d] = (plots[m][1] and single[m][plots[m][1]] or 0) + sum + (optimistic[d + 1] or 0)
  end
  local width = params.Beam
  local beam = { { Score = 0, Layout = Copy(base) } }
  for d = 1, #order do
    local m = order[d]
    local heap, seq = {}, 0
    for _, entry in ipairs(beam) do
      local layout = entry.Layout
      local used = {}
      for mm = 1, #layout do
        if layout[mm] ~= 0 then used[layout[mm]] = true end
      end
      for _, i in ipairs(plots[m]) do
        if not used[i] then
          local score = entry.Score + single[m][i]
          for e = 1, d - 1 do
            local prev = order[e]
            if touching[i][layout[prev]] then score = score + pair[m][prev] end
          end
          for _, f in ipairs(fixedSlots) do
            if touching[i][layout[f]] then score = score + pair[m][f] end
          end
          seq = seq + 1
          stats.Nodes = stats.Nodes + 1
          if stats.Nodes % SDP_Tiers.NODES_PER_UNIT == 0 then Tick(1) end
          HeapPush(heap, width, { Score = score + (optimistic[d + 1] or 0), Partial = score, Seq = seq, Parent = layout, Slot = m, Plot = i })
        end
      end
    end
    -- Materialize the kept children, best first.
    table.sort(heap, function(a, b) return Worse(b, a) end)
    beam = {}
    for r, child in ipairs(heap) do
      local layout = Copy(child.Parent)
      layout[child.Slot] = child.Plot
      beam[r] = { Score = child.Partial, Layout = layout }
    end
  end
  -- The best complete layouts by model score.
  table.sort(beam, function(a, b) return Better(a.Score, a.Layout, b.Score, b.Layout) end)
  local ranked = {}
  for r = 1, math.min(params.Shortlist, #beam) do
    if self:OverBudget() then break end
    local layout = beam[r].Layout
    local gain, isLegal = self:Evaluate(layout)
    if isLegal then ranked[#ranked + 1] = { Gain = gain, Layout = layout } end
    self:Consider(gain, isLegal, layout)
  end
  stats.Shortlist = (stats.Shortlist or 0) + #ranked
  table.sort(ranked, function(a, b) return Better(a.Gain, a.Layout, b.Gain, b.Layout) end)
  return ranked, optimistic[1]
end

-- The order the beam places slots in (Params.BeamOrder):
--   "request"  as given
--   "single"   best single value first
--   "pairs"    most pair gain with the other slots first
--   "legal"    fewest legal plots first
-- Ties keep the given order.
function Search:BeamOrder(order, plots)
  local mode = self.Params.BeamOrder or "request"
  if mode == "request" then return order end
  local single, pair = self.ModelSingle, self.Pair
  local key = {}
  for pos, m in ipairs(order) do
    local value
    if mode == "single" then
      value = plots[m][1] and single[m][plots[m][1]] or 0
    elseif mode == "pairs" then
      value = 0
      for _, b in ipairs(order) do
        if b ~= m and pair[m][b] > 0 then value = value + pair[m][b] end
      end
    else
      value = -#plots[m]
    end
    key[m] = { Value = value, Pos = pos }
  end
  local sorted = Copy(order)
  table.sort(sorted, function(a, b)
    if key[a].Value ~= key[b].Value then return key[a].Value > key[b].Value end
    return key[a].Pos < key[b].Pos
  end)
  return sorted
end

-- Local search from the next `count` ranked layouts that differ from every
-- earlier start in at least two slots. `state` holds Ranked, NextStart,
-- Started and the best layout found (BestLayout, BestGain): the search
-- itself (default) or one combination of a pool (SDP_Search pools).
function Search:RunStarts(count, state)
  state = state or self
  local done = 0
  while done < count and state.NextStart <= #state.Ranked and not self:OverBudget() do
    local start = state.Ranked[state.NextStart]
    state.NextStart = state.NextStart + 1
    local fresh = true
    for _, earlier in ipairs(state.Started) do
      if not Differ(start.Layout, earlier, math.min(2, self.K)) then fresh = false end
    end
    if fresh then
      state.Started[#state.Started + 1] = start.Layout
      local layout, gain = self:LocalSearch(start.Layout, start.Gain)
      if state ~= self and (state.BestLayout == nil or Better(gain, layout, state.BestGain, state.BestLayout)) then
        state.BestLayout, state.BestGain = layout, gain
      end
      self.Stats.Starts = self.Stats.Starts + 1
      done = done + 1
    end
  end
end

-- Groups of placed slots that touch each other.
local function Components(layout, touching)
  local seen, groups = {}, {}
  for m = 1, #layout do
    if not seen[m] and layout[m] ~= 0 then
      local group, queue = {}, { m }
      seen[m] = true
      while #queue > 0 do
        local a = table.remove(queue, 1)
        group[#group + 1] = a
        for b = 1, #layout do
          if not seen[b] and layout[b] ~= 0 and touching[layout[a]][layout[b]] then
            seen[b] = true
            queue[#queue + 1] = b
          end
        end
      end
      table.sort(group)
      groups[#groups + 1] = group
    end
  end
  return groups
end

-- Local search from `layout`. Moves: one slot to a free plot; two slots
-- trade plots (Swap); a group of touching slots, or all of them, shifted one
-- plot in any direction; two adjacent slots to another adjacent pair of
-- plots (Pair). Only slots in `active` (a set; default all) move, and only
-- placed ones. Params.Improve = "first" takes the first improving move of a
-- pass instead of the best. Returns the local optimum and its value.
function Search:LocalSearch(layout, gain, active)
  local k, n, legal, params, stats = self.K, self.N, self.Legal, self.Params, self.Stats
  local adjacent, touching = self:Touching()
  local candidates, at, board = self.Candidates, self.CandidateAt, self.Board
  local first = params.Improve == "first"
  local cur = Copy(layout)
  local movable = {}
  for m = 1, k do
    if (active == nil or active[m]) and cur[m] ~= 0 then movable[#movable + 1] = m end
  end
  for _ = 1, params.MaxPasses do
    local bestTrial, bestGain = nil, nil
    local function Try()
      if first and bestTrial ~= nil then return end
      stats.Tries = stats.Tries + 1
      Tick(SDP_Tiers.UNITS_PER_TRY)
      local trialGain, isLegal = self:Evaluate(cur)
      if isLegal and trialGain > gain and (bestTrial == nil or Better(trialGain, cur, bestGain, bestTrial)) then
        bestTrial, bestGain = Copy(cur), trialGain
      end
    end
    local inUse = {}
    for m = 1, k do
      if cur[m] ~= 0 then inUse[cur[m]] = m end
    end
    -- One slot to a free plot.
    for _, m in ipairs(movable) do
      local keep = cur[m]
      for i = 1, n do
        if legal[m][i] and not inUse[i] then
          cur[m] = i
          Try()
          if self:OverBudget() then break end
        end
      end
      cur[m] = keep
      if self:OverBudget() then break end
    end
    -- Two slots trade plots.
    if params.Swap and not self:OverBudget() then
      for x = 1, #movable - 1 do
        for y = x + 1, #movable do
          local a, b = movable[x], movable[y]
          if legal[a][cur[b]] and legal[b][cur[a]] and not self:OverBudget() then
            cur[a], cur[b] = cur[b], cur[a]
            Try()
            cur[a], cur[b] = cur[b], cur[a]
          end
        end
      end
    end
    -- A group of touching slots (or all of them) one plot over.
    if not self:OverBudget() then
      local only = {}
      for m = 1, k do only[m] = 0 end
      for _, m in ipairs(movable) do only[m] = cur[m] end
      local groups = Components(only, touching)
      if #groups > 1 then groups[#groups + 1] = Copy(movable) end
      for _, group in ipairs(groups) do
        local inGroup = {}
        for _, m in ipairs(group) do inGroup[m] = true end
        for direction = 1, 6 do
          local moved, ok = {}, true
          for _, m in ipairs(group) do
            local q = board:Neighbours(candidates[cur[m]].Index)[direction]
            local i = q and at[q]
            if i == nil or not legal[m][i] or (inUse[i] and not inGroup[inUse[i]]) then
              ok = false
              break
            end
            moved[m] = i
          end
          if ok and not self:OverBudget() then
            local keep = Copy(cur)
            for _, m in ipairs(group) do cur[m] = moved[m] end
            Try()
            cur = keep
          end
        end
      end
    end
    -- Two adjacent slots move together to another adjacent pair of plots.
    if params.Pair and not self:OverBudget() then
      for x = 1, #movable - 1 do
        for y = x + 1, #movable do
          local a, b = movable[x], movable[y]
          if touching[cur[a]][cur[b]] then
            local keepA, keepB = cur[a], cur[b]
            for i = 1, n do
              local freeI = not inUse[i] or inUse[i] == a or inUse[i] == b
              if legal[a][i] and freeI then
                for _, j in ipairs(adjacent[i]) do
                  local freeJ = not inUse[j] or inUse[j] == a or inUse[j] == b
                  if legal[b][j] and freeJ and not (i == keepA and j == keepB)
                      and not (i == keepB and j == keepA) and not self:OverBudget() then
                    cur[a], cur[b] = i, j
                    Try()
                  end
                end
              end
            end
            cur[a], cur[b] = keepA, keepB
          end
        end
      end
    end
    if bestTrial == nil then break end
    cur, gain = bestTrial, bestGain
    self:Consider(gain, true, cur)
  end
  return cur, gain
end

-- Ruin and recreate from the best layout, `count` times: take some slots off,
-- put them back one by one each on its best free plot (exact values), then
-- local search. Kick r starts from slot ((r - 1) mod K) + 1; each cycle
-- through the slots ruins more, so repeated kicks never just repeat:
--   cycle 0  the seed and the slots next to it; the seed may not go back
--   cycle 1  the seed and the slots within two plots
--   cycle 2  the seed and the slots next to it; none may go back
--   cycle 3+ two seeds (the second c slots further on) and their neighbours
-- `state` (default the search itself) holds the layout kicked (BestLayout,
-- BestGain) and the kick counters; for one combination of a pool, only its
-- placed slots move, so the combination stays.
function Search:Kicks(count, state)
  state = state or self
  local k, n, legal, candidates = self.K, self.N, self.Legal, self.Candidates
  local _, touching = self:Touching()
  state.KickIndex = state.KickIndex or 0
  state.KicksWithout = state.KicksWithout or 0
  local function Near(a, b, range)
    if range == 1 then return touching[a][b] end
    local ca, cb = candidates[a], candidates[b]
    return Map.GetPlotDistance(ca.X, ca.Y, cb.X, cb.Y) <= range
  end
  for _ = 1, count do
    if state.BestLayout == nil or self:OverBudget() then return end
    state.KickIndex = state.KickIndex + 1
    -- Seeds cycle through the slots; with pools through the placed ones only
    -- (the others are candidates left out).
    local cycleSlots = {}
    for m = 1, k do
      if not self:HasPools() or state.BestLayout[m] ~= 0 then cycleSlots[#cycleSlots + 1] = m end
    end
    local kk = math.max(1, #cycleSlots)
    local pos = (state.KickIndex - 1) % kk + 1
    local seed = cycleSlots[pos] or 1
    local cycle = math.floor((state.KickIndex - 1) / kk)
    local layout = Copy(state.BestLayout)
    local seeds = { seed }
    if cycle >= 3 and kk > 1 then seeds[2] = cycleSlots[(pos - 1 + cycle - 2) % kk + 1] end
    local range = (cycle == 1) and 2 or 1
    local removed, isRemoved = {}, {}
    for _, sd in ipairs(seeds) do
      if not isRemoved[sd] and layout[sd] ~= 0 then
        removed[#removed + 1], isRemoved[sd] = sd, true
      end
    end
    for _, sd in ipairs(seeds) do
      for m = 1, k do
        if not isRemoved[m] and layout[m] ~= 0 and layout[sd] ~= 0 and Near(layout[m], layout[sd], range) then
          removed[#removed + 1], isRemoved[m] = m, true
        end
      end
    end
    local forbidden = {}
    for _, m in ipairs(removed) do
      if m == seed or cycle == 2 then forbidden[m] = layout[m] end
    end
    for _, m in ipairs(removed) do layout[m] = 0 end
    local ok = true
    for _, m in ipairs(removed) do
      local used = {}
      for mm = 1, k do
        if layout[mm] ~= 0 then used[layout[mm]] = true end
      end
      local bestI, bestGain = nil, nil
      for i = 1, n do
        if legal[m][i] and not used[i] and forbidden[m] ~= i then
          layout[m] = i
          self.Stats.Tries = self.Stats.Tries + 1
          Tick(SDP_Tiers.UNITS_PER_TRY)
          local gain = self:Evaluate(layout)
          if bestI == nil or gain > bestGain then bestI, bestGain = i, gain end
        end
      end
      if bestI == nil then
        ok = false
        break
      end
      layout[m] = bestI
    end
    local before = state.BestGain
    if ok then
      local gain, isLegal = self:Evaluate(layout)
      if isLegal then
        self:Consider(gain, true, layout)
        local found, foundGain = self:LocalSearch(layout, gain)
        if state ~= self and Better(foundGain, found, state.BestGain, state.BestLayout) then
          state.BestLayout, state.BestGain = found, foundGain
        end
      end
    end
    if state.BestGain > before then state.KicksWithout = 0 else state.KicksWithout = state.KicksWithout + 1 end
  end
end

-- Best placement of the slots in `order` with the others as in `base`
-- (SDP_Multi: one city at a time). Exhaustive when small, else the model
-- shortlist; then local search moving these slots only. Returns the layout
-- and its value, or nil when the slots fit nowhere.
function Search:SolveBlock(order, base)
  local active = {}
  for _, m in ipairs(order) do active[m] = true end
  local count = self:CountLayouts(order, UsedBy(base, active), self.Params.ExactLimit)
  local best, gain
  if count == 0 then return nil end
  if count <= self.Params.ExactLimit then
    local _, layout, value = self:Exhaustive(order, base)
    best, gain = layout, value
  else
    local ranked = self:Shortlist(order, base)
    if ranked[1] then best, gain = ranked[1].Layout, ranked[1].Gain end
  end
  if best == nil then return nil end
  return self:LocalSearch(best, gain, active)
end

-- ===========================================================================
-- The whole search over all slots (single city; SDP_Multi drives its own).
-- ===========================================================================
function Search:AllSlots()
  local order = {}
  for m = 1, self.K do order[m] = m end
  return order
end

function Search:EmptyLayout()
  local layout = {}
  for m = 1, self.K do layout[m] = 0 end
  return layout
end

-- First run.
function Search:Run()
  local params = self.Params
  if self:HasPools() then
    self:RunPools(self.PoolGroups[1])
    return self:PlaceWhatFits()
  end
  self:SetBudgets()
  if self.K == 0 then return end
  local order, base = self:AllSlots(), self:EmptyLayout()
  local used = UsedBy(base, {})
  local count = self:CountLayouts(order, used, params.ExactLimit)
  self.Stats.Layouts = count
  if count <= params.ExactLimit then
    self.Stats.Method = "exhaustive"
    self.Exact = self:Exhaustive(order, base)
  else
    self.Stats.Method = "shortlist"
    self.Ranked, self.Bound = self:Shortlist(order, base)
    self.NextStart, self.Started = 1, {}
    self:RunStarts(params.Starts)
    self:Kicks(params.Kicks or 0)
  end
  self:PlaceWhatFits()
end

-- No layout places every required slot: some need the same few plots (a
-- harbor and a water park where one coastal plot takes either; late-game
-- stress test, 2026-10-21). Place as many as fit (design goal G4): leave out
-- one required slot, then two, and so on, in slot order, and solve the rest
-- (SolveBlock; candidates stay out). Consider keeps the layout with the most
-- slots placed, then the best value. Stops at the first count that places
-- anything, or on the budget.
function Search:PlaceWhatFits()
  if self.BestLayout ~= nil or self.K < 2 then return end
  local required = {}
  for m = 1, self.K do
    if not self.Optional[m] then required[#required + 1] = m end
  end
  local base = self:EmptyLayout()
  for drop = 1, #required - 1 do
    local out = {}
    local function Walk(start, depth)
      if self:OverBudget() then return end
      if depth > drop then
        local order = {}
        for _, m in ipairs(required) do
          if not out[m] then order[#order + 1] = m end
        end
        local layout, gain = self:SolveBlock(order, base)
        if layout ~= nil then self:Consider(gain, true, layout) end
        return
      end
      for x = start, #required - (drop - depth) do
        out[required[x]] = true
        Walk(x + 1, depth + 1)
        out[required[x]] = nil
      end
    end
    Walk(1, 1)
    if self.BestLayout ~= nil or self:OverBudget() then return end
  end
end

function Search:CanContinue()
  if self.Stats.Method == "pools" then return self:CanContinuePools() end
  if self.Stats.Method ~= "shortlist" or self.Ranked == nil then return false end
  if self.NextStart <= #self.Ranked then return true end
  -- Four cycles of kicks (every strength, see Kicks) found nothing: stop.
  return (self.Params.Kicks or 0) > 0 and (self.KicksWithout or 0) < 4 * self.K
end

-- One more batch: the next shortlist starts and kicks. Returns false when
-- there is nothing left to try.
function Search:Continue()
  if not self:CanContinue() then return false end
  if self.Stats.Method == "pools" then return self:ContinuePools() end
  self:SetBudgets()
  local before = self.BestGain
  self.Stats.Continues = self.Stats.Continues + 1
  self:RunStarts(SDP_Tiers.SINGLE_CONTINUE_STARTS)
  self:Kicks(self.Params.Kicks or 0)
  self.Converged = before ~= nil and self.BestGain == before
  return true
end

-- ===========================================================================
-- Pools: which candidate districts to place (design: feedback item 1). The
-- single-city solver and the site scores run RunPools on their one group;
-- SDP_Multi chooses per city with Combos, SolveBlock and TypeSwaps.
-- ===========================================================================
SDP_Search.COMBO_LIMIT = 5000 -- combinations ranked per group at most

local function Choose(n, k)
  local c = 1
  for i = 1, k do c = c * (n - k + i) / i end
  return c
end

-- The group's required slots and `slots`, ascending.
function Search:ActiveOrder(g, slots)
  local order = {}
  for _, m in ipairs(self.RequiredSlots[g] or {}) do order[#order + 1] = m end
  for _, m in ipairs(slots) do order[#order + 1] = m end
  table.sort(order)
  return order
end

-- The optional slots of group g that `layout` places, ascending.
function Search:ChosenOf(g, layout)
  local chosen = {}
  for _, m in ipairs(self.PoolSlots[g] or {}) do
    if layout[m] ~= 0 then chosen[#chosen + 1] = m end
  end
  return chosen
end

function Search:ComboKey(slots)
  local names = {}
  for x, m in ipairs(slots) do names[x] = self.Types[m] end
  return table.concat(names, ",")
end

-- Every way to pick PoolCount[g] of group g's optional slots, best
-- optimistic value first: { Slots (ascending), Value, Key }. The value is the
-- model's: each slot's best single value, plus the positive pair gains among
-- the picked slots and with the group's required ones (each pair once), plus
-- the same for the required slots alone. Like the model bound it is usually
-- optimistic. Ties: by the types' names. More than COMBO_LIMIT combinations:
-- only the candidates with the best values of their own take part.
-- Whether picking `slots` (optional slots of group g) puts partner districts
-- (spec.Apart) in one city: a slot whose partner the city has or requires,
-- or two partners among the slots.
function Search:Clashes(g, slots)
  local apart = self.Apart
  if apart == nil then return false end
  local partners, present = apart.Partners, (apart.Present and apart.Present[g]) or {}
  local avoid = (apart.Avoid and apart.Avoid[g]) or {}
  for x, m in ipairs(slots) do
    local own = partners[self.Types[m]]
    if own ~= nil and avoid[self.Types[m]] and self:PartnerCandidate(g, own) then return true end
    if own ~= nil then
      for other in pairs(own) do
        if present[other] then return true end -- a yes or no: the order does not matter
      end
      for _, r in ipairs(self.RequiredSlots[g] or {}) do
        if own[self.Types[r]] then return true end
      end
      for y = 1, x - 1 do
        if own[self.Types[slots[y]]] then return true end
      end
    end
  end
  return false
end

-- Whether group g has an optional slot of a type in `own` (a partner set)
-- with a legal plot: the side a city takes instead of an avoided one.
function Search:PartnerCandidate(g, own)
  for _, m in ipairs(self.PoolSlots[g] or {}) do
    if own[self.Types[m]] then
      for i = 1, self.N do
        if self.Legal[m][i] then return true end
      end
    end
  end
  return false
end

-- Whether `slots` (optional slots of group g) hold two districts one city
-- cannot have (spec.Exclusive), or one that a required slot of g excludes.
function Search:Excluded(g, slots)
  local exclusive = self.Exclusive
  for x, m in ipairs(slots) do
    local own = exclusive[self.Types[m]]
    if own ~= nil then
      for _, r in ipairs(self.RequiredSlots[g] or {}) do
        if own[self.Types[r]] then return true end
      end
      for y = 1, x - 1 do
        if own[self.Types[slots[y]]] then return true end
      end
    end
  end
  return false
end

function Search:Combos(g)
  self.ComboCache = self.ComboCache or {}
  if self.ComboCache[g] ~= nil then return self.ComboCache[g] end
  local list = self:BuildCombos(g, self.Apart ~= nil)
  if self.Apart ~= nil and #list == 0 then
    -- Every combination puts partners together: allow it (and say so).
    self.ApartRelaxed[g] = true
    list = self:BuildCombos(g, false)
  end
  self.ComboCache[g] = list
  return list
end

-- The combinations of group g, best first; `apart`: without the ones that
-- clash (Clashes), candidates the city cannot take left out before the
-- COMBO_LIMIT cut.
function Search:BuildCombos(g, apart)
  self:Model()
  local single, pair, legal, n = self.ModelSingle, self.Pair, self.Legal, self.N
  local required, need = self.RequiredSlots[g] or {}, self.PoolCount[g] or 0
  local function BestSingle(m)
    local best = nil
    for i = 1, n do
      if legal[m][i] and (best == nil or single[m][i] > best) then best = single[m][i] end
    end
    return best or 0
  end
  local base = 0
  for x, a in ipairs(required) do
    base = base + BestSingle(a)
    for y = 1, x - 1 do
      if pair[a][required[y]] > 0 then base = base + pair[a][required[y]] end
    end
  end
  local pool, own = {}, {}
  for _, m in ipairs(self.PoolSlots[g] or {}) do
    if not (apart and self:Clashes(g, { m })) and not self:Excluded(g, { m }) then
      local value = BestSingle(m)
      for _, r in ipairs(required) do
        if pair[m][r] > 0 then value = value + pair[m][r] end
      end
      own[m] = value
      pool[#pool + 1] = m
    end
  end
  if #pool < need then return {} end
  while #pool > need and Choose(#pool, need) > SDP_Search.COMBO_LIMIT do
    local worst = 1
    for x = 2, #pool do
      if own[pool[x]] <= own[pool[worst]] then worst = x end
    end
    table.remove(pool, worst)
  end
  local list, chosen = {}, {}
  local function Walk(start, depth, value)
    if depth > need then
      local slots = Copy(chosen)
      list[#list + 1] = { Slots = slots, Value = base + value, Key = self:ComboKey(slots) }
      return
    end
    for x = start, #pool - (need - depth) do
      local m = pool[x]
      chosen[depth] = m
      if not (apart and self:Clashes(g, chosen)) and not self:Excluded(g, chosen) then
        local add = own[m]
        for d = 1, depth - 1 do
          if pair[m][chosen[d]] > 0 then add = add + pair[m][chosen[d]] end
        end
        Walk(x + 1, depth + 1, value + add)
      end
      chosen[depth] = nil
    end
  end
  Walk(1, 1, 0)
  table.sort(list, function(a, b)
    if a.Value ~= b.Value then return a.Value > b.Value end
    return a.Key < b.Key
  end)
  return list
end

-- The moves that swap one placed candidate of group g in `layout` for one
-- left out, the newcomer on its best free plot (exact values): { Slots
-- (the new combination), Key, Gain, Layout }, best first. Budgeted like
-- local search tries.
function Search:SwapMoves(g, layout)
  local moves, n, legal = {}, self.N, self.Legal
  local chosen, out = {}, {}
  for _, m in ipairs(self.PoolSlots[g] or {}) do
    if layout[m] ~= 0 then chosen[#chosen + 1] = m else out[#out + 1] = m end
  end
  local apart = self.Apart ~= nil and #self:Combos(g) > 0 and not self.ApartRelaxed[g]
  local trial = Copy(layout)
  for _, x in ipairs(chosen) do
    local keepX = trial[x]
    trial[x] = 0
    local used = {}
    for m = 1, self.K do
      if trial[m] ~= 0 then used[trial[m]] = true end
    end
    for _, y in ipairs(out) do
      local bestI, bestGain = nil, nil
      local swapped = {}
      for _, m in ipairs(chosen) do
        if m ~= x then swapped[#swapped + 1] = m end
      end
      swapped[#swapped + 1] = y
      for i = 1, ((apart and self:Clashes(g, swapped)) or self:Excluded(g, swapped)) and 0 or n do
        if legal[y][i] and not used[i] then
          if self:OverBudget() then break end
          trial[y] = i
          self.Stats.Tries = self.Stats.Tries + 1
          Tick(SDP_Tiers.UNITS_PER_TRY)
          local gain, isLegal = self:Evaluate(trial)
          if isLegal and (bestI == nil or gain > bestGain) then bestI, bestGain = i, gain end
        end
      end
      trial[y] = 0
      if bestI ~= nil then
        local slots = {}
        for _, m in ipairs(chosen) do
          if m ~= x then slots[#slots + 1] = m end
        end
        slots[#slots + 1] = y
        table.sort(slots)
        local moved = Copy(trial)
        moved[y] = bestI
        moves[#moves + 1] = { Slots = slots, Key = self:ComboKey(slots), Gain = bestGain, Layout = moved }
      end
    end
    trial[x] = keepX
  end
  table.sort(moves, function(a, b)
    if a.Gain ~= b.Gain then return a.Gain > b.Gain end
    return a.Key < b.Key
  end)
  return moves
end

-- The best improving swap over the groups with pools (SDP_Multi): returns
-- the new layout and value, or nil.
function Search:TypeSwaps(layout, gain)
  local best = nil
  for _, g in ipairs(self.PoolGroups) do
    if self:OverBudget() then break end
    local move = self:SwapMoves(g, layout)[1]
    if move ~= nil and move.Gain > gain and (best == nil or move.Gain > best.Gain) then best = move end
  end
  if best == nil then return nil end
  self:Consider(best.Gain, true, best.Layout)
  return best.Layout, best.Gain
end

-- Single group: every combination solved so far, best first.
function Search:SortEntries()
  table.sort(self.PoolEntries, function(a, b)
    return Ahead(Placed(a.BestLayout), a.BestGain, a.BestLayout, Placed(b.BestLayout), b.BestGain, b.BestLayout)
  end)
end

-- Solve one combination: exhaustively when small (ScreenExact layouts at
-- most; RefineCombos goes up to ExactLimit for the best ones), else the
-- model shortlist (ScreenShortlist layouts) and one local search. Its state
-- (best layout, ranked starts, kick counters) is kept for refining it later.
function Search:ScreenCombo(g, slots, key)
  local params = self.Params
  local entry = { Slots = slots, Key = key, Order = self:ActiveOrder(g, slots), Started = {}, NextStart = 1, Ranked = {} }
  self.PoolSeen[key] = entry
  local base = self:EmptyLayout()
  local limit = math.min(params.ExactLimit, params.ScreenExact or params.ExactLimit)
  local count = self:CountLayouts(entry.Order, {}, params.ExactLimit)
  entry.Count = count
  if count == 0 then return entry end
  if count <= limit then
    local complete, layout, gain = self:Exhaustive(entry.Order, base)
    entry.Exact, entry.BestLayout, entry.BestGain = complete, layout, gain
  else
    local shortlist = params.Shortlist
    params.Shortlist = math.min(shortlist, params.ScreenShortlist or shortlist)
    entry.Ranked, entry.Bound = self:Shortlist(entry.Order, base)
    params.Shortlist = shortlist
    self:RunStarts(1, entry)
  end
  if entry.BestLayout ~= nil then
    self.PoolEntries[#self.PoolEntries + 1] = entry
    self:SortEntries()
  end
  return entry
end

-- Solve the next `count` combinations in ranked order. A combination whose
-- optimistic value is below the last solution's value ends it: the rest
-- rank lower still.
function Search:ScreenCombos(count)
  local g = self.PoolGroup
  local combos = self:Combos(g)
  local solutions = self.Params.Solutions or 3
  local done = 0
  while done < count and self.NextCombo <= #combos and not self:OverBudget() do
    local c = combos[self.NextCombo]
    local last = self.PoolEntries[solutions]
    if last ~= nil and c.Value < last.BestGain then
      self.Pruned = true
      self.NextCombo = #combos + 1
      break
    end
    self.NextCombo = self.NextCombo + 1
    if self.PoolSeen[c.Key] == nil then
      self:ScreenCombo(g, c.Slots, c.Key)
      done = done + 1
    end
  end
end

-- From the best combinations, swap one candidate for another; a new
-- combination that would rank among the solutions is solved too (at most
-- `limit`). Catches what the optimistic ranking got wrong.
function Search:SwapCombos(limit)
  local g, solutions = self.PoolGroup, self.Params.Solutions or 3
  local tried = 0
  local top = {}
  for r = 1, math.min(solutions, #self.PoolEntries) do top[r] = self.PoolEntries[r] end
  for _, entry in ipairs(top) do
    for _, move in ipairs(self:SwapMoves(g, entry.BestLayout)) do
      if tried >= limit or self:OverBudget() then return end
      if self.PoolSeen[move.Key] == nil then
        local last = self.PoolEntries[solutions]
        if last == nil or move.Gain > last.BestGain then
          self:ScreenCombo(g, move.Slots, move.Key)
          tried = tried + 1
        end
      end
    end
  end
end

-- The best combinations: solved exhaustively when they have at most
-- ExactLimit layouts, else more local search starts and kicks.
function Search:RefineCombos(starts, kicks)
  local params = self.Params
  local solutions = params.Solutions or 3
  local top = {}
  for r = 1, math.min(solutions, #self.PoolEntries) do top[r] = self.PoolEntries[r] end
  for _, entry in ipairs(top) do
    if not entry.Exact and not self:OverBudget() then
      if entry.Count ~= nil and entry.Count <= params.ExactLimit then
        local complete, layout, gain = self:Exhaustive(entry.Order, self:EmptyLayout())
        entry.Exact = complete
        if layout ~= nil and (entry.BestLayout == nil or Better(gain, layout, entry.BestGain, entry.BestLayout)) then
          entry.BestLayout, entry.BestGain = layout, gain
        end
      else
        self:RunStarts(starts, entry)
        self:Kicks(kicks, entry)
      end
    end
  end
  self:SortEntries()
end

function Search:RunPools(g)
  local params = self.Params
  self:SetBudgets()
  self.Stats.Method = "pools"
  self.PoolGroup = g
  self.PoolEntries, self.PoolSeen, self.NextCombo = {}, {}, 1
  if self.K == 0 then return end
  self.Stats.Combos = #self:Combos(g)
  local count = params.Combos or 3
  self:ScreenCombos(count)
  self:SwapCombos(count)
  self:RefineCombos(math.max(0, (params.Starts or 1) - 1), params.Kicks or 0)
end

function Search:CanContinuePools()
  if self.PoolEntries == nil or self.K == 0 then return false end
  if self.NextCombo <= #self:Combos(self.PoolGroup) then return true end
  local solutions = self.Params.Solutions or 3
  for r = 1, math.min(solutions, #self.PoolEntries) do
    local entry = self.PoolEntries[r]
    if not entry.Exact then
      if entry.NextStart <= #entry.Ranked then return true end
      if (self.Params.Kicks or 0) > 0 and (entry.KicksWithout or 0) < 4 * self.Selected then return true end
    end
  end
  return false
end

function Search:ContinuePools()
  self:SetBudgets()
  local before = self.BestGain
  self.Stats.Continues = self.Stats.Continues + 1
  local count = math.max(1, math.ceil((self.Params.Combos or 3) / 2))
  self:ScreenCombos(count)
  self:SwapCombos(count)
  self:RefineCombos(SDP_Tiers.SINGLE_CONTINUE_STARTS, self.Params.Kicks or 0)
  self.Converged = before ~= nil and self.BestGain == before
  return true
end

-- Every combination was solved, each exhaustively: the result is optimal.
function Search:PoolsExact()
  if self.Pruned or self.PoolEntries == nil or self.NextCombo <= #self:Combos(self.PoolGroup) then return false end
  for _, entry in pairs(self.PoolSeen) do
    if entry.BestLayout ~= nil and not entry.Exact then return false end
  end
  return true
end

-- Estimated upper bound: the best optimistic value of a combination not
-- solved exactly.
function Search:PoolsBound()
  local bound = nil
  for _, c in ipairs(self:Combos(self.PoolGroup)) do
    local entry = self.PoolSeen[c.Key]
    local value = c.Value
    if entry ~= nil and entry.Exact then value = entry.BestGain or value end
    if entry ~= nil and entry.Bound ~= nil then value = entry.Bound end
    if bound == nil or value > bound then bound = value end
  end
  return bound
end

-- Up to `count` solutions: the best layout of each solved combination, best
-- first; then the alternatives kept along the way (other plots for the same
-- districts), as long as they are distinct from the ones taken.
function Search:Solutions(count)
  local pool = {}
  for _, entry in ipairs(self.PoolEntries or {}) do
    pool[#pool + 1] = { Layout = entry.BestLayout, Gain = entry.BestGain }
  end
  if self.BestLayout ~= nil then table.insert(pool, 1, { Layout = self.BestLayout, Gain = self.BestGain }) end
  for _, e in ipairs(self.Alt) do pool[#pool + 1] = { Layout = e.Layout, Gain = e.Gain } end
  local kept = {}
  for _, entry in ipairs(pool) do
    if #kept >= count then break end
    local distinct = true
    for _, other in ipairs(kept) do
      if not self:IsDistinct(entry.Layout, other.Layout) then distinct = false end
    end
    if distinct then kept[#kept + 1] = entry end
  end
  return kept
end

-- Quality indicators (design 7.4) for `gain`, the value reported.
function Search:Quality(gain)
  local exhaustive = self.Stats.Method == "exhaustive" and self.Exact == true
  if self.Stats.Method == "pools" then exhaustive, self.Bound = self:PoolsExact(), self:PoolsBound() end
  local gap = nil
  if not exhaustive and self.Bound ~= nil and self.Bound > 0 and gain ~= nil then
    gap = math.max(0, (self.Bound - gain) / self.Bound)
  end
  return {
    Exhaustive = exhaustive, Bound = (not exhaustive) and self.Bound or nil, Gap = gap,
    Converged = self.Converged, CanContinue = self:CanContinue(), Truncated = self.Stats.Truncated,
  }
end
