-- @state GameCore_Tuner
-- Step 3 (see limited_prepare.lua): finish what the capital is building,
-- the district ordered in step 2. When the order did not place it, place it
-- with the build queue instead (see below) and say so.
local player = Players[Game.GetLocalPlayer()]
local city = player:GetCities():GetCapitalCity()
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
-- The order places the district at once (not finished); finish it.
local district = city:GetDistricts():GetDistrict(row.Index)
if district ~= nil and district:IsComplete() then
  print(row.DistrictType .. " already finished in the capital")
  return
end
if district == nil then
  -- 2026-10-27, Gathering Storm on the fixed test map: the order of step 2
  -- did not reach the game core. Say what the core has, then place the
  -- district with the build queue on a ring-1 tile without a feature or a
  -- resource, where placing it directly changes nothing the normal way
  -- would not (AGENTS pitfall 36 is about features and the checks it skips).
  local culture = player:GetCulture()
  print("the order did not place " .. row.DistrictType .. "; the game core has the civic: "
    .. tostring(row.PrereqCivic == nil or culture:HasCivic(GameInfo.Civics[row.PrereqCivic].Index))
    .. "; population " .. city:GetPopulation())
  local plots = {}
  for dx = -1, 1 do
    for dy = -1, 1 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 1)
      if plot ~= nil and Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY()) == 1
          and plot:GetOwner() == player:GetID() and not plot:IsWater() and not plot:IsImpassable()
          and not plot:IsNaturalWonder() and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1
          and plot:GetResourceType() == -1 and plot:GetFeatureType() == -1 then
        plots[#plots + 1] = plot
      end
    end
  end
  table.sort(plots, function(a, b) return a:GetIndex() < b:GetIndex() end)
  if #plots == 0 then error(row.DistrictType .. " was not placed and no bare ring-1 tile is left") end
  city:GetBuildQueue():CreateDistrict(row.Index, plots[1]:GetIndex())
  print("placed " .. row.DistrictType .. " at " .. plots[1]:GetX() .. "," .. plots[1]:GetY() .. " with the build queue")
else
  city:GetBuildQueue():FinishProgress()
end
district = city:GetDistricts():GetDistrict(row.Index)
if district == nil then error(row.DistrictType .. " was not placed: see the output above") end
print("finished " .. row.DistrictType .. ": " .. tostring(district:IsComplete()))
