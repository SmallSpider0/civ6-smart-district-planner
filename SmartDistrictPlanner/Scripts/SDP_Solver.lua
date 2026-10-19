-- SDP_Solver: places the chosen districts around one city so that the
-- weighted adjacency gain of the whole neighbourhood is highest, optionally
-- counting what the plots they take would have produced (SDP_Land, design
-- 4.2). The search itself is SDP_Search: exhaustive for small problems
-- (optimal), otherwise a model-ranked shortlist, local search and kicks;
-- every value is exact DMT through SDP_Board.
-- Include order: MapTacks, SDP_Rules, SDP_City, SDP_Overlay, SDP_Tiers,
-- SDP_Task, SDP_Board, SDP_Land, SDP_Search, SDP_Solver.

SDP_Solver = {}

local function DefaultWeights(weights)
  local out = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local w = weights and weights[yieldType]
    out[yieldType] = (w == nil) and 1 or w
  end
  return out
end

-- ===========================================================================
-- Session: one solve, kept so that "continue" can resume it.
-- ===========================================================================
local Session = {}
Session.__index = Session

-- Request = {
--   PlayerID, CityID
--   Districts            district types to place (each once)
--   Weights              { [yield] = 0..3 } for the five adjacency yields; YIELD_FOOD
--                        and FEATURE also weigh the land part; missing ones weigh 1
--   AllowFeatureRemoval  default true (requirement constraint 5)
--   Land                 count the land part (default false)
--   Tier                 "FAST" | "STANDARD" | "FINE" (default STANDARD)
--   Params               overrides of the tier's parameters (tests)
-- }
-- The overlay must be installed.
function SDP_Solver.NewSession(request, scan)
  local self = setmetatable({}, Session)
  local params = SDP_Tiers.Params(SDP_Tiers.Single, request.Tier, request.Params)
  local playerID = scan.PlayerID
  self.Request, self.Params, self.Scan, self.PlayerID = request, params, scan, playerID
  self.Weights = DefaultWeights(request.Weights)

  -- Districts: drop duplicates and ones the city cannot take, keep request order.
  local plannable, byType = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do byType[d.Type] = d end
  local status = SDP_City.DistrictStatus(scan, plannable)
  local districts, unplaced, seen = {}, {}, {}
  for _, districtType in ipairs(request.Districts or {}) do
    if not seen[districtType] then
      seen[districtType] = true
      if not byType[districtType] then
        unplaced[#unplaced + 1] = { Type = districtType, Reason = "NOT_AVAILABLE" }
      elseif status[districtType] then
        unplaced[#unplaced + 1] = { Type = districtType, Reason = status[districtType] }
      else
        districts[#districts + 1] = districtType
      end
    end
  end
  self.Unplaced = unplaced

  self.Fixed = SDP_Overlay.FixedSubjects(scan)
  self.Base = SDP_Overlay.Evaluate({}, self.Fixed, self.Weights)
  local bases = {}
  for f, item in ipairs(self.Base.Fixed) do bases[f] = item.Score end
  self.Board = SDP_Board.New(playerID, self.Fixed, self.Weights, bases)
  self.ExtraCalls = #self.Fixed -- the baseline evaluation above

  local lands = {}
  if request.Land then
    local specialty = 0
    for _, districtType in ipairs(districts) do
      if byType[districtType].Specialty then specialty = specialty + 1 end
    end
    local population = math.max(scan.Population, SDP_Land.RequiredPopulation(scan.SpecialtyBuilt + specialty))
    self.Land = SDP_Land.ForScan(scan, self.Fixed, request.Weights, population)
    lands[1] = self.Land
  end

  local slots = {}
  for s, districtType in ipairs(districts) do slots[s] = { Key = districtType, Type = "DISTRICT", Group = 1 } end
  self.Search = SDP_Search.New({
    PlayerID = playerID, Board = self.Board, Weights = self.Weights, Params = params,
    Candidates = scan.Candidates, Slots = slots, Lands = lands,
  })
  for _, s in ipairs(self.Search:Singles()) do
    unplaced[#unplaced + 1] = { Type = districts[s], Reason = "NO_LEGAL_PLOT" }
  end
  self.Stats = self.Search.Stats
  return self
end

function Session:Run()
  self.Search:Run()
end

function Session:CanContinue()
  return self.Search:CanContinue()
end

-- One more batch of local searches. Returns false when there is nothing left.
function Session:Continue()
  return self.Search:Continue()
end

-- The plan for the best layout, with DMT's yields and tooltips.
-- Returns {
--   Ok, Error,
--   Plan        { Type, X, Y, Index, Yields, ToolTip, Score } per placed district
--   Unplaced    { Type, Reason }: NOT_AVAILABLE (not this civ's), BUILT,
--               MAX_PER_PLAYER (SDP_City.DistrictStatus) or NO_LEGAL_PLOT
--   Gain        adjacency gain over the baseline plus the land part (<= 0)
--   Adjacency   adjacency gain alone; LandDelta: the land part (0 when off)
--   Total, Baseline  joint DMT totals with and without the plan
--   Neighbours  fixed subjects whose score the plan changes: { Subject, Before, After, ToolTip }
--   Quality     { Exhaustive, Bound, Gap, Converged, CanContinue, Truncated }
--   Stats       { Tier, Method = "exhaustive" | "shortlist" | "none", Layouts (counted
--               up to ExactLimit + 1), Nodes, Calls (DMT), Evaluations, Tries,
--               Starts, Continues, Truncated, Hits, Mismatch }
--   Session     for SDP_Solver.Continue
-- }
function Session:Result()
  local search, board, stats = self.Search, self.Board, self.Stats
  board:Clear()
  local base = self.Base
  local result = {
    Ok = true, Plan = {}, Unplaced = self.Unplaced, Neighbours = {}, Session = self,
    Baseline = base.Total, Total = base.Total, Gain = 0, Adjacency = 0, LandDelta = 0, Stats = stats,
  }
  local best = search.BestLayout
  if search.K > 0 and best == nil then
    result.Ok, result.Error = false, "NO_LEGAL_LAYOUT"
  end
  if best ~= nil then
    local subjects = {}
    for m, i in ipairs(best) do subjects[m] = search:Subject(m, i) end
    local final = SDP_Overlay.Evaluate(subjects, self.Fixed, self.Weights)
    self.ExtraCalls = self.ExtraCalls + 2 * #subjects + #self.Fixed
    for m, i in ipairs(best) do
      local item, c = final.Placements[m], search.Candidates[i]
      result.Plan[m] = {
        Type = search.Types[m], X = c.X, Y = c.Y, Index = c.Index,
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
    local adjacency = final.Total - base.Total
    local landDelta = search:LandDelta(best)
    -- The board's incremental value must match the full evaluation.
    stats.Mismatch = (not final.Legal) or math.abs(adjacency + landDelta - search.BestGain) > 1e-6 or nil
    result.Total, result.Adjacency, result.LandDelta = final.Total, adjacency, landDelta
    result.Gain = adjacency + landDelta
  end
  stats.Calls = board.Calls + self.ExtraCalls
  stats.Hits = board.Hits
  result.Quality = search:Quality(result.Gain)
  return result
end

-- Expected work of a solve in SDP_Tiers units (one DMT call or one layout
-- evaluation is about one unit), for the time estimate and the progress
-- bar. Rough on purpose: it never changes what is computed.
function SDP_Solver.EstimateUnits(n, k, params)
  if k == 0 or n == 0 then return 0 end
  local singles = 3 * n * k
  local layouts = 1
  for m = 0, k - 1 do
    layouts = layouts * math.max(0, n - m)
    if layouts > params.ExactLimit then break end
  end
  if layouts <= params.ExactLimit then return singles + layouts * SDP_Tiers.UNITS_PER_TRY end
  -- The search usually stops long before its budgets: the measured work
  -- (SDP_Tiers Work), capped by what the budgets allow.
  local work = params.Work or { 10, 2 }
  local typical = n * (work[1] * k + work[2] * k * k)
  local cap = params.CallLimit + params.NodeLimit / SDP_Tiers.NODES_PER_UNIT
    + (params.Shortlist + params.TryLimit) * SDP_Tiers.UNITS_PER_TRY
  return math.min(typical, cap)
end

-- ===========================================================================
-- Entry points
-- ===========================================================================

-- Solve at once (the overlay is installed and removed here).
function SDP_Solver.Solve(request)
  local playerID = request.PlayerID
  local scan = SDP_City.Scan(playerID, request.CityID, { allowFeatureRemoval = request.AllowFeatureRemoval })
  if scan == nil then return { Ok = false, Error = "NO_CITY" } end
  local ok, result = pcall(SDP_Overlay.With, playerID, SDP_Solver.SolveScan, request, scan)
  if not ok then return { Ok = false, Error = tostring(result) } end
  return result
end

-- The solve itself; the overlay must be installed. Exposed for tests and SDP_Task jobs.
function SDP_Solver.SolveScan(request, scan)
  local session = SDP_Solver.NewSession(request, scan)
  session:Run()
  return session:Result()
end

-- One more batch of local searches for a result (its Session), at once.
-- Returns the new result (the same plan or a better one).
function SDP_Solver.Continue(result)
  local session = result and result.Session
  if session == nil or not session:CanContinue() then return result end
  local ok, out = pcall(SDP_Overlay.With, session.PlayerID, function()
    session:Continue()
    return session:Result()
  end)
  if not ok then return { Ok = false, Error = tostring(out) } end
  return out
end
