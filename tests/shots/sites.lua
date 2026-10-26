-- Screenshot stage: the City sites tab (tools/shots.py stage sites).
-- The default district grid (issue 90: candidates, 3 per site), Standard.
local sites = SDP_Panel.Sites
SDP_Panel.Open()
SDP_Panel.SelectTab("SITES")
sites.SetCount(3)
for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do sites.SetState(d.Type, sites.DefaultState(d)) end
sites.SetDistrictCount(3)
sites.SetTier("STANDARD")
sites.Solve()
SDP_Panel.RunTask(5000)
local r = sites.State().Result
print("STAGED sites", r and r.Ok, r and #r.Solutions)
