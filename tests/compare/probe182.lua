-- probe182.lua: issue 182, a district supplied for a wonder on the
-- several-cities tab against one of the cities' candidates standing next to
-- the wonder.
--
--   node tools/compare.mjs --probe tests/compare/probe182.lua --arg '<scene> <wonder,...> [TIER=STANDARD] [COUNT=3]'
--
-- The tab's default request: every city of the scene takes part, the shared
-- list with every district that takes population as a candidate (no
-- required ones), COUNT districts more per city, land on. Solved three ways:
--   BEFORE  one solve: the district supplied to the first city that can take it
--   AFTER   SolveNow: supplied again to another city that picks one from its
--           candidates in the first plan, the better plan kept (again: none,
--           kept, moved)
-- Prints one "ROW {json}" line per way.

include("cmp_lib")

local arg = PROBE_ARG or ""
local words, tier, count = {}, "STANDARD", 3
for word in arg:gmatch("%S+") do
  if word:match("^TIER=") then tier = word:sub(6)
  elseif word:match("^COUNT=") then count = tonumber(word:sub(7))
  else words[#words + 1] = word end
end
local id, list = words[1], words[2] or "BUILDING_COLOSSEUM"

local NAMES = { "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
  "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Remind", "SDP_Pins" }

local scn, w, request = CmpRun.Setup(id)
include("MapTacks")
for _, name in ipairs(NAMES) do include(name) end
w.Events.LoadGameViewStateDone()

local wonders = {}
for t in list:gmatch("[^,]+") do wonders[#wonders + 1] = t end
local pool = {}
for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do
  if d.Specialty and not (d.MaxPerPlayer and d.MaxPerPlayer > 0) then pool[#pool + 1] = d.Type end
end
local existing = {}
for _, city in ipairs(request.cities) do existing[city:GetID()] = true end

local function Encode(v)
  local t = type(v)
  if t == "table" then
    local parts, isList = {}, #v > 0
    if isList then
      for _, x in ipairs(v) do parts[#parts + 1] = Encode(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q:%s", k, Encode(v[k])) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  elseif t == "number" then return string.format("%.4f", v)
  elseif t == "boolean" then return tostring(v) end
  return "null"
end

local function Request(extra)
  local r = { PlayerID = 0, Tier = tier, Districts = {}, Pool = pool, Count = count, Existing = existing,
    Wonders = wonders, Weights = request.weights }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local function Row(way, r, poolable, calls)
  local row = { scene = id, way = way, wonders = list, ok = r.Ok, gain = r.Gain, adjacency = r.Adjacency, calls = calls,
    again = poolable }
  if not r.Ok then row.error = tostring(r.Error) end
  local placedWonders, perCity, wonderAt, near = 0, {}, {}, {}
  for _, p in ipairs(r.Plan or {}) do
    if p.Kind == "WONDER" then
      placedWonders = placedWonders + 1
      wonderAt[p.Type] = p
    else
      perCity[p.City] = (perCity[p.City] or 0) + 1
    end
  end
  row.wondersPlaced = placedWonders
  local counts = {}
  for _, c in ipairs(r.Cities or {}) do counts[#counts + 1] = perCity[c.Key] or 0 end
  row.perCity = counts
  -- Districts next to each placed wonder of the type it needs, and how many
  -- of each type were planned in all.
  local types = {}
  for _, p in ipairs(r.Plan or {}) do
    if p.Kind ~= "WONDER" then types[p.Type] = (types[p.Type] or 0) + 1 end
  end
  for wt, wp in pairs(wonderAt) do
    local need = GameInfo.Buildings[wt].AdjacentDistrict
    if need ~= nil then
      local n = 0
      for _, p in ipairs(r.Plan or {}) do
        if p.Kind ~= "WONDER" and SDP_Rules.BaseDistrict(p.Type) == need and Map.GetPlotDistance(p.X, p.Y, wp.X, wp.Y) == 1 then
          n = n + 1
        end
      end
      near[wt] = n
      local all = 0
      for t, c in pairs(types) do
        if SDP_Rules.BaseDistrict(t) == need then all = all + c end
      end
      row["planned_" .. need] = all
    end
  end
  row.near = near
  row.supplied = #(r.Supplied or {})
  local unplaced = {}
  for _, u in ipairs(r.Unplaced or {}) do unplaced[#unplaced + 1] = tostring(u.Type) .. ":" .. tostring(u.Reason) end
  row.unplaced = unplaced
  print("ROW " .. Encode(row))
end

local function Run(way, again)
  SDP_Multi.SUPPLY_AGAIN = again
  local ok, r = pcall(SDP_Overlay.With, 0, SDP_Multi.SolveNow, Request())
  if not ok then r = { Ok = false, Error = r } end
  local stats = r.Stats or {}
  local calls = stats.Calls
  if stats.Again ~= nil then calls = calls + stats.Again.Calls end
  Row(way, r, stats.Again and (stats.Again.Moved and "moved" or "kept") or "none", calls)
end

Run("BEFORE", false)
Run("AFTER", true)
