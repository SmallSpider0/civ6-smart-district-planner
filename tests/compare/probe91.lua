-- probe91.lua: issue 91, how each weight moves the single-city and the
-- several-cities objective.
--
--   node tools/compare.mjs --probe probe91.lua --arg 'SINGLE <scene> [<district,...>] [|<variation names>]'
--   node tools/compare.mjs --probe probe91.lua --arg 'MULTI <scene> [|<variation names>]'
--
-- One world per scene. The default settings (yields 1, land 1, housing 1,
-- distance 0, coverage 0, standard tier) are solved first; every variation
-- changes one setting from there. Each plan is reported with its own
-- objective's parts and rescored on the default session (adjacency with all
-- weights 1, land part with land weight 1), so plans are compared on one
-- ruler. Prints one "ROW {json}" line per run.

include("cmp_lib")

local arg = PROBE_ARG or ""
local head, wanted = arg:match("^([^|]*)|?(.*)$")
local words = {}
for word in head:gmatch("%S+") do words[#words + 1] = word end
local mode, id, list = words[1], words[2], words[3]

local NAMES = { "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
  "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi" }
local YIELDS = { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION" }

local scn, w, request = CmpRun.Setup(id)
include("MapTacks")
for _, name in ipairs(NAMES) do include(name) end
w.Events.LoadGameViewStateDone()

local districts = request.districts
if list ~= nil and list ~= "" then
  districts = {}
  for t in list:gmatch("[^,]+") do districts[#districts + 1] = t end
end

local function Defaults()
  return { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1, LAND = 1,
    HOUSING = 1, DISTANCE = 0, COVERAGE = 0 }
end

-- Variations: name -> changes from the defaults.
local VARIATIONS = { { "default", {} } }
for _, y in ipairs(YIELDS) do
  for _, v in ipairs({ 0, 3 }) do
    VARIATIONS[#VARIATIONS + 1] = { y:gsub("YIELD_", ""):lower() .. "=" .. v, { [y] = v } }
  end
end
for _, v in ipairs({ 0, 0.5, 2, 3 }) do VARIATIONS[#VARIATIONS + 1] = { "land=" .. v, { LAND = v } } end
for _, v in ipairs({ 0, 3 }) do VARIATIONS[#VARIATIONS + 1] = { "housing=" .. v, { HOUSING = v } } end
for _, v in ipairs({ 0.5, 1, 3 }) do VARIATIONS[#VARIATIONS + 1] = { "distance=" .. v, { DISTANCE = v } } end
for _, v in ipairs({ 1, 3 }) do VARIATIONS[#VARIATIONS + 1] = { "coverage=" .. v, { COVERAGE = v } } end
VARIATIONS[#VARIATIONS + 1] = { "preset=science", { YIELD_SCIENCE = 1.5 } }
VARIATIONS[#VARIATIONS + 1] = { "preset=culture", { YIELD_CULTURE = 3 } }
VARIATIONS[#VARIATIONS + 1] = { "preset=religion", { YIELD_FAITH = 3 } }
VARIATIONS[#VARIATIONS + 1] = { "preset=halfgoldfaith", { YIELD_GOLD = 0.5, YIELD_FAITH = 0.5 } }

local only = nil
if wanted ~= nil and wanted ~= "" then
  only = {}
  for name in wanted:gmatch("[^,]+") do only[name] = true end
end

local function Solve(settings)
  local weights = {}
  for k, v in pairs(settings) do weights[k] = v end
  if mode == "SINGLE" then
    return SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Districts = districts, Weights = weights,
      Land = settings.LAND > 0, Distance = settings.DISTANCE, Coverage = settings.COVERAGE, Tier = "STANDARD",
      Remind = false, Apart = true, AllowFeatureRemoval = true, Auto = { DISTRICT_AQUEDUCT = true, DISTRICT_BATH = true,
        DISTRICT_DAM = true } })
  end
  local existing = {}
  for _, city in ipairs(request.cities) do existing[city:GetID()] = true end
  return SDP_Multi.Solve({ PlayerID = 0, Tier = "STANDARD", Districts = districts, Existing = existing, Weights = weights,
    Land = settings.LAND > 0, Distance = settings.DISTANCE, Coverage = settings.COVERAGE, Remind = false, Apart = true,
    Auto = { DISTRICT_AQUEDUCT = true, DISTRICT_BATH = true, DISTRICT_DAM = true } })
end

-- The layout of `plan` on `session`'s search (slots matched by type and city).
local function LayoutOf(session, plan)
  local search = session.Search
  local layout = {}
  for m = 1, search.K do
    layout[m] = 0
    local key = nil
    if mode == "MULTI" then
      local spec = session.SlotSpecs[search.SlotIndex[m]]
      key = spec.Group and session.Participants[spec.Group].Key or nil
    end
    for _, p in ipairs(plan) do
      if p.Type == search.Types[m] and (mode == "SINGLE" or p.City == key) then
        for i, c in ipairs(search.Candidates) do
          if c.Index == p.Index then layout[m] = i end
        end
      end
    end
  end
  return layout
end

local function Round(x) return x and math.floor(x * 1000 + 0.5) / 1000 or nil end

local base = nil
local function Report(name, settings, r)
  local row = { scene = id, mode = mode, name = name, ok = r.Ok, error = r.Error }
  if not r.Ok then
    print("ROW " .. CmpRun.Json.Encode(row))
    return
  end
  row.gain, row.adjacency, row.land = Round(r.Gain), Round(r.Adjacency), Round(r.LandDelta)
  row.appeal, row.cost, row.coverage = Round(r.AppealDelta or 0), Round(r.CostDelta or 0), Round(r.CoverageDelta or 0)
  row.improvementHousing = r.ImprovementHousing
  row.plan, row.yields = {}, {}
  local ownScore = 0
  for _, p in ipairs(r.Plan) do
    row.plan[#row.plan + 1] = string.format("%s%s@%d,%d", p.City and (p.City .. ":") or "", (p.Type:gsub("DISTRICT_", "")),
      p.X, p.Y)
    for _, y in ipairs(YIELDS) do
      local v = p.Yields and p.Yields[y] or 0
      if v ~= 0 then row.yields[y] = (row.yields[y] or 0) + v end
    end
    if p.Housing ~= nil then row.housing = (row.housing or 0) + p.Housing end
    ownScore = ownScore + (p.Score or 0)
  end
  row.neighbours = Round(r.Adjacency - ownScore)
  row.reminders = #(r.Remind or {})
  local unplaced = {}
  for _, u in ipairs(r.Unplaced or {}) do unplaced[#unplaced + 1] = (u.Type:gsub("DISTRICT_", "")) .. ":" .. tostring(u.Reason) end
  row.unplaced = unplaced
  if r.Covered ~= nil then row.covered = type(r.Covered) == "table" and #r.Covered or r.Covered end
  if base == nil then
    base = r
  else
    -- Rescore on the default session.
    local session, search = base.Session, base.Session.Search
    local layout = LayoutOf(session, r.Plan)
    local g, adj, land, appeal = SDP_Overlay.With(0, function()
      search.Board:Clear()
      local gain = search:Evaluate(layout)
      local a = search.Board:Total()
      search.Board:Clear()
      return gain, a, search:LandDelta(layout), search:AppealDelta(layout)
    end)
    row.onDefault = { objective = Round(g), adjacency = Round(adj), land = Round(land), appeal = Round(appeal) }
    local moved = 0
    local baseAt = {}
    for _, p in ipairs(base.Plan) do baseAt[(p.City or "") .. p.Type] = p.Index end
    for _, p in ipairs(r.Plan) do
      if baseAt[(p.City or "") .. p.Type] ~= p.Index then moved = moved + 1 end
    end
    row.moved = moved
    -- The default plan under this setting's objective (on this run's session).
    local here = r.Session
    if here ~= nil and here.Search ~= nil then
      local layoutHere = LayoutOf(here, base.Plan)
      row.basePlanHere = Round(SDP_Overlay.With(0, function()
        here.Search.Board:Clear()
        local gain, legal = here.Search:Evaluate(layoutHere)
        here.Search.Board:Clear()
        return legal and gain or nil
      end))
    end
  end
  print("ROW " .. CmpRun.Json.Encode(row))
end

for _, v in ipairs(VARIATIONS) do
  local name, changes = v[1], v[2]
  if name == "default" or only == nil or only[name] then
    local settings = Defaults()
    for k, x in pairs(changes) do settings[k] = x end
    Report(name, settings, Solve(settings))
  end
end
