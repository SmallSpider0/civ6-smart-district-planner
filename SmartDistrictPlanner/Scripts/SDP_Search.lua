-- SDP_Search: the placement search shared by the single-city solver
-- (SDP_Solver) and the multi-city solver (SDP_Multi).
--
-- A problem is a set of slots (a district or wonder to place, belonging to a
-- group: a city) over one sorted list of candidate plots. A layout gives each
-- slot a candidate position (0: not placed). Its value is SDP_Board's exact
-- DMT gain plus the land part of every land model (SDP_Land).
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
--   Slots       { Key, Type ("DISTRICT" | "WONDER"), Group, Allowed = { [position] = true } or nil (all) }
--   Lands       SDP_Land models whose part counts (each only sees its own plots)
-- }
function SDP_Search.New(spec)
  local self = setmetatable({}, Search)
  self.PlayerID, self.Board, self.Weights, self.Params = spec.PlayerID, spec.Board, spec.Weights, spec.Params
  self.Candidates, self.N = spec.Candidates, #spec.Candidates
  self.Lands = spec.Lands or {}
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

-- Every slot alone on every allowed candidate. Slots without any legal plot
-- are dropped; returns the list of their indices into spec.Slots. Afterwards
-- K, Types, Kinds, Groups, Single, Legal and SlotIndex (into spec.Slots)
-- describe the placeable slots.
function Search:Singles()
  local board, n = self.Board, self.N
  local types, kinds, groups, single, legal, subjects, index, dropped = {}, {}, {}, {}, {}, {}, {}, {}
  for s, slot in ipairs(self.SlotSpecs) do
    local gains, ok, row, any = {}, {}, {}, false
    for i = 1, n do
      if slot.Allowed == nil or slot.Allowed[i] then
        local c = self.Candidates[i]
        row[i] = { Key = slot.Key, Type = slot.Type or "DISTRICT", X = c.X, Y = c.Y }
        board:Put(1, row[i])
        local gain, isLegal = board:Total()
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
  return dropped
end

-- Move the board to `layout` and return its value (DMT gain + land parts)
-- and whether DMT allows every placed slot. Position 0 leaves a slot off.
function Search:Evaluate(layout)
  local board, candidates, k = self.Board, self.Candidates, self.K
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
  local gain, legal = board:Total()
  self.Stats.Evaluations = self.Stats.Evaluations + 1
  if #self.Lands > 0 then
    local taken, placed = self.Taken, 0
    for m = 1, k do
      if layout[m] ~= 0 then
        placed = placed + 1
        taken[placed] = candidates[layout[m]].Index
      end
    end
    for _, land in ipairs(self.Lands) do
      gain = gain + SDP_Land.ScoreTaken(land, taken, placed, self.Mark) - land.Base
    end
  end
  return gain, legal
end

-- The land part of a layout alone (for reports).
function Search:LandDelta(layout)
  local taken = {}
  for m = 1, self.K do
    if layout[m] ~= 0 then taken[#taken + 1] = self.Candidates[layout[m]].Index end
  end
  local delta = 0
  for _, land in ipairs(self.Lands) do delta = delta + SDP_Land.ScoreTaken(land, taken, #taken, {}) - land.Base end
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

function Search:Consider(gain, legal, layout)
  if legal and (self.BestLayout == nil or Better(gain, layout, self.BestGain, self.BestLayout)) then
    self.BestLayout, self.BestGain = Copy(layout), gain
    return true
  end
  return false
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
-- in `base`.
function Search:Exhaustive(order, base)
  local active = {}
  for _, m in ipairs(order) do active[m] = true end
  local used = UsedBy(base, active)
  local layout = Copy(base)
  local legal, n, stopped = self.Legal, self.N, false
  local function Walk(d)
    if d > #order then
      local gain, isLegal = self:Evaluate(layout)
      self:Consider(gain, isLegal, layout)
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
  return not stopped
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
  local single = {}
  for m = 1, k do
    single[m] = {}
    local rows = (adjacency[self.Types[m]] or {}).Rows or {}
    for i = 1, n do
      local value = self.Single[m][i] - loss[i]
      for _, row in ipairs(rows) do
        if row.TilesRequired > 1 then
          local count = 0
          for _, key in ipairs(fixedNear[i]) do
            if row.Any or key == row.District then count = count + 1 end
          end
          value = value + (weights[row.YieldType] or 0) * row.YieldChange * (count % row.TilesRequired) / row.TilesRequired
        end
      end
      single[m][i] = value
    end
  end
  local pair = {}
  for a = 1, k do
    pair[a] = {}
    for b = 1, k do
      pair[a][b] = SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, self.Types[a], self.Types[b]), weights)
        + SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, self.Types[b], self.Types[a]), weights)
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

