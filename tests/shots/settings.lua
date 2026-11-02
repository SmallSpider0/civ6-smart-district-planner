-- Screenshot stage: the One city tab with its settings open and every wonder
-- that can be chosen ticked (tools/shots.py stage settings), so the settings
-- scroll in their own box and the Solve button stays in the panel (issue 199).
local pid = Game.GetLocalPlayer()
SDP_Panel.Open()
SDP_Panel.SelectTab("SINGLE")
SDP_Panel.SetFold(false)
local n = 0
for _, w in ipairs(SDP_Wonders.List(pid, nil)) do
  if w.Status == nil then SDP_Panel.SetWonder(w.Type, true); n = n + 1 end
end
SDP_Panel.FitWindow()
print("STAGED settings", n, Controls.SettingsScroll:GetSizeY(), Controls.SettingsStack:GetSizeY(), Controls.SinglePage:GetSizeY())
