-- @state GameCore_Tuner
-- Undo camp_setup.lua: take off the deer it put down (the tile it
-- remembered); natural deer stay.
local index = Game:GetProperty("SDP_TEST_DEER")
if index == nil then return end
local p = Map.GetPlotByIndex(index)
if p ~= nil then
  ResourceBuilder.SetResourceType(p, -1)
  print("deer removed at", p:GetX(), p:GetY())
end
Game:SetProperty("SDP_TEST_DEER", nil)
