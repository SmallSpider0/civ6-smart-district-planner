-- Probe (issue 216): run in the SDP_Panel state after `shots.py stage
-- settings`. Scrolls the settings to the district grid and prints, for every
-- district cell, where its name ends and where its state starts (x in the
-- cell, 156 wide) and how tall each is; a line OVERLAP when the name runs
-- into the state, TALL when the name or the state is taller than the cell
-- plus 6 (wrapped into more lines than the cell holds: on 2026-11-03 the
-- state wrapped one letter a line and this probe still said OVERLAPS 0).
--   python3 -I tools/civ6tuner.py exec -s SDP_Panel -f tests/bench/probe_cells.lua
Controls.SettingsScroll:SetScrollValue(1)
local overlaps, tall = 0, 0
for _, r in ipairs(SDP_Panel.State().DistrictRows) do
  local inst = r.Inst
  local selected = not inst.NameDark:IsHidden()
  local name = selected and inst.NameDark or inst.Name
  local state = selected and inst.StateDark or inst.State
  local nameEnd = 30 + name:GetSizeX()
  local stateStart = inst.Root:GetSizeX() - 12 - state:GetSizeX()
  local limit = inst.Root:GetSizeY() + 6
  print("CELL", r.Type, name:GetText(), state:GetText(), nameEnd, stateStart, name:GetSizeY(), state:GetSizeY())
  if nameEnd > stateStart then
    overlaps = overlaps + 1
    print("OVERLAP", r.Type)
  end
  if name:GetSizeY() > limit or state:GetSizeY() > limit then
    tall = tall + 1
    print("TALL", r.Type)
  end
end
print("CELLS", #SDP_Panel.State().DistrictRows, "OVERLAPS", overlaps, "TALL", tall)
