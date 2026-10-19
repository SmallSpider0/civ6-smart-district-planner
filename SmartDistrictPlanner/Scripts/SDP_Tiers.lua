-- SDP_Tiers: the three solver tiers (docs/multicity-design.md section 7).
-- A tier only changes how much work the solvers may do; every budget is a
-- count, never a time, so a tier gives the same result on every machine
-- (requirement constraint 6). All tier parameters live here.

SDP_Tiers = {}

SDP_Tiers.ORDER = { "FAST", "STANDARD", "FINE" }
SDP_Tiers.DEFAULT = "STANDARD"

-- Single-city solver (SDP_Solver, SDP_Search). Tuned with
-- tests/offline/bench_single.lua (docs/multicity-design.md section 9).
--   ExactLimit  evaluate every layout exactly when there are at most this many
--   Beam        partial layouts the model beam search keeps per step
--   BeamOrder   which slots the beam places first ("pairs": the ones with
--               the most pair gain with the others; see SDP_Search.BeamOrder)
--   Shortlist   best model layouts evaluated exactly (local search starts)
--   NodeLimit   model search nodes (only for Beam = 0: depth-first search)
--   CallLimit   DMT calls (GetBonusYields + CanPlacePin), singles included
--   TryLimit    layouts tried by local search and kicks (each costs Lua work
--               and, for a neighbourhood not seen before, DMT calls)
--   MaxPasses   local search passes per start
--   Starts      local searches in the first run (from the best exact layouts)
--   Kicks       ruin-and-recreate rounds after them (SDP_Search.Kicks)
--   Swap, Pair  local search also swaps two districts / moves an adjacent pair
--   Sliced      computed over several frames (SDP_Task) instead of at once
--   Work        time estimate: units = plots * (Work[1] * k + Work[2] * k^2)
--               for k districts (measured in the game, 2026-10-20; the
--               search stops well before its budgets)
SDP_Tiers.Single = {
  FAST = {
    ExactLimit = 1000, Beam = 150, BeamOrder = "pairs", Shortlist = 20, NodeLimit = 100000, CallLimit = 2000, TryLimit = 3000,
    MaxPasses = 10, Starts = 1, Kicks = 0, Swap = false, Pair = false, Sliced = false, Work = { 5.4, 0 },
  },
  STANDARD = {
    ExactLimit = 3000, Beam = 400, BeamOrder = "pairs", Shortlist = 100, NodeLimit = 500000, CallLimit = 6000, TryLimit = 8000,
    MaxPasses = 20, Starts = 3, Kicks = 4, Swap = true, Pair = false, Sliced = false, Work = { 9.7, 1.2 },
  },
  FINE = {
    ExactLimit = 40000, Beam = 1000, BeamOrder = "pairs", Shortlist = 200, NodeLimit = 2000000, CallLimit = 30000, TryLimit = 40000,
    MaxPasses = 30, Starts = 8, Kicks = 24, Swap = true, Pair = false, Sliced = true, Work = { 9.5, 6.3 },
  },
}

