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
--   Districts            district types to place (each once): the required ones
--   Pool, Count          candidate district types and how many districts that
--                        take population (specialty districts, required ones
--                        included) the plan should have: the solver picks the
--                        rest from the pool (feedback item 1). Count at most
--                        the required number: no picking, as before
--   Auto                 { [district type] = true }: districts the plan adds by
--                        itself when the city needs them (SDP_City.NeedsAuto:
--                        an aqueduct without fresh water, a dam on floodplains)
--   Distance             distance cost weight (0 or nil: off; SDP_City.DistanceCosts)
--   Remind               find the woods and rainforest each solution's
--                        districts take adjacency from (SDP_Remind)
--   Weights              { [yield] = 0..3 } for the five adjacency yields; YIELD_FOOD
--                        and FEATURE also weigh the land part, HOUSING the
--                        housing of districts that depend on appeal (SDP_Appeal);
--                        missing ones weigh 1
--   AllowFeatureRemoval  default true (requirement constraint 5)
--   Land                 count the land part (default false)
--   Tier                 "FAST" | "STANDARD" | "FINE" (default STANDARD)
--   Params               overrides of the tier's parameters (tests)
--   IgnorePins           this mod's earlier pins being replaced ({ ID, X, Y },
--                        SDP_Pins.Own): planned as if they were gone; scan
--                        with SDP_City.ScanOptions(request)
--   Apart                false: pick partner districts (SDP_Rules.Apart, the
--                        harbor and the commercial hub) into one city like any
--                        others; default: not, unless the count needs it
-- }
-- The overlay must be installed.
function SDP_Solver.NewSession(request, scan)
  local self = setmetatable({}, Session)
  SDP_Overlay.HidePins(request.IgnorePins)
  local params = SDP_Tiers.Params(SDP_Tiers.Single, request.Tier, request.Params)
  local playerID = scan.PlayerID
  self.Request, self.Params, self.Scan, self.PlayerID = request, params, scan, playerID
  self.Weights = DefaultWeights(request.Weights)

  -- Districts: drop duplicates and ones the city cannot take, keep request order.
  local plannable, byType = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do byType[d.Type] = d end
  local status = SDP_City.DistrictStatus(scan, plannable)
  local districts, unplaced, seen, kept = {}, {}, {}, {}
  for _, districtType in ipairs(request.Districts or {}) do
    if not seen[districtType] then
      seen[districtType] = true
      local excluded = SDP_Rules.ExcludedBy(districtType, kept)
      if not byType[districtType] then
        unplaced[#unplaced + 1] = { Type = districtType, Reason = "NOT_AVAILABLE" }
      elseif status[districtType] then
        unplaced[#unplaced + 1] = { Type = districtType, Reason = status[districtType],
          Other = status[districtType] == "EXCLUSIVE" and SDP_Rules.ExcludedBy(districtType, SDP_City.BuiltTypes(scan)) or nil }
      elseif excluded ~= nil then
        -- Two required districts one city cannot have: the first one asked stays.
        unplaced[#unplaced + 1] = { Type = districtType, Reason = "EXCLUSIVE", Other = excluded }
      else
        districts[#districts + 1] = districtType
        kept[districtType] = true
      end
    end
  end
  -- Districts the city needs (feedback item 4), unless built or pinned.
  local pinned = {}
  for _, pin in ipairs(scan.Pins) do pinned[(pin.Icon or ""):gsub("^ICON_", "")] = true end
  self.Auto = {}
  for _, d in ipairs(plannable) do
    if request.Auto and request.Auto[d.Type] and not seen[d.Type] and not status[d.Type] and not pinned[d.Type]
        and SDP_City.NeedsAuto(scan, d.Type) then
      seen[d.Type] = true
      districts[#districts + 1] = d.Type
      self.Auto[d.Type] = true
    end
  end
  -- Candidates (feedback item 1): districts that take population, not
  -- required, plannable here, without an empire limit.
  local requiredSpecialty = 0
  for _, districtType in ipairs(districts) do
    if byType[districtType].Specialty then requiredSpecialty = requiredSpecialty + 1 end
  end
  -- A candidate the required ones exclude stays out; of candidates that
  -- exclude each other at most one is picked (SDP_Search Excluded), so the
  -- pick is capped by how many can stand together.
  local pool, together = {}, {}
  for _, districtType in ipairs(request.Pool or {}) do
    local row = byType[districtType]
    if row ~= nil and not seen[districtType] and not status[districtType] and row.Specialty
        and not (row.MaxPerPlayer and row.MaxPerPlayer > 0) and SDP_Rules.ExcludedBy(districtType, kept) == nil then
      seen[districtType] = true
      pool[#pool + 1] = districtType
      if SDP_Rules.ExcludedBy(districtType, together) == nil then together[districtType] = true end
    end
  end
  local fit = 0
  for _ in pairs(together) do fit = fit + 1 end
  local pick = math.max(0, math.min((request.Count or 0) - requiredSpecialty, fit))
  if pick == 0 then pool = {} end
  self.Pick = pick
  self.Unplaced = unplaced

  self.Fixed = SDP_Overlay.FixedSubjects(scan)
  self.Base = SDP_Overlay.Evaluate({}, self.Fixed, self.Weights)
  local bases = {}
  for f, item in ipairs(self.Base.Fixed) do bases[f] = item.Score end
  self.Board = SDP_Board.New(playerID, self.Fixed, self.Weights, bases)
  self.ExtraCalls = #self.Fixed -- the baseline evaluation above

  local lands = {}
  if request.Land then
    local specialty = requiredSpecialty + pick
    local population = math.max(scan.Population, SDP_Land.RequiredPopulation(scan.SpecialtyBuilt + specialty))
    self.Land = SDP_Land.ForScan(scan, self.Fixed, request.Weights, population)
    lands[1] = self.Land
  end

  -- Partner districts kept apart (SDP_Rules.Apart): what the city has already.
  self.Present = SDP_City.PresentDistricts(scan)
  local apart = nil
  if request.Apart ~= false and pick > 0 and #SDP_Rules.Apart().Pairs > 0 then
    apart = { Partners = SDP_Rules.Apart().Partners, Present = { [1] = self.Present } }
  end

  local workable = {}
  for _, index in ipairs(SDP_Land.Workable(scan)) do workable[index] = true end

  local slots = {}
  for s, districtType in ipairs(districts) do slots[s] = { Key = districtType, Type = "DISTRICT", Group = 1 } end
  for _, districtType in ipairs(pool) do slots[#slots + 1] = { Key = districtType, Type = "DISTRICT", Group = 1, Optional = true } end
  self.Search = SDP_Search.New({
    PlayerID = playerID, Board = self.Board, Weights = self.Weights, Params = params,
    Candidates = scan.Candidates, Slots = slots, Lands = lands,
    Pools = pick > 0 and { [1] = pick } or nil,
    Costs = SDP_City.DistanceCosts(playerID, scan.Candidates, request.Distance),
    Alternatives = params.Solutions or 3, Apart = apart, Exclusive = SDP_Rules.Exclusive(),
    Appeal = { Fixed = self.Fixed, Weights = request.Weights, Workable = workable },
  })
  for _, s in ipairs(self.Search:Singles()) do
    if not slots[s].Optional then
      unplaced[#unplaced + 1] = { Type = slots[s].Key, Reason = "NO_LEGAL_PLOT", Auto = self.Auto[slots[s].Key] }
    end
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
  SDP_Overlay.HidePins(self.Request.IgnorePins) -- a new install has the full pin data
  return self.Search:Continue()
end

-- Plan, values and neighbours of one layout, with DMT's yields and
-- tooltips. The board must be clear.
function Session:PlanFor(layout)
  local search, base = self.Search, self.Base
  local subjects, slotsPlaced = {}, {}
  for m = 1, search.K do
    if layout[m] ~= 0 then
      subjects[#subjects + 1] = search:Subject(m, layout[m])
      slotsPlaced[#slotsPlaced + 1] = m
    end
  end
  local final = SDP_Overlay.Evaluate(subjects, self.Fixed, self.Weights)
  self.ExtraCalls = self.ExtraCalls + 2 * #subjects + #self.Fixed
  local out = { Plan = {}, Neighbours = {}, Picked = {}, Legal = final.Legal }
  local appeal = {}
  if search.AppealModel ~= nil then out.AppealDelta = search:AppealDelta(layout, appeal) end
  for n, m in ipairs(slotsPlaced) do
    local item, c = final.Placements[n], search.Candidates[layout[m]]
    local a = appeal[m] or {}
    out.Plan[n] = {
      Type = search.Types[m], X = c.X, Y = c.Y, Index = c.Index,
      Yields = item.Yields, ToolTip = item.ToolTip, Score = item.Score,
      Unowned = c.Unowned, RemoveTech = c.RemoveTech,
      Auto = self.Auto[search.Types[m]], Picked = search.Optional[m],
      Appeal = a.Appeal, Housing = a.Housing, Tiles = a.Tiles, TilesCounted = a.TilesCounted,
    }
    if search.Optional[m] then out.Picked[#out.Picked + 1] = search.Types[m] end
  end
  for f, item in ipairs(final.Fixed) do
    if item.Score ~= base.Fixed[f].Score then
      out.Neighbours[#out.Neighbours + 1] = {
        Subject = item.Subject, Before = base.Fixed[f].Score, After = item.Score, ToolTip = item.ToolTip,
      }
    end
  end
  if self.Request.Apart ~= false then
    local types = {}
    for n, p in ipairs(out.Plan) do types[n] = p.Type end
    out.Together = SDP_Rules.Together(types, self.Present)
  end
  local taken = {}
  for n, p in ipairs(out.Plan) do taken[n] = p.Index end
  local lost = SDP_Appeal.ImprovementHousing(self.PlayerID, taken)
  if lost < 0 then out.ImprovementHousing = lost end
  out.Total = final.Total
  out.Adjacency = final.Total - base.Total
  out.LandDelta = search:LandDelta(layout)
  out.CostDelta = search:CostDelta(layout)
  out.Gain = out.Adjacency + out.LandDelta + out.CostDelta + (out.AppealDelta or 0)
  if self.Request.Remind then
    local plan = {}
    for n, p in ipairs(out.Plan) do plan[n] = { Type = p.Type, Kind = "DISTRICT", X = p.X, Y = p.Y } end
    out.Remind = SDP_Remind.Find(self.PlayerID, plan)
  end
  return out
end

-- The plan for the best layout, with DMT's yields and tooltips, and up to
-- Params.Solutions distinct solutions (other candidate districts first, then
-- other plots).
-- Returns {
--   Ok, Error,
--   Solutions   best first, each { Plan, Neighbours, Picked (types chosen from
--               the pool), Gain, Adjacency, LandDelta, CostDelta, AppealDelta, Total, Remind, Together }
--   and the best solution's fields at the top level:
--   Plan        { Type, X, Y, Index, Yields, ToolTip, Score, Auto, Picked, and for a
--               district that depends on appeal: Appeal (of its plot), Housing,
--               Tiles (a preserve's yields on the workable plots around it) }
--   Unplaced    { Type, Reason, Auto, Other }: NOT_AVAILABLE (not this civ's), BUILT,
--               MAX_PER_PLAYER, EXCLUSIVE (SDP_City.DistrictStatus; or two
--               required ones a city cannot have, the second left out; Other:
--               the district it excludes), NO_LEGAL_PLOT, or NO_FREE_PLOT
--               (the others took its plots: no layout places them all)
--   Gain        adjacency gain over the baseline plus the land part (<= 0)
--               plus the distance cost (<= 0) plus the appeal part
--   Adjacency   adjacency gain alone; LandDelta, CostDelta: the land part and
--               the distance cost (0 when off); AppealDelta: the appeal part
--               (SDP_Appeal; nil when no district depends on appeal)
--   ImprovementHousing  housing the city loses to districts built over its
--               farms, pastures ... (SDP_Appeal.ImprovementHousing; negative,
--               nil when none; reported, not part of Gain)
--   Total, Baseline  joint DMT totals with and without the plan
--   Neighbours  fixed subjects whose score the plan changes: { Subject, Before, After, ToolTip }
--   Remind      (Request.Remind) the woods and rainforest the plan relies on (SDP_Remind)
--   Together    (unless Request.Apart is false) partner districts the plan
--               leaves in the city together (SDP_Rules.Together)
--   Quality     { Exhaustive, Bound, Gap, Converged, CanContinue, Truncated }
--   Stats       { Tier, Method = "exhaustive" | "shortlist" | "pools" | "none", Layouts (counted
--               up to ExactLimit + 1), Nodes, Calls (DMT), Evaluations, Tries,
--               Starts, Continues, Truncated, Hits, Mismatch, Combos }
--   Session     for SDP_Solver.Continue
-- }
function Session:Result()
  local search, board, stats = self.Search, self.Board, self.Stats
  board:Clear()
  local base = self.Base
  local result = {
    Ok = true, Plan = {}, Unplaced = self.Unplaced, Neighbours = {}, Session = self, Solutions = {},
    Baseline = base.Total, Total = base.Total, Gain = 0, Adjacency = 0, LandDelta = 0, CostDelta = 0, Stats = stats,
  }
  if search.K > 0 and search.BestLayout == nil then
    result.Ok, result.Error = false, "NO_LEGAL_LAYOUT"
  end
  if search.BestLayout ~= nil then
    for _, entry in ipairs(search:Solutions(self.Params.Solutions or 3)) do
      result.Solutions[#result.Solutions + 1] = self:PlanFor(entry.Layout)
    end
    local best = result.Solutions[1]
    for _, key in ipairs({ "Plan", "Neighbours", "Total", "Adjacency", "LandDelta", "CostDelta", "AppealDelta", "ImprovementHousing", "Gain", "Remind",
      "Picked", "Together" }) do
      result[key] = best[key]
    end
    -- Required slots the best layout leaves out (Search:PlaceWhatFits; the
    -- search's slots all have a legal plot of their own).
    local unplaced = {}
    for _, u in ipairs(self.Unplaced) do unplaced[#unplaced + 1] = u end
    for m = 1, search.K do
      if search.BestLayout[m] == 0 and not search.Optional[m] then
        unplaced[#unplaced + 1] = { Type = search.Types[m], Reason = "NO_FREE_PLOT", Auto = self.Auto[search.Types[m]] }
      end
    end
    result.Unplaced = unplaced
    -- The board's incremental value must match the full evaluation.
    stats.Mismatch = (not best.Legal) or math.abs(best.Gain - search.BestGain) > 1e-6 or nil
  end
  stats.Calls = board.Calls + self.ExtraCalls
  stats.Hits = board.Hits
  result.Quality = search:Quality(result.Gain)
  return result
end

-- Expected work of a solve in SDP_Tiers units (one DMT call or one layout
-- evaluation is about one unit), for the time estimate and the progress
-- bar. Rough on purpose: it never changes what is computed.
function SDP_Solver.EstimateUnits(n, k, params, pool, pick)
  if (pick or 0) > 0 and (pool or 0) > pick then
    -- Picking from a pool: every candidate's singles, then about Combos
    -- combinations solved (screened with a short list) and the best three refined.
    local combos = 1
    for i = 1, pick do combos = combos * (pool - pick + i) / i end
    local each = SDP_Solver.EstimateUnits(n, k + pick, params)
    local screened = math.min(combos, 1.5 * (params.Combos or 3))
    return 3 * n * pool + each * (0.5 * screened + math.min(3, combos))
  end
  k = k + (pick or 0)
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
  local scan = SDP_City.Scan(playerID, request.CityID, SDP_City.ScanOptions(request))
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

-- Where one district is good (design 18, item 6): every candidate plot of
-- the city where DMT and the game allow it, with the gain of placing it
-- alone (its own adjacency plus what it adds to its neighbours, weighted).
-- request: PlayerID, CityID, District, Weights, AllowFeatureRemoval,
-- IgnorePins. Returns { { Index, X, Y, Gain } } best first (ties by plot), or
-- nil when the city does not exist.
function SDP_Solver.Heat(request)
  local playerID = request.PlayerID
  local scan = SDP_City.Scan(playerID, request.CityID, SDP_City.ScanOptions(request))
  if scan == nil then return nil end
  local weights = DefaultWeights(request.Weights)
  return SDP_Overlay.With(playerID, function()
    SDP_Overlay.HidePins(request.IgnorePins)
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local base = SDP_Overlay.Evaluate({}, fixed, weights).Total
    local out = {}
    for _, c in ipairs(scan.Candidates) do
      local result = SDP_Overlay.Evaluate({ SDP_Overlay.Subject(request.District, c.X, c.Y) }, fixed, weights)
      if result.Legal then
        out[#out + 1] = { Index = c.Index, X = c.X, Y = c.Y, Gain = result.Total - base, Yields = result.Placements[1].Yields }
      end
    end
    table.sort(out, function(a, b)
      if a.Gain ~= b.Gain then return a.Gain > b.Gain end
      return a.Index < b.Index
    end)
    return out
  end)
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
