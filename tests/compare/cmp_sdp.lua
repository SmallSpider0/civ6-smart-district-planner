-- cmp_sdp.lua: Smart District Planner (this mod) as a comparison planner.
-- Loads the mod's scripts in the panel's include order, lets the game
-- "finish loading" (Events.LoadGameViewStateDone), and solves at once with
-- weights 1 and, by default, adjacency only (the judge's gain).
--   variant FAST | STANDARD | FINE   the tier
--   variant STANDARD_LAND (any tier + "_LAND")  with the land part on, as the
--                                    panel has it by default; "_LAND<nnn>"
--                                    scales the land part by nnn / 100 (the
--                                    land coefficient, issue 53: _LAND050 is
--                                    0.5; _LAND is 1). Only here, not in the
--                                    mod: every plot value SDP_Land gives (and
--                                    a preserve's yields on the plots around
--                                    it) is multiplied, so the land models the
--                                    solvers and the oracle read are scaled
--   variant <TIER>_SWAP (before _LAND) the swap switch on: plots another of
--                                    the player's cities owns are candidates
--                                    when they can be swapped (issue 54)
--   variant <TIER>_COV<n>            multi: the coverage part on, weight n
--                                    (design 19)
--   variant ORACLE                   the exact reference (cmp_oracle.lua, issue
--                                    48): the fine tier's plan, then branch and
--                                    bound over the same search to the proven
--                                    optimum (or a range when cut short);
--                                    ORACLE_CHECK also tries every layout when
--                                    there are at most 400000 (stats.oracle.brute)
--                                    and runs 8 hill climbs that do not use the
--                                    bound (stats.oracle.climb, never above);
--                                    "@<n>" sets the node limit to n million;
--                                    ORACLE_LAND[nnn] (and _CHECK): the same
--                                    for the mod's whole objective with the
--                                    land part on (scaled as above), starting
--                                    from FINE_LAND[nnn]'s plan
--   variant CITY_BY_CITY             multi only: each city planned alone with
--                                    STANDARD, in city order, earlier plans
--                                    pinned (the baseline a player gets by
--                                    using the single-city tab city by city)

CmpAdapters = CmpAdapters or {}

local function LoadSDP()
  include("MapTacks")
  for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
    "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Sites", "SDP_SiteSolver" }) do
    include(name)
  end
end

-- Put a plan on the map as pins, the way DMT's context records them.
local function Pin(type, x, y)
  local pin = PlayerConfigurations[0]:GetMapPin(x, y)
  pin:SetIconName("ICON_" .. type)
  local subject = CreateMapPinSubject(pin)
  local real = UpdateMapPinSubject
  real(0, x, y, subject)
end

-- Scale the land part by `lambda` (variants "_LAND<nnn>"): every plot value
-- and one-time value SDP_Land gives, and a preserve's yields on the plots
-- around it (the boosts SDP_Land.ScoreTaken adds), so the land models are
-- built scaled. Each run has its own Lua state: nothing to undo.
local function ScaleLand(lambda)
  if lambda == 1 then return end
  local values = SDP_Land.PlotValues
  SDP_Land.PlotValues = function(plot, ctx)
    local tile, once = values(plot, ctx)
    return lambda * tile, lambda * once
  end
  local scoreTaken = SDP_Land.ScoreTaken
  SDP_Land.ScoreTaken = function(model, taken, count, mark, boost)
    if boost ~= nil then
      local scaled = {}
      for index, extra in pairs(boost) do scaled[index] = lambda * extra end
      boost = scaled
    end
    return scoreTaken(model, taken, count, mark, boost)
  end
end