-- Multi-city solver (SDP_Multi, design 4.5), always over several frames.
-- The same parameters as Single, per city block (ExactLimit, Beam,
-- Shortlist, NodeLimit) or for the whole run (CallLimit, TryLimit), plus
--   Starts   starts tried (SDP_Multi Session:StartPlan): city by city, joint,
--            narrow-beam city by city, reversed, ...
--   Rounds   block rounds per start: each city re-solved with the others fixed
--   Solutions  distinct plans to offer (design 4.5)
--   Prelude  a lighter tier whose starts run first, with its parameters
--            (SDP_Multi Session:RunPrelude): the tier never ends below them
--   Work     time estimate: units per (district or wonder) slot and plot,
--            for two cities; times (cities / 2) ^ MULTI_GROWTH (measured in
--            the game, 2026-10-20), the prelude's own added on top
-- Tuned with tests/offline/bench_multi.lua.
SDP_Tiers.Multi = {
  FAST = {
    ExactLimit = 500, Beam = 100, BeamOrder = "pairs", Shortlist = 20, NodeLimit = 100000,
    CallLimit = 8000, TryLimit = 8000, MaxPasses = 10, Starts = 3, Rounds = 1, Kicks = 0, Solutions = 3,
    Swap = false, Pair = false, Sliced = true, Work = 21,
  },
  STANDARD = {
    ExactLimit = 2000, Beam = 300, BeamOrder = "pairs", Shortlist = 50, NodeLimit = 300000,
    CallLimit = 30000, TryLimit = 40000, MaxPasses = 20, Starts = 5, Rounds = 2, Kicks = 24, Solutions = 3,
    Swap = true, Pair = false, Sliced = true, Work = 88, Prelude = "FAST",
  },
  FINE = {
    ExactLimit = 8000, Beam = 600, BeamOrder = "pairs", Shortlist = 100, NodeLimit = 1000000,
    CallLimit = 120000, TryLimit = 150000, MaxPasses = 30, Starts = 4, Rounds = 3, Kicks = 64, Solutions = 3,
    Swap = true, Pair = false, Sliced = true, Work = 140, Prelude = "STANDARD",
  },
}

-- Site selection (SDP_SiteSolver, design 3.4-3.5), over several frames.
--   Refined        best coarse sites scored with their districts (M)
--   Site           single-city search parameters for those districts (over FAST)
--   ComboNodes     branch-and-bound nodes over combinations
--   Keep           best combinations kept to pick the distinct solutions from
--   ContinueSites  sites refined by each "continue"
--   Site.Work      time estimate: units per refined site and planned district
--                  (measured in the game, 2026-10-20)
SDP_Tiers.Sites = {
  FAST = {
    Refined = 20, ComboNodes = 100000, Keep = 30, Solutions = 3, ContinueSites = 20, Sliced = true,
    Site = { Beam = 60, Shortlist = 8, Starts = 1, Kicks = 0, Swap = false, TryLimit = 1500, CallLimit = 100000, Work = 85 },
  },
  STANDARD = {
    Refined = 40, ComboNodes = 500000, Keep = 40, Solutions = 3, ContinueSites = 20, Sliced = true,
    Site = { Beam = 120, Shortlist = 15, Starts = 1, Kicks = 0, Swap = true, TryLimit = 3000, CallLimit = 100000, Work = 98 },
  },
  FINE = {
    Refined = 80, ComboNodes = 2000000, Keep = 60, Solutions = 3, ContinueSites = 20, Sliced = true,
    Site = { Beam = 250, Shortlist = 30, Starts = 2, Kicks = 2, Swap = true, TryLimit = 6000, CallLimit = 100000, Work = 195 },
  },
}

-- Each "continue" runs this many more local searches (single city).
SDP_Tiers.SINGLE_CONTINUE_STARTS = 5

-- Work units for frame slicing and time estimates. One unit is about one DMT
-- call. Measured in the game (macOS, 2026-10-20, tests/bench and
-- docs/self-test-report.md): a DMT call ~0.042 ms, a layout evaluation
-- ~0.01 ms, a model search node ~0.002-0.005 ms; with the solvers' own work
-- around them, about 20000 units per second when run at once.
SDP_Tiers.UNITS_PER_TRY = 0.25   -- one layout evaluation
SDP_Tiers.NODES_PER_UNIT = 20    -- model search nodes per unit
SDP_Tiers.MULTI_GROWTH = 0.35    -- multi-city work per slot grows with the cities

-- Parameters of `tier` ("FAST" | "STANDARD" | "FINE", default STANDARD) for
-- a solver group (SDP_Tiers.Single, ...), with `overrides` applied on top
-- (tests). Returns a new table.
function SDP_Tiers.Params(group, tier, overrides)
  local base = group[tier or SDP_Tiers.DEFAULT] or group[SDP_Tiers.DEFAULT]
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(overrides or {}) do out[k] = v end
  out.Tier = group[tier] and tier or SDP_Tiers.DEFAULT
  return out
end
