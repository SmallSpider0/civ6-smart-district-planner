-- @state GameCore_Tuner
-- Remove the capital's campus again (teardown for build_campus.lua).
local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
local district = city and city:GetDistricts():GetDistrict(GameInfo.Districts["DISTRICT_CAMPUS"].Index)
if district ~= nil then
  CityManager.DestroyDistrict(district)
  print("campus removed")
end
