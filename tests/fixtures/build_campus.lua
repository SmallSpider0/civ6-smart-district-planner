-- @state GameCore_Tuner
-- Build a finished campus next to the local player's capital (game core
-- API, so the UI sees a real built district). Used as a test @setup; undo
-- with destroy_campus.lua.
local player = Players[Game.GetLocalPlayer()]
local city = player:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local campus = GameInfo.Districts["DISTRICT_CAMPUS"].Index
if city:GetDistricts():HasDistrict(campus) then
  print("campus already built")
  return
end
-- Prefer a bare land plot next to the city; else allow a feature (woods...);
-- else look one ring further out.
local function Usable(plot, allowFeature)
  return plot ~= nil and not plot:IsWater() and not plot:IsImpassable() and not plot:IsNaturalWonder()
    and plot:GetResourceType() == -1 and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1
    and (allowFeature or plot:GetFeatureType() == -1)
end
for _, pass in ipairs({ { 1, false }, { 1, true }, { 2, true } }) do
  local ring, allowFeature = pass[1], pass[2]
  for dx = -ring, ring do
    for dy = -ring, ring do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, ring)
      if plot ~= nil and Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY()) == ring
          and Usable(plot, allowFeature) then
        city:GetBuildQueue():CreateDistrict(campus, plot:GetIndex())
        print("campus built at", plot:GetX(), plot:GetY())
        return
      end
    end
  end
end
error("no usable land plot within two rings of the capital")
