-- @state GameCore_Tuner
-- Undo traits_setup.lua: the plots it gave the capital belong to nobody again.
local data = Game:GetProperty("SDP_TEST_TRAIT_PLOTS")
if data == nil then return end
local count = 0
for index in data:gmatch("(%d+):") do
  local p = Map.GetPlotByIndex(tonumber(index))
  if p ~= nil then
    WorldBuilder.CityManager():SetPlotOwner(p:GetX(), p:GetY(), false)
    count = count + 1
  end
end
Game:SetProperty("SDP_TEST_TRAIT_PLOTS", nil)
print("SDP_TRAIT_PLOTS released", count)
