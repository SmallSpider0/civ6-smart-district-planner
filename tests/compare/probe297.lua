-- probe297.lua: issue 297, what coastal sites have against river and dry ones.
--
--   node tools/compare.mjs --probe tests/compare/probe297.lua --arg '<scene>'
--
-- Solves the scene with the sites tab's defaults (the default district grid,
-- 3 per site, distance cost 0.5) and prints, for every refined site, its
-- parts in points (as the score adds them) and in per-turn values, its water,
-- whether it is next to the sea, the sea plots among the plots it works and
-- its visible luxury and strategic plots. One "ROW {json}" line per site.

include("cmp_lib")

local id = PROBE_ARG or ""
local scn, w, request = CmpRun.Setup(id)
include("MapTacks")
for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land",
    "SDP_Appeal", "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Sites",
    "SDP_SiteSolver" }) do
  include(name)
end
w.Events.LoadGameViewStateDone()

local PARTS = { "District", "Farm", "Feature", "Water", "Luxury", "Strategic", "Appeal", "Penalty" }
local function Round(x) return math.floor(x * 100 + 0.5) / 100 end
local function Print(row) print("ROW " .. CmpRun.Json.Encode(row)) end

local grid = SDP_Sites.DefaultDistricts(0, 3)
local result = SDP_SiteSolver.Solve({ PlayerID = 0, Tier = "STANDARD", K = request.sites.count, D = request.sites.distance,
  Districts = grid.Districts, Pool = grid.Pool, Pick = grid.Pick, Distance = SDP_Sites.DEFAULT_DISTANCE })
if not result.Ok then
  Print({ scene = id, error = tostring(result.Error) })
  return
end
local session = result.Session
local ctx = session.Ctx
local chosen = {}
for _, s in ipairs(result.Solutions[1] and result.Solutions[1].Sites or {}) do chosen[s.Index] = true end
for _, site in ipairs(session.Order or {}) do
  if site.Fine ~= nil and site.CenterLegal then
    local parts, raw = {}, {}
    for _, key in ipairs(PARTS) do parts[key] = Round(site.Parts[key] or 0) end
    -- Per-turn values: the points divided by the part's points per unit.
    local unit = { District = ctx.Items.DISTRICT, Farm = ctx.Items.LAND, Feature = ctx.Items.FEATURE,
      Water = ctx.Items.HOUSING, Luxury = ctx.Items.AMENITY, Strategic = ctx.Items.STRATEGIC }
    for key, u in pairs(unit) do raw[key] = (u ~= 0) and Round((site.Parts[key] or 0) / u) or 0 end
    -- The plots it works: its best P by value (SDP_Land.Model sorts them).
    local sea, worked = 0, 0
    for _, p in ipairs(site.Land.Plots) do
      if worked < site.Land.P then
        worked = worked + 1
        if Map.GetPlotByIndex(p.Index):IsWater() then sea = sea + 1 end
      end
    end
    local seaAll = 0
    for _, p in ipairs(site.Land.Plots) do
      if Map.GetPlotByIndex(p.Index):IsWater() then seaAll = seaAll + 1 end
    end
    local lux, strat = 0, 0
    for _, r in ipairs(site.Resources) do
      if r.Luxury then lux = lux + 1 else strat = strat + 1 end
    end
    local harbor = false
    for _, d in ipairs(site.Districts or {}) do
      if ctx.CoastDistricts[d.Type] then harbor = true end
    end
    Print({ scene = id, site = site.X .. "," .. site.Y, chosen = chosen[site.Index] == true,
      water = site.Info.WaterKind, coastal = Map.GetPlot(site.X, site.Y):IsCoastalLand(), harbor = harbor,
      housing = site.Info.Housing, parts = parts, raw = raw, fine = Round(site.Fine), P = site.Land.P,
      seaWorked = sea, seaPlots = seaAll, plots = #site.Land.Plots, luxuryPlots = lux, strategicPlots = strat })
  end
end
