-- @state GameCore_Tuner
-- Step 3 (see limited_prepare.lua): finish what the capital is building,
-- the district ordered in step 2. An error when it was not placed at all.
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
city:GetBuildQueue():FinishProgress()
district = city:GetDistricts():GetDistrict(row.Index)
if district == nil then
  error(row.DistrictType .. " was not placed: see limited_order.lua's output")
end
print("finished " .. row.DistrictType .. ": " .. tostring(district:IsComplete()))
