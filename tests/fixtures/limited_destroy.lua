-- @state GameCore_Tuner
-- Teardown for limited_prepare.lua: remove the capital's empire-limited
-- district again (the technology and civic stay unlocked).
local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
local types = {}
for row in GameInfo.Districts() do
  if row.MaxPerPlayer ~= nil and row.MaxPerPlayer > 0 and row.TraitType == nil then types[#types + 1] = row.DistrictType end
end
table.sort(types)
local district = city ~= nil and #types > 0 and city:GetDistricts():GetDistrict(GameInfo.Districts[types[1]].Index) or nil
if district ~= nil then
  CityManager.DestroyDistrict(district)
  print(types[1] .. " removed")
end
