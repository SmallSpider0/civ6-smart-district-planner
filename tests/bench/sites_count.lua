-- How the City sites tab's "Districts count" changes its solve time (issue
-- 124). Run in the SDP_Panel state by tests/bench/sites_count.py on a loaded
-- game. Loading this file defines SDP_SitesCount; the driver calls one
-- function per Tuner request and times it (Lua timers are whole seconds).
-- Every report prints one line "SDP_SCOUNT {json}".
--   Setup(count)  the tab at its defaults (Standard tier, 3 new cities,
--                 distance 5, the Balanced preset, every district at its
--                 default state) with this Districts count; reports the request
--   Solve()       the tab's request solved at once with SDP_SiteSolver.Solve,
--                 the call of the stress test's "sites 3 within 5" step
--   Restore()     the count back to its default
-- Changes the tab's settings in memory and in the game's settings store
-- (do not save the game afterwards).
SDP_SitesCount = {}
local C = SDP_SitesCount
local pid = Game.GetLocalPlayer()
local P = SDP_PageSites

local function Json(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.10g", v)
  end
  if t == "string" then
    local q = string.format("%q", v):gsub("\\\n", "\\n")
    return (q:gsub("%c", function(c) return string.format("\\u%04x", c:byte()) end))
  end
  if t == "boolean" then return tostring(v) end
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do parts[i] = Json(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q", k) .. ":" .. Json(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function Emit(t) print("SDP_SCOUNT " .. Json(t)) end

function C.Setup(count)
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do P.SetState(d.Type, P.DefaultState(d)) end
  P.SetCount(3)
  P.SetDistance(5)
  P.SetTier("STANDARD")
  P.SetPreset("BALANCED")
  P.SetDistrictCount(count)
  local r = P.Request()
  C.Request = r
  Emit({ Step = "Setup", Count = count, Tier = r.Tier, K = r.K, D = r.D, Must = r.Districts, Pool = r.Pool, Pick = r.Pick,
    Distance = r.Distance })
end

function C.Solve()
  local r = SDP_SiteSolver.Solve(C.Request)
  local sites, keys = (r.Ok and r.Solutions[1] and r.Solutions[1].Sites) or {}, {}
  for i, s in ipairs(sites) do keys[i] = s.X .. "," .. s.Y end
  Emit({ Step = "Solve", Ok = r.Ok == true, Error = r.Error and tostring(r.Error) or nil, Found = #sites,
    Solutions = r.Ok and #r.Solutions or 0, Calls = r.Stats and r.Stats.Calls or nil, Sites = table.concat(keys, " ") })
end

function C.Restore()
  P.SetDistrictCount(SDP_Sites.DEFAULT_COUNT)
  Emit({ Step = "Restore" })
end
