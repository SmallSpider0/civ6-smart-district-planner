-- @state GameCore_Tuner
-- Undo wonder_elsewhere.lua: remove the wonder it built (the plot it
-- remembered); other civs' wonders stay. Nothing to do when the setup
-- built none.
local index = Game:GetProperty("SDP_TEST_WONDER_ELSEWHERE")
if index == nil then return end
Game:SetProperty("SDP_TEST_WONDER_ELSEWHERE", nil)
local plot = Map.GetPlotByIndex(index)
local wonder = plot ~= nil and plot:GetWonderType() or -1
local city = wonder ~= -1 and Cities.GetPlotPurchaseCity(plot) or nil
if city ~= nil then
  -- Read the type before removing it: the plot forgets it.
  local name = GameInfo.Buildings[wonder].BuildingType
  city:GetBuildings():RemoveBuilding(wonder)
  print("removed " .. name .. " at " .. plot:GetX() .. "," .. plot:GetY())
end
