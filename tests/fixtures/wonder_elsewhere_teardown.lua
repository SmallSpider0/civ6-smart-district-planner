-- @state GameCore_Tuner
-- Remove the wonder wonder_elsewhere.lua built for another civ.
local me = Game.GetLocalPlayer()
for index = 0, Map.GetPlotCount() - 1 do
  local plot = Map.GetPlotByIndex(index)
  local owner = plot:GetOwner()
  if plot:GetWonderType() ~= -1 and owner ~= -1 and owner ~= me then
    local city = Cities.GetPlotPurchaseCity(plot)
    if city ~= nil then
      city:GetBuildings():RemoveBuilding(plot:GetWonderType())
      print("removed " .. GameInfo.Buildings[plot:GetWonderType()].BuildingType .. " at " .. plot:GetX() .. "," .. plot:GetY())
    end
  end
end
