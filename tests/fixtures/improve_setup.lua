-- @state GameCore_Tuner
-- For tests/test_improve.lua (issue 227): a resource that takes an
-- improvement giving a district adjacency one for one (the first such
-- District_Adjacencies row by table order, e.g. a Quarry next to an
-- Industrial Zone; a bonus resource the improvement can go on) on a bare
-- land tile two rings from the capital. Remembers the tile in a game
-- property; improve_teardown.lua takes the resource off again.
local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local resource = nil
for link in GameInfo.District_Adjacencies() do
  local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
  if resource == nil and row ~= nil and row.AdjacentImprovement ~= nil and (row.TilesRequired or 1) == 1 then
    for r in GameInfo.Improvement_ValidResources() do
      local res = GameInfo.Resources[r.ResourceType]
      if resource == nil and r.ImprovementType == row.AdjacentImprovement and res ~= nil
          and res.ResourceClassType == "RESOURCECLASS_BONUS" then
        resource = res
      end
    end
  end
end
if resource == nil then
  print("no improvement gives a district adjacency one for one in this ruleset")
  return
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
ResourceBuilder.SetResourceType(best, resource.Index, 1)
Game:SetProperty("SDP_TEST_IMPROVE", best:GetIndex())
print("SDP_IMPROVE", resource.ResourceType, best:GetX(), best:GetY())
