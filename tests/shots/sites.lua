-- Screenshot stage: the City sites tab (tools/shots.py stage sites).
-- 5 districts, each site scored with 3, Standard.
local sites = SDP_Panel.Sites
SDP_Panel.Open()
SDP_Panel.SelectTab("SITES")
sites.SetCount(3)
for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_THEATER",
  "DISTRICT_INDUSTRIAL_ZONE" }) do sites.SetSelected(d, true) end
sites.SetTier("STANDARD")
sites.Solve()
SDP_Panel.RunTask(5000)
local r = sites.State().Result
print("STAGED sites", r and r.Ok, r and #r.Solutions)
