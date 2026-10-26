-- issue 91: the appeal part of scene D's default plan, housing and preserve tiles apart.
include("cmp_lib")
local scn, w, request = CmpRun.Setup("S01-rome-temperate-mid")
include("MapTacks")
for _, n in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
  "SDP_Coverage", "SDP_Search", "SDP_Solver" }) do include(n) end
w.Events.LoadGameViewStateDone()
local r = SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Weights = { LAND = 1, HOUSING = 1 }, Land = true,
  Districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_NEIGHBORHOOD", "DISTRICT_PRESERVE" },
  Tier = "STANDARD", Auto = { DISTRICT_AQUEDUCT = true, DISTRICT_BATH = true, DISTRICT_DAM = true } })
local model = r.Session.Search.AppealModel
for g, c in pairs(model.Cities) do
  print(string.format("city %s housing before %.2f target %d", tostring(g), c.Housing, c.Target))
end
for _, p in ipairs(r.Plan) do
  local t = {}
  for k, v in pairs(p.Tiles or {}) do t[#t + 1] = k:gsub("YIELD_", "") .. "+" .. v end
  table.sort(t)
  print(string.format("  %-24s appeal %s housing %s tiles %s counted %s", p.Type, tostring(p.Appeal), tostring(p.Housing),
    table.concat(t, " "), tostring(p.TilesCounted)))
end
print(string.format("gain %.3f adjacency %.3f land %.3f appeal %.3f", r.Gain, r.Adjacency, r.LandDelta, r.AppealDelta))
local land = r.Session.Land
print(string.format("P %d workable %d", land.P, #land.Plots))
