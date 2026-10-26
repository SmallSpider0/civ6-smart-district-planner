-- issue 91: the land model of a scene's city (P, plots, cut, losses of the default plan's plots).
include("cmp_lib")
local id = PROBE_ARG
local scn, w, request = CmpRun.Setup(id)
include("MapTacks")
for _, n in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
  "SDP_Coverage", "SDP_Search", "SDP_Solver" }) do include(n) end
w.Events.LoadGameViewStateDone()
local r = SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Districts = request.districts, Weights = { LAND = 1 },
  Land = true, Tier = "STANDARD", Auto = { DISTRICT_AQUEDUCT = true, DISTRICT_BATH = true, DISTRICT_DAM = true } })
local land = r.Session.Land
local vals = {}
for i, p in ipairs(land.Plots) do vals[i] = string.format("%.2f", p.Tile) end
print(string.format("%s pop %d P %d workable %d base %.2f", id, request.target:GetPopulation(), land.P, #land.Plots, land.Base))
print("values best first: " .. table.concat(vals, " "))
for _, p in ipairs(r.Plan) do
  local q = land.ByIndex[p.Index]
  local plot = Map.GetPlotByIndex(p.Index)
  local f = plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()].FeatureType or "-"
  local res = plot:GetResourceType() ~= -1 and GameInfo.Resources[plot:GetResourceType()].ResourceType or "-"
  print(string.format("  %-28s (%d,%d) %s %s %s tile %.2f loss %.2f adj score %.1f", p.Type, p.X, p.Y,
    GameInfo.Terrains[plot:GetTerrainType()].TerrainType, f, res, q and q.Tile or -1, land.Loss[p.Index] or -1, p.Score or 0))
end
print(string.format("  gain %.2f adjacency %.2f land %.2f", r.Gain, r.Adjacency, r.LandDelta))
local kinds = {}
for _, p in ipairs(land.Plots) do
  local plot = Map.GetPlotByIndex(p.Index)
  local k = string.format("%.2f %s %s %s y%d/%d/%d", p.Tile, GameInfo.Terrains[plot:GetTerrainType()].TerrainType,
    plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()].FeatureType or "-",
    plot:GetResourceType() ~= -1 and GameInfo.Resources[plot:GetResourceType()].ResourceType or "-",
    plot:GetYield(0), plot:GetYield(1), plot:GetYield(2))
  kinds[k] = (kinds[k] or 0) + 1
end
local ks = {}
for k in pairs(kinds) do ks[#ks + 1] = k end
table.sort(ks)
for _, k in ipairs(ks) do print("   " .. kinds[k] .. " x " .. k) end
