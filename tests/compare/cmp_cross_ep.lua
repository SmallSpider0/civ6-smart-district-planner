-- cmp_cross_ep.lua: Empire Planner's own objective for any planner's plan
-- (CmpRun.Cross, design 18.1 item 2).
--
-- Runs in a fresh Lua state after CmpRun.Setup(id): the scenario's world, and
-- here EP's three logic files, loaded unmodified (ep_rules, ep_meta,
-- ep_planner, in the order ep_panel includes them; ep_rules brings DMT's
-- dmt_yieldcalculator in through its legality bridge and unhooks it, as in
-- EP's own context). Nothing of EP is reimplemented for the district
-- objective: the numbers come from EP_Planner._test, the seam EP exports for
-- its own offline suite.
--
-- Districts (single, multi and wonder scenarios):
--   EP_Planner.Prepare(playerID, options) builds EP's plot cache and civ
--   tables exactly as a Plan does (weights = request.weights, the districts
--   the request names enabled, nothing else); the plan's districts become
--   EP's `plan` claims ({ district = type, cityIdx }) and one placement list
--   per city; score = EP_Planner.PlanTotal over the scenario's cities
--   (request.target for single, request.cities for multi). That is the number
--   EP ranks its layouts by, and it is taken before EP's wonder pass, so
--   wonders are not in it (parts.withWonders: the same total with the plan's
--   wonders claiming their tiles, { wonder = type }). Per planned district
--   ScorePlacement = (rule-engine adjacency weighted by request.weights + 0.4
--   x the adjacency of improvements that could be built beside it) x EP's
--   district priority x the leader's AI bias, minus the bonus resource it
--   buries, minus 0.15 x the tile's weighted yield, plus Korea's isolation and
--   Japan's clustering terms. Built districts are not part of it (EP never
--   counts them), so the empty plan scores 0 and gain = score.
--   illegal: placements EP's own legality refuses with the rest of the plan
--   (wonders included) in place (DistrictLegal: rules layer + civ rules + empire cap + centre
--   adjacency, IsLegalWonder for wonders; reason from EP_Rules.WhyIllegal),
--   a type twice in one city or already built there (EP's layout never
--   plans those), and placements outside the scenario's cities.
--   parts.belowSlotBar: specialty districts whose raw (unweighted) marginal
--   gain is under EP_Meta.MIN_DISTRICT_ADJACENCY -- EP's layout refuses those
--   ("not worth a slot") although they add to PlanTotal. dmtRefused
--   (informational, not in illegal): placements EP's DMT bridge
--   (EP_Rules.DmtCanPlace) refuses, as it would at commit time.
--
-- Sites (sites scenarios): EP's greedy site choice (ChooseSites) adds, per
--   picked site, BaseSiteScore(site, with the resources earlier picks banked
--   and earlier picks counting as home) + the change in the empire's district
--   total the new city brings. Summed over the plan's sites in order, that is
--     score    = sum of BaseSiteScore + BuildLayout(prep, sites).score
--     baseline = BuildLayout(prep, {}).score       (the empire as it is)
--   BuildLayout is EP's own (greedy + swap + two refinement rounds, no
--   jittered restarts, generator seeded as Run seeds it). The banking of
--   resources between picks (ChooseSites' local `bank`) is restated here, as
--   are the site search's legality conditions (CollectCandidateSites and
--   ChooseSites inline them; the constants are EP's exports): revealed land,
--   no mountain, natural wonder or district, not another player's tile,
--   within SITE_SEARCH_RANGE of an own city, MIN_CITY_SPACING from every city
--   and from the other sites, MIN_FOREIGN_SPACING from foreign cities.

CmpCross = CmpCross or {}

-- EP_Planner.Run seeds its generator with this before planning
-- (ep_planner.lua PLAN_SEED); BuildLayout draws from it only in restarts.
local EP_PLAN_SEED = 20260822

local function Copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

local function Round(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

-- EP loaded as its panel loads it, and the options a Plan with the request's
-- districts would pass.
local function LoadEP(request)
  include("ep_rules")
  include("ep_meta")
  include("ep_planner")
  if EP_Planner == nil or EP_Rules == nil or EP_Meta == nil or EP_Planner._test == nil then
    error("Empire Planner did not load")
  end
  local playerID = request.playerID
  local wanted = {}
  for _, t in ipairs(request.districts) do wanted[t] = true end
  local disabled, slots = {}, 0
  for _, t in ipairs(EP_Rules.GetCivDistricts(playerID)) do
    if not wanted[t] then disabled[t] = true end
  end
  for _, t in ipairs(request.districts) do
    local row = GameInfo.Districts[t]
    if row and row.RequiresPopulation and not row.CityCenter then slots = slots + 1 end
  end
  local sites = request.scenario.kind == "sites" and request.sites ~= nil
  return {
    numNewCities = sites and request.sites.count or 0,
    districtsPerCity = math.max(1, math.min(9, slots)),
    wondersPerEra = 3,
    wondersPerCityEra = 1,
    weights = Copy(request.weights),
    wantDistricts = true,
    wantWonders = false,
    wantImprovements = false,
    wantSites = sites,
    disabledTypes = disabled,
  }
end

-- ---------------------------------------------------------------------------
-- Districts: EP's PlanTotal of the plan.
-- ---------------------------------------------------------------------------
local function DistrictObjective(request, plan, prep, out)
  local T = EP_Planner._test
  local cache, weights = prep.cache, prep.weights
  local function Note(s) out.notes[#out.notes + 1] = s end
  local function Illegal(p, why)
    out.illegal[#out.illegal + 1] = { type = p.type, x = p.x, y = p.y, city = p.city, reason = why }
  end

  local ctxByCity = {}
  for _, ctx in ipairs(prep.ownCities) do ctxByCity[ctx.cityID] = ctx end
  local scope = {}
  if request.scenario.kind == "single" then
    scope[1] = request.target
  else
    for i, c in ipairs(request.cities) do scope[i] = c end
  end
  local contexts, inScope = {}, {}
  for _, c in ipairs(scope) do
    local ctx = ctxByCity[c:GetID()]
    if ctx == nil then
      Note("EP has no context for city " .. c:GetID())
    else
      contexts[#contexts + 1] = ctx
      inScope[c:GetID()] = ctx
    end
  end

  -- The plan as EP's claims, in the plan's order (first claim on a tile wins).
  local claims, districtClaims, layouts, items = {}, {}, {}, {}
  for _, p in ipairs(plan.placements or {}) do
    local plot = (p.x ~= nil and p.y ~= nil) and Map.GetPlot(p.x, p.y) or nil
    local ctx = p.city ~= nil and inScope[p.city] or nil
    local isDistrict = p.type ~= nil and EP_Rules.DistrictInfo(p.type) ~= nil
    local isWonder = not isDistrict and p.type ~= nil and EP_Rules.WonderInfo(p.type) ~= nil
    if plot == nil then
      Illegal(p, "off_map")
    elseif ctx == nil then
      Illegal(p, "no_city")
    elseif not isDistrict and not isWonder then
      Illegal(p, "unknown_type")
    else
      local idx = plot:GetIndex()
      if claims[idx] ~= nil then
        Illegal(p, "same_tile")
      else
        if isDistrict then
          claims[idx] = { district = p.type, cityIdx = ctx.centerIdx }
          districtClaims[idx] = claims[idx]
          layouts[ctx.centerIdx] = layouts[ctx.centerIdx] or {}
          table.insert(layouts[ctx.centerIdx], { type = p.type, idx = idx })
        else
          claims[idx] = { wonder = p.type, cityIdx = ctx.centerIdx }
        end
        items[#items + 1] = { p = p, idx = idx, ctx = ctx, district = isDistrict }
      end
    end
  end

  local score = T.PlanTotal(contexts, layouts, cache, districtClaims, weights)
  local baseline = T.PlanTotal(contexts, {}, cache, {}, weights)
  local withWonders = T.PlanTotal(contexts, layouts, cache, claims, weights)

  -- Per placement: EP's score and its parts; legality with the rest in place.
  local perDistrict, wonders = {}, {}
  local adjacency, tileCost, resourceCost = 0, 0, 0
  local seenInCity, dmtRefused, belowSlotBar = {}, {}, 0
  for _, it in ipairs(items) do
    local p, idx, ctx = it.p, it.idx, it.ctx
    local claim = claims[idx]
    claims[idx] = nil
    local legal
    if it.district then
      legal = T.DistrictLegal(p.type, idx, cache, claims, ctx)
    else
      legal = EP_Rules.IsLegalWonder(p.type, idx, cache, claims, ctx)
    end
    local why = nil
    if not legal then
      why = EP_Rules.WhyIllegal(p.type, idx, cache, claims, ctx) or "EP planner rule (civ placement rule, empire cap or centre adjacency)"
    end
    claims[idx] = claim
    if why ~= nil then Illegal(p, why) end
    if it.district then
      local key = ctx.centerIdx .. ":" .. p.type
      if seenInCity[key] then Illegal(p, "twice_in_city") end
      seenInCity[key] = true
      if ctx.built[p.type] then Illegal(p, "already_built") end
      local s = T.ScorePlacement({ type = p.type, idx = idx }, cache, districtClaims, weights)
      local adj = EP_Rules.ScoreAdjacency(p.type, idx, cache, districtClaims, weights, nil)
      local tc = EP_Rules.PlotYieldScore(cache, idx, weights) * T.DISTRICT_TILE_COST
      local rc = T.BonusResourceCost(idx, cache, weights)
      adjacency, tileCost, resourceCost = adjacency + adj, tileCost + tc, resourceCost + rc
      -- EP's "worth a slot" bar: a specialty district's raw (unweighted)
      -- marginal gain must reach EP_Meta.MIN_DISTRICT_ADJACENCY or EP's
      -- layout refuses it. Measured as what removing it costs the plan.
      local info = EP_Rules.DistrictInfo(p.type)
      local raw = -T.TrialDelta({ { idx = idx, claim = nil } }, cache, districtClaims, nil)
      local below = info ~= nil and info.requiresPop and raw < (EP_Meta.MIN_DISTRICT_ADJACENCY or 0)
      if below then belowSlotBar = belowSlotBar + 1 end
      perDistrict[#perDistrict + 1] = { type = p.type, x = p.x, y = p.y, city = p.city, score = Round(s),
        adjacency = Round(adj), tileCost = Round(tc), resourceCost = Round(rc), rawGain = Round(raw),
        belowSlotBar = below or nil }
    else
      wonders[#wonders + 1] = { type = p.type, x = p.x, y = p.y, city = p.city, legal = legal }
    end
    -- DMT's verdict through EP's bridge, as EP asks it at commit time.
    local subjectType = it.district and "DISTRICT" or "WONDER"
    EP_Rules.LastDmtReason = nil
    if not EP_Rules.DmtCanPlace(subjectType, p.type, idx, cache, ctx) then
      dmtRefused[#dmtRefused + 1] = { type = p.type, x = p.x, y = p.y, reason = EP_Rules.LastDmtReason }
    end
  end

  out.score, out.baseline, out.gain = Round(score), Round(baseline), Round(score - baseline)
  out.parts = { districts = perDistrict, adjacency = Round(adjacency), tileCost = Round(tileCost),
    resourceCost = Round(resourceCost), belowSlotBar = belowSlotBar, wonders = (#wonders > 0) and wonders or nil,
    withWonders = (#wonders > 0) and Round(withWonders) or nil }
  out.dmtRefused = dmtRefused
  out.objective = "EP_Planner PlanTotal before the wonder pass (planned districts only)"
end

-- ---------------------------------------------------------------------------
-- Sites: EP's greedy site objective for the plan's sites, in plan order.
-- ---------------------------------------------------------------------------
local function SiteObjective(request, plan, prep, out)
  local T = EP_Planner._test
  local cache = prep.cache
  local playerID = request.playerID
  local function Illegal(p, why)
    out.illegal[#out.illegal + 1] = { x = p.x, y = p.y, reason = why }
  end
  local ownPlots, allPlots, foreignPlots = {}, {}, {}
  for _, ctx in ipairs(prep.ownCities) do ownPlots[#ownPlots + 1] = ctx.centerIdx end
  for _, player in ipairs(Game.GetPlayers({ Alive = true })) do
    for _, c in player:GetCities():Members() do
      local idx = Map.GetPlot(c:GetX(), c:GetY()):GetIndex()
      allPlots[#allPlots + 1] = idx
      -- Only cities EP can see count against the wider foreign floor.
      if player:GetID() ~= playerID and cache.facts[idx] ~= nil then foreignPlots[#foreignPlots + 1] = idx end
    end
  end

  local order = {}
  for _, p in ipairs(plan.placements or {}) do
    local plot = (p.x ~= nil and p.y ~= nil) and Map.GetPlot(p.x, p.y) or nil
    local f = plot and cache.facts[plot:GetIndex()] or nil
    if plot == nil then
      Illegal(p, "off_map")
    elseif f == nil then
      Illegal(p, "unrevealed")
    elseif f.isWater or f.isMountain or f.isImpassable then
      Illegal(p, "terrain")
    else
      local idx = plot:GetIndex()
      local function Dist(other) return EP_Rules.PlotDistance(cache, idx, other) end
      if f.isNaturalWonder then Illegal(p, "natural_wonder") end
      if f.district ~= nil then Illegal(p, "district") end
      if f.owner ~= -1 and f.owner ~= playerID then Illegal(p, "foreign_tile") end
      local inRange = false
      for _, c in ipairs(ownPlots) do
        if Dist(c) <= EP_Planner.SITE_SEARCH_RANGE then inRange = true end
      end
      if not inRange then Illegal(p, "beyond_search_range") end
      for _, c in ipairs(allPlots) do
        if Dist(c) < EP_Planner.MIN_CITY_SPACING then Illegal(p, "too_close_city") break end
      end
      for _, c in ipairs(foreignPlots) do
        if Dist(c) < EP_Planner.MIN_FOREIGN_SPACING then Illegal(p, "too_close_foreign") break end
      end
      for _, other in ipairs(order) do
        if Dist(other) < EP_Planner.MIN_CITY_SPACING then Illegal(p, "too_close_site") break end
      end
      order[#order + 1] = idx
    end
  end

  -- Site scores as ChooseSites accumulates them: each pick banks the
  -- resources within 3 of it (one physical plot pays once) and counts as home
  -- for the next.
  local pending, taken, claimed, siteScores, siteSum = {}, {}, {}, {}, 0
  for _, idx in ipairs(order) do
    local s = T.BaseSiteScore(idx, cache, prep.weights, prep.snapshot, pending, taken, claimed)
    siteSum = siteSum + s
    local f0 = cache.facts[idx]
    siteScores[#siteScores + 1] = { x = f0.x, y = f0.y, score = Round(s) }
    for dx = -3, 3 do
      for dy = -3, 3 do
        local plot = Map.GetPlotXYWithRangeCheck(f0.x, f0.y, dx, dy, 3)
        if plot ~= nil then
          local rIdx = plot:GetIndex()
          local rf = cache.facts[rIdx]
          if rf ~= nil and rf.resource ~= nil and not taken[rIdx] then
            taken[rIdx] = true
            pending[rf.resource] = (pending[rf.resource] or 0) + 1
          end
        end
      end
    end
    claimed[#claimed + 1] = idx
  end

  T.SetSeed(EP_PLAN_SEED)
  local base = T.BuildLayout(prep, {}, 0, nil, nil)
  T.SetSeed(EP_PLAN_SEED)
  local with = T.BuildLayout(prep, order, 0, nil, nil)
  local score = siteSum + with.score
  out.score, out.baseline, out.gain = Round(score), Round(base.score), Round(score - base.score)
  out.parts = { siteScore = Round(siteSum), sites = siteScores, districtTotal = Round(with.score),
    districtBaseline = Round(base.score) }
  out.objective = "EP greedy site objective: sum BaseSiteScore + BuildLayout district total (baseline: no new city)"
end

function CmpCross.ep(request, plan, w)
  local out = { illegal = {}, notes = {} }
  local options = LoadEP(request)
  local prep = EP_Planner._test.Prepare(request.playerID, options, nil)
  if request.scenario.kind == "sites" then
    SiteObjective(request, plan, prep, out)
  else
    DistrictObjective(request, plan, prep, out)
  end
  return out
end