-- The exact reference on the session a solve left (inside the overlay).
-- Returns the oracle's result; `cityOf(m)` gives slot m's city. `land`:
-- the oracle is for the mod's whole objective (land part on, scaled by
-- `lambda`), else for the adjacency gain alone.
local function Oracle(result, out, cityOf, check, weights, land, lambda)
  include("cmp_oracle")
  local search = result.Session.Search
  local options = { Land = land }
  local o = SDP_Overlay.With(0, CmpOracle.Run, search, search.BestLayout, options)
  if check then
    local brute, count = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 400000, options)
    o.Brute, o.BruteCount = brute, count
    -- Hill climbs over the slots the optimum places (independent of the bound).
    local active = {}
    for m = 1, search.K do active[m] = (o.Layout and o.Layout[m] or 0) ~= 0 end
    o.Climb, o.ClimbEvaluations = SDP_Overlay.With(0, CmpOracle.Climb, search, active, 8, 20261023, options)
  end
  out.placements = {}
  for m = 1, search.K do
    local i = o.Layout and o.Layout[m] or 0
    if i ~= 0 then
      local c = search.Candidates[i]
      out.placements[#out.placements + 1] = { city = cityOf(m), type = search.Types[m], x = c.X, y = c.Y }
    end
  end
  out.stats.sdpGain = o.Adjacency or o.Value
  if land then out.stats.sdpObjective = o.Value end
  out.stats.oracle = { value = o.Value, upper = o.Upper, proven = o.Proven, complete = o.Complete, start = o.Start,
    nodes = o.Nodes, leaves = o.Leaves, violations = o.Violations, maxExcess = o.MaxExcess, pairs = o.Pairs, combos = o.Combos,
    brute = o.Brute, bruteLayouts = o.BruteCount, climb = o.Climb, climbEvaluations = o.ClimbEvaluations,
    adjacency = o.Adjacency, unproven = o.Unproven,
    -- The objective the optimum is for (issue 48): the judge's adjacency
    -- gain with these yield weights, or with land on the mod's whole
    -- objective (adjacency + lambda x land part + housing).
    objective = { weights = weights, land = land == true, lambda = land and lambda or nil } }
  return o
end

function CmpAdapters.sdp(request, variant, w)
  -- "ORACLE", "ORACLE_CHECK", "ORACLE_LAND[nnn]", "ORACLE_LAND[nnn]_CHECK",
  -- optionally "@<millions>" for the node limit.
  local base, limit = variant:match("^(ORACLE[_A-Z0-9]*)@(%d+)$")
  if base ~= nil then
    include("cmp_oracle")
    CmpOracle.NODE_LIMIT = tonumber(limit) * 1e6
    variant = base
  end
  local oracle = variant:match("^ORACLE") ~= nil
  local check = oracle and variant:match("_CHECK$") ~= nil
  if oracle then variant = "FINE" .. variant:gsub("_CHECK$", ""):gsub("^ORACLE", "") end
  -- "<TIER>_LAND[nnn]": the land part on (the panel's default), scaled by
  -- nnn / 100; else adjacency only.
  local coverage = tonumber(variant:match("_COV(%d)$") or "")
  variant = variant:gsub("_COV%d$", "")
  local land, lambda = false, nil
  local digits = variant:match("_LAND(%d*)$")
  if digits ~= nil then
    land = true
    lambda = digits == "" and 1 or tonumber(digits) / 100
    variant = variant:gsub("_LAND%d*$", "")
  end
  local swap = variant:match("_SWAP$") ~= nil
  variant = variant:gsub("_SWAP$", "")
  LoadSDP()
  if land then ScaleLand(lambda) end
  w.Events.LoadGameViewStateDone()
  local stats = {}
  if land then stats.sdpLambda = lambda end
  CmpRun.CountDMT(stats)
  local scn = request.scenario
  local out = { placements = {}, stats = stats, notes = {} }
  local function Take(plan, cityID)
    for _, p in ipairs(plan or {}) do
      out.placements[#out.placements + 1] = { city = cityID, type = p.Type, x = p.X, y = p.Y }
    end
  end
  if scn.kind == "sites" then
    -- The sites tab: K sites within D, scored with the scenario's districts.
    local r = SDP_SiteSolver.Solve({ PlayerID = 0, Tier = variant, K = request.sites.count, D = request.sites.distance,
      Districts = request.districts })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    for _, site in ipairs((r.Ok and r.Solutions[1] and r.Solutions[1].Sites) or {}) do
      out.placements[#out.placements + 1] = { kind = "SITE", x = site.X, y = site.Y }
    end
    stats.method = "sites"
  elseif scn.kind == "single" and #(request.wonders or {}) > 0 then
    -- Wonders with the districts: the single-city tab solves this city as
    -- SDP_Multi with only this city (SDP_Panel's WonderRequest).
    local id = request.target:GetID()
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = request.districts, Wonders = request.wonders,
      Only = { [id] = true }, Weights = request.weights, Land = land, Swap = swap })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    for _, p in ipairs(r.Plan or {}) do
      out.placements[#out.placements + 1] = { city = id, type = p.Type, x = p.X, y = p.Y, kind = p.Kind }
    end
    stats.sdpGain, stats.sdpAppeal = r.Adjacency, r.AppealDelta
    if land then stats.sdpObjective = r.Gain end
    stats.sdpQuality = r.Quality -- design 7.4: Exhaustive, Bound, Gap, Converged, Truncated
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
  elseif scn.kind == "single" then
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Districts = request.districts,
      Land = land, Tier = variant, Weights = request.weights, Swap = swap })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    Take(r.Plan, request.target:GetID())
    if oracle and r.Ok then
      local id = request.target:GetID()
      Oracle(r, out, function() return id end, check, request.weights, land, lambda)
      stats.method = "oracle"
      return out
    end
    stats.sdpGain, stats.sdpAppeal = r.Adjacency, r.AppealDelta
    -- The mod's own objective of its plan (with land on: adjacency + lambda x
    -- land part + housing), to set against ORACLE_LAND's optimum.
    if land then stats.sdpObjective = r.Gain end
    stats.sdpQuality = r.Quality -- design 7.4: Exhaustive, Bound, Gap, Converged, Truncated
    stats.method = r.Stats and r.Stats.Method
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. u.Type .. " " .. tostring(u.Reason) end
  elseif variant == "CITY_BY_CITY" then
    for _, city in ipairs(request.cities) do
      local r = SDP_Solver.Solve({ PlayerID = 0, CityID = city:GetID(), Districts = request.districts,
        Land = false, Tier = "STANDARD", Weights = request.weights })
      if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
      Take(r.Plan, city:GetID())
      for _, p in ipairs(r.Plan or {}) do Pin(p.Type, p.X, p.Y) end
      for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. u.Type .. " " .. tostring(u.Reason) end
    end
  else
    local existing, plans = {}, nil
    for _, city in ipairs(request.cities) do existing[city:GetID()] = true end
    if request.plans then
      -- Each city its own list (the tab's "plan for" pulldown).
      plans = {}
      for _, city in ipairs(request.cities) do plans["C" .. city:GetID()] = request.plans[city:GetID()] or {} end
    end
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = plans and {} or request.districts, Plans = plans,
      Existing = existing, Land = land, Weights = request.weights, Coverage = coverage, Swap = swap })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    local byKey = {}
    for _, c in ipairs(r.Cities or {}) do byKey[c.Key] = c.CityID end
    if oracle and r.Ok then
      local search = r.Session.Search
      Oracle(r, out, function(m) return r.Cities[search.Groups[m]].CityID end, check, request.weights, land, lambda)
      stats.method = "oracle"
      return out
    end
    for _, p in ipairs(r.Plan or {}) do
      if p.Kind == nil or p.Kind == "DISTRICT" then
        out.placements[#out.placements + 1] = { city = byKey[p.City], type = p.Type, x = p.X, y = p.Y }
      end
    end
    stats.sdpGain, stats.sdpAppeal = r.Adjacency, r.AppealDelta
    if land then stats.sdpObjective = r.Gain end
    stats.sdpQuality = r.Quality -- design 7.4: Exhaustive, Bound, Gap, Converged, Truncated
    stats.sdpCovered = r.Covered
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
  end
  return out
end
