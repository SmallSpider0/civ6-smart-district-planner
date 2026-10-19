-- SDP_Solver: places the chosen districts around one city so that the
-- weighted adjacency gain of the whole neighbourhood is highest.
--
--   1. Singles: DMT evaluates every district alone on every candidate plot:
--      its own yields plus what it changes on the fixed subjects next to it.
--   2. Small problems (at most EXACT_LIMIT layouts) evaluate every layout
--      with DMT, so the optimum is guaranteed.
--   3. Otherwise a linear model ranks layouts: the singles plus, for each
--      pair of adjacent planned districts, their district-to-district gains
--      (SDP_Rules.AdjacencyTable). A depth-first search with an upper bound
--      keeps the best SHORTLIST layouts; DMT then evaluates each of them.
--   4. Local search from the best exact layout: move one district at a time
--      to every other plot, apply the best improving move, repeat.
-- Budgets are counts, never time, and every loop runs over sorted arrays with
-- ties broken by plot indices, so the same request always gives the same plan
-- (requirement constraint 6).
-- Include order: MapTacks, SDP_Rules, SDP_City, SDP_Overlay, SDP_Solver.

SDP_Solver = {}

SDP_Solver.EXACT_LIMIT = 1200     -- evaluate every layout when there are at most this many
SDP_Solver.SHORTLIST = 100        -- layouts the linear model passes to DMT
-- The two budgets bound the main-thread stall (requirement: about 2 s at
-- most). Measured on macOS 1.0.12.54: ~2 µs per search node, ~0.5 ms per
-- joint DMT evaluation, so each budget costs about one second at worst.
SDP_Solver.NODE_LIMIT = 500000    -- linear search nodes before the search stops early
SDP_Solver.EVAL_LIMIT = 2000      -- DMT evaluations per solve, singles included
SDP_Solver.MAX_PASSES = 20        -- local search passes

local function DefaultWeights(weights)
  local out = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local w = weights and weights[yieldType]
    out[yieldType] = (w == nil) and 1 or w
  end
  return out
end

-- Layout = array of candidate positions, one per district (same order).
local function LayoutKey(layout)
  return table.concat(layout, ",")
end

-- a before b: higher score first, then smaller plot indices (lexicographic).
local function Better(scoreA, layoutA, scoreB, layoutB, candidates)
  if scoreA ~= scoreB then return scoreA > scoreB end
  for i = 1, #layoutA do
    local ia, ib = candidates[layoutA[i]].Index, candidates[layoutB[i]].Index
    if ia ~= ib then return ia < ib end
  end
  return false
end

-- Number of ways to place the districts on distinct legal plots, counting
-- stops just above `limit`.
local function CountLayouts(legal, n, k, limit)
  local used, count = {}, 0
  local function Walk(m)
    if count > limit then return end
    if m > k then count = count + 1 return end
    for i = 1, n do
      if legal[m][i] and not used[i] then
        used[i] = true
        Walk(m + 1)
        used[i] = false
      end
    end
  end
  Walk(1)
  return count
end

