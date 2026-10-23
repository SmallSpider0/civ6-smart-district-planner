-- cmp_oracle.lua: the exact reference solver (issue 36), variant sdp:ORACLE.
--
-- Branch and bound over every slot of the search the mod's own solver built
-- (same candidates, legal plots, single values and exact evaluation), so the
-- optimum is over exactly the layouts the mod may choose, judged by the same
-- DMT. Only for district slots without pools (no optional slots, no wonders).
-- The value is the DMT adjacency gain alone (the judge's gain): the search's
-- own objective may add parts the judge does not count (the housing a
-- pinned neighbourhood gets from appeal), so it only decides legality.
--
-- Upper bound of a layout: the sum over its slots of the model's single value
-- (the exact value alone, plus the share of each TilesRequired step the
-- fixed neighbours have started) and over its pairs of neighbouring slots of
--   max(exact pair interaction at those two plots, unrounded table pair, 0)
-- The exact pair interaction (both together minus each alone, with DMT)
-- holds what the table does not (Japan's trait); the unrounded table holds
-- the TilesRequired steps three districts complete together; negative
-- interactions count 0, so rounding cannot make them count twice. This is an
-- upper bound for the rules the game has, but not provably for every DMT
-- modifier, so every exactly evaluated layout is checked against its bound:
-- a layout worth more than its bound makes the result "not proven".
--
-- A run that hits the node limit reports the best layout found (lower) and
-- the largest bound of what it did not search (upper).

CmpOracle = {}

CmpOracle.NODE_LIMIT = 5e7
local EPS = 1e-6

-- The judge's value of `layout` (DMT adjacency gain) and whether the search
-- allows it (DMT, reach, a wonder's own city).
local function Value(search, layout)
  local _, legal = search:Evaluate(layout)
  local gain = search.Board:Total()
  return gain, legal
end

-- The exact pair interaction of every two district types on every two
-- neighbouring candidate plots, as Bound[ta][tb][i][j] (with the unrounded
-- table and 0 folded in), and its maximum over plots MaxPair[ta][tb].
local function PairBounds(search)
  local board, n, k = search.Board, search.N, search.K
  local adjacent = search:Touching()
  local adjacency = SDP_Rules.AdjacencyTable(search.PlayerID)
  local types, typeOf, single, legal = {}, {}, {}, {}
  for m = 1, k do
    local t = search.Types[m]
    typeOf[m] = t
    if single[t] == nil then
      types[#types + 1] = t
      single[t], legal[t] = {}, {}
    end
    for i = 1, n do
      if search.Legal[m][i] and not legal[t][i] then
        legal[t][i], single[t][i] = true, search.Single[m][i]
      end
    end
  end
  table.sort(types)
  for m = 1, k do board:Put(m, nil) end
  board:Total()
  local bound, maxPair, measured = {}, {}, 0
  for _, ta in ipairs(types) do
    bound[ta], maxPair[ta] = bound[ta] or {}, maxPair[ta] or {}
    for _, tb in ipairs(types) do
      if bound[ta][tb] == nil then
        local tableValue = SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, ta, tb), search.Weights)
          + SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, tb, ta), search.Weights)
        local floor = math.max(tableValue, 0)
        local ab, ba, best = {}, {}, floor
        for i = 1, n do
          if legal[ta][i] then
            for _, j in ipairs(adjacent[i]) do
              if legal[tb][j] then
                local ci, cj = search.Candidates[i], search.Candidates[j]
                board:Put(1, { Key = ta, Type = "DISTRICT", X = ci.X, Y = ci.Y })
                board:Put(2, { Key = tb, Type = "DISTRICT", X = cj.X, Y = cj.Y })
                local both, ok = board:Total()
                board:Put(1, nil)
                board:Put(2, nil)
                measured = measured + 1
                local value = floor
                if ok then value = math.max(floor, both - single[ta][i] - single[tb][j]) end
                ab[i] = ab[i] or {}
                ab[i][j] = value
                ba[j] = ba[j] or {}
                ba[j][i] = value
                if value > best then best = value end
              end
            end
          end
        end
        board:Total()
        bound[ta][tb], maxPair[ta][tb] = ab, best
        bound[tb] = bound[tb] or {}
        maxPair[tb] = maxPair[tb] or {}
        bound[tb][ta], maxPair[tb][ta] = ba, best
      end
    end
  end
  return bound, maxPair, typeOf, measured
