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
--   variant <TIER>_GROWTH            sites: the Growth first preset (SDP_Sites.PRESETS)
--   variant <TIER>_GRID[n]           sites: the tab's default district grid
--                                    (issue 90: every candidate the rules
--                                    allow, n per site, default 3) in place
--                                    of the scenario's districts; before
--                                    _GROWTH when both
--                                    (design 19)
--   variant <TIER>_DENSE             sites: dense packing (issue 87), up to
--                                    SDP_SiteSolver.DENSE_MAX_K sites; before
--                                    _GRID when both
--   variant <TIER>_K<n>              sites: n sites instead of the scenario's
--                                    count (issue 87: dense against normal);
--                                    before _GRID
--   variant <TIER>_KNEW<n>           sites: the first plot of a new strategic
--                                    kind counts n times (SDP_Sites.KIND_NEW,
--                                    issue 86: 2, 3 and 4 measured); before _DIST
--   variant ..._DIST<nnn> (last)     the distance cost weight nnn / 100 (single
--                                    and multi; the panel's default is
--                                    _DIST050 since issue 91; sites too,
--                                    for the districts around each site),
--                                    else off
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
--   variant <TIER>_GROUP<n>          multi only: the cities in groups of n in
--                                    city order (the capital first), each
--                                    group planned on the Several cities tab
--                                    with the tier, earlier groups' plans
--                                    pinned (issue 63: a player who plans a
--                                    few cities at a time); each city gets
--                                    its own list ("_GROUP<n>S": the shared
--                                    list, as the tab sends it)

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
    local tile, once, bare = values(plot, ctx)
    return lambda * tile, lambda * once, bare and lambda * bare
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
      out.placements[#out.placements + 1] = { city = cityOf(m), type = search.Types[m], x = c.X, y = c.Y,
        kind = search.Kinds[m] }
    end
  end
  -- compare.mjs --refscore sets CMP_REFERENCE (the reference layout's plan,
  -- JSON): value it on the same search, under the optimum's objective.
  if CMP_REFERENCE ~= nil and CMP_REFERENCE ~= "" then
    out.stats.reference = SDP_Overlay.With(0, CmpOracle.ScoreLayout, search,
      CmpRun.Json.Decode(CMP_REFERENCE).placements, cityOf, options)
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

