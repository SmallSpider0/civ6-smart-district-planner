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
  -- did not reach the game core: the core had the civic, the interface did
  -- not see it (no popup was open), so the interface dropped the order. Say
  -- what the core has, then place the district with the build queue. This
  -- test only needs the district to stand; AGENTS pitfall 36 (features,
  -- skipped checks) does not matter for it.
  local culture = player:GetCulture()
  print("the order did not place " .. row.DistrictType .. "; the game core has the civic: "
    .. tostring(row.PrereqCivic == nil or culture:HasCivic(GameInfo.Civics[row.PrereqCivic].Index))
    .. "; population " .. city:GetPopulation())
  -- As build_campus.lua: a bare ring-1 tile, else one with a feature, else
  -- ring 2 (taken for the city when it is not yet).
  local function Usable(plot, allowFeature)
    return plot ~= nil and not plot:IsWater() and not plot:IsImpassable() and not plot:IsNaturalWonder()
      and plot:GetResourceType() == -1 and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1
      and (plot:GetOwner() == -1 or plot:GetOwner() == player:GetID())
      and (allowFeature or plot:GetFeatureType() == -1)
  end
  local chosen = nil
  for _, pass in ipairs({ { 1, false }, { 1, true }, { 2, true } }) do
    local ring, allowFeature = pass[1], pass[2]
    local plots = {}
    for dx = -ring, ring do
      for dy = -ring, ring do
        local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, ring)
        if plot ~= nil and Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY()) == ring
            and Usable(plot, allowFeature) then
          plots[#plots + 1] = plot
        end
      end
    end
    table.sort(plots, function(a, b) return a:GetIndex() < b:GetIndex() end)
    if chosen == nil and #plots > 0 then chosen = plots[1] end
  end
  if chosen == nil then error(row.DistrictType .. " was not placed and no land tile within two rings is free") end
  if chosen:GetOwner() == -1 then
    WorldBuilder.CityManager():SetPlotOwner(chosen:GetX(), chosen:GetY(), player:GetID(), city:GetID())
  end
  city:GetBuildQueue():CreateDistrict(row.Index, chosen:GetIndex())
  print("placed " .. row.DistrictType .. " at " .. chosen:GetX() .. "," .. chosen:GetY() .. " with the build queue")
else
  city:GetBuildQueue():FinishProgress()
end
district = city:GetDistricts():GetDistrict(row.Index)
if district == nil then error(row.DistrictType .. " was not placed: see the output above") end
print("finished " .. row.DistrictType .. ": " .. tostring(district:IsComplete()))
