-- @state GameCore_Tuner
-- A pillaged farm and a bare tile beside it, both flat land a farm can go on
-- (Improvement_ValidTerrains) without feature or resource, within three
-- rings of the capital, for the land part's pillaged improvements (tests/test_pillaged.lua, issue 345).
-- Picks the first such pair by plot index of the same terrain and remembers
-- the farm in a game property; pillage_teardown.lua takes it off again.
local city = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local farm = GameInfo.Improvements["IMPROVEMENT_FARM"]
-- Terrains a farm can go on, from the rules (issue 353: Rise and Fall's test
-- map gave a flat pair a farm cannot go on, so the bare one had no farm value).
local farmTerrain = {}
for row in GameInfo.Improvement_ValidTerrains() do
  if row.ImprovementType == farm.ImprovementType then farmTerrain[GameInfo.Terrains[row.TerrainType].Index] = true end
end
local function Bare(p)
  return p ~= nil and not p:IsWater() and not p:IsHills() and not p:IsMountain() and not p:IsNaturalWonder()
    and not p:IsCity() and p:GetResourceType() == -1 and p:GetFeatureType() == -1 and p:GetImprovementType() == -1
    and p:GetDistrictType() == -1 and farmTerrain[p:GetTerrainType()] == true
end
local list = {}
for dx = -3, 3 do
  for dy = -3, 3 do
    local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
    if Bare(p) then list[#list + 1] = p end
  end
end
table.sort(list, function(a, b) return a:GetIndex() < b:GetIndex() end)
for _, a in ipairs(list) do
  for _, b in ipairs(list) do
    if a ~= b and a:GetTerrainType() == b:GetTerrainType() and a:IsFreshWater() == b:IsFreshWater() and a:IsRiver() == b:IsRiver() then
      ImprovementBuilder.SetImprovementType(a, farm.Index, Game.GetLocalPlayer())
      ImprovementBuilder.SetImprovementPillaged(a, true)
      Game:SetProperty("SDP_TEST_PILLAGED", a:GetIndex())
      Game:SetProperty("SDP_TEST_PILLAGED_BARE", b:GetIndex())
      print("SDP_PILLAGED", a:GetX(), a:GetY(), "bare", b:GetX(), b:GetY())
      return
    end
  end
end
error("no two bare flat tiles of one farmable terrain three rings from the capital")