-- The long-run reference (cmp_longrun.lua, issue 40) on a fine solve's
-- result: 20 continues (`again`: SDP_Multi.Continue or SDP_Solver.Continue),
-- annealing from the best layout, the two-slot check of the fine plan
-- (issue 40), then the oracle from the best layout (Oracle above) for the
-- upper end.
local function LongRun(result, out, cityOf, request, again)
  local search = result.Session.Search
  local k = search.K
  local function Gain(layout)
    return SDP_Overlay.With(0, function()
      search.Board:Clear()
      search:Evaluate(layout)
      return search.Board:Total()
    end)
  end
  local fine = {}
  for m = 1, k do fine[m] = search.BestLayout[m] end
  local fineGain = Gain(fine)
  local fineTwo = SDP_Overlay.With(0, CmpLongrun.TwoSlot, search, fine)
  for _ = 1, 20 do
    local nextResult = again(result)
    if not nextResult.Ok then break end
    result = nextResult
  end
  local continued = {}
  for m = 1, k do continued[m] = search.BestLayout[m] end
  local continuedGain = Gain(continued)
  local annealed, layout, evaluations = SDP_Overlay.With(0, CmpLongrun.Anneal, search, continued, 200000, 20261025)
  search.BestLayout = layout
  local o = Oracle(result, out, cityOf, false, request.weights, false, nil)
  out.stats.longrun = {
    fine = fineGain, fineTwoSlot = { improving = fineTwo.improving, best = fineTwo.best, evaluations = fineTwo.evaluations },
    continued = continuedGain, annealed = annealed, annealEvaluations = evaluations,
    value = o.Value, upper = o.Upper, proven = o.Proven, complete = o.Complete,
  }
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
  -- "LONGRUN[@<millions>]" (issue 40): the fine tier, 20 continues,
  -- annealing, then the oracle from there to its node limit (default 1
  -- million): a range [value, upper] where the optimum cannot be proven.
  local longrun = variant:match("^LONGRUN") ~= nil
  if longrun then
    include("cmp_oracle")
    include("cmp_longrun")
    CmpOracle.NODE_LIMIT = tonumber(variant:match("@(%d+)$") or "1") * 1e6
    variant = "FINE"
  end
  local oracle = variant:match("^ORACLE") ~= nil
  local check = oracle and variant:match("_CHECK$") ~= nil
  if oracle then variant = "FINE" .. variant:gsub("_CHECK$", ""):gsub("^ORACLE", "") end
  -- "..._DIST<nnn>": the distance cost weight nnn / 100 (issue 91).
  local distance = tonumber(variant:match("_DIST(%d+)$") or "")
  if distance ~= nil then distance = distance / 100 end
  variant = variant:gsub("_DIST%d+$", "")
  -- "<TIER>_KNEW<n>" (sites, issue 86): the new strategic kind's factor.
  local knew = tonumber(variant:match("_KNEW(%d)$") or "")
  variant = variant:gsub("_KNEW%d$", "")
  -- "<TIER>_GROWTH" (sites): the sites tab's Growth first preset.
  local growth = variant:match("_GROWTH$") ~= nil
  variant = variant:gsub("_GROWTH$", "")
  -- "<TIER>_DENSE[_GRID..]" (sites, issue 87): dense packing.
  local dense = variant:match("_DENSE") ~= nil
  variant = variant:gsub("_DENSE", "")
  -- "<TIER>_K<n>[_GRID..]" (sites, issue 87): n sites instead of the scenario's.
  local count = tonumber(variant:match("_K(%d+)") or "")
  variant = variant:gsub("_K%d+", "")
  -- "<TIER>_GRID[n]" (sites): the tab's default grid, n districts per site.
  local grid = variant:match("_GRID(%d*)$")
  variant = variant:gsub("_GRID%d*$", "")
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
  local group = tonumber(variant:match("_GROUP(%d+)S?$") or "")
  local sharedList = variant:match("_GROUP%d+S$") ~= nil
  variant = variant:gsub("_GROUP%d+S?$", "")
  LoadSDP()
  if knew ~= nil then SDP_Sites.KIND_NEW = knew end
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
    local districts = { Districts = request.districts }
    if grid ~= nil then districts = SDP_Sites.DefaultDistricts(0, tonumber(grid)) end
    local r = SDP_SiteSolver.Solve({ PlayerID = 0, Tier = variant, D = request.sites.distance,
      K = count or (dense and SDP_SiteSolver.DENSE_MAX_K) or request.sites.count, Dense = dense,
      Districts = districts.Districts, Pool = districts.Pool, Pick = districts.Pick,
      Weights = growth and SDP_Sites.PRESETS.GROWTH or nil, Distance = distance })
    if dense and r.Ok then stats.sdpPackings, stats.sdpMostSites = r.Stats.Packings, r.Stats.MostSites end
    if grid ~= nil then stats.sdpPool = districts.Pool end
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    -- The districts placed around each site ("TYPE@x,y"), for comparing
    -- variants (issue 91); the judge does not read them.
    local siteDistricts = {}
    for _, site in ipairs((r.Ok and r.Solutions[1] and r.Solutions[1].Sites) or {}) do
      out.placements[#out.placements + 1] = { kind = "SITE", x = site.X, y = site.Y }
      for _, d in ipairs(site.Districts or {}) do
        siteDistricts[#siteDistricts + 1] = d.Type .. "@" .. d.X .. "," .. d.Y
      end
    end
    stats.sdpSiteDistricts = siteDistricts
    stats.method = "sites"
  elseif scn.kind == "single" and #(request.wonders or {}) > 0 then
    -- Wonders with the districts: the single-city tab solves this city as
    -- SDP_Multi with only this city (SDP_Panel's WonderRequest).
    local id = request.target:GetID()
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = request.districts, Wonders = request.wonders,
      Only = { [id] = true }, Weights = request.weights, Land = land, Swap = swap, Coverage = coverage, Distance = distance })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    for _, p in ipairs(r.Plan or {}) do
      out.placements[#out.placements + 1] = { city = id, type = p.Type, x = p.X, y = p.Y, kind = p.Kind }
      -- The improvement a wonder needs next to it (issue 51), tacked with it.
      if p.Support ~= nil then
        out.placements[#out.placements + 1] = { city = id, type = p.Support.Type, x = p.Support.X, y = p.Support.Y,
          kind = "IMPROVEMENT" }
      end
    end
    if oracle and r.Ok then
      Oracle(r, out, function() return id end, check, request.weights, land, lambda)
      stats.method = "oracle"
      return out
    end
    stats.sdpGain, stats.sdpAppeal, stats.sdpLand, stats.sdpCost = r.Adjacency, r.AppealDelta, r.LandDelta, r.CostDelta
    if land then stats.sdpObjective = r.Gain end
    stats.sdpQuality = r.Quality -- design 7.4: Exhaustive, Bound, Gap, Converged, Truncated
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
  elseif scn.kind == "single" then
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Districts = request.districts,
      Pool = request.pool, Count = request.count,
      Land = land, Tier = variant, Weights = request.weights, Swap = swap, Coverage = coverage, Distance = distance })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    Take(r.Plan, request.target:GetID())
    if longrun and r.Ok then
      local id = request.target:GetID()
      LongRun(r, out, function() return id end, request, SDP_Solver.Continue)
      stats.method = "longrun"
      return out
    end
    if oracle and r.Ok then
      local id = request.target:GetID()
      Oracle(r, out, function() return id end, check, request.weights, land, lambda)
      stats.method = "oracle"
      return out
    end
    stats.sdpGain, stats.sdpAppeal, stats.sdpLand, stats.sdpCost = r.Adjacency, r.AppealDelta, r.LandDelta, r.CostDelta
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
  elseif group ~= nil then
    local all = request.cities
    for first = 1, #all, group do
      local existing, plans = {}, nil
      for c, city in ipairs(all) do existing[city:GetID()] = c >= first and c < first + group end
      -- Every city its own list, also when all want the same; "_GROUP<n>S":
      -- the shared list, as the tab sends it by default, where an existing
      -- city skips what it has tacked (SDP_City.OwnPins). Before issue 64 it
      -- skipped any tack of the type within four plots, a neighbour's too.
      if request.plans or not sharedList then
        plans = {}
        for _, city in ipairs(all) do
          plans["C" .. city:GetID()] = (request.plans and request.plans[city:GetID()]) or request.districts
        end
      end
      local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = plans and {} or request.districts, Plans = plans,
        Existing = existing, Land = land, Weights = request.weights, Distance = distance })
      if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
      local byKey = {}
      for _, c in ipairs(r.Cities or {}) do byKey[c.Key] = c.CityID end
      for _, p in ipairs(r.Plan or {}) do
        if p.Kind == nil or p.Kind == "DISTRICT" then
          out.placements[#out.placements + 1] = { city = byKey[p.City], type = p.Type, x = p.X, y = p.Y }
          Pin(p.Type, p.X, p.Y)
        end
      end
      for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
    end
    stats.method = "groups of " .. group
  else
    local existing, plans = {}, nil
    for _, city in ipairs(request.cities) do existing[city:GetID()] = true end
    if request.plans then
      -- Each city its own list (the tab's "plan for" pulldown).
      plans = {}
      for _, city in ipairs(request.cities) do plans["C" .. city:GetID()] = request.plans[city:GetID()] or {} end
    end
    -- One planned city (the coverage scenes RC, RP): exactly that city, as
    -- the single-city tab would ask; city-center tacks do not take part.
    local only = #request.cities == 1 and existing or nil
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = plans and {} or request.districts, Plans = plans,
      Existing = existing, Only = only, Land = land, Weights = request.weights, Coverage = coverage, Swap = swap,
      Distance = distance })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    local byKey = {}
    for _, c in ipairs(r.Cities or {}) do byKey[c.Key] = c.CityID end
    if longrun and r.Ok then
      LongRun(r, out, function(m) return r.Cities[r.Session.Search.Groups[m]].CityID end, request, SDP_Multi.Continue)
      stats.method = "longrun"
      return out
    end
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
    stats.sdpGain, stats.sdpAppeal, stats.sdpLand, stats.sdpCost = r.Adjacency, r.AppealDelta, r.LandDelta, r.CostDelta
    if land then stats.sdpObjective = r.Gain end
    stats.sdpQuality = r.Quality -- design 7.4: Exhaustive, Bound, Gap, Converged, Truncated
    stats.sdpCovered = r.Covered
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
  end
  return out
end
