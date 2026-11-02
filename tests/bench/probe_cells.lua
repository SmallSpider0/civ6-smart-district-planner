-- Probe (issue 216): run in the SDP_Panel state after `shots.py stage
-- settings`. Scrolls the settings to the district grid and prints, for every
-- district cell, where its name ends and where its state starts (x in the
-- cell, 156 wide); a line OVERLAP when the name runs into the state.
--   python3 -I tools/civ6tuner.py exec -s SDP_Panel -f tests/bench/probe_cells.lua
Controls.SettingsScroll:SetScrollValue(1)
local overlaps = 0
for _, r in ipairs(SDP_Panel.State().DistrictRows) do
  local inst = r.Inst
  local selected = not inst.NameDark:IsHidden()
  local name = selected and inst.NameDark or inst.Name
  local state = selected and inst.StateDark or inst.State
  local nameEnd = 30 + name:GetSizeX()
  local stateStart = inst.Root:GetSizeX() - 12 - state:GetSizeX()
  print("CELL", r.Type, name:GetText(), state:GetText(), nameEnd, stateStart)
  if nameEnd > stateStart then
    overlaps = overlaps + 1
    print("OVERLAP", r.Type)
  end
end
print("CELLS", #SDP_Panel.State().DistrictRows, "OVERLAPS", overlaps)
