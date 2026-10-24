-- @state GameCore_Tuner
-- Deer on a bare land tile two rings from the capital, for the Temple of
-- Artemis test (tests/test_support.lua, issue 51): a tile a Camp can go on.
-- Picks the first such tile by plot index and remembers it in a game
-- property; camp_teardown.lua takes it off again.
-- Does nothing when the ruleset has no Temple of Artemis (the base game).
local temple = GameInfo.Buildings["BUILDING_TEMPLE_ARTEMIS"]
if temple == nil then
  print("no Temple of Artemis in this ruleset")
  return
end
local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local deer = GameInfo.Resources["RESOURCE_DEER"]
for dx = -2, 2 do
  for dy = -2, 2 do
    local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 2)
    if p ~= nil and p:GetResourceType() == deer.Index then
      print("deer already at", p:GetX(), p:GetY())
      return
    end
  end
end
local best = nil
for dx = -2, 2 do
  for dy = -2, 2 do
    local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 2)
    if p ~= nil and Map.GetPlotDistance(city:GetX(), city:GetY(), p:GetX(), p:GetY()) == 2 and not p:IsWater()
        and not p:IsMountain() and not p:IsNaturalWonder() and p:GetResourceType() == -1 and p:GetFeatureType() == -1
        and p:GetImprovementType() == -1 and p:GetDistrictType() == -1 and (best == nil or p:GetIndex() < best:GetIndex()) then
      best = p
    end
  end
end
if best == nil then error("no bare land tile two rings from the capital") end
ResourceBuilder.SetResourceType(best, deer.Index, 1)
Game:SetProperty("SDP_TEST_DEER", best:GetIndex())
print("SDP_DEER", best:GetX(), best:GetY())
