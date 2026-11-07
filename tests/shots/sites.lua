-- Screenshot stage: the City sites tab (tools/shots.py stage sites).
-- The default district grid (issue 90: candidates, 3 per site; shots.py put
-- the panel back to its defaults first), Standard.
local sites = SDP_Panel.Sites
SDP_Panel.Open()
SDP_Panel.SelectTab("SITES")
sites.SetCount(3)
sites.SetDistrictCount(3)
sites.SetTier("STANDARD")
sites.Solve()
SDP_Panel.RunTask(5000)
local r = sites.State().Result
print("STAGED sites", r and r.Ok, r and #r.Solutions)
