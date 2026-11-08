-- @state GameCore_Tuner
-- Undo pillage_setup.lua: take off the pillaged farm it put down.
local index = Game:GetProperty("SDP_TEST_PILLAGED")
if index == nil then return end
local p = Map.GetPlotByIndex(index)
if p ~= nil then
  ImprovementBuilder.SetImprovementType(p, -1)
  print("pillaged farm removed at", p:GetX(), p:GetY())
end
Game:SetProperty("SDP_TEST_PILLAGED", nil)
Game:SetProperty("SDP_TEST_PILLAGED_BARE", nil)