end

-- Run on `search` (inside the overlay). `incumbentLayout`: a layout to start
-- from (the tier's plan), valued again here. Returns
-- { Layout, Value, Upper, Proven, Complete, Nodes, Leaves, Violations, MaxExcess, Pairs }.
function CmpOracle.Run(search, incumbentLayout)
  local k, n = search.K, search.N
  for m = 1, k do
    if search.Kinds[m] ~= "DISTRICT" then error("oracle: only district slots") end
    if search.Optional[m] then error("oracle: optional slots (pools) are not supported") end
  end
  search:Model()
  local single = search.ModelSingle
  local bound, maxPair, typeOf, measured = PairBounds(search)
  local adjacent = search:Touching()

  -- Single bound: the model's single, never below the exact single.
  local sb, plots, bestSB = {}, {}, {}
  for m = 1, k do
    sb[m], plots[m] = {}, {}
    for i = 1, n do
      if search.Legal[m][i] then
        sb[m][i] = math.max(single[m][i], search.Single[m][i])
        plots[m][#plots[m] + 1] = i
      end
    end
    table.sort(plots[m], function(a, b)
      if sb[m][a] ~= sb[m][b] then return sb[m][a] > sb[m][b] end
      return a < b
    end)
    bestSB[m] = plots[m][1] and sb[m][plots[m][1]] or -math.huge
  end

  -- Slot order: the strongest first; ties by slot.
  local order, pos = {}, {}
  for m = 1, k do order[m] = m end
  table.sort(order, function(a, b)
    if bestSB[a] ~= bestSB[b] then return bestSB[a] > bestSB[b] end
    return a < b
  end)
  for d, m in ipairs(order) do pos[m] = d end
  -- pairAt[m][i][t]: the largest pair bound of slot m on plot i with a
  -- district of type t on a neighbouring plot.
  local pairAt = {}
  for m = 1, k do
    pairAt[m] = {}
    local tm = typeOf[m]
    for _, i in ipairs(plots[m]) do
      local row = {}
      for t, byPlot in pairs(bound[tm]) do
        local best = nil
        for _, v in pairs(byPlot[i] or {}) do
          if best == nil or v > best then best = v end
        end
        if best ~= nil then row[t] = best end
      end
      pairAt[m][i] = row
    end
  end
  -- With integer weights every value is an integer, so a bound can be
  -- rounded down before it is compared.
  local integral = true
  for _, w in pairs(search.Weights) do
    if w ~= math.floor(w) then integral = false end
  end
  local function Cap(x)
    if integral then return math.floor(x + EPS) end
    return x
  end

  local layout, slotAt = {}, {}
  for m = 1, k do layout[m] = 0 end
  local best, bestValue = nil, -math.huge
  if incumbentLayout ~= nil then
    local value, legal = Value(search, incumbentLayout)
    if legal then
      best, bestValue = {}, value
      for m = 1, k do best[m] = incumbentLayout[m] end
    end
  end
  local startValue = bestValue
  local stats = { Nodes = 0, Leaves = 0, Violations = 0, MaxExcess = 0 }
  local stopped, openMax = false, -math.huge

  -- Upper bound of what the slots from depth d on add: for each, the best
  -- over its free plots of its single value, its pairs with the placed
  -- slots next to that plot, and its largest pairs with the unplaced slots
  -- before it in the order (each pair counted at the later slot), at most
  -- as many as the plot has free neighbours. nil when a slot has no plot.
  local gains = {}
  local function Rest(d)
    local total = 0
    for e = d, k do
      local m = order[e]
      local tm = typeOf[m]
      local best = nil
      for _, i in ipairs(plots[m]) do
        if slotAt[i] == nil then
          local v, free = sb[m][i], 0
          for _, j in ipairs(adjacent[i]) do
            local p = slotAt[j]
            if p ~= nil then
              v = v + bound[tm][typeOf[p]][i][j]
            else
              free = free + 1
            end
          end
          local row, count = pairAt[m][i], 0
          for f = d, e - 1 do
            local g = row[typeOf[order[f]]]
            if g ~= nil and g > 0 then
              count = count + 1
              gains[count] = g
            end
          end
          if count > 0 and free > 0 then
            for x = count + 1, #gains do gains[x] = nil end
            table.sort(gains, function(a, b) return a > b end)
            for x = 1, math.min(free, count) do v = v + gains[x] end
          end
          if best == nil or v > best then best = v end
        end
      end
      if best == nil then return nil end
      total = total + best
    end
    return total
  end

  local function Walk(d, cur)
    stats.Nodes = stats.Nodes + 1
    if stats.Nodes > CmpOracle.NODE_LIMIT then
      stopped = true
      openMax = math.max(openMax, Cap(cur + (Rest(d) or 0)))
      return
    end
    if d > k then
      if cur <= bestValue + EPS then return end
      local value, legal = Value(search, layout)
      stats.Leaves = stats.Leaves + 1
      if value > cur + EPS then
        stats.Violations = stats.Violations + 1
        stats.MaxExcess = math.max(stats.MaxExcess, value - cur)
      end
      if legal and value > bestValue + EPS then
        best, bestValue = {}, value
        for m = 1, k do best[m] = layout[m] end
      end
      return
    end
    local m = order[d]
    local rest = Rest(d + 1)
    if rest == nil then return end
    local t = typeOf[m]
    local children = {}
    for _, i in ipairs(plots[m]) do
      if slotAt[i] == nil then
        local v = sb[m][i]
        for _, j in ipairs(adjacent[i]) do
          local p = slotAt[j]
          if p ~= nil then v = v + bound[t][typeOf[p]][i][j] end
        end
        children[#children + 1] = { I = i, V = v }
      end
    end
    table.sort(children, function(a, b)
      if a.V ~= b.V then return a.V > b.V end
      return a.I < b.I
    end)
    for c, child in ipairs(children) do
      local limit = Cap(cur + child.V + rest)
      if limit <= bestValue + EPS then break end
      if stopped then
        openMax = math.max(openMax, limit)
        break
      end
      layout[m], slotAt[child.I] = child.I, m
      Walk(d + 1, cur + child.V)
      layout[m], slotAt[child.I] = 0, nil
      if stopped then
        local nextChild = children[c + 1]
        if nextChild ~= nil then openMax = math.max(openMax, Cap(cur + nextChild.V + rest)) end
        break
      end
    end
  end

  Walk(1, 0)
  local upper = stopped and math.max(bestValue, openMax) or bestValue
  return {
    Layout = best, Value = bestValue, Upper = upper, Complete = not stopped,
    Proven = (not stopped) and stats.Violations == 0,
    Nodes = stats.Nodes, Leaves = stats.Leaves, Violations = stats.Violations, MaxExcess = stats.MaxExcess,
    Pairs = measured, Start = startValue,
  }
end

-- Every layout, for checking Run on small cases: the best legal value, or
-- nil when there are more than `limit` layouts.
function CmpOracle.BruteForce(search, limit)
  local k, n = search.K, search.N
  local order = {}
  for m = 1, k do order[m] = m end
  local used = {}
  if search:CountLayouts(order, used, limit) > limit then return nil end
  local layout, best, count = {}, nil, 0
  for m = 1, k do layout[m] = 0 end
  local function Walk(m)
    if m > k then
      count = count + 1
      local value, legal = Value(search, layout)
      if legal and (best == nil or value > best) then best = value end
      return
    end
    for i = 1, n do
      if search.Legal[m][i] and not used[i] then
        used[i], layout[m] = true, i
        Walk(m + 1)
        used[i], layout[m] = nil, 0
      end
    end
  end
  Walk(1)
  return best, count
end
