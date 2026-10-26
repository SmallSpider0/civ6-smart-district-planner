-- @state InGame
-- Step 2 (see limited_prepare.lua): order the district in the capital on the
-- first tile, nearest ring first and then by tile index, where the game lets
-- the city start it (CityManager.CanStartOperation).
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local types = {}
for row in GameInfo.Districts() do
  if row.MaxPerPlayer ~= nil and row.MaxPerPlayer > 0 and row.TraitType == nil then types[#types + 1] = row.DistrictType end
end
table.sort(types)
if #types == 0 then
  print("no empire-limited district in this ruleset")
  return
end
local row = GameInfo.Districts[types[1]]
for _, district in Players[pid]:GetDistricts():Members() do
  if district:GetType() == row.Index then
    print(row.DistrictType .. " already built")
    return
  end
end
local plots = {}
for dx = -3, 3 do
  for dy = -3, 3 do
    local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
    if plot ~= nil then
      local ring = Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY())
      if ring > 0 then plots[#plots + 1] = { Ring = ring, Plot = plot } end
    end
  end
end
table.sort(plots, function(a, b)
  if a.Ring ~= b.Ring then return a.Ring < b.Ring end
  return a.Plot:GetIndex() < b.Plot:GetIndex()
end)
for _, entry in ipairs(plots) do
  local t = {}
  t[CityOperationTypes.PARAM_X] = entry.Plot:GetX()
  t[CityOperationTypes.PARAM_Y] = entry.Plot:GetY()
  t[CityOperationTypes.PARAM_DISTRICT_TYPE] = row.Hash
  t[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE
  if CityManager.CanStartOperation(city, CityOperationTypes.BUILD, t) then
    CityManager.RequestOperation(city, CityOperationTypes.BUILD, t)
    print("ordered " .. row.DistrictType .. " at " .. entry.Plot:GetX() .. "," .. entry.Plot:GetY())
    return
  end
end
error("the capital cannot start " .. row.DistrictType .. " on any tile within three rings")
