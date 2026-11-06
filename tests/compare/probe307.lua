-- probe307.lua: issue 307, many wonders over several cities hang the game.
--
--   node tools/compare.mjs --probe tests/compare/probe307.lua --arg 'cities=6,wonders=19,tier=STANDARD'
--
-- Six (or `cities`) Roman cities on a made-up map with every terrain the
-- wonders want, real rules and DMT. The Several cities tab's request (its
-- defaults: four districts each, land part, improvements) with the first
-- `wonders` wonders the player can build (0: none, all: every one) runs as
-- the panel runs it, an SDP_Task job one slice per frame at the largest
-- quota (SDP_Task.MAX_QUOTA). Printed: per slice the units the task counted,
-- the DMT calls made and the seconds; the worst slice, the totals, and the
-- solves the request took (SolveNow's retries). `cap` (seconds, default 900)
-- stops a run that does not end.

include("cmp_lib")

local args = {}
for k, v in string.gmatch(PROBE_ARG or "", "(%w+)=([%w_]+)") do args[k] = v end
local nCities = tonumber(args.cities or "6")
local nWonders = args.wonders or "19"
local tier = args.tier or "STANDARD"
local cap = tonumber(args.cap or "900")
local quota = tonumber(args.quota or "2000")

local Wd, Ht = 30, 22
local function Idx(x, y) return y * Wd + x end
local plots = {}
local seed = 307
local function Rand() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
local TERRAINS = { "TERRAIN_GRASS", "TERRAIN_GRASS", "TERRAIN_PLAINS", "TERRAIN_PLAINS", "TERRAIN_DESERT",
  "TERRAIN_GRASS_HILLS", "TERRAIN_PLAINS_HILLS", "TERRAIN_DESERT_HILLS", "TERRAIN_TUNDRA", "TERRAIN_GRASS_MOUNTAIN" }
for y = 0, Ht - 1 do
  for x = 0, Wd - 1 do
    local t = TERRAINS[1 + math.floor(Rand() * #TERRAINS)]
    local p = { t = t }
    if (t == "TERRAIN_GRASS" or t == "TERRAIN_PLAINS") and Rand() < 0.2 then p.f = "FEATURE_FOREST" end
    if x <= 1 or y <= 1 or x >= Wd - 2 or y >= Ht - 2 then p = { t = (x == 0 or y == 0 or x == Wd - 1 or y == Ht - 1) and "TERRAIN_OCEAN" or "TERRAIN_COAST" } end
    plots[Idx(x, y) + 1] = p
  end
end
-- A lake in the middle.
plots[Idx(14, 10) + 1] = { t = "TERRAIN_COAST" }
plots[Idx(15, 10) + 1] = { t = "TERRAIN_COAST" }
local CENTERS = { { 6, 6 }, { 13, 6 }, { 20, 6 }, { 6, 14 }, { 13, 14 }, { 20, 14 }, { 26, 10 }, { 9, 10 } }
local centers = {}
for n = 1, nCities do
  centers[n] = CENTERS[n]
  plots[Idx(CENTERS[n][1], CENTERS[n][2]) + 1] = { t = "TERRAIN_GRASS" }
end
local edges = {}
for y = 3, 18 do edges[#edges + 1] = { Idx(10, y), Idx(11, y) } end
local edges2 = {}
for y = 3, 18 do edges2[#edges2 + 1] = { Idx(17, y), Idx(18, y) } end
local cities = {}
for n, c in ipairs(centers) do
  cities[n] = { id = 65535 + n, owner = 0, x = c[1], y = c[2], name = "CITY_" .. n, population = 12, capital = n == 1,
    plots = {}, districts = {}, buildings = {} }
end
local spec = { width = Wd, height = Ht, plots = plots,
  rivers = { { name = "R1", edges = edges, floodplains = {} }, { name = "R2", edges = edges2, floodplains = {} } },
  players = { { id = 0, civ = "CIVILIZATION_ROME", leader = "LEADER_TRAJAN", techs = "all", civics = "all" } },
  cities = cities, wonders = {}, pins = {} }
CmpScenarios.ById["X307"] = { id = "X307", kind = "multi", path = "custom", spec = spec, civ = "CIVILIZATION_ROME",
  leader = "LEADER_TRAJAN", districts = { "DISTRICT_CAMPUS" } }
local scn, w = CmpRun.Setup("X307")
for _, c in Players[0]:GetCities():Members() do
  for _, e in ipairs(w.Neighbours(Map.GetPlot(c:GetX(), c:GetY()))) do if e:GetOwner() == -1 then e.owner, e.city = 0, c end end
end
include("MapTacks")
for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land",
  "SDP_Appeal", "SDP_Improve", "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Pins", "SDP_Remind", "SDP_Multi" }) do include(name) end
w.Events.LoadGameViewStateDone()

-- The wonders: the first n the player can build, by type.
local wonders = {}
for _, row in ipairs(SDP_Wonders.List(0)) do
  if row.Status == nil then wonders[#wonders + 1] = row.Type end
end
table.sort(wonders)
local available = #wonders
if nWonders ~= "all" then
  local n = tonumber(nWonders)
  while #wonders > n do table.remove(wonders) end
end

-- Count the DMT calls (SDP_Overlay calls the globals by name).
local dmt = 0
local rawYields, rawPlace = GetBonusYields, CanPlacePin
GetBonusYields = function(...) dmt = dmt + 1; return rawYields(...) end
CanPlacePin = function(...) dmt = dmt + 1; return rawPlace(...) end
-- Count the solves (sessions run).
-- Units by phase: Tick adds to the innermost wrapped method running.
local sessions, runs = 0, 0
local stack, phases, phaseSeconds = { "other" }, {}, {}
local switched = nil -- when the top of the stack last changed (nil: between slices)
local function Charge()
  local now = cmp_now()
  if switched ~= nil then
    local key = stack[#stack]
    phaseSeconds[key] = (phaseSeconds[key] or 0) + (now - switched)
  end
  switched = now
end
local function Push(label) Charge(); stack[#stack + 1] = label end
local function Pop() Charge(); stack[#stack] = nil end
local function Wrap(class, name, label)
  local raw = class[name]
  if raw == nil then return end
  class[name] = function(...)
    Push(label)
    local a, b, c, d = raw(...)
    Pop()
    return a, b, c, d
  end
end
local wrapped = false
local allSessions = {}
local assignCalls, groupCalls = 0, 0
local rawNew = SDP_Multi.NewSession
SDP_Multi.NewSession = function(...)
  sessions = sessions + 1
  Push("NewSession")
  local s = rawNew(...)
  Pop()
  allSessions[#allSessions + 1] = s
  if not wrapped and s.Improve ~= nil then
    local Model = getmetatable(s.Improve)
    Model = Model and (Model.__index or Model)
    if Model ~= nil then
      local rawAssign, rawGroup = Model.Assign, Model.AssignGroup
      Model.Assign = function(...) assignCalls = assignCalls + 1; return rawAssign(...) end
      Model.AssignGroup = function(...) groupCalls = groupCalls + 1; return rawGroup(...) end
      Wrap(Model, "AssignGroup", "Improve:AssignGroup")
      Wrap(Model, "Assign", "Improve:Assign")
      Wrap(Model, "Ring2", "Improve:Ring2")
      Wrap(Model, "IsTarget", "Improve:IsTarget")
    end
  end
  if not wrapped then
    wrapped = true
    local Session, Search = getmetatable(s), getmetatable(s.Search)
    Session = Session.__index or Session
    Search = Search.__index or Search
    local rawRun = Session.Run
    Session.Run = function(self, ...) runs = runs + 1; return rawRun(self, ...) end
    for _, name in ipairs({ "RunPrelude", "RunStart", "RunWideJoint", "Repair", "Result", "Polish", "SolveCity",
        "PlanFor", "Distinct" }) do
      Wrap(Session, name, "Session:" .. name)
    end
    for _, name in ipairs({ "Singles", "MeasurePairs", "Shortlist", "Beam", "Exhaustive", "LocalSearch", "Kicks",
        "Untangle", "RunPools", "Evaluate", "Solutions", "ImprovePlan", "SupportPlots", "Reachable", "WondersServed",
        "SharesRiver", "CoverageCount", "CountLayouts", "AllFit", "SolveBlock" }) do
      Wrap(Search, name, "Search:" .. name)
    end
    local Board = getmetatable(s.Board)
    Board = Board.__index or Board
    for _, name in ipairs({ "Total", "Put" }) do Wrap(Board, name, "Board:" .. name) end
    Wrap(SDP_Land, "ScoreTaken", "SDP_Land.ScoreTaken")
    if s.Search.AppealModel ~= nil then
      local Appeal = getmetatable(s.Search.AppealModel)
      Appeal = Appeal and (Appeal.__index or Appeal)
      if Appeal ~= nil then Wrap(Appeal, "Score", "Appeal:Score") end
    end
  end
  return s
end
local function AddPhase(units)
  local key = stack[#stack]
  phases[key] = (phases[key] or 0) + units
end

local existing = {}
for _, c in Players[0]:GetCities():Members() do existing[c:GetID()] = true end
local weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1, LAND = 1,
  COVERAGE = 0, DISTANCE = 0.5 }
local request = { PlayerID = 0, Tier = tier, Target = true,
  Districts = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" },
  Wonders = wonders, Existing = existing, Weights = weights, Land = true, Coverage = 0, Distance = 0.5,
  Remind = true, Apart = true, Swap = true, Improvements = true, WorkedImprovements = false }
local params = SDP_Tiers.Params(SDP_Tiers.Multi, tier)
local estimate = SDP_Multi.EstimateUnits(nCities, 4, #wonders, params, 0, 0)

-- The longest stretch without a Tick: work no quota can split (the frame
-- it falls in is at least that long, whatever the quota).
local lastTick, gaps = nil, {}
local rawTick = SDP_Task.Tick
local function Gap(where)
  local now = cmp_now()
  if lastTick ~= nil then
    local g = now - lastTick
    if #gaps < 12 or g > gaps[#gaps].s then
      local trace = debug and debug.traceback and debug.traceback("", 3) or ""
      trace = trace:gsub("SmartDistrictPlanner/Scripts/", ""):gsub("\n%s*", " | ")
      gaps[#gaps + 1] = { s = g, where = where, trace = trace:sub(1, 400) }
      table.sort(gaps, function(a, b) return a.s > b.s end)
      while #gaps > 12 do table.remove(gaps) end
    end
  end
  lastTick = now
end
SDP_Task.Tick = function(units)
  Gap("tick")
  AddPhase(units)
  return rawTick(units)
end

local result, message
local job = { Name = "planner", PlayerID = 0, Estimate = estimate,
  Run = function() return SDP_Multi.SolveNow(request) end,
  OnDone = function(value) result = value end, OnError = function(value) message = value end }
SDP_Task.Start(job)
local started = cmp_now()
local status = "running"
local worst = { Units = 0, Dmt = 0, Seconds = 0 }
local steps, lastDmt = 0, 0
local log = {}
local hist = { 0, 0, 0, 0, 0 } -- slices over 0.05, 0.2, 0.5, 1, 2 seconds
local LIMITS = { 0.05, 0.2, 0.5, 1, 2 }
while status == "running" do
  local t0 = cmp_now()
  lastTick = t0
  switched = t0
  status = SDP_Task.Step(quota)
  Charge()
  switched = nil
  local dt = cmp_now() - t0
  Gap("end of slice")
  lastTick = nil
  steps = steps + 1
  local units, calls = job.LastUsed or 0, dmt - lastDmt
  lastDmt = dmt
  for k, limit in ipairs(LIMITS) do if dt > limit then hist[k] = hist[k] + 1 end end
  log[#log + 1] = { step = steps, s = dt, u = units, d = calls }
  if dt > worst.Seconds then worst.Seconds, worst.SecondsStep, worst.SecondsUnits, worst.SecondsDmt = dt, steps, units, calls end
  if units > worst.Units then worst.Units = units end
  if calls > worst.Dmt then worst.Dmt, worst.DmtStep = calls, steps end
  if cmp_now() - started > cap then
    SDP_Task.Cancel()
    status = "capped"
  end
end
local total = cmp_now() - started
local evaluations, tries, nodes = 0, 0, 0
for _, one in ipairs(allSessions) do
  evaluations = evaluations + (one.Search.Stats.Evaluations or 0)
  tries = tries + (one.Search.Stats.Tries or 0)
  nodes = nodes + (one.Search.Stats.Nodes or 0)
end
table.sort(log, function(a, b) return a.s > b.s end)
local top = {}
for k = 1, math.min(8, #log) do top[k] = log[k] end
local placed, unplaced = 0, 0
for _, p in ipairs(result and result.Plan or {}) do if p.Kind == "WONDER" or p.Type:find("^BUILDING_") then placed = placed + 1 end end
for _, u in ipairs(result and result.Unplaced or {}) do if tostring(u.Type):find("^BUILDING_") then unplaced = unplaced + 1 end end
print("ROW " .. CmpRun.Json.Encode({ cities = nCities, wonders = #wonders, available = available, tier = tier, status = status,
  error = message, steps = steps, units = job.Units, estimate = job.Estimate, dmt = dmt, seconds = total,
  sessions = sessions, runs = runs, worstSeconds = worst.Seconds, worstSecondsStep = worst.SecondsStep,
  worstSecondsUnits = worst.SecondsUnits, worstSecondsDmt = worst.SecondsDmt, worstUnits = worst.Units,
  worstDmt = worst.Dmt, top = top, gaps = gaps, evaluations = evaluations, tries = tries, nodes = nodes, assignCalls = assignCalls, groupCalls = groupCalls,
  slotsK = allSessions[1] and allSessions[1].Search.K, candidatesN = allSessions[1] and allSessions[1].Search.N,
  phases = phases, phaseSeconds = phaseSeconds, over = hist, wondersPlaced = placed, wondersUnplaced = unplaced,
  gain = result and result.Gain, adjacency = result and result.Adjacency }))