-- Whether two layouts differ in at least `count` slots.
local function Differ(a, b, count)
  local diff = 0
  for m = 1, #a do
    if a[m] ~= b[m] then diff = diff + 1 end
  end
  return diff >= count
end

-- Local search from the next `count` ranked layouts that differ from every
-- earlier start in at least two slots.
function Search:RunStarts(count)
  local done = 0
  while done < count and self.NextStart <= #self.Ranked and not self:OverBudget() do
    local start = self.Ranked[self.NextStart]
    self.NextStart = self.NextStart + 1
    local fresh = true
    for _, earlier in ipairs(self.Started) do
      if not Differ(start.Layout, earlier, math.min(2, self.K)) then fresh = false end
    end
    if fresh then
      self.Started[#self.Started + 1] = start.Layout
      self:LocalSearch(start.Layout, start.Gain)
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

-- Local search from `layout` (every slot placed). Moves: one slot to a free
-- plot; two slots trade plots (Swap); a group of touching slots, or all of
-- them, shifted one plot in any direction; two adjacent slots to another
-- adjacent pair of plots (Pair). Params.Improve = "first" takes the first
-- improving move of a pass instead of the best. Returns the local optimum.
function Search:LocalSearch(layout, gain)
  local k, n, legal, params, stats = self.K, self.N, self.Legal, self.Params, self.Stats
  local adjacent, touching = self:Touching()
  local candidates, at, board = self.Candidates, self.CandidateAt, self.Board
  local first = params.Improve == "first"
  local cur = Copy(layout)
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
    for m = 1, k do inUse[cur[m]] = m end
    -- One slot to a free plot.
    for m = 1, k do
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
      for a = 1, k - 1 do
        for b = a + 1, k do
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
      local groups = Components(cur, touching)
      if #groups > 1 then
        local all = {}
        for m = 1, k do all[m] = m end
        groups[#groups + 1] = all
      end
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
      for a = 1, k - 1 do
        for b = a + 1, k do
          if cur[a] ~= 0 and cur[b] ~= 0 and touching[cur[a]][cur[b]] then
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
function Search:Kicks(count)
  local k, n, legal, candidates = self.K, self.N, self.Legal, self.Candidates
  local _, touching = self:Touching()
  self.KickIndex = self.KickIndex or 0
  self.KicksWithout = self.KicksWithout or 0
  local function Near(a, b, range)
    if range == 1 then return touching[a][b] end
    local ca, cb = candidates[a], candidates[b]
    return Map.GetPlotDistance(ca.X, ca.Y, cb.X, cb.Y) <= range
  end
  for _ = 1, count do
    if self.BestLayout == nil or self:OverBudget() then return end
    self.KickIndex = self.KickIndex + 1
    local seed = (self.KickIndex - 1) % k + 1
    local cycle = math.floor((self.KickIndex - 1) / k)
    local layout = Copy(self.BestLayout)
    local seeds = { seed }
    if cycle >= 3 and k > 1 then seeds[2] = (seed - 1 + cycle - 2) % k + 1 end
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
    local before = self.BestGain
    if ok then
      local gain, isLegal = self:Evaluate(layout)
      if isLegal then
        self:Consider(gain, true, layout)
        self:LocalSearch(layout, gain)
      end
    end
    if self.BestGain > before then self.KicksWithout = 0 else self.KicksWithout = self.KicksWithout + 1 end
  end
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
end

function Search:CanContinue()
  if self.Stats.Method ~= "shortlist" or self.Ranked == nil then return false end
  if self.NextStart <= #self.Ranked then return true end
  -- Four cycles of kicks (every strength, see Kicks) found nothing: stop.
  return (self.Params.Kicks or 0) > 0 and (self.KicksWithout or 0) < 4 * self.K
end

-- One more batch: the next shortlist starts and kicks. Returns false when
-- there is nothing left to try.
function Search:Continue()
  if not self:CanContinue() then return false end
  self:SetBudgets()
  local before = self.BestGain
  self.Stats.Continues = self.Stats.Continues + 1
  self:RunStarts(SDP_Tiers.SINGLE_CONTINUE_STARTS)
  self:Kicks(self.Params.Kicks or 0)
  self.Converged = before ~= nil and self.BestGain == before
  return true
end

-- Quality indicators (design 7.4) for `gain`, the value reported.
function Search:Quality(gain)
  local exhaustive = self.Stats.Method == "exhaustive" and self.Exact == true
  local gap = nil
  if not exhaustive and self.Bound ~= nil and self.Bound > 0 and gain ~= nil then
    gap = math.max(0, (self.Bound - gain) / self.Bound)
  end
  return {
    Exhaustive = exhaustive, Bound = (not exhaustive) and self.Bound or nil, Gap = gap,
    Converged = self.Converged, CanContinue = self:CanContinue(), Truncated = self.Stats.Truncated,
  }
end
