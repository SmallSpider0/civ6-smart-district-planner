-- cmp_cross_amt.lua: a plan (from any planner) scored with the objective
-- Auto Map Tacks Planner r49 (AMT) maximizes, for CmpRun.Cross in
-- cmp_lib.lua. The scenario's world exists; AMT is loaded unmodified the
-- way cmp_amt.lua loads it (CmpAmt.Load) and given the same input as the
-- comparison's "" variant:
--   single city  open the planner, set the slot count, click the request's
--                districts (in its order: slot order = AMT's specialty
--                order) and wonders, click Plan, put request.weights into the
--                queued job
--   multi-city   joint planner, every city in a slot, the same districts,
--                Government Plaza AUTO, confirm the scope, request.weights
--                through AMT_MC_M3_MergeWeights
-- and AMT runs up to the start of its search: its own requests, fixed
-- subjects (built districts, improvements, pins), weights and run cache,
-- and every request's raw candidates (AMT's per-tile items, after its tile
-- filters and DMT check). The search itself is skipped (SearchBestPlan
-- returns an empty state; the joint inputs are taken and the solve stops
-- with an input error, which AMT shows as a failure).
--
-- The plan's placements become AMT items: the raw candidate of the same
-- type, tile (and city) of the first request that has it and room left
-- (AMT places one item per request: a single-city request is one district
-- or one of a group of alternatives such as Commercial Hub / Harbor; joint
-- requests up to their cardinalityMax). A placement beyond a request's room
-- uses that request's candidate; one no request covers (e.g. a district the
-- player could not select because AMT's six specialty slots were full) is
-- looked up among the raw candidates of a request built for it alone (AMT's
-- tile filters and DMT check for that type and city; specialty order from
-- AMT's default order). Both are scored and counted in outsideRequests. A
-- wonder that needs a district is matched to the candidate variant whose
-- support bundle the plan has, and that plan district enters as the
-- wonder's support item (specialty order 99), as in AMT's own states. A
-- placement with no raw candidate either way is one AMT rejects (illegal;
-- rejected[].detail names the first AMT filter it fails), and so is one
-- EvaluatePlan rejects within the whole plan (DMT under the projected
-- layout, wonder tile rules): it is dropped and the rest evaluated again.
-- Check: for AMT's own "" plans the score equals the score AMT reports for
-- its plan (bestState.score, single city; plan 1's score, joint).
--
--   score     EvaluatePlan(items) of the accepted items, AMT's local
--             function (reached through the debug library, as cmp_amt.lua
--             reaches AMT's locals): per item its DMT yields x weights x
--             AMT's multiplier (specialty district 6 + 1.5 per slot ahead of
--             the 4th, other district 2, wonder 1.25), plus the fixed
--             subjects' DMT yields under the new layout (same multipliers),
--             minus the tile yields the items take, plus layout terms
--             (coverage, focus, preserve) and wonder spatial effects
--   baseline  EvaluatePlan({}) (SearchBestPlan's starting state)
--   gain      score - baseline; higher is better for AMT
--   gainInRequests  the same over the items inside AMT's requests only
--             (outsideRequests dropped): the part of the plan AMT could
--             have produced for this input; equals gain for AMT's own plans
-- Single city: AMT ranks states lexicographically, first by the number of
-- placed districts per priority, then strategic resources, then this score
-- (minus 0.001 per item); parts.placedByPriority shows the first tier.
-- Multi-city: the joint solve scores a layout with the same EvaluatePlan
-- over all cities at once (fixed subjects of every city, coverage scoped to
-- the participants: inputs.scoreOptions); its rank puts legality, wonders,
-- slot fulfilment, strategic resources and the coverage gap before the
-- score, and redundancy after it. The score here is that joint EvaluatePlan
-- (one call over all cities, not a per-city sum) plus the Government Plaza
-- hub preference AMT adds to its final plans (at most 1 point,
-- parts.governmentHubBonus), i.e. the score AMT reports for its plan.

include("cmp_amt")

CmpCross = CmpCross or {}

local A = CmpAmt

local function Note(notes, s) notes[#notes + 1] = s end

local function IsWonder(t)
  local row = GameInfo.Buildings[t]
  return row ~= nil and row.IsWonder == true
end

local function Copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- An AMT raw candidate as a plan item: the support bundle a wonder variant
-- carries is not part of this plan (the plan's own districts are).
local function AsItem(raw)
  local item = Copy(raw)
  item.supportItems = nil
  return item
end

-- ===========================================================================
-- AMT's inputs
-- ===========================================================================
-- Single city: the "" variant's clicks, then AMT's own preparation up to
-- BuildCandidateShortlists (captured: every request gets rawCandidates),
-- and an empty search.
local function CaptureSingle(request, notes)
  local city = request.target
  A.SelectSingleCity(city, request, notes)
  local ctx = nil
  local realShort, fShort, iShort = A.FindUpvalue(A.Roots(), "BuildCandidateShortlists")
  if type(realShort) ~= "function" then error("AMT local not found: BuildCandidateShortlists") end
  debug.setupvalue(fShort, iShort, function(requests, playerID, weights, ignoredKeys, reservedKeys, overwrite, clear,
                                            fixedSubjects, autoRegistry, runCache)
    ctx = { requests = requests, playerID = playerID, weights = weights, ignoredKeys = ignoredKeys,
      reservedKeys = reservedKeys, overwrite = overwrite, clear = clear, fixedSubjects = fixedSubjects,
      autoRegistry = autoRegistry, runCache = runCache }
    return realShort(requests, playerID, weights, ignoredKeys, reservedKeys, overwrite, clear, fixedSubjects,
      autoRegistry, runCache)
  end)
  local realSearch = SearchBestPlan
  local budgets = nil
  SearchBestPlan = function(_, _, _, _, _, citySpecialtyBudgets)
    budgets = citySpecialtyBudgets
    return { items = {}, occupied = {}, score = 0, priorityCounts = {}, specialtyCounts = {}, yieldsByItem = {} }, {}
  end
  local ok, err = pcall(function()
    A.ClickPlan(request, "", notes)
    A.Pump()
  end)
  SearchBestPlan = realSearch
  debug.setupvalue(fShort, iShort, realShort)
  if not ok then error(err, 0) end
  if ctx == nil then
    -- Every request was skipped before the candidate stage (all built,
    -- pinned or over the population limit): AMT's fixed subjects and a run
    -- cache as BuildAutoPlanPreview makes them.
    Note(notes, "AMT skipped every request before its candidate stage: " .. tostring(Controls.ResultText:GetText()))
    local fixed = select(3, A.RequireLocal("GetExistingPlannedDistricts")({ city }, {}))
    ctx = { requests = {}, playerID = 0, weights = A.NeutralWeights(request), ignoredKeys = {},
      reservedKeys = A.RequireLocal("BuildCityCenterKeys")({ city }), overwrite = false, clear = false,
      fixedSubjects = fixed, autoRegistry = A.RequireLocal("LoadAutoPinRegistry")(0),
      runCache = A.RequireLocal("BuildPlanningRunCache")(0) }
  end
  ctx.mode = "single"
  ctx.budget = budgets and budgets[city:GetID()] or nil
  ctx.cityFor = function() return city end
  -- One item per request (SearchBestPlan adds one candidate per request;
  -- only improvement pools take several).
  ctx.candidateLists = {}
  for _, r in ipairs(ctx.requests) do
    ctx.candidateLists[#ctx.candidateLists + 1] = { id = r.requestID, list = r.rawCandidates or {},
      cap = r.isAutoQuantity and math.huge or 1 }
  end
  return ctx
end

-- Multi-city: the "" variant's clicks up to the scope page, then the joint
-- inputs as AMT builds them (raw candidates of every request as contracts).
local function CaptureJoint(request, notes)
  A.OpenJointScope(request, notes)
  local realMerge, realInputs = AMT_MC_M3_MergeWeights, AMT_MC_M3_BuildJointInputs
  AMT_MC_M3_MergeWeights = function() return A.NeutralWeights(request) end
  local inputs, reason = nil, nil
  AMT_MC_M3_BuildJointInputs = function(...)
    inputs, reason = realInputs(...)
    return nil, "cross-score: inputs taken, solve skipped"
  end
  local ok, err = pcall(function()
    if not A.Click(Controls.MCScopeConfirmButton) then error("scope confirm not clickable") end
    A.Pump()
  end)
  AMT_MC_M3_MergeWeights, AMT_MC_M3_BuildJointInputs = realMerge, realInputs
  if not ok then error(err, 0) end
  if type(inputs) ~= "table" then error("AMT joint inputs not built: " .. tostring(reason)) end
  local ctx = { playerID = 0, weights = inputs.weights, ignoredKeys = inputs.ignoredKeys or {},
    fixedSubjects = inputs.fixedSubjects, runCache = inputs.runCache, scoreOptions = inputs.scoreOptions,
    overwrite = false, clear = false, autoRegistry = A.RequireLocal("LoadAutoPinRegistry")(0), mode = "joint" }
  local centers = {}
  for _, c in ipairs(request.cities) do centers[#centers + 1] = c end
  ctx.reservedKeys = A.RequireLocal("BuildCityCenterKeys")(centers)
  local planning = inputs.planningCities or {}
  ctx.cityFor = function(cityID) return planning[cityID] end
  -- Contracts by request, in request-ID order; each carries AMT's raw item.
  local caps = {}
  for _, field in ipairs({ "requests", "uniqueRequests", "improvementRequests" }) do
    for _, r in ipairs(inputs[field] or {}) do
      if r.requestID then caps[r.requestID] = tonumber(r.cardinalityMax) or 1 end
    end
  end
  local ids = {}
  for id in pairs(inputs.candidatesFor or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  ctx.candidateLists = {}
  ctx.contractOf = {}
  for _, id in ipairs(ids) do
    local list = {}
    for _, contract in ipairs(inputs.candidatesFor[id]) do
      if contract.legacy then
        list[#list + 1] = contract.legacy
        ctx.contractOf[contract.legacy] = contract
      end
    end
    ctx.candidateLists[#ctx.candidateLists + 1] = { id = id, list = list, cap = caps[id] or 1 }
  end
  ctx.skippedNotes = inputs.skippedNotes
  ctx.hubPotentials = inputs.governmentHubPotentials
  return ctx
end

-- ===========================================================================
-- Plan -> AMT items
-- ===========================================================================
local function Matches(raw, p, subjectType)
  return raw.subjectType == subjectType and raw.subjectKey == p.type and raw.x == p.x and raw.y == p.y
    and (raw.cityID == nil or p.city == nil or raw.cityID == p.city)
end

-- The raw candidates of a request for this type and city alone (cached).
local function OwnCandidates(ctx, p, subjectType, cityID)
  local key = subjectType .. ":" .. p.type .. ":" .. tostring(cityID)
  ctx.own = ctx.own or {}
  if ctx.own[key] == nil then
    local city = ctx.cityFor(cityID)
    local list = {}
    if city ~= nil then
      local r = { subjectType = subjectType, subjectKey = p.type, subjectOptions = { p.type },
        district = subjectType == "DISTRICT" and p.type or nil, cities = { city }, cityID = cityID,
        requestID = "CROSS:" .. p.type, isOptional = subjectType ~= "WONDER",
        selectedDistricts = subjectType == "WONDER" and ctx.selectedDistricts or nil }
      list = A.RequireLocal("BuildRawCandidates")(r, ctx.playerID, ctx.weights, ctx.ignoredKeys, ctx.reservedKeys,
        ctx.overwrite, ctx.clear, ctx.fixedSubjects, ctx.autoRegistry, ctx.runCache)
    end
    ctx.own[key] = list
  end
  return ctx.own[key]
end

-- Why AMT has no candidate for a placement (diagnostic only): the first of
-- its candidate filters that fails, in BuildRawCandidates' order, checked
-- with AMT's own helpers.
local function Why(ctx, q, subjectType, cityID)
  local ok, reason = pcall(function()
    local L = A.RequireLocal
    local city = ctx.cityFor(cityID)
    local plot = Map.GetPlot(q.x, q.y)
    if city == nil or plot == nil then return "NO_CITY_OR_PLOT" end
    local native = city.isPlanningCity and city.nativeCity or city
    if Map.GetPlotDistance(native:GetX(), native:GetY(), q.x, q.y) > 3 then return "OUT_OF_RANGE" end
    if not IsPlotRevealedToPlayer(plot, ctx.playerID) then return "UNREVEALED" end
    if native:GetX() == q.x and native:GetY() == q.y then return "CITY_CENTER" end
    if plot:IsOwned() and plot:GetOwner() ~= ctx.playerID then return "FOREIGN_TILE" end
    if plot:IsOwned() and not L("GetCityOwnedPlotKeys")(native, ctx.runCache)[L("Key")(q.x, q.y)] then
      return "OTHER_CITY_TILE"
    end
    if L("FindMapPinAt")(ctx.playerID, q.x, q.y, ctx.runCache) ~= nil then return "PINNED_TILE" end
    local item = { subjectType = subjectType, subjectKey = q.type, x = q.x, y = q.y, plot = plot, cityID = cityID }
    if not L("ImprovementPlacement").CanPlan(item, ctx.playerID, ctx.runCache) then return "PROTECTED_RESOURCE" end
    if subjectType == "WONDER" then
      local can, deferred = AMT_WonderPlanner.CanUseRawCandidate(ctx.playerID, item)
      if not can then return "WONDER_TILE_RULES" end
      if deferred then return "NO_SUPPORT" end
    end
    pcall(UpdatePinYields, ctx.playerID, {})
    local okPin, can, tip = pcall(CanPlacePin, ctx.playerID, { Key = q.type, Type = subjectType, X = q.x, Y = q.y,
      CityID = cityID })
    if okPin and can ~= true then return "DMT_REJECT " .. tostring(tip):gsub("%s+", " "):sub(1, 120) end
    return "OTHER"
  end)
  return ok and reason or ("UNKNOWN " .. tostring(reason):sub(1, 80))
end

local function PlanKey(t, x, y) return tostring(t) .. "@" .. tostring(x) .. "," .. tostring(y) end

-- How well a wonder candidate's support bundle fits the plan: 1 when every
-- support item is a placement of the plan (same type and tile), else 0.
local function SupportFit(c, planAt)
  for _, s in ipairs(c.supportItems or {}) do
    if not planAt[PlanKey(s.subjectKey, s.x, s.y)] then return 0 end
  end
  return 1
end

-- The candidates of one list for this placement: the first match, or for a
-- wonder the variant whose support bundle the plan has (AMT adds a wonder
-- that needs a district together with that district as its support item).
local function FindIn(list, q, subjectType, planAt)
  local best, bestFit = nil, -1
  for _, c in ipairs(list) do
    if Matches(c, q, subjectType) then
      if subjectType ~= "WONDER" then return c end
      local fit = SupportFit(c, planAt)
      if fit > bestFit then best, bestFit = c, fit end
    end
  end
  return best
end

local function ToItems(ctx, request, plan, out)
  local items, seen = {}, {}
  local single = ctx.mode == "single"
  local planAt = {}
  for _, p in ipairs(plan.placements or {}) do planAt[PlanKey(p.type, p.x, p.y)] = true end
  for _, p in ipairs(plan.placements or {}) do
    local subjectType = IsWonder(p.type) and "WONDER" or (GameInfo.Districts[p.type] and "DISTRICT" or nil)
    local cityID = single and request.target:GetID() or p.city
    local where = PlanKey(p.type, p.x, p.y)
    if subjectType == nil then
      Note(out.notes, "not a district or wonder, not scored: " .. where)
    elseif seen[p.x .. "," .. p.y] then
      out.rejected[#out.rejected + 1] = { type = p.type, x = p.x, y = p.y, stage = "OVERLAP" }
    else
      seen[p.x .. "," .. p.y] = true
      local q = { type = p.type, x = p.x, y = p.y, city = cityID }
      -- The first request with room left that has this candidate, else the
      -- first one that has it (beyond what AMT would place for it).
      local raw, entry, full = nil, nil, nil
      for _, e in ipairs(ctx.candidateLists) do
        local c = FindIn(e.list, q, subjectType, planAt)
        if c then
          if (e.used or 0) < e.cap then raw, entry = c, e break end
          if full == nil then full = { c, e } end
        end
      end
      local inRequest = raw ~= nil
      if raw then
        entry.used = (entry.used or 0) + 1
      elseif full then
        raw = full[1]
        Note(out.notes, "beyond AMT's request " .. tostring(full[2].id) .. " (it places " .. tostring(full[2].cap)
          .. "; e.g. Commercial Hub and Harbor are one request): " .. where)
      else
        raw = FindIn(OwnCandidates(ctx, q, subjectType, cityID), q, subjectType, planAt)
        if raw ~= nil then Note(out.notes, "outside AMT's requests (scored with its own candidate): " .. where) end
      end
      if raw == nil then
        out.rejected[#out.rejected + 1] = { type = p.type, x = p.x, y = p.y, stage = "NO_CANDIDATE",
          detail = Why(ctx, q, subjectType, cityID) }
      else
        if not inRequest then out.outsideRequests = out.outsideRequests + 1 end
        local item = AsItem(raw)
        item.cmpInRequest = inRequest
        item.cmpContract = ctx.contractOf and ctx.contractOf[raw] or nil
        item.cmpSupport = subjectType == "WONDER" and SupportFit(raw, planAt) == 1 and raw.supportItems or nil
        items[#items + 1] = item
      end
    end
  end
  -- A plan district that is a wonder's support enters as AMT's support item
  -- (specialty order 99, priority 1), as in AMT's own states; it still
  -- covers the district's request (WonderSupportCoversDistrictRequest).
  local index = {}
  for i, item in ipairs(items) do
    if item.subjectType == "DISTRICT" then index[PlanKey(item.subjectKey, item.x, item.y)] = i end
  end
  for _, item in ipairs(items) do
    for _, s in ipairs(item.cmpSupport or {}) do
      local i = index[PlanKey(s.subjectKey, s.x, s.y)]
      if i and not items[i].isWonderSupport then
        local support = AsItem(s)
        support.cmpInRequest = items[i].cmpInRequest
        items[i] = support
      end
    end
    item.cmpSupport = nil
  end
  return items
end

-- ===========================================================================
-- AMT's objective
-- ===========================================================================
local function Evaluate(ctx, items)
  local EvaluatePlan = A.RequireLocal("EvaluatePlan")
  if ctx.mode == "joint" then
    return EvaluatePlan(ctx.playerID, items, ctx.weights, ctx.ignoredKeys, ctx.fixedSubjects, ctx.runCache,
      ctx.scoreOptions)
  end
  return EvaluatePlan(ctx.playerID, items, ctx.weights, ctx.ignoredKeys, ctx.fixedSubjects, ctx.runCache)
end

-- EvaluatePlan voids a layout with any item it rejects; drop that item (the
-- one its diagnostic names, else the last) and evaluate the rest again.
local function EvaluateAccepted(ctx, items, out)
  while true do
    local score, yieldsByItem, diagnostic = Evaluate(ctx, items)
    if score ~= nil and score > -math.huge then return score, yieldsByItem, items end
    if #items == 0 then return nil, nil, items end
    local index = #items
    if type(diagnostic) == "table" and diagnostic.x ~= nil then
      for i, item in ipairs(items) do
        if item.x == diagnostic.x and item.y == diagnostic.y then index = i break end
      end
    end
    local item = items[index]
    out.rejected[#out.rejected + 1] = { type = item.subjectKey, x = item.x, y = item.y,
      stage = type(diagnostic) == "table" and diagnostic.stage or "REJECTED",
      detail = type(diagnostic) == "table" and diagnostic.detail and tostring(diagnostic.detail):sub(1, 160) or nil }
    table.remove(items, index)
  end
end

-- Joint solve: the bounded Government Plaza preference AMT adds to a final
-- plan's score (ApplyGovernmentHubPoolPreference: up to 1 point for a plaza
-- with several possible district neighbours), with AMT's own function.
local function HubBonus(ctx, items)
  if ctx.mode ~= "joint" or ctx.hubPotentials == nil then return 0 end
  local state = { items = {} }
  for _, item in ipairs(items) do
    if item.cmpContract then state.items[#state.items + 1] = { candidate = item.cmpContract } end
  end
  return (AMT_MultiCity.Solver.GovernmentHubPreference(state, ctx.hubPotentials, nil)) or 0
end

-- AMT's per-item multiplier in EvaluatePlan (for the breakdown only).
local function Multiplier(item)
  if item.subjectType == "DISTRICT" then
    if item.isSpecialty then
      local order = tonumber(item.specialtyOrder) or 99
      return 6 + math.max(0, 4 - math.min(order, 4)) * 1.5
    end
    return 2
  elseif item.subjectType == "WONDER" then
    return 1.25
  end
  return 0.3
end

function CmpCross.amt(request, plan, w)
  local scn = request.scenario
  local notes = {}
  local out = { notes = notes, rejected = {}, outsideRequests = 0 }
  if scn.kind == "sites" then
    Note(notes, "AMT does not choose city sites; not scored")
    return out
  end
  A.Load(w, request, notes)
  local ctx = scn.kind == "single" and CaptureSingle(request, notes) or CaptureJoint(request, notes)
  -- A wonder's own request lets AMT add the selected districts as its support.
  ctx.selectedDistricts = request.districts
  out.objective = ctx.mode == "single" and "EvaluatePlan (single-city search)" or
    "EvaluatePlan (joint solve, all cities, scoped coverage)"
  out.weights = A.WeightsText(ctx.weights)
  local candidates = 0
  for _, entry in ipairs(ctx.candidateLists) do candidates = candidates + #entry.list end
  out.amtCandidates = candidates
  for _, n in ipairs(ctx.skippedNotes or {}) do Note(notes, "AMT skipped: " .. tostring(n)) end

  local baseline = Evaluate(ctx, {})
  if baseline == nil or baseline == -math.huge then
    Note(notes, "baseline rejected by EvaluatePlan; 0 as in SearchBestPlan")
    baseline = 0
  end
  local items = ToItems(ctx, request, plan, out)
  local score, yieldsByItem, accepted = EvaluateAccepted(ctx, items, out)
  if score == nil then score = baseline end
  local hub = HubBonus(ctx, accepted)
  score = score + hub
  out.score, out.baseline, out.gain = score, baseline, score - baseline
  out.illegal = #out.rejected
  out.scored = #accepted
  -- The same objective over the accepted items AMT's requests cover (one
  -- per request, in plan order): what AMT could have placed for this input.
  local inside = {}
  for _, item in ipairs(accepted) do
    if item.cmpInRequest then inside[#inside + 1] = item end
  end
  if #inside == #accepted then
    out.gainInRequests = out.gain
  else
    local scratch = { rejected = {} }
    local s2, _, kept = EvaluateAccepted(ctx, inside, scratch)
    out.gainInRequests = (s2 or baseline) + HubBonus(ctx, kept) - baseline
  end

  -- Breakdown: each item's own weighted DMT yields x AMT's multiplier; the
  -- rest of the gain is the fixed subjects' change, the tile yields taken,
  -- layout terms and wonder effects.
  local parts = { items = {}, itemsTotal = 0, placedByPriority = {} }
  for i, item in ipairs(accepted) do
    local yields = (yieldsByItem or {})[i] or {}
    local weighted = 0
    local keys = {}
    for y in pairs(yields) do keys[#keys + 1] = y end
    table.sort(keys)
    local shown = {}
    for _, y in ipairs(keys) do
      weighted = weighted + yields[y] * (ctx.weights[y] or 1)
      shown[y] = yields[y]
    end
    local m = Multiplier(item)
    parts.items[#parts.items + 1] = { type = item.subjectKey, x = item.x, y = item.y, yields = shown,
      multiplier = m, order = item.specialtyOrder, contribution = weighted * m, inRequest = item.cmpInRequest }
    parts.itemsTotal = parts.itemsTotal + weighted * m
    if item.subjectType == "DISTRICT" and item.districtPriority then
      local pr = tostring(math.max(1, math.min(99, math.floor(item.districtPriority))))
      parts.placedByPriority[pr] = (parts.placedByPriority[pr] or 0) + 1
    end
  end
  parts.governmentHubBonus = hub
  parts.other = out.gain - parts.itemsTotal - hub
  if ctx.budget then
    -- AMT's specialty-district budget for this city (slots the player set,
    -- population budget): it never places more new ones than `available`.
    parts.specialtyBudget = { available = ctx.budget.available, totalSlots = ctx.budget.totalSlots,
      existing = ctx.budget.existingSlots, targetPopulation = ctx.budget.targetPopulation }
  end
  out.parts = parts
  return out
end
