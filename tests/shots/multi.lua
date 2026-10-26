-- Screenshot stage: the Several cities tab (tools/shots.py stage multi).
-- Places the City sites tab's plan as site tacks first (stage sites), then
-- the default group (capital and the three sites), shared list with Campus,
-- Holy Site and Commercial Hub as Musts, 3 per city, Fast, and the Temple of
-- Artemis (Rise and Fall, Gathering Storm), whose Camp the result shows. The
-- result list is scrolled so the temple's row and the Camp's row are in view.
local sites = SDP_Panel.Sites
if sites.State().Result == nil then
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  sites.SetCount(3)
  sites.SetTier("STANDARD")
  sites.Solve()
  SDP_Panel.RunTask(5000)
end
print("placed", sites.Place())
SDP_Panel.Open()
SDP_Panel.SelectTab("MULTI")
local multi = SDP_Panel.Multi
multi.Refresh()
for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }) do multi.SetSelected(d, true) end
local wonder = GameInfo.Buildings["BUILDING_TEMPLE_ARTEMIS"] and "BUILDING_TEMPLE_ARTEMIS" or "BUILDING_GREAT_LIBRARY"
multi.SetWonder(wonder, true)
multi.SetTier("FAST")
multi.Solve()
SDP_Panel.RunTask(20000)
local r = multi.State().Result

-- Scroll the result list to the wonder's row: rows are the stack's shown
-- children, top to bottom, 2 px apart (StackPadding in SDP_Panel.xml).
local name = Locale.Lookup(GameInfo.Buildings[wonder].Name)
local top, total, at = 0, 0, nil
for _, c in ipairs(Controls.MultiResultStack:GetChildren()) do
  if not c:IsHidden() then
    local found = false
    local function scan(control, depth)
      local ok, text = pcall(function() return control:GetText() end)
      if ok and text and text:find(name, 1, true) then found = true end
      if depth < 5 then
        local ok2, kids = pcall(function() return control:GetChildren() end)
        if ok2 and kids then for _, k in ipairs(kids) do scan(k, depth + 1) end end
      end
    end
    scan(c, 0)
    if found and at == nil then at = total end
    total = total + c:GetSizeY() + 2
  end
end
local view = Controls.MultiResultScroll:GetSizeY()
if at ~= nil and total > view then
  Controls.MultiResultScroll:SetScrollValue(math.min(1, math.max(0, (at - 4) / (total - view))))
end
print("STAGED multi", r and r.Ok, r and #r.Solutions, wonder, at, total, view)
