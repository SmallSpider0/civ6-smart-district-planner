-- probe88.lua: issue 88, the city sites score on one per-turn scale.
--
--   node tools/compare.mjs --probe tests/compare/probe88.lua --arg 'SITE <scene> [<x,y>] [|<variation names>]'
--   node tools/compare.mjs --probe tests/compare/probe88.lua --arg 'ALL <scene>'
--
-- SITE: solves the scene with the default weights, takes the site at x,y
-- (default: the first site of the best solution) and scores that same site again under each variation
-- (one weight changed from the default); also solves each variation and
-- says whether the chosen sites change. ALL: the parts of every refined
-- site of the default solve (shares over many sites). Prints one
-- "ROW {json}" line per result.

include("cmp_lib")

local arg = PROBE_ARG or ""
local head, wanted = arg:match("^([^|]*)|?(.*)$")
local words = {}
for word in head:gmatch("%S+") do words[#words + 1] = word end
local mode, id, at = words[1], words[2], words[3]

local scn, w, request = CmpRun.Setup(id)
include("MapTacks")
for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land",
    "SDP_Appeal", "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Sites",
    "SDP_SiteSolver" }) do
  include(name)
end
w.Events.LoadGameViewStateDone()

local PARTS = { "District", "Farm", "Feature", "Water", "Luxury", "Strategic", "Appeal", "Penalty" }

local VARIATIONS = { { "default", {} } }
for _, v in ipairs({ 0.5, 0 }) do VARIATIONS[#VARIATIONS + 1] = { "feature=" .. v, { FEATURE = v } } end
for _, v in ipairs({ 2 }) do VARIATIONS[#VARIATIONS + 1] = { "district=" .. v, { DISTRICT = v } } end
for _, v in ipairs({ 2 }) do VARIATIONS[#VARIATIONS + 1] = { "housing=" .. v, { HOUSING = v } } end
for _, v in ipairs({ 0.5, 2 }) do VARIATIONS[#VARIATIONS + 1] = { "land=" .. v, { LAND = v } } end
for _, v in ipairs({ 2 }) do VARIATIONS[#VARIATIONS + 1] = { "amenity=" .. v, { AMENITY = v } } end
for _, v in ipairs({ 2 }) do VARIATIONS[#VARIATIONS + 1] = { "strategic=" .. v, { STRATEGIC = v } } end
VARIATIONS[#VARIATIONS + 1] = { "mix", { FEATURE = 0.5, DISTRICT = 2, HOUSING = 2 } }

local only = nil
if wanted ~= nil and wanted ~= "" then
  only = {}
  for name in wanted:gmatch("[^,]+") do only[name] = true end
end

local function Weights(changes)
  local out = {}
  for k, v in pairs(SDP_Sites.PRESETS.BALANCED) do out[k] = v end
  for k, v in pairs(changes) do out[k] = v end
  return out
end

-- ALL measures per-turn values (no points: SDP_Sites.ItemWeights).
local function Request(changes)
  return { PlayerID = 0, Tier = "STANDARD", K = request.sites.count, D = request.sites.distance,
    Districts = request.districts, Weights = Weights(changes), Raw = mode == "ALL" }
end

local function Round(x) return math.floor(x * 100 + 0.5) / 100 end

local function Parts(parts)
  local out, total = {}, 0
  for _, key in ipairs(PARTS) do
    local v = parts[key] or 0
    out[key] = Round(v)
    total = total + (key == "Penalty" and -v or v)
  end
  out.Total = Round(total)
  return out
end

local function Print(row) print("ROW " .. CmpRun.Json.Encode(row)) end

-- One site at (x, y) scored as the solver scores a refined site.
local function ScoreSite(changes, x, y)
  local site
  SDP_Overlay.With(0, function()
    local req = Request(changes)
    local ctx = SDP_Sites.Context(0, req)
    local _, centers = SDP_Sites.Candidates(0, { K = req.K, D = req.D })
    site = SDP_Sites.Coarse(ctx, { X = x, Y = y, Index = Map.GetPlotIndex(x, y), Unrevealed = 0 }, centers)
    SDP_Sites.Board(ctx, { site })
    SDP_Sites.Fine(ctx, site, SDP_Tiers.Params(SDP_Tiers.Single, "FAST", SDP_Tiers.Params(SDP_Tiers.Sites, "STANDARD").Site))
    ctx.Board = nil
    site.Ctx = ctx
  end)
  return site
end

local function Chosen(result)
  local list = {}
  for _, s in ipairs((result.Ok and result.Solutions[1] and result.Solutions[1].Sites) or {}) do
    list[#list + 1] = s.X .. "," .. s.Y
  end
  return table.concat(list, " ")
end

local base = SDP_SiteSolver.Solve(Request({}))
if not base.Ok then
  Print({ scene = id, error = base.Error })
  return
end

if mode == "ALL" then
  local ctx = base.Session.Ctx
  for _, site in ipairs(base.Session.Order or {}) do
    if site.Fine ~= nil and site.CenterLegal then
      Print({ scene = id, site = site.X .. "," .. site.Y, parts = Parts(site.Parts), P = site.Land.P,
        districts = #(site.Districts or {}), growth = Round(ctx.Land.Growth), cities = ctx.Cities, water = site.Info.WaterKind })
    end
  end
  return
end

local first = base.Solutions[1].Sites[1]
local x, y = first.X, first.Y
if at ~= nil then
  local ax, ay = at:match("^(%d+),(%d+)$")
  x, y = tonumber(ax), tonumber(ay)
end
local defaultChosen = Chosen(base)
for _, v in ipairs(VARIATIONS) do
  local name, changes = v[1], v[2]
  if only == nil or only[name] or name == "default" then
    local site = ScoreSite(changes, x, y)
    local result = name == "default" and base or SDP_SiteSolver.Solve(Request(changes))
    local info = site.Info
    local resources = {}
    for _, r in ipairs(site.Resources) do resources[#resources + 1] = r.Type .. (r.Luxury and "" or "*") end
    local districts = {}
    for _, d in ipairs(site.Districts or {}) do districts[#districts + 1] = d.Type .. "@" .. d.X .. "," .. d.Y .. "=" .. Round(d.Value) end
    Print({ scene = id, variation = name, site = x .. "," .. y, parts = Parts(site.Parts), water = info.WaterKind,
      housing = info.Housing, features = info.Features, resources = resources, districts = districts,
      P = site.Land.P, plots = #site.Land.Plots, growth = Round(site.Ctx.Land.Growth), cities = site.Ctx.Cities,
      points = site.Ctx.Points, chosen = Chosen(result), changed = Chosen(result) ~= defaultChosen,
      solutionSites = result.Ok and #result.Solutions[1].Sites or 0 })
  end
end
