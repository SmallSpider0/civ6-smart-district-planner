-- cmp_oracle.lua: the exact reference solver (issue 36), variant sdp:ORACLE.
--
-- Branch and bound over every slot of the search the mod's own solver built
-- (same candidates, legal plots, single values and exact evaluation), so the
-- optimum is over exactly the layouts the mod may choose, judged by the same
-- DMT. District and wonder slots (issue 48: a wonder is a slot like a
-- district, its value what it adds to its neighbours; its own rules, such
-- as the district it must be next to, are the search's legality, checked
-- at the leaves); not wonders that need an improvement next to them. With
-- pools ("pick N from these candidates") every allowed combination of each
-- group is searched in turn (SDP_Search's Clashes and Excluded rules), best
-- optimistic value first, all sharing one incumbent.
-- The value is the DMT adjacency gain alone (the judge's gain): the search's
-- own objective may add parts the judge does not count (the housing a
-- pinned neighbourhood gets from appeal), so it only decides legality.
--
-- Upper bound of a layout: the sum over its slots of the model's single value
-- (the exact value alone, plus the share of each TilesRequired step the
-- fixed neighbours and the slot's own fixed neighbours have started) and
-- over its pairs of neighbouring slots of
--   max(unrounded table pair + what the exact pair has beyond the table
--       rounded at those two plots, unrounded table pair, 0)
-- (PairBounds). The exact pair interaction (both together minus each
-- alone, with DMT) holds what the table does not (Japan's trait); the
-- unrounded table holds the TilesRequired steps districts complete
-- together; negative interactions count 0. The pairs among the slots not
-- placed yet are also capped by how many edges that many hexagons can have
-- (Rest). This is an upper bound for the rules the game has, but not
-- provably for every DMT modifier, so every exactly evaluated layout is
-- checked against its bound: a layout worth more than its bound makes the
-- result "not proven".
--
-- A run that hits the node limit reports the best layout found (lower) and
-- the largest bound of what it did not search (upper).
--
-- With options.Land (variant sdp:ORACLE_LAND, issue 48) the value is the
-- search's whole objective (search:Evaluate: DMT gain + the land part of
-- every land model + the housing of districts that depend on appeal), and
-- the bound changes:
--   Land: a city works its best P plots of its model. With the plots S
--     taken, let c(S) be the (P+1)-th best free plot's value (0 when there
--     is none); taking one more plot x costs exactly
--       Delta(x | S) = max(0, t_x - c(S))
--     and c(S) only falls as S grows, so Delta only rises: the loss is
--     supermodular. Each placement on the search path takes off its Delta
--     under the plots placed before it, which adds up to the exact land
--     part of the leaf (no slack); a slot not yet placed takes off its
--     Delta under the plots placed so far, a lower bound of what it will
--     cost. Pairs of districts only lose land together, so the pair bounds
--     stay as they are. Needs every plot value >= 0.
--   Housing (SDP_Appeal): a constant at the root, the housing every fixed
--     neighbourhood would have with the best appeal any placement around it
--     could give, above what it has now; and for a housing slot on a plot,
--     its housing at the best appeal there. HousingValue rises with slope
--     at most 1, so housing points added up are an upper bound.
--   A preserve placed by the plan raises the land value of the plots
--     around it (its grove and sanctuary), which breaks the monotonicity:
--     such runs are not proven (Unproven lists why).
--   Values are no longer whole numbers: bounds are not rounded down.
-- Without land, bounds are rounded down to a multiple of 1/scale when the
-- weights are whole multiples of it (see Cap).

CmpOracle = CmpOracle or {}

CmpOracle.NODE_LIMIT = CmpOracle.NODE_LIMIT or 5e7
local EPS = 1e-6

-- The value of `layout` and whether the search allows it (DMT, reach, a
-- wonder's own city), and its DMT adjacency gain. The value is that gain
-- (the judge's), or with `land` the search's whole objective.
local function Value(search, layout, land)
  local objective, legal = search:Evaluate(layout)
  local gain = search.Board:Total()
  if land then return objective, legal, gain end
  return gain, legal, gain
end

-- Start a computation on a freshly installed overlay. The board's slots
-- still sit where the last computation left them (Run ends on its best
-- layout, BruteForce and Climb on their last), but on the layer of the
-- overlay that computation had: the new one starts empty, and Evaluate only
-- puts slots that move. A slot that stays is then missing from the layer,
-- its neighbours are valued without it, and the board remembers those
-- values under neighbourhoods that have it (REF05 under g05f05 gave 17, not
-- 20; Climb on S03-rome-desert-late valued 34 layouts too low). Take every
-- slot off first, so each is put on this layer.
local function Fresh(search)
  search.Board:Clear()
end

-- What taking one more plot costs a land model (issue 48): with the plots
-- marked in `taken` ({ [plot index] = true }) taken, the (P+1)-th best free
-- plot's value (0 when there is none) ...
function CmpOracle.Cut(model, taken)
  local count = 0
  for _, p in ipairs(model.Plots) do
    if not taken[p.Index] then
      count = count + 1
      if count == model.P + 1 then return p.Tile end
    end
  end
  return 0
end

-- ... and a plot of value `tile` then costs max(0, tile - cut).
function CmpOracle.Delta(tile, cut)
  return tile > cut and tile - cut or 0
end

-- The pair bound of every two slot types on every two neighbouring
-- candidate plots, as Bound[ta][tb][i][j], and its maximum over plots
-- MaxPair[ta][tb]; and Own[t][i], what a slot of type t on plot i gets
-- once, whatever its neighbours (issue 48).
--
-- A table row that needs TilesRequired = T district neighbours (+1 for
-- every two districts) gives a district with F such neighbours already
-- floor(F / T) steps; k more give floor((F + k) / T) - floor(F / T), at
-- most (F mod T) / T + k / T steps. So the district gets (F mod T) / T of
-- the row once (Own: the model's single holds it, the exact single gets it
-- added) and each neighbour the unrounded 1 / T share (the table). Measuring the pair on two plots and
-- counting it on every edge (as before) counted the step a neighbour
-- completes on each of the district's six edges: with nine or more
-- districts the bound was twice the optimum. What the exact pair has
-- beyond the table rounded at those plots (both together minus each alone,
-- minus the table's rows with the step completed or not: Japan's trait,
-- other modifiers) still counts in full. A count F that differs from DMT's
-- only makes the bound larger.
local function PairBounds(search)
  local board, n, k = search.Board, search.N, search.K
  local adjacent = search:Touching()
  local adjacency = SDP_Rules.AdjacencyTable(search.PlayerID)
  local types, typeOf, single, legal, kindOf = {}, {}, {}, {}, {}
  for m = 1, k do
    local t = search.Types[m]
    typeOf[m], kindOf[t] = t, search.Kinds[m]
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
  -- The step rows of each type on each plot, with F counted exactly as
  -- SDP_Search's model counts it for its singles (fixed district subjects
  -- next to the plot; the row's district by type, as the table), so that
  -- the share the model's single holds and the step a pair completes here
  -- agree.
  local fixedNear = {}
  for i = 1, n do
    local list = {}
    for _, q in ipairs(board:Neighbours(search.Candidates[i].Index)) do
      local f = q and board.fixedAt[q]
      if f and f.Subject.Type == "DISTRICT" then list[#list + 1] = f.Subject.Key end
    end
    fixedNear[i] = list
  end
  local steps, own = {}, {}
  for _, t in ipairs(types) do
    steps[t], own[t] = {}, {}
    local rows = (adjacency[t] or {}).Rows or {}
    for i = 1, n do
      if legal[t][i] then
        local list, share = {}, 0
        for _, row in ipairs(rows) do
          if row.TilesRequired > 1 and (row.Any or row.District) then
            local count = 0
            for _, key in ipairs(fixedNear[i]) do
              if row.Any or key == row.District then count = count + 1 end
            end
            local value = (search.Weights[row.YieldType] or 0) * row.YieldChange
            list[#list + 1] = { Row = row, F = count, Value = value }
            share = share + value * (count % row.TilesRequired) / row.TilesRequired
          end
        end
        steps[t][i], own[t][i] = list, share
      end
    end
  end
  -- Side ta on plot i, one more neighbour of type tb: the step rows'
  -- part rounded (the step completed or not) and unrounded.
  local function StepParts(ta, i, tb)
    local rounded, unrounded = 0, 0
    if kindOf[tb] ~= "DISTRICT" then return 0, 0 end
    for _, step in ipairs(steps[ta][i]) do
      local row = step.Row
      if row.Any or row.District == tb then
        local T = row.TilesRequired
        rounded = rounded + step.Value * (math.floor((step.F + 1) / T) - math.floor(step.F / T))
        unrounded = unrounded + step.Value / T
      end
    end
    return rounded, unrounded
  end
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
                board:Put(1, { Key = ta, Type = kindOf[ta], X = ci.X, Y = ci.Y })
                board:Put(2, { Key = tb, Type = kindOf[tb], X = cj.X, Y = cj.Y })
                local both, ok = board:Total()
                board:Put(1, nil)
                board:Put(2, nil)
                measured = measured + 1
                local value = floor
                if ok then
                  local ra, ua = StepParts(ta, i, tb)
                  local rb, ub = StepParts(tb, j, ta)
                  local rounded = tableValue - ua - ub + ra + rb
                  local excess = both - single[ta][i] - single[tb][j] - rounded
                  if excess > 0 then value = math.max(floor, tableValue + excess) end
                end
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
  return bound, maxPair, typeOf, measured, own
end

-- The housing part's bound (see the header): the constant at the root and,
-- per slot and plot, the housing at the best appeal there (weighted).
-- Unproven gets a reason when a placed preserve counts.
local function HousingBounds(search, unproven)
  local appeal = search.AppealModel
  local extra = {}
  for m = 1, search.K do extra[m] = {} end
  if appeal == nil then return 0, extra end
  local rules, candidates, n = appeal.Rules, search.Candidates, search.N
  for m = 1, search.K do
    if appeal.Value[m] and rules.Tiles[search.Types[m]] ~= nil and not appeal.Optional[m] then
      unproven[#unproven + 1] = "preserve tiles: " .. search.Types[m]
      break
    end
  end
  -- The largest appeal a placement on each candidate adds to its neighbours.
  local position, lift = {}, {}
  for i = 1, n do
    position[candidates[i].Index] = i
    local best = 0
    for m = 1, search.K do
      if search.Legal[m][i] then best = math.max(best, appeal.Own[m] - appeal.Cleared[i]) end
    end
    lift[i] = best
  end
  local function Best(index, ownCleared)
    local plot = Map.GetPlotByIndex(index)
    if plot:IsWater() then return appeal.BaseAppeal(index) end
    local value = appeal.BaseAppeal(index) - ownCleared
    for dir = 0, 5 do
      local q = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
      local i = q and position[q:GetIndex()] or nil
      if i ~= nil then value = value + lift[i] end
    end
    return value
  end
  local weight = appeal.HousingWeight
  local constant = 0
  for _, f in ipairs(appeal.FixedValue) do
    local now = SDP_Appeal.Housing(rules, f.Type, appeal.BaseAppeal(f.Index)) or 0
    local best = SDP_Appeal.Housing(rules, f.Type, Best(f.Index, 0)) or 0
    if best > now then constant = constant + weight * (best - now) end
  end
  for m = 1, search.K do
    if appeal.Value[m] and rules.Housing[search.Types[m]] ~= nil then
      for i = 1, n do
        if search.Legal[m][i] then
          extra[m][i] = weight * (SDP_Appeal.Housing(rules, search.Types[m], Best(candidates[i].Index, appeal.OwnCleared[i])) or 0)
        end
      end
    end
  end
  return constant, extra
end

-- Run on `search` (inside the overlay). `incumbentLayout`: a layout to start
-- from (the tier's plan), valued again here. `options.Land`: the search's
-- whole objective (see the header). Returns { Layout, Value, Adjacency,
-- Upper, Proven, Complete, Nodes, Leaves, Violations, MaxExcess, Pairs,
-- Unproven (reasons the bound may not hold) }.
function CmpOracle.Run(search, incumbentLayout, options)
  local land = options ~= nil and options.Land == true
  local k, n = search.K, search.N
  for m = 1, k do
    local kind, spec = search.Kinds[m], search.SlotSpecs and search.SlotSpecs[search.SlotIndex[m]] or {}
    if kind ~= "DISTRICT" and kind ~= "WONDER" then error("oracle: only district and wonder slots") end
    -- The improvement a wonder needs next to it (issue 51) is placed by
    -- Evaluate with the wonder, outside the pair bounds: not covered.
    if spec.Support ~= nil then error("oracle: a wonder that needs an improvement next to it") end
  end
  search:Model()
  local single = search.ModelSingle
  local bound, maxPair, typeOf, measured, own = PairBounds(search)
  local adjacent = search:Touching()
  local unproven = {}

  -- Land models (with land): per candidate, the models that hold its plot
  -- and its value there; the cut of each model (CmpOracle.Cut).
  local lands = land and search.Lands or {}
  local holds, rootLoss = {}, {}
  for i = 1, n do
    local index = search.Candidates[i].Index
    local list, loss = {}, 0
    for l, model in ipairs(lands) do
      local p = model.ByIndex[index]
      if p ~= nil then
        list[#list + 1] = { L = l, Tile = p.Tile }
        loss = loss + (model.Loss[index] or 0)
      end
    end
    holds[i], rootLoss[i] = list, loss
  end
  local negative = false
  for _, model in ipairs(lands) do
    for _, p in ipairs(model.Plots) do
      if p.Tile < 0 then negative = true end
    end
  end
  if negative then unproven[#unproven + 1] = "negative plot value" end
  local takenAt, cut = {}, {}
  for l, model in ipairs(lands) do cut[l] = CmpOracle.Cut(model, takenAt) end
  local function Delta(i)
    local d = 0
    for _, h in ipairs(holds[i]) do d = d + CmpOracle.Delta(h.Tile, cut[h.L]) end
    return d
  end
  local housingConstant, housingExtra = 0, nil
  if land then housingConstant, housingExtra = HousingBounds(search, unproven) end
  -- The appeal part of a slot alone on a plot, as the model added it.
  local appealSingle = nil
  if land and search.AppealModel ~= nil then
    appealSingle = {}
    local layout = search:EmptyLayout()
    for m = 1, k do
      appealSingle[m] = {}
      if search.AppealModel.Value[m] then
        for i = 1, n do
          if search.Legal[m][i] then
            layout[m] = i
            appealSingle[m][i] = search:AppealDelta(layout)
            layout[m] = 0
          end
        end
      end
    end
  end

  -- Single bound: the model's single, never below the exact single. With
  -- land: the model's single without its land loss and appeal part (the
  -- adjacency alone), plus the housing bound; the land is taken off on the
  -- way (Delta).
  local sb, plots, bestSB = {}, {}, {}
  for m = 1, k do
    sb[m], plots[m] = {}, {}
    for i = 1, n do
      if search.Legal[m][i] then
        -- The exact single with its share of started steps (Own; the
        -- model's single holds it too).
        local exact = search.Single[m][i] + (own[typeOf[m]][i] or 0)
        if land then
          local adjacencyOnly = single[m][i] + rootLoss[i] - ((appealSingle and appealSingle[m][i]) or 0)
          sb[m][i] = math.max(adjacencyOnly, exact) + (housingExtra[m][i] or 0)
        else
          sb[m][i] = math.max(single[m][i], exact)
        end
        plots[m][#plots[m] + 1] = i
      end
    end
    table.sort(plots[m], function(a, b)
      if sb[m][a] ~= sb[m][b] then return sb[m][a] > sb[m][b] end
      return a < b
    end)
    bestSB[m] = plots[m][1] and sb[m][plots[m][1]] or -math.huge
  end

  -- The slots searched (the required ones and one combination of each
  -- pool), strongest first; ties by slot. Set by SetActive.
  local order, depth = {}, 0
  local function SetActive(active)
    order = {}
    for x, m in ipairs(active) do order[x] = m end
    table.sort(order, function(a, b)
      if bestSB[a] ~= bestSB[b] then return bestSB[a] > bestSB[b] end
      return a < b
    end)
    depth = #order
  end
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
  -- DMT adjacency yields are whole numbers, so with weights that are whole
  -- multiples of 1/scale (scale up to 100: 0.25 -> 4, AMT's 1.15 -> 20)
  -- every value is a multiple of 1/scale and a bound can be rounded down to
  -- one before it is compared (not with land: plot values are not).
  local scale = nil
  if not land then
    for _, s in ipairs({ 1, 2, 4, 5, 10, 20, 25, 50, 100 }) do
      local ok = true
      for _, w in pairs(search.Weights) do
        if math.abs(w * s - math.floor(w * s + 0.5)) > 1e-9 then ok = false end
      end
      if ok then scale = s break end
    end
  end
  local function Cap(x)
    if scale ~= nil then return math.floor(x * scale + EPS) / scale end
    return x
  end

  local layout, slotAt = {}, {}
  for m = 1, k do layout[m] = 0 end
  local best, bestValue = nil, -math.huge
  if incumbentLayout ~= nil then
    local value, legal = Value(search, incumbentLayout, land)
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
  -- `first` (default d): the first slot in the order not placed yet. A node
  -- at depth d bounds its children with Rest(d + 1, d): the slot it places
  -- has no plot yet, so its pairs with the later slots count as pairs with
  -- an unplaced slot (Rest(d + 1) alone left them out, issue 53).
  --
  -- A second bound, the smaller of the two counts (issue 48: with nine or
  -- more districts the first counts each slot's pairs with every earlier
  -- unplaced one, up to six each, far more pairs than the plots can hold):
  -- each slot's best plot without its pairs with unplaced slots, plus the
  -- largest pair maxima among the unplaced slots, no more of them than
  -- EdgeCap(u): the most edges u cells of the hexagonal grid can have
  -- among themselves, floor(3u - sqrt(12u - 3)) (Harary and Harborth 1976),
  -- and no more than half of what each slot's six best pairs with the other
  -- unplaced slots give (every edge has two ends, each with six neighbours).
  local gains, unplacedPairs, incident = {}, {}, {}
  local function EdgeCap(u)
    if u < 2 then return 0 end
    return math.floor(3 * u - math.sqrt(12 * u - 3) + EPS)
  end
  local function Rest(d, first)
    first = first or d
    local total, alone = 0, 0
    local pairCount = 0
    for e = d, depth do
      local tm = typeOf[order[e]]
      for f = first, e - 1 do
        local g = maxPair[tm][typeOf[order[f]]]
        if g ~= nil and g > 0 then
          pairCount = pairCount + 1
          unplacedPairs[pairCount] = g
        end
      end
    end
    for e = d, depth do
      local m = order[e]
      local tm = typeOf[m]
      local best, bestAlone = nil, nil
      for _, i in ipairs(plots[m]) do
        if slotAt[i] == nil then
          local v, free = sb[m][i] - Delta(i), 0
          for _, j in ipairs(adjacent[i]) do
            local p = slotAt[j]
            if p ~= nil then
              v = v + bound[tm][typeOf[p]][i][j]
            else
              free = free + 1
            end
          end
          if bestAlone == nil or v > bestAlone then bestAlone = v end
          local row, count = pairAt[m][i], 0
          for f = first, e - 1 do
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
      total, alone = total + best, alone + bestAlone
    end
    local cap = EdgeCap(depth - first + 1)
    if pairCount > cap then
      for x = pairCount + 1, #unplacedPairs do unplacedPairs[x] = nil end
      table.sort(unplacedPairs, function(a, b) return a > b end)
    end
    local byEdges = 0
    for x = 1, math.min(cap, pairCount) do byEdges = byEdges + unplacedPairs[x] end
    local byEnds = 0
    for e = first, depth do
      local te, count = typeOf[order[e]], 0
      for f = first, depth do
        local g = f ~= e and maxPair[te][typeOf[order[f]]] or nil
        if g ~= nil and g > 0 then
          count = count + 1
          incident[count] = g
        end
      end
      for x = count + 1, #incident do incident[x] = nil end
      if count > 6 then table.sort(incident, function(a, b) return a > b end) end
      for x = 1, math.min(6, count) do byEnds = byEnds + incident[x] / 2 end
    end
    return math.min(total, alone + math.min(byEdges, byEnds))
  end

  local function Walk(d, cur)
    stats.Nodes = stats.Nodes + 1
    if stats.Nodes > CmpOracle.NODE_LIMIT then
      stopped = true
      openMax = math.max(openMax, Cap(cur + (Rest(d) or 0)))
      return
    end
    if d > depth then
      if cur <= bestValue + EPS then return end
      local value, legal = Value(search, layout, land)
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
    local rest = Rest(d + 1, d)
    if rest == nil then return end
    local t = typeOf[m]
    local children = {}
    for _, i in ipairs(plots[m]) do
      if slotAt[i] == nil then
        local v = sb[m][i] - Delta(i)
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
      -- The plot is taken: the cuts of the models that hold it may fall.
      local list, saved = holds[child.I], nil
      if #list > 0 then
        saved = {}
        takenAt[search.Candidates[child.I].Index] = true
        for x, h in ipairs(list) do
          saved[x] = cut[h.L]
          if h.Tile >= cut[h.L] then cut[h.L] = CmpOracle.Cut(lands[h.L], takenAt) end
        end
      end
      Walk(d + 1, cur + child.V)
      if saved ~= nil then
        takenAt[search.Candidates[child.I].Index] = nil
        for x, h in ipairs(list) do cut[h.L] = saved[x] end
      end
      layout[m], slotAt[child.I] = 0, nil
      if stopped then
        local nextChild = children[c + 1]
        if nextChild ~= nil then openMax = math.max(openMax, Cap(cur + nextChild.V + rest)) end
        break
      end
    end
  end

  -- The combinations to search: required slots plus, for each pool group,
  -- one allowed choice of its candidates; the best optimistic value first.
  local required = {}
  for m = 1, k do
    if not search.Optional[m] then required[#required + 1] = m end
  end
  local combos = { required }
  for _, g in ipairs(search.PoolGroups or {}) do
    local list, count, choices = search.PoolSlots[g], search.PoolCount[g], {}
    local pick = {}
    local function Choose(from)
      if #pick == count then
        if not search:Clashes(g, pick) and not search:Excluded(g, pick) then
          local copy = {}
          for x, m in ipairs(pick) do copy[x] = m end
          choices[#choices + 1] = copy
        end
        return
      end
      for x = from, #list do
        pick[#pick + 1] = list[x]
        Choose(x + 1)
        pick[#pick] = nil
      end
    end
    Choose(1)
    local grown = {}
    for _, base in ipairs(combos) do
      for _, choice in ipairs(choices) do
        local c = {}
        for x, m in ipairs(base) do c[x] = m end
        for _, m in ipairs(choice) do c[#c + 1] = m end
        grown[#grown + 1] = c
      end
    end
    combos = grown
  end
  local ranked = {}
  for x, active in ipairs(combos) do
    SetActive(active)
    local root = Rest(1)
    if root ~= nil then ranked[#ranked + 1] = { Active = active, Root = Cap(root + housingConstant), Seq = x } end
  end
  table.sort(ranked, function(a, b)
    if a.Root ~= b.Root then return a.Root > b.Root end
    return a.Seq < b.Seq
  end)
  for _, c in ipairs(ranked) do
    if c.Root <= bestValue + EPS then break end
    if stopped then
      openMax = math.max(openMax, c.Root)
    else
      SetActive(c.Active)
      Walk(1, housingConstant)
    end
  end
  stats.Combos = #ranked
  local upper = stopped and math.max(bestValue, openMax) or bestValue
  local adjacency = nil
  if best ~= nil then
    local _, _, gain = Value(search, best, land)
    adjacency = gain
  end
  return {
    Layout = best, Value = bestValue, Adjacency = adjacency, Upper = upper, Complete = not stopped,
    Proven = (not stopped) and stats.Violations == 0 and #unproven == 0,
    Nodes = stats.Nodes, Leaves = stats.Leaves, Violations = stats.Violations, MaxExcess = stats.MaxExcess,
    Pairs = measured, Start = startValue, Combos = stats.Combos, Unproven = #unproven > 0 and unproven or nil,
  }
end

-- A given layout (a reference scene's, compare.mjs --refscore, issue 53)
-- valued by the same search as the optimum, so the two are on one
-- objective. `placements`: { { city, type, x, y } }; each takes a free slot
-- of its type whose city `cityOf(m)` is its city, on the candidate at its
-- plot. Returns { value, legal, adjacency, missing }: value and adjacency as
-- Run's Value and Adjacency; missing lists the placements with no such slot
-- or candidate (value nil then: the layout is outside the search), and
-- `unplaced` the slots no placement took. A placement of a type the search
-- has no slot for at all is left out on both sides (listed in `skipped`):
-- the comparison framework requests no harbor when the only water within
-- three plots is a lake (cmp_lib.lua's SeaInReach), and neither has one.
function CmpOracle.ScoreLayout(search, placements, cityOf, options)
  local land = options ~= nil and options.Land == true
  local k, n = search.K, search.N
  Fresh(search)
  local at = {}
  for i = 1, n do
    local c = search.Candidates[i]
    at[c.X .. "," .. c.Y] = i
  end
  local layout, missing, skipped, types = {}, {}, {}, {}
  for m = 1, k do
    layout[m] = 0
    types[search.Types[m]] = true
  end
  for _, p in ipairs(placements) do
    local i = at[p.x .. "," .. p.y]
    local slot = nil
    if i ~= nil then
      for m = 1, k do
        if layout[m] == 0 and search.Types[m] == p.type and cityOf(m) == p.city then
          slot = m
          break
        end
      end
    end
    if not types[p.type] then
      skipped[#skipped + 1] = { type = p.type, x = p.x, y = p.y, city = p.city }
    elseif slot == nil then
      missing[#missing + 1] = { type = p.type, x = p.x, y = p.y, city = p.city,
        reason = i == nil and "not a candidate" or "no slot" }
    else
      layout[slot] = i
    end
  end
  local unplaced = {}
  for m = 1, k do
    if layout[m] == 0 then unplaced[#unplaced + 1] = { type = search.Types[m], city = cityOf(m) } end
  end
  local out = { missing = #missing > 0 and missing or nil, unplaced = #unplaced > 0 and unplaced or nil,
    skipped = #skipped > 0 and skipped or nil }
  if #missing == 0 then
    local value, legal, gain = Value(search, layout, land)
    out.value, out.legal, out.adjacency = value, legal, gain
  end
  return out
end

-- Every layout, for checking Run on small cases: the best legal value, or
-- nil when there are more than `limit` layouts (or pools: not covered).
-- `options.Land`: the whole objective, as Run.
function CmpOracle.BruteForce(search, limit, options)
  local land = options ~= nil and options.Land == true
  local k, n = search.K, search.N
  if #(search.PoolGroups or {}) > 0 then return nil end
  local order = {}
  for m = 1, k do order[m] = m end
  local used = {}
  if search:CountLayouts(order, used, limit) > limit then return nil end
  Fresh(search)
  local layout, best, count = {}, nil, 0
  for m = 1, k do layout[m] = 0 end
  local function Walk(m)
    if m > k then
      count = count + 1
      local value, legal = Value(search, layout, land)
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

-- An independent check that does not use the bound (issue 48): `starts`
-- hill climbs from random layouts of the slots `active` places (each step
-- moves one slot to the free legal plot that the exact DMT value likes
-- best). The best value found must not be above the optimum. A fixed
-- pseudo-random sequence from `seed` keeps it reproducible. Returns the
-- best value (or nil) and the number of evaluations. `options.Land`: the
-- whole objective, as Run.
function CmpOracle.Climb(search, active, starts, seed, options)
  local land = options ~= nil and options.Land == true
  local k = search.K
  Fresh(search)
  local x = (seed % 2147483646) + 1.0
  local function Random(count)
    x = (x * 16807.0) % 2147483647.0
    return math.floor(x % count) + 1
  end
  local slots = {}
  for m = 1, k do
    if active[m] then slots[#slots + 1] = m end
  end
  local legalPlots = {}
  for _, m in ipairs(slots) do
    legalPlots[m] = {}
    for i = 1, search.N do
      if search.Legal[m][i] then legalPlots[m][#legalPlots[m] + 1] = i end
    end
  end
  local best, evaluations = nil, 0
  local layout, used = {}, {}
  for _ = 1, starts do
    for m = 1, k do layout[m] = 0 end
    used = {}
    local ok = true
    for _, m in ipairs(slots) do
      local list, placed = legalPlots[m], false
      for _ = 1, 4 * #list do
        local i = list[Random(#list)]
        if not used[i] then
          layout[m], used[i], placed = i, true, true
          break
        end
      end
      if not placed then ok = false end
    end
    local value, legal = 0, false
    if ok then
      value, legal = Value(search, layout, land)
      evaluations = evaluations + 1
    end
    if legal then
      local improved = true
      while improved do
        improved = false
        for _, m in ipairs(slots) do
          local from, bestPlot, bestValue = layout[m], nil, value
          for _, i in ipairs(legalPlots[m]) do
            if not used[i] then
              layout[m] = i
              local v, l = Value(search, layout, land)
              evaluations = evaluations + 1
              if l and v > bestValue + EPS then bestPlot, bestValue = i, v end
            end
          end
          layout[m] = from
          if bestPlot ~= nil then
            used[from], used[bestPlot] = nil, true
            layout[m], value, improved = bestPlot, bestValue, true
          end
        end
      end
      if best == nil or value > best then best = value end
    end
  end
  return best, evaluations
end

