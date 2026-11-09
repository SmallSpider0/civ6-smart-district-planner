-- probe359.lua: issue 359, "at least N of the taking-part cities build
-- district X" on the several-cities tab, the planner choosing which cities.
--
--   node tools/compare.mjs --probe tests/compare/probe359.lua --arg '<scene> <DISTRICT_X:N,...> [TIER=STANDARD] [COUNT=3]'
--
-- The tab's default request (every city of the scene takes part, the shared
-- list with every district that takes population as a candidate, the count
-- COUNT as a target, land, swap, improvements on). For each constraint:
--   BASE    the default request; how many cities have X (built, pinned or planned)
--   HOSTS   when fewer than N: every set of hosts among the cities without X,
--           X required there (a list of their own), a candidate elsewhere,
--           each a whole solve
-- and per city the values a cheap rule could pick hosts by: distance from
-- the centre (the capital), production (SDP_Multi.Production), the best
-- value X has on one tile alone (Search.Single). Prints "ROW {json}" lines.

include("cmp_lib")

local arg = PROBE_ARG or ""
local words, tier, count = {}, "STANDARD", 3
for word in arg:gmatch("%S+") do
  if word:match("^TIER=") then tier = word:sub(6)
  elseif word:match("^COUNT=") then count = tonumber(word:sub(7))
  else words[#words + 1] = word end
end
local id, list = words[1], words[2] or "DISTRICT_CAMPUS:2"

local NAMES = { "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
  "SDP_Improve", "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Remind", "SDP_Pins" }

local scn, w, request = CmpRun.Setup(id)
include("MapTacks")
for _, name in ipairs(NAMES) do include(name) end
w.Events.LoadGameViewStateDone()

local plannable = SDP_Rules.PlannableDistricts(0)
local pool = {}
for _, d in ipairs(plannable) do
  if d.Specialty and not (d.MaxPerPlayer and d.MaxPerPlayer > 0) and SDP_Appeal.Rules().Tiles[d.Type] == nil then
    pool[#pool + 1] = d.Type
  end
end
-- The civilization's own type for a base type (Korea: the Seowon).
local function Own(base)
  local own = nil
  for _, d in ipairs(plannable) do
    if SDP_Rules.BaseDistrict(d.Type) == base then
      if own == nil or d.Type ~= base then own = d.Type end
    end
  end
  return own
end
local existing, keys = {}, {}
for _, city in ipairs(request.cities) do
  existing[city:GetID()] = true
  keys[#keys + 1] = "C" .. city:GetID()
end
local capital = Players[0]:GetCities():GetCapitalCity()
local center = capital and ("C" .. capital:GetID()) or keys[1]

local function Encode(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    if #v > 0 then
      for _, x in ipairs(v) do parts[#parts + 1] = Encode(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local ks = {}
    for k in pairs(v) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    for _, k in ipairs(ks) do parts[#parts + 1] = string.format("%q:%s", k, Encode(v[k])) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  elseif t == "number" then return string.format("%.4f", v)
  elseif t == "boolean" then return tostring(v) end
  return "null"
end

local function Request(extra)
  local r = { PlayerID = 0, Tier = tier, Districts = {}, Pool = pool, Count = count, Target = true,
    Existing = existing, Weights = request.weights, Land = true, Swap = true, Apart = true,
    Improvements = true, Center = center }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local function Solve(r)
  local t0 = os.clock()
  local ok, result = pcall(SDP_Overlay.With, 0, SDP_Multi.SolveNow, r)
  local seconds = os.clock() - t0
  if not ok then return { Ok = false, Error = tostring(result) }, seconds end
  return result, seconds
end

-- Cities that have X: built or pinned (the scan), or planned.
local function Having(r, x)
  local have, planned = {}, {}
  local session = r.Session
  for _, part in ipairs(session and session.Participants or {}) do
    if part.Present[x] or SDP_City.TackedDistricts(part.Scan)[x] then have[part.Key] = true end
  end
  for _, p in ipairs(r.Plan or {}) do
    if p.Kind ~= "WONDER" and p.Type == x then planned[p.City] = true end
  end
  return have, planned
end

local function Calls(r)
  local stats = r.Stats or {}
  return (stats.Calls or 0) + (stats.Hosts and stats.Hosts.Calls or 0) + (stats.Again and stats.Again.Calls or 0)
end

local function Combos(items, k)
  local out = {}
  local function Rec(start, chosen)
    if #chosen == k then
      local c = {}
      for i, v in ipairs(chosen) do c[i] = v end
      out[#out + 1] = c
      return
    end
    for i = start, #items do
      chosen[#chosen + 1] = items[i]
      Rec(i + 1, chosen)
      chosen[#chosen] = nil
    end
  end
  Rec(1, {})
  return out
end

local base, baseSeconds = Solve(Request())
local session = base.Session
-- Per city: distance from the centre, production.
local info = {}
local cx, cy
for _, part in ipairs(session.Participants) do
  if part.Key == center then cx, cy = part.X, part.Y end
end
for p, part in ipairs(session.Participants) do
  info[part.Key] = { p = p, distance = Map.GetPlotDistance(cx, cy, part.X, part.Y),
    production = SDP_Multi.Production(0, part), placed = 0 }
end
for _, e in ipairs(base.Plan or {}) do
  if e.Kind ~= "WONDER" and info[e.City] then info[e.City].placed = info[e.City].placed + 1 end
end

for spec in list:gmatch("[^,]+") do
  local baseType, n = spec:match("^([%w_]+):(%d+)$")
  n = tonumber(n)
  local x = Own(baseType)
  if x == nil then
    print("ROW " .. Encode({ scene = id, x = baseType, n = n, skip = "not plannable" }))
  else
    -- Best single value of X per city (the base session's optional slot).
    local search = session.Search
    local single = {}
    for m = 1, search.K do
      if search.Types[m] == x then
        local key = session.Participants[search.Groups[m]].Key
        local best = nil
        for i = 1, search.N do
          if search.Legal[m][i] and (best == nil or search.Single[m][i] > best) then best = search.Single[m][i] end
        end
        single[key] = best
      end
    end
    local have, planned = Having(base, x)
    local nHave, nPlanned, lacking = 0, 0, {}
    for _, key in ipairs(keys) do
      if have[key] then nHave = nHave + 1
      elseif planned[key] then nPlanned = nPlanned + 1 end
      if not have[key] then lacking[#lacking + 1] = key end
    end
    local cities = {}
    for _, key in ipairs(keys) do
      cities[key] = { distance = info[key].distance, production = info[key].production, single = single[key],
        have = have[key] == true, planned = planned[key] == true }
    end
    local row = { scene = id, x = x, n = n, cities = cities, baseGain = base.Gain, baseCalls = Calls(base),
      baseSeconds = baseSeconds, have = nHave, planned = nPlanned, center = center }
    local need = n - nHave
    if nHave + nPlanned >= n then
      row.free = true
    elseif #lacking < need then
      row.impossible = true
    else
      -- Hosts among the cities without X; X required there, a candidate elsewhere.
      local sets = {}
      for _, hosts in ipairs(Combos(lacking, need)) do
        local plans = {}
        for _, key in ipairs(hosts) do plans[key] = { x } end
        local r, seconds = Solve(Request({ Plans = plans }))
        local h, pl = Having(r, x)
        local with = 0
        for _, key in ipairs(keys) do
          if h[key] or pl[key] then with = with + 1 end
        end
        local unplaced = {}
        for _, u in ipairs(r.Unplaced or {}) do unplaced[#unplaced + 1] = tostring(u.City) .. ":" .. tostring(u.Type) .. ":" .. tostring(u.Reason) end
        sets[#sets + 1] = { hosts = hosts, ok = r.Ok, gain = r.Gain, calls = Calls(r), seconds = seconds, with = with,
          unplaced = unplaced, error = r.Ok and nil or tostring(r.Error) }
      end
      row.sets = sets
    end
    print("ROW " .. Encode(row))
  end
end
