-- Probe (issue 216): run in the SDP_Panel state after `shots.py stage
-- settings`. Scrolls the settings to the district grid and prints, for every
-- district cell, where its name ends and where its state starts (x in the
-- cell, 156 wide) and how tall each is; a line OVERLAP when the name runs
-- into the state, TALL when the name or the state is taller than the cell
-- plus 6 (wrapped into more lines than the cell holds: on 2026-11-03 the
-- state wrapped one letter a line and this probe still said OVERLAPS 0),
-- MIDWORD when a wrapped name is narrower than one of its words, so the game
-- broke that word in two ("Encampme / nt", 2026-11-03), and TRUNCATED (not
-- counted as a failure: the full name is the tooltip) when the name is cut.
-- Words are runs of non-space characters without multi-byte ones: a Chinese
-- name may wrap anywhere (a byte loop: the game's Lua matches no byte with a
-- pattern such as "[\128-\255]").
--   python3 -I tools/civ6tuner.py exec -s SDP_Panel -f tests/bench/probe_cells.lua
Controls.SettingsScroll:SetScrollValue(1)
local NO_WRAP = 4096
local overlaps, tall, midword, truncated = 0, 0, 0, 0
for _, r in ipairs(SDP_Panel.State().DistrictRows) do
  local inst = r.Inst
  local selected = not inst.NameDark:IsHidden()
  local name = selected and inst.NameDark or inst.Name
  local state = selected and inst.StateDark or inst.State
  local text = name:GetText()
  local nameWidth, nameHeight = name:GetSizeX(), name:GetSizeY()
  local nameEnd = 30 + nameWidth
  local stateStart = inst.Root:GetSizeX() - 12 - state:GetSizeX()
  local limit = inst.Root:GetSizeY() + 6
  local cut = name.IsTextTruncated ~= nil and name:IsTextTruncated()
  -- Measure each word on the name's own label at its font size; the cells
  -- are drawn again below.
  local widest, widestWord, lineHeight = 0, "", nil
  name:SetTruncateWidth(0)
  name:SetWrapWidth(NO_WRAP)
  for word in text:gmatch("%S+") do
    local ascii = true
    for i = 1, #word do
      if word:byte(i) >= 128 then ascii = false end
    end
    if ascii then
      name:SetText(word)
      if name:GetSizeX() > widest then widest, widestWord = name:GetSizeX(), word end
      lineHeight = lineHeight or name:GetSizeY()
    end
  end
  print("CELL", r.Type, text, state:GetText(), nameEnd, stateStart, nameHeight, state:GetSizeY(), widestWord, widest)
  if nameEnd > stateStart then
    overlaps = overlaps + 1
    print("OVERLAP", r.Type)
  end
  if nameHeight > limit or state:GetSizeY() > limit then
    tall = tall + 1
    print("TALL", r.Type)
  end
  if cut then
    truncated = truncated + 1
    print("TRUNCATED", r.Type)
  elseif lineHeight ~= nil and nameHeight > lineHeight * 1.5 and widest > nameWidth + 1 then
    midword = midword + 1
    print("MIDWORD", r.Type, widestWord, widest, nameWidth)
  end
end
-- Draw the cells again (no setting changes: a wonder that is not there).
SDP_Panel.SetWonder("SDP_PROBE_NO_WONDER", false)
Controls.SettingsScroll:SetScrollValue(1)
print("CELLS", #SDP_Panel.State().DistrictRows, "OVERLAPS", overlaps, "TALL", tall, "MIDWORD", midword, "TRUNCATED", truncated)
