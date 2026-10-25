-- Screenshot stage: the One city tab on the capital (tools/shots.py stage single).
-- Campus a Must, 3 districts, Standard; the other settings stay at their defaults.
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
SDP_Panel.Open()
SDP_Panel.SelectTab("SINGLE")
SDP_Panel.SelectCity(city:GetID())
SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
SDP_Panel.SetCount(3)
SDP_Panel.SetTier("STANDARD")
SDP_Panel.Solve()
local r = SDP_Panel.RunTask(5000)
print("STAGED single", r and r.Ok, r and #r.Plan)
