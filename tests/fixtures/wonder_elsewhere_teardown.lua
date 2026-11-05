-- @state GameCore_Tuner
-- Remove the wonder wonder_elsewhere.lua built for another civ.
local me = Game.GetLocalPlayer()
for index = 0, Map.GetPlotCount() - 1 do
  local plot = Map.GetPlotByIndex(index)
  local owner = plot:GetOwner()
  local wonder = plot:GetWonderType()
  if wonder ~= -1 and owner ~= -1 and owner ~= me then
    local city = Cities.GetPlotPurchaseCity(plot)
    if city ~= nil then
      -- Read the type before removing it: the plot forgets it.
      local name = GameInfo.Buildings[wonder].BuildingType
      city:GetBuildings():RemoveBuilding(wonder)
      print("removed " .. name .. " at " .. plot:GetX() .. "," .. plot:GetY())
    end
  end
end
