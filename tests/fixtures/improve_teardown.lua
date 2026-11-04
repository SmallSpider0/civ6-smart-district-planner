-- @state GameCore_Tuner
-- Undo improve_setup.lua: take off the resource it put down.
local index = Game:GetProperty("SDP_TEST_IMPROVE")
if index == nil then return end
local p = Map.GetPlotByIndex(index)
if p ~= nil then
  ResourceBuilder.SetResourceType(p, -1)
  print("resource removed at", p:GetX(), p:GetY())
end
Game:SetProperty("SDP_TEST_IMPROVE", nil)
