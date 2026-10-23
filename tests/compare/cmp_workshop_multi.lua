-- cmp_workshop_multi.lua: the Workshop picture "several cities at once": three
-- German cities in a triangle, four plots apart, each asking for a Commercial
-- Hub and a Hansa, planned together and city by city (fine tier, real rules and
-- DMT). Run: node tools/compare.mjs --probe tests/compare/cmp_workshop_multi.lua
-- (tools/workshop.py render does, and draws the two plans).
include("cmp_lib")
local Wd, Ht = 18, 16
local function Idx(x, y) return y * Wd + x end
local plots = {}
local seed = 7
local function Rand() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
for y = 0, Ht - 1 do
  for x = 0, Wd - 1 do
    local r = Rand()
    local p = { t = r < 0.62 and "TERRAIN_GRASS" or (r < 0.9 and "TERRAIN_PLAINS" or "TERRAIN_GRASS_HILLS") }
    if p.t ~= "TERRAIN_GRASS_HILLS" and Rand() < 0.16 then p.f = "FEATURE_FOREST" end
    if x == 0 or y == 0 or x == Wd - 1 or y == Ht - 1 then p = { t = "TERRAIN_COAST" } end
    plots[Idx(x, y) + 1] = p
  end
end
local centers = { { 7, 5 }, { 11, 5 }, { 9, 9 } }
for _, c in ipairs(centers) do plots[Idx(c[1], c[2]) + 1] = { t = "TERRAIN_GRASS" } end
local edges = {}
for y = 3, 12 do edges[#edges + 1] = { Idx(8, y), Idx(9, y) } end
local cities = {}
for n, c in ipairs(centers) do
  cities[n] = { id = 65535 + n, owner = 0, x = c[1], y = c[2], name = "CITY_" .. n, population = 10, capital = n == 1,
    plots = {}, districts = {}, buildings = {} }
end
local spec = { width = Wd, height = Ht, plots = plots, rivers = { { name = "R", edges = edges, floodplains = {} } },
  players = { { id = 0, civ = "CIVILIZATION_GERMANY", leader = "LEADER_BARBAROSSA", techs = "all", civics = "all" } },
  cities = cities, wonders = {}, pins = {} }
CmpScenarios.ById["XT"] = { id = "XT", kind = "multi", path = "custom", spec = spec, civ = "CIVILIZATION_GERMANY",
  leader = "LEADER_BARBAROSSA", districts = { "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" } }
local scn, w = CmpRun.Setup("XT")
-- Each city owns its first ring.
for _, c in Players[0]:GetCities():Members() do
  for _, e in ipairs(w.Neighbours(Map.GetPlot(c:GetX(), c:GetY()))) do if e:GetOwner() == -1 then e.owner, e.city = 0, c end end
end
include("MapTacks")
for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land",
  "SDP_Appeal", "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi" }) do include(name) end
w.Events.LoadGameViewStateDone()
local Wt = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local two = { "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HANSA" }
local existing, plans = {}, {}
for _, c in Players[0]:GetCities():Members() do existing[c:GetID()] = true; plans["C" .. c:GetID()] = two end
local function Show(label, plan, cityOf, gain)
  print("RESULT " .. label .. " " .. tostring(gain))
  for _, p in ipairs(plan) do
    local y = {}
    for k, v in pairs(p.Yields or {}) do if v ~= 0 then y[#y + 1] = k:gsub("YIELD_", "") .. "=" .. v end end
    table.sort(y)
    print(string.format("ITEM %s %s %s %d %d %s", label, tostring(cityOf(p)), p.Type, p.X, p.Y, table.concat(y, ",")))
  end
end
local r = SDP_Multi.Solve({ PlayerID = 0, Tier = "FINE", Districts = {}, Plans = plans, Existing = existing, Land = false, Weights = Wt })
local byKey = {}
for _, c in ipairs(r.Cities or {}) do byKey[c.Key] = c.CityID end
Show("joint", r.Plan or {}, function(p) return byKey[p.City] end, r.Adjacency)
-- City by city: each city alone, the earlier cities' plans kept as pins (what a player gets one city at a time).
-- The six districts are then valued together, as for the joint plan.
local cfg, pins, subjects, owner = PlayerConfigurations[0], {}, {}, {}
for _, c in Players[0]:GetCities():Members() do
  local s = SDP_Solver.Solve({ PlayerID = 0, CityID = c:GetID(), Districts = two, Land = false, Tier = "FINE", Weights = Wt })
  for _, p in ipairs(s.Plan or {}) do
    local pin = cfg:GetMapPin(p.X, p.Y); pin:SetIconName("ICON_" .. p.Type); pin:SetName(""); w.LuaEvents.DMT_MapPinAdded(pin)
    pins[#pins + 1] = pin:GetID()
    subjects[#subjects + 1] = SDP_Overlay.Subject(p.Type, p.X, p.Y)
    owner[#subjects] = c:GetID()
  end
end
for _, id in ipairs(pins) do
  w.LuaEvents.DMT_MapPinRemoved(cfg:GetMapPinID(id)); cfg:DeleteMapPin(id)
end
local final = SDP_Overlay.With(0, SDP_Overlay.Evaluate, subjects, {}, Wt)
local base = SDP_Overlay.With(0, SDP_Overlay.Evaluate, {}, {}, Wt)
local plan = {}
for n, item in ipairs(final.Placements) do
  plan[n] = { Type = subjects[n].Key, X = subjects[n].X, Y = subjects[n].Y, Yields = item.Yields }
end
Show("single", plan, function(p) for n, q in ipairs(plan) do if q == p then return owner[n] end end end, final.Total - base.Total)
print("SINGLE_TOTAL " .. (final.Total - base.Total))
local out = {}
for i = 0, Wd * Ht - 1 do local p = Map.GetPlotByIndex(i); out[#out + 1] = { t = plots[i + 1].t, f = plots[i + 1].f, river = p:IsRiver() } end
print("SPEC " .. CmpRun.Json.Encode({ width = Wd, height = Ht, plots = out, cities = centers }))
