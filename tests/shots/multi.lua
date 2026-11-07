-- Screenshot stage: the Several cities tab (tools/shots.py stage multi).
-- Places the City sites tab's plan as site tacks first (stage sites), then
-- the default group (capital and the three sites), shared list with Campus,
-- Holy Site and Commercial Hub as Musts, the capital's own list with Campus,
-- Commercial Hub and Industrial Zone, 3 per city, Fast, and the Temple of
-- Artemis (Rise and Fall, Gathering Storm), whose Camp the result shows. The
-- result list is scrolled so the temple's row and the Camp's row are in view.
-- shots.py put the panel back to its defaults first: the sites are solved here.
local sites = SDP_Panel.Sites
SDP_Panel.Open()
SDP_Panel.SelectTab("SITES")
sites.SetCount(3)
sites.SetDistrictCount(3)
sites.SetTier("STANDARD")
sites.Solve()
SDP_Panel.RunTask(5000)
print("placed", sites.Place())
SDP_Panel.Open()
SDP_Panel.SelectTab("MULTI")
local multi = SDP_Panel.Multi
multi.Refresh()
for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }) do multi.SetSelected(d, true) end
-- The capital gets its own list (Industrial Zone a Must instead of the Holy
-- Site) and stays the list shown, so the back button to the shared list is in
-- view (issue 187).
local capital = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
multi.SetPlanFor("C" .. capital:GetID())
multi.SetSelected("DISTRICT_HOLY_SITE", false)
multi.SetSelected("DISTRICT_INDUSTRIAL_ZONE", true)
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