-- Solve. request = {
--   PlayerID, CityID,
--   Districts            district types to place (each once)
--   Weights              { [yield] = 0..3 }, missing yields weigh 1
--   AllowFeatureRemoval  default true (requirement constraint 5)
-- }
-- Returns {
--   Ok, Error,
--   Plan        { Type, X, Y, Index, Yields, ToolTip, Score } per placed district, request order
--   Unplaced    { Type, Reason } districts left out: NOT_AVAILABLE (not this
--               civ's), BUILT, MAX_PER_PLAYER (SDP_City.DistrictStatus) or
--               NO_LEGAL_PLOT
--   Gain        joint total of the plan minus the baseline (no new districts)
--   Total, Baseline
--   Neighbours  fixed subjects whose score the plan changes: { Subject, Before, After, ToolTip }
--   Stats       { Method = "exhaustive" | "shortlist" | "none", Layouts (counted up
--               to EXACT_LIMIT + 1), Nodes, Evaluations (DMT, all stages), Truncated }
-- }
function SDP_Solver.Solve(request)
  local playerID = request.PlayerID
  local scan = SDP_City.Scan(playerID, request.CityID, { allowFeatureRemoval = request.AllowFeatureRemoval })
  if scan == nil then return { Ok = false, Error = "NO_CITY" } end
  local ok, result = pcall(SDP_Overlay.With, playerID, SDP_Solver.SolveScan, request, scan)
  if not ok then return { Ok = false, Error = tostring(result) } end
  return result
end

-- The solve itself; the overlay must be installed. Exposed for tests.
function SDP_Solver.SolveScan(request, scan)
  local playerID = scan.PlayerID
  local weights = DefaultWeights(request.Weights)
  local candidates = scan.Candidates
  local n = #candidates
  local stats = { Layouts = 0, Nodes = 0, Evaluations = 0, Truncated = false }

  -- Districts: drop duplicates and ones the city cannot take, keep request order.
  local plannable, available = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do available[d.Type] = true end
  local status = SDP_City.DistrictStatus(scan, plannable)
  local districts, unplaced, seen = {}, {}, {}
  for _, districtType in ipairs(request.Districts or {}) do
    if not seen[districtType] then
      seen[districtType] = true
      if not available[districtType] then
        unplaced[#unplaced + 1] = { Type = districtType, Reason = "NOT_AVAILABLE" }
      elseif status[districtType] then
        unplaced[#unplaced + 1] = { Type = districtType, Reason = status[districtType] }
      else
        districts[#districts + 1] = districtType
      end
    end
  end

  local fixed = SDP_Overlay.FixedSubjects(scan)
  local base = SDP_Overlay.Evaluate({}, fixed, weights)
  stats.Evaluations = 1

  -- Fixed subjects next to each candidate, with their baseline scores.
  local fixedNear = {}
  for i, c in ipairs(candidates) do
    local near, baseline = {}, 0
    for f, subject in ipairs(fixed) do
      if Map.GetPlotDistance(c.X, c.Y, subject.X, subject.Y) == 1 then
        near[#near + 1] = subject
        baseline = baseline + base.Fixed[f].Score
      end
    end
    fixedNear[i] = { Subjects = near, Baseline = baseline }
  end

  -- 1. Singles.
  local single, legal = {}, {}
  local placeable = {}
  for d, districtType in ipairs(districts) do
    single[d], legal[d] = {}, {}
    local any = false
    for i, c in ipairs(candidates) do
      local near = fixedNear[i]
      local res = SDP_Overlay.Evaluate({ SDP_Overlay.Subject(districtType, c.X, c.Y) }, near.Subjects, weights)
      stats.Evaluations = stats.Evaluations + 1
      legal[d][i] = res.Legal
      single[d][i] = res.Total - near.Baseline
      any = any or res.Legal
    end
    if any then
      placeable[#placeable + 1] = d
    else
      unplaced[#unplaced + 1] = { Type = districtType, Reason = "NO_LEGAL_PLOT" }
    end
  end
  -- Keep only placeable districts from here on.
  local types, s1, l1 = {}, {}, {}
  for m, d in ipairs(placeable) do
    types[m], s1[m], l1[m] = districts[d], single[d], legal[d]
  end
  single, legal = s1, l1
  local k = #types

  local result = {
    Ok = true, Plan = {}, Unplaced = unplaced, Neighbours = {},
    Baseline = base.Total, Total = base.Total, Gain = 0, Stats = stats,
  }
  if k == 0 then
    stats.Method = "none"
    return result
  end

  -- Exact joint evaluation of a layout, memoized.
  local memo = {}
  local function Exact(layout)
    local key = LayoutKey(layout)
    local hit = memo[key]
    if hit ~= nil then return hit end
    if stats.Evaluations >= SDP_Solver.EVAL_LIMIT then
      stats.Truncated = true
      return nil
    end
    local subjects = {}
    for m, i in ipairs(layout) do subjects[m] = SDP_Overlay.Subject(types[m], candidates[i].X, candidates[i].Y) end
    local res = SDP_Overlay.Evaluate(subjects, fixed, weights)
    stats.Evaluations = stats.Evaluations + 1
    local entry = { Legal = res.Legal, Gain = res.Total - base.Total, Result = res }
    memo[key] = entry
    return entry
  end

  local bestLayout, bestGain = nil, nil
  local function Consider(layout)
    local entry = Exact(layout)
    if entry ~= nil and entry.Legal
        and (bestLayout == nil or Better(entry.Gain, layout, bestGain, bestLayout, candidates)) then
      bestLayout, bestGain = { unpack(layout) }, entry.Gain
    end
  end

  local count = CountLayouts(legal, n, k, SDP_Solver.EXACT_LIMIT)
  if count <= SDP_Solver.EXACT_LIMIT then
    -- 2. Small problem: every layout exactly.
    stats.Method, stats.Layouts = "exhaustive", count
    local layout, used = {}, {}
    local function Walk(m)
      if m > k then Consider(layout) return end
      for i = 1, n do
        if legal[m][i] and not used[i] then
          used[i], layout[m] = true, i
          Walk(m + 1)
          used[i], layout[m] = false, nil
        end
      end
    end
    Walk(1)
  else
    -- 3. Linear ranking with an upper bound, then the shortlist exactly.
    stats.Method, stats.Layouts = "shortlist", count
    local adjacency = SDP_Rules.AdjacencyTable(playerID)
    local pair = {}
    for a = 1, k do
      pair[a] = {}
      for b = 1, k do
        pair[a][b] = SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, types[a], types[b]), weights)
          + SDP_Overlay.Score(SDP_Rules.NeighbourGain(adjacency, types[b], types[a]), weights)
      end
    end
    local touching = {}
    for i = 1, n do
      touching[i] = {}
      for j = 1, n do
        touching[i][j] = Map.GetPlotDistance(candidates[i].X, candidates[i].Y, candidates[j].X, candidates[j].Y) == 1
      end
    end
    -- Optimistic remaining score from district m on: best single plus every
    -- positive pair gain (each district has at most six neighbours).
    local optimistic = {}
    for m = k, 1, -1 do
      local bestSingle = nil
      for i = 1, n do
        if legal[m][i] and (bestSingle == nil or single[m][i] > bestSingle) then bestSingle = single[m][i] end
      end
      local pairs = 0
      for b = 1, k do
        if b ~= m and pair[m][b] > 0 then pairs = pairs + pair[m][b] end
      end
      optimistic[m] = (bestSingle or 0) + pairs + (optimistic[m + 1] or 0)
    end

    local shortlist = {} -- { Score, Layout } best first
    local function Keep(score, layout)
      local size = #shortlist
      if size >= SDP_Solver.SHORTLIST
          and not Better(score, layout, shortlist[size].Score, shortlist[size].Layout, candidates) then
        return
      end
      local entry = { Score = score, Layout = { unpack(layout) } }
      local pos = size + 1
      while pos > 1 and Better(score, layout, shortlist[pos - 1].Score, shortlist[pos - 1].Layout, candidates) do
        shortlist[pos] = shortlist[pos - 1]
        pos = pos - 1
      end
      shortlist[pos] = entry
      if #shortlist > SDP_Solver.SHORTLIST then shortlist[#shortlist] = nil end
    end

    local layout, used = {}, {}
    local function Walk(m, partial)
      if m > k then Keep(partial, layout) return end
      stats.Nodes = stats.Nodes + 1
      if stats.Nodes > SDP_Solver.NODE_LIMIT then stats.Truncated = true return end
      if #shortlist >= SDP_Solver.SHORTLIST and partial + optimistic[m] <= shortlist[#shortlist].Score then return end
      for i = 1, n do
        if legal[m][i] and not used[i] then
          local score = partial + single[m][i]
          for prev = 1, m - 1 do
            if touching[i][layout[prev]] then score = score + pair[m][prev] end
          end
          used[i], layout[m] = true, i
          Walk(m + 1, score)
          used[i], layout[m] = false, nil
          if stats.Truncated then return end
        end
      end
    end
    Walk(1, 0)
    for _, entry in ipairs(shortlist) do Consider(entry.Layout) end
    stats.Shortlist = #shortlist
  end

  -- 4. Local search from the best layout found.
  if bestLayout ~= nil and stats.Method == "shortlist" then
    for _ = 1, SDP_Solver.MAX_PASSES do
      local moveLayout, moveGain = nil, nil
      local inUse = {}
      for _, i in ipairs(bestLayout) do inUse[i] = true end
      for m = 1, k do
        for i = 1, n do
          if legal[m][i] and not inUse[i] then
            local trial = { unpack(bestLayout) }
            trial[m] = i
            local entry = Exact(trial)
            if entry ~= nil and entry.Legal and entry.Gain > bestGain
                and (moveLayout == nil or Better(entry.Gain, trial, moveGain, moveLayout, candidates)) then
              moveLayout, moveGain = trial, entry.Gain
            end
          end
        end
      end
      if moveLayout == nil then break end
      bestLayout, bestGain = moveLayout, moveGain
    end
  end

  if bestLayout == nil then
    result.Ok = false
    result.Error = "NO_LEGAL_LAYOUT"
    return result
  end

  local final = memo[LayoutKey(bestLayout)].Result
  for m, i in ipairs(bestLayout) do
    local item = final.Placements[m]
    result.Plan[m] = {
      Type = types[m], X = candidates[i].X, Y = candidates[i].Y, Index = candidates[i].Index,
      Yields = item.Yields, ToolTip = item.ToolTip, Score = item.Score,
    }
  end
  for f, item in ipairs(final.Fixed) do
    if item.Score ~= base.Fixed[f].Score then
      result.Neighbours[#result.Neighbours + 1] = {
        Subject = item.Subject, Before = base.Fixed[f].Score, After = item.Score, ToolTip = item.ToolTip,
      }
    end
  end
  result.Total, result.Gain = final.Total, bestGain
  return result
end
