-- @state GameCore_Tuner
-- Step 1 of building a district the empire may have only one of
-- (Districts.MaxPerPlayer > 0, e.g. the Government Plaza) the way the player
-- does (AGENTS pitfall 36): unlock its technology and civic. The district is
-- the first such type without a civilization trait, by type name (the same
-- choice in limited_order.lua, limited_finish.lua, limited_destroy.lua and
-- tests/test_unique.lua). Nothing to do in a ruleset without one.
local player = Players[Game.GetLocalPlayer()]
if player:GetCities():GetCapitalCity() == nil then error("no capital: run found_capital.lua first") end
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
if row.PrereqTech ~= nil then player:GetTechs():SetTech(GameInfo.Technologies[row.PrereqTech].Index, true) end
if row.PrereqCivic ~= nil then player:GetCulture():SetCivic(GameInfo.Civics[row.PrereqCivic].Index, true) end
print("prepared " .. row.DistrictType)
