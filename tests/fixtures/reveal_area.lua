-- Reveal the plots within 12 of the local player's capital, as if explored.
-- On turn 1 only the capital's own surroundings are revealed, and a city
-- site needs most of its rings revealed (SDP_Sites.Candidates), so the site
-- and multi-city tests run this first. Seeing a plot once leaves it revealed.
--   python3 -I tools/civ6tuner.py exec -s GameCore_Tuner -f tests/fixtures/reveal_area.lua
local pid = Game.GetLocalPlayer()
local capital = Players[pid]:GetCities():GetCapitalCity()
if capital == nil then
  print("no capital")
  return
end
local visibility = PlayersVisibility[pid]
local revealed = 0
for index = 0, Map.GetPlotCount() - 1 do
  local plot = Map.GetPlotByIndex(index)
  if Map.GetPlotDistance(plot:GetX(), plot:GetY(), capital:GetX(), capital:GetY()) <= 12
      and not visibility:IsRevealed(index) then
    visibility:ChangeVisibilityCount(index, 1)
    visibility:ChangeVisibilityCount(index, -1)
    revealed = revealed + 1
  end
end
print("revealed", revealed)
